#!/usr/bin/env python3
"""Read-only query latency on the retained concurrency fixture (prepared, not run).

Per binary: one persistent MCP session, 20 warmups, then 200 timed find_symbol
calls. Every reply must match the independently checked synthetic probe oracle.
No map build, live request, trust action, source change, or database write.
"""

import argparse
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import platform
import signal
import sqlite3
import statistics
import subprocess
import tempfile
import time


def require(ok, message):
    """Raise a benchmark failure when an acceptance condition is false."""
    if not ok:
        raise RuntimeError(message)


def digest(path):
    """Return the SHA-256 digest of an existing file's bytes."""
    return hashlib.sha256(path.read_bytes()).hexdigest()


def save(path, value):
    """Write readable JSON evidence with a trailing newline."""
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n")


def fingerprint(path):
    """Capture file content and identity for before-and-after stability checks."""
    stat = path.stat()
    return {"sha256": digest(path), "inode": stat.st_ino, "device": stat.st_dev,
            "size": stat.st_size, "mtime_ns": stat.st_mtime_ns}


def oracle(database, repository):
    """Verify the 50,000-symbol fixture and derive its complete probe reply."""
    for suffix in ("-journal", "-wal", "-shm"):
        sidecar = Path(str(database) + suffix)
        require(not sidecar.exists(), f"fixture has SQLite sidecar {sidecar}; use a quiescent completed fixture")
    # immutable is only for this inspection connection. It cannot create files
    # or perform journal recovery. No writers may run during this experiment.
    with sqlite3.connect(database.as_uri() + "?mode=ro&immutable=1", uri=True) as db:
        require(db.execute("PRAGMA integrity_check").fetchone()[0] == "ok", "fixture database failed integrity check")
        meta = dict(db.execute("SELECT key,value FROM meta"))
        require(Path(meta["root"]).resolve() == repository, "database root is not the explicit fixture repository")
        rows = db.execute("""SELECT scip,name_path,kind,signature,def_file,def_line,def_col,body_start,body_end
                             FROM symbols WHERE in_repo=1 AND name='probe'""").fetchall()
        require(rows == [("scip-typescript npm concurrency-fixture 0.0.0 probe().", "probe", "function",
                          "function probe(): void // A", "A.ts", 0, 9, 0, 0)],
                "database is not the known generation-A synthetic probe fixture")
        count = db.execute("SELECT count(*) FROM symbols WHERE in_repo=1").fetchone()[0]
        require(count == 50000, f"expected the 50,000-symbol fixture, found {count} symbols")
        edited = db.execute("SELECT edited_mtime FROM files WHERE file='A.ts'").fetchone()
    source = repository / "A.ts"
    require(source.read_text() == "export function probe() {}\n", "synthetic probe source differs from the known fixture")
    expected = {"name_path": "probe", "kind": "function", "signature": "function probe(): void // A",
                "relative_path": "A.ts", "line": 1, "column": 10, "body_lines": [1, 1]}
    scip_time = int(meta.get("scip_time", "0"))
    mtime = source.stat().st_mtime_ns
    if scip_time > 0 and mtime > scip_time and mtime != (edited[0] if edited else None):
        expected["stale"] = True
    return [expected], {"in_repo_symbols": count, "schema_version": meta.get("schema_version"),
                        "scip_time": scip_time, "source": fingerprint(source)}


def trial(helper, binary, database, directory, expected):
    """Measure 200 validated queries after 20 warmups in one bounded session."""
    directory.mkdir()
    env = {name: value for name, value in os.environ.items() if name in ("PATH", "HOME", "LANG", "LC_ALL", "TZ")}
    env["SWAN_TRUST_BUILD"] = "0"

    class Client(helper.MCP):
        """Adapt the demo MCP client for an isolated session and bounded cleanup."""

        def __init__(self):
            """Start Swan with the fixture database, filtered environment and log."""
            self.stderr = (directory / "serve.stderr.log").open("wb")
            self.process = subprocess.Popen([str(binary), "serve", str(database)], cwd=directory, env=env,
                                            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.stderr,
                                            start_new_session=True)
            self.next_id, self.buffer, self.transcript = 0, b"", []

        def close(self):
            """Close stdin, kill a hung process group, and check Swan's exit status."""
            if self.process.poll() is None:
                try:
                    self.process.stdin.close()
                except BrokenPipeError:
                    pass
                try:
                    self.process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    try:
                        os.killpg(self.process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    self.process.wait(timeout=5)
            self.stderr.close()
            require(self.process.returncode == 0, f"Swan exited with {self.process.returncode}")

    client = None
    times, warmups = [], []

    def expired(signum, frame):
        """Abort the trial when its 120-second alarm fires."""
        raise TimeoutError("trial exceeded 120 seconds")

    previous_handler = signal.signal(signal.SIGALRM, expired)
    signal.setitimer(signal.ITIMER_REAL, 120)
    result = {"binary": str(binary), "binary_sha256": digest(binary), "warmup_count": 20,
              "sample_count": 200, "status": "running"}
    try:
        started = time.perf_counter_ns()
        client = Client()
        init = client.request("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                             "clientInfo": {"name": "swan-reader-latency", "version": "1"}})
        require(init["result"]["serverInfo"]["name"] == "swan", "unexpected MCP server")
        client.notify("notifications/initialized")
        result["startup_initialize_ms"] = (time.perf_counter_ns() - started) / 1e6
        arguments = {"name_path_pattern": "probe", "include_body": False}
        for i in range(220):
            tick = time.perf_counter_ns()
            reply = client.tool("find_symbol", arguments)
            elapsed = (time.perf_counter_ns() - tick) / 1e6
            require(reply == expected, f"reply {i + 1} differed from the complete known oracle: {reply!r}")
            (warmups if i < 20 else times).append(elapsed)
        require(digest(binary) == result["binary_sha256"], "binary changed during the trial")
        ordered = sorted(times)
        result.update(status="passed", warmup_ms=warmups, latency_ms=times,
                      median_ms=statistics.median(times), mean_ms=statistics.mean(times),
                      p95_ms=ordered[math.ceil(len(ordered) * .95) - 1],
                      min_ms=min(times), max_ms=max(times), every_reply_validated=True)
    except BaseException as error:
        result.update(status="failed", failure=f"{type(error).__name__}: {error}")
        raise
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, previous_handler)
        try:
            if client:
                try:
                    save(directory / "mcp-transcript.json", client.transcript)
                finally:
                    client.close()
        except BaseException as error:
            result.update(status="failed", cleanup_failure=f"{type(error).__name__}: {error}")
            raise
        finally:
            save(directory / "timing.json", result)
    return result


def main():
    """Validate the fixture, measure selected binaries and persist comparisons."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True, help="Exact candidate executable")
    parser.add_argument("--baseline", type=Path, help="Optional exact earlier executable; runs first")
    parser.add_argument("--database", type=Path, required=True, help="Retained generation-A baseline.db")
    parser.add_argument("--repository", type=Path, required=True, help="Its existing synthetic repo directory")
    parser.add_argument("--mcp-helper", type=Path, required=True, help="Reviewed Swan scripts/demo-offline.py")
    parser.add_argument("--output-parent", type=Path, required=True)
    args = parser.parse_args()
    require(platform.system() == "Linux", "Linux is required for this process/session measurement")
    database, repository, helper_path = (p.resolve(strict=True) for p in (args.database, args.repository, args.mcp_helper))
    binaries = [("baseline", args.baseline)] if args.baseline else []
    binaries.append(("candidate", args.binary))
    binaries = [(label, path.resolve(strict=True)) for label, path in binaries]
    require(all(path.is_file() and os.access(path, os.X_OK) for _, path in binaries), "an executable is missing")
    if args.baseline:
        require(digest(binaries[0][1]) != digest(binaries[1][1]), "baseline and candidate are identical executables")
    expected, fixture_info = oracle(database, repository)
    before = fingerprint(database)
    args.output_parent.mkdir(parents=True, exist_ok=True)
    directory = Path(tempfile.mkdtemp(prefix="swan-reader-latency-", dir=args.output_parent)).resolve()
    print("Evidence: " + str(directory), flush=True)
    spec = importlib.util.spec_from_file_location("swan_demo_client", helper_path)
    helper = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(helper)
    summary = {"status": "running", "started_utc": datetime.now(timezone.utc).isoformat(),
               "database": str(database), "database_before": before, "repository": str(repository),
               "fixture": fixture_info, "expected_reply": expected, "platform": platform.platform(),
               "load_average": list(os.getloadavg()), "harness_sha256": digest(Path(__file__).resolve()),
               "helper": str(helper_path), "helper_sha256": digest(helper_path), "trials": {},
               "limits": ["one process session per binary; 200 serial samples after 20 warmups",
                          "IPC and JSON decoding included; assertion and startup time excluded",
                          "baseline runs first; OS cache/order/scheduling effects remain",
                          "no live query, mutation, map building, or concurrent writer",
                          "synthetic fixture; not a tail-latency or statistical-significance claim"]}
    try:
        for label, binary in binaries:
            require(fingerprint(database) == before, "fixture database changed before a trial")
            require(fingerprint(repository / "A.ts") == fixture_info["source"], "fixture source changed before a trial")
            summary["trials"][label] = trial(helper, binary, database, directory / label, expected)
            require(fingerprint(database) == before, "query trial changed the database or an external writer ran")
            expected_after, info_after = oracle(database, repository)
            require(expected_after == expected and info_after == fixture_info, "fixture state changed during a trial")
        if args.baseline:
            earlier, later = (summary["trials"][key] for key in ("baseline", "candidate"))
            summary["comparison"] = {"median_delta_ms": later["median_ms"] - earlier["median_ms"],
                                     "p95_delta_ms": later["p95_ms"] - earlier["p95_ms"],
                                     "interpretation": "descriptive overhead only; assess absolute cost before considering optimization"}
        summary["status"] = "passed"
        print("PASS every query matched the known fixture; DB/source unchanged", flush=True)
    except BaseException as error:
        summary.update(status="failed", failure=f"{type(error).__name__}: {error}")
        raise
    finally:
        save(directory / "summary.json", summary)
        print("Evidence retained: " + str(directory), flush=True)


if __name__ == "__main__":
    main()
