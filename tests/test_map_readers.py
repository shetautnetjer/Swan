#!/usr/bin/env python3
"""Bounded reader regressions against an explicit Swan binary (Linux).

Only a new temporary fixture directory is changed. No indexers, live servers,
trust operations, builds or installations run. Uses the protocol/timeout
helpers in check_concurrency.py. Artifacts are retained for inspection.

python3 tests/test_map_readers.py --binary /absolute/bin/swan --output-parent /tmp
"""

import argparse
from contextlib import closing
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

from check_concurrency import MCP, child_environment, connect, require


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--output-parent", type=Path, required=True)
    parser.add_argument("--timeout", type=float, default=15)
    options = parser.parse_args()
    binary = options.binary.resolve(strict=True)
    directory = Path(tempfile.mkdtemp(prefix="swan-readers-", dir=options.output_parent)).resolve()
    repo, rows = directory / "repo", directory / "rows"
    repo.mkdir()
    rows.mkdir()
    database = directory / "swan.db"
    source = repo / "A.ts"
    body = "function probe() { return 1; }"
    source.write_text(body + "\n")
    symbol = "scip-typescript npm reader-fixture 0.0.0 probe()."
    (rows / "symbols.tsv").write_text(f"{symbol}\tprobe\t17\t\t{body}\n")
    (rows / "extents.tsv").write_text(f"{symbol}\tA.ts\t0\t0\t0\t{len(body)}\n")
    (rows / "occurrences.tsv").write_text(f"{symbol}\tA.ts\t0\t9\t0\t14\tdef\n")
    (rows / "relationships.tsv").write_text("")
    marker = rows / "scip-started"
    marker.write_text("")
    # Deliberate ordering, all in the past: no sleeps or filesystem timestamp
    # guessing. Later Swan edits must be newer than the refreshed SCIP time.
    anchor = time.time_ns()
    initial_source, initial_map = anchor - 20_000_000_000, anchor - 15_000_000_000
    external_source, refreshed_map = anchor - 10_000_000_000, anchor - 5_000_000_000
    os.utime(source, ns=(initial_source, initial_source))
    os.utime(marker, ns=(initial_map, initial_map))
    results = []

    def command(name):
        result = subprocess.run([str(binary), name, str(rows), str(database), str(repo)],
            capture_output=True, text=True, timeout=options.timeout, env=child_environment())
        require(result.returncode == 0, result.stdout + result.stderr)

    def metadata(key):
        with closing(connect(database)) as connection:
            return connection.execute("SELECT value FROM meta WHERE key=?", (key,)).fetchone()[0]

    command("index")
    require(int(metadata("scip_time")) == initial_map, "fixture SCIP time did not use explicit marker")
    client = MCP(binary, database, directory, options.timeout)

    def call(name, arguments):
        answer = client.request("tools/call", {"name": name, "arguments": arguments})
        require("result" in answer, "unexpected protocol error: " + repr(answer))
        result = answer["result"]
        return result.get("isError", False), result["content"][0]["text"]

    def probe(stale=False):
        failed, text = call("find_symbol", {"name_path_pattern": "probe", "include_body": True})
        require(not failed, text)
        found = json.loads(text)
        require(len(found) == 1 and found[0]["relative_path"] == "A.ts", "missing/wrong symbol: " + text)
        require(found[0].get("stale", False) is stale, "wrong freshness: " + text)
        return found[0]

    try:
        probe()
        # Outside edit, then actual external refresh in another process. Both
        # queries use the same already-running server.
        os.utime(source, ns=(external_source, external_source))
        probe(stale=True)
        os.utime(marker, ns=(refreshed_map, refreshed_map))
        command("refresh")
        require(int(metadata("scip_time")) == refreshed_map, "refresh did not publish new SCIP time")
        require(source.stat().st_mtime_ns < refreshed_map, "invalid fresh-source barrier")
        probe()
        results.append("external refresh reloads SCIP freshness in the existing server")

        # Real edits, not manually planted freshness metadata: the next request
        # must reopen while preserving the mtime recorded by mark_edited.
        for value in (2, 3):
            updated = f"function probe() {{ return {value}; }}"
            failed, text = call("replace_symbol_body", {
                "name_path": "probe", "relative_path": "A.ts", "body": updated})
            require(not failed, text)
            require(source.read_text() == updated + "\n", "Swan edit wrote incorrect source")
            with closing(connect(database)) as connection:
                edited = connection.execute("SELECT edited_mtime FROM files WHERE file='A.ts'").fetchone()[0]
            require(edited == source.stat().st_mtime_ns and edited > refreshed_map,
                    "edit freshness was not persisted with a newer actual mtime")
            require(probe().get("body") == updated + "\n", "next request did not read Swan's edited body")
        results.append("two Swan edits remain fresh across subsequent reopened requests")

        with closing(connect(database)) as holder:
            holder.execute("BEGIN EXCLUSIVE")
            try:
                failed, text = call("find_symbol", {"name_path_pattern": "probe"})
                require(failed and any(word in text.lower() for word in ("locked", "busy")),
                        "locked map did not return an explicit MCP error: " + text)
                cli = subprocess.run([str(binary), "query", str(database), "symbol", "probe"],
                    capture_output=True, text=True, timeout=options.timeout, env=child_environment())
                require(cli.returncode != 0 and any(word in (cli.stdout + cli.stderr).lower()
                        for word in ("locked", "busy")), "CLI silently accepted a locked map")
            finally:
                holder.rollback()
        probe()
        results.append("busy MCP read reports an error, same server recovers; CLI fails explicitly")

        saved = directory / "saved.db"
        database.rename(saved)
        try:
            failed, text = call("find_symbol", {"name_path_pattern": "probe"})
            require(failed and "cannot open map" in text, "missing path reused stale open map: " + text)
            require(not database.exists(), "reader created a missing database")
        finally:
            saved.rename(database)
        probe()
        results.append("missing selected map is an error without database creation; restored path recovers")

        version = metadata("schema_version")
        with closing(connect(database)) as connection:
            connection.execute("UPDATE meta SET value='unsupported-test-schema' WHERE key='schema_version'")
            connection.commit()
        try:
            failed, text = call("find_symbol", {"name_path_pattern": "probe"})
            require(failed and "index schema" in text, "replacement schema was not rejected: " + text)
        finally:
            with closing(connect(database)) as connection:
                connection.execute("UPDATE meta SET value=? WHERE key='schema_version'", (version,))
                connection.commit()
        probe()
        results.append("unsupported schema errors and the same server recovers after restoration")
    finally:
        client.close()
        (directory / "reader-results.json").write_text(json.dumps(results, indent=2) + "\n")
        print("Artifacts:", directory)
    for result in results:
        print("PASS:", result)


if __name__ == "__main__":
    main()
