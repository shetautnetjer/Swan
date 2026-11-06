#!/usr/bin/env python3
"""Bounded Linux benchmark of an existing Swan candidate; no installs or trust writes.

Creates only disposable TypeScript/Python projects under a NEW output directory.
Measures map operations; verifies known semantics and final incremental/fresh equality.
This is an experiment harness, not a production benchmark or an optimization claim.
"""

import argparse
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import re
import shutil
import signal
import sqlite3
import statistics
import subprocess
import tempfile
import time


def require(ok, message):
    if not ok:
        raise RuntimeError(message)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else None


def save(path, value):
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n")


def source_hashes(repository):
    return {str(p.relative_to(repository)): sha(p)
            for p in sorted(repository.rglob("*")) if p.is_file()}


def fixture(repository, language, count):
    repository.mkdir()
    if language == "typescript":
        save(repository / "package.json", {"name": "swan-bench-ts", "version": "0.0.0", "private": True})
        save(repository / "tsconfig.json", {
            "compilerOptions": {"strict": True, "noEmit": True, "target": "ES2020",
                                "module": "esnext", "moduleResolution": "bundler", "types": []},
            "include": ["*.ts"],
        })
    else:
        (repository / "pyproject.toml").write_text('[project]\nname = "swan-bench-python"\nversion = "0.0.0"\n')
        save(repository / "pyrightconfig.json", {"include": ["."], "pythonVersion": "3.11"})
    suffix = "ts" if language == "typescript" else "py"
    for i in range(count):
        name, previous = f"bench_f{i:03d}", f"bench_f{i-1:03d}"
        if language == "typescript":
            prefix = f'import {{ {previous} }} from "./m{i-1:03d}";\n' if i else ""
            expression = f"{previous}(x) + {i}" if i else "x + 0"
            text = prefix + f"export function {name}(x: number): number {{\n  return {expression};\n}}\n"
        else:
            prefix = f"from m{i-1:03d} import {previous}\n\n" if i else ""
            expression = f"{previous}(x) + {i}" if i else "x + 0"
            text = prefix + f"def {name}(x: int) -> int:\n    return {expression}\n"
        (repository / f"m{i:03d}.{suffix}").write_text(text)
    return suffix


def canonical(database):
    # Mirror tests/dump.py, with complete extents and occurrence flags. IDs and
    # timestamps are storage details; stable SCIP identities are the join keys.
    queries = {
        "symbols": """SELECT scip,name,name_path,kind,signature,doc,def_file,def_line,def_col,
                       body_start,body_end,body_start_col,body_end_col,in_repo,language
                       FROM symbols ORDER BY scip""",
        "occurrences": """SELECT s.scip,o.file,o.start_line,o.start_col,o.end_line,o.end_col,
                       o.is_def,e.scip,o.by_name,o.is_import FROM occurrences o
                       JOIN symbols s ON s.id=o.symbol_id
                       LEFT JOIN symbols e ON e.id=o.enclosing_id
                       ORDER BY 2,3,4,5,6,1,7,8,9,10""",
        "relationships": """SELECT s.scip,t.scip,r.file,r.is_impl,r.is_ref,r.is_typedef,r.is_def
                       FROM relationships r JOIN symbols s ON s.id=r.symbol_id
                       JOIN symbols t ON t.id=r.related_id ORDER BY 1,2,3,4,5,6,7""",
        "files": "SELECT file,hash,rows FROM files ORDER BY file",
    }
    with sqlite3.connect(database.as_uri() + "?mode=ro", uri=True) as db:
        require(db.execute("PRAGMA integrity_check").fetchone()[0] == "ok", "SQLite integrity check failed")
        return {name: db.execute(sql).fetchall() for name, sql in queries.items()}


def known_answers(database, repository, suffix, count, edited=False, added=False):
    with sqlite3.connect(database.as_uri() + "?mode=ro", uri=True) as db:
        db.row_factory = sqlite3.Row
        definitions = db.execute("""SELECT * FROM symbols WHERE in_repo=1
                                   AND name GLOB 'bench_f[0-9][0-9][0-9]'""").fetchall()
        require(len(definitions) == count, f"expected {count} generated function definitions, got {len(definitions)}")
        require(sorted(item["name"] for item in definitions) == [f"bench_f{i:03d}" for i in range(count)],
                "generated definition identities contain a duplicate or omission")
        for item in definitions:
            index = int(item["name"][-3:])
            expected_file = f"m{index:03d}.{suffix}"
            text = (repository / expected_file).read_text()
            lines = text.splitlines()
            line = next(i for i, value in enumerate(lines) if
                        (f"function {item['name']}(" in value or f"def {item['name']}(" in value))
            require((item["def_file"], item["def_line"]) == (expected_file, line),
                    f"wrong definition position for {item['name']}")
            require(item["body_start"] is not None and item["body_end"] is not None,
                    f"missing source extent for {item['name']}")
            body = "\n".join(lines[item["body_start"]:item["body_end"] + 1])
            require(f"return {'x + 1000' if edited else 'x + 0'}" in body if index == 0 else "return " in body,
                    f"incorrect source body extent for {item['name']}")
        base = next(row for row in definitions if row["name"] == "bench_f000")
        refs = db.execute("""SELECT o.file,o.start_line,o.start_col,e.name AS enclosing
                             FROM occurrences o LEFT JOIN symbols e ON e.id=o.enclosing_id
                             WHERE o.symbol_id=? AND o.is_def=0 AND o.is_import=0
                             ORDER BY o.file,o.start_line,o.start_col""", (base["id"],)).fetchall()
        expected = []
        for filename, enclosing in [(f"m001.{suffix}", "bench_f001")] + ([(f"added.{suffix}", "bench_added")] if added else []):
            lines = (repository / filename).read_text().splitlines()
            line = next(i for i, value in enumerate(lines) if "return bench_f000(" in value)
            expected.append((filename, line, lines[line].index("bench_f000"), enclosing))
        require(sorted(tuple(row) for row in refs) == sorted(expected), "wrong base-function call references/enclosing functions")
        extra = db.execute("SELECT count(*) FROM symbols WHERE in_repo=1 AND name='bench_added'").fetchone()[0]
        require(extra == int(added), "added-file definition does not match fixture state")
        return {"definitions_checked": len(definitions), "base_call_references": [list(row) for row in refs],
                "added_definition": bool(extra), "base_name_path": base["name_path"]}


def stop_session(process):
    # Swan's synchronous helpers can create process groups within our private
    # session. Terminate those too on a timeout, never processes in other sessions.
    for sig in (signal.SIGTERM, signal.SIGKILL):
        for entry in Path("/proc").iterdir():
            if not entry.name.isdigit():
                continue
            try:
                pid = int(entry.name)
                if pid != os.getpid() and os.getsid(pid) == process.pid:
                    os.kill(pid, sig)
            except (ProcessLookupError, PermissionError):
                pass
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            pass


def measured_map(binary, repository, map_dir, stage, env, timeout, time_binary):
    stage.mkdir()
    command = [str(binary), "map", str(repository), str(map_dir)]
    full = [str(time_binary), "-f", "%e\t%U\t%S\t%M\t%x", "-o", str(stage / "time.tsv"), *command]
    save(stage / "command.json", {"argv": full, "cwd": str(stage), "timeout_seconds": timeout})
    started = time.monotonic()
    with (stage / "stdout.log").open("wb") as stdout, (stage / "stderr.log").open("wb") as stderr:
        process = subprocess.Popen(full, cwd=stage, env=env, stdout=stdout, stderr=stderr, start_new_session=True)
        try:
            code = process.wait(timeout=timeout)
        except (subprocess.TimeoutExpired, KeyboardInterrupt):
            stop_session(process)
            save(stage / "failure.json", {"reason": "timeout or interrupted", "elapsed_seconds": time.monotonic() - started})
            raise
    result = {"wall_seconds": time.monotonic() - started, "exit_code": code}
    raw = (stage / "time.tsv").read_text().splitlines()
    fields = raw[-1].split("\t") if raw else []
    if len(fields) == 5:
        result.update(time_wall_seconds=float(fields[0]), user_seconds=float(fields[1]),
                      system_seconds=float(fields[2]), max_rss_kib=int(fields[3]))
    output = (stage / "stdout.log").read_text(errors="replace")
    result["phase_reports"] = [line for line in output.splitlines()
                               if re.search(r"\bms\b|reused|nothing changed", line)]
    for path in map_dir.glob("log-*.txt"):
        shutil.copyfile(path, stage / path.name)
    for name in ("index-manifest.tsv", "python-pieces.tsv", "typescript-layers.txt"):
        if (map_dir / name).is_file():
            shutil.copyfile(map_dir / name, stage / name)
    save(stage / "timing.json", result)
    require(code == 0, f"map failed with exit {code}; inspect {stage}")
    require((map_dir / "swan.db").is_file(), "map succeeded without a database")
    return result


def mcp_check(helper_path, binary, database, folder, env, expected, edited):
    # Reuse the repository's existing bounded JSON client. Only construction is
    # overridden to pass this experiment's restricted environment and cwd.
    spec = importlib.util.spec_from_file_location("swan_demo_client", helper_path)
    helper = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(helper)

    class Client(helper.MCP):
        def __init__(self):
            self.stderr = (folder / "serve.stderr.log").open("wb")
            self.process = subprocess.Popen([str(binary), "serve", str(database)], env=env, cwd=folder,
                                            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.stderr)
            self.next_id, self.buffer, self.transcript = 0, b"", []

    client = Client()
    try:
        init = client.request("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                             "clientInfo": {"name": "swan-runtime-benchmark", "version": "1"}})
        require(init["result"]["serverInfo"]["name"] == "swan", "MCP initialized a different server")
        client.notify("notifications/initialized")
        found = client.tool("find_symbol", {"name_path_pattern": expected["base_name_path"], "include_body": True})
        require(len(found) == 1 and f"return x + {1000 if edited else 0}" in found[0]["body"],
                "MCP known definition/body check failed")
        refs = client.tool("find_referencing_symbols", {"name_path": expected["base_name_path"]})
        require(len(refs) == 1, "MCP base symbol is ambiguous or absent")
        actual = sorted((r["relative_path"], r["line"] - 1, r["column"] - 1) for r in refs[0]["references"]
                        if "return bench_f000(" in r.get("text", ""))
        require(actual == sorted(tuple(r[:3]) for r in expected["base_call_references"]), "MCP call references disagree with exact DB oracle")
    finally:
        try:
            save(folder / "mcp-transcript.json", client.transcript)
        finally:
            client.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True, help="Exact existing candidate, in its complete Swan installation")
    parser.add_argument("--output-parent", type=Path, required=True, help="Parent of a new disposable experiment directory")
    parser.add_argument("--time-binary", type=Path, default=Path("/usr/bin/time"),
                        help="Absolute path to GNU time; may be privately extracted without a host install")
    parser.add_argument("--files", type=int, default=120, choices=range(100, 201), metavar="100..200")
    parser.add_argument("--jobs", type=int, choices=(1, 2), default=1, help="1 is conservative for a 4GB CUA")
    parser.add_argument("--timeout", type=int, default=240, help="Seconds per map; 14 map invocations maximum")
    parser.add_argument("--mcp-helper", type=Path, help="Optional scripts/demo-offline.py from the reviewed Swan checkout")
    options = parser.parse_args()
    require(platform.system() == "Linux", "This measurement harness requires Linux /proc and GNU time")
    require(15 <= options.timeout <= 600, "timeout must be between 15 and 600 seconds")
    binary = options.binary.resolve(strict=True)
    require(binary.is_file() and os.access(binary, os.X_OK), "binary is not executable")
    swan_root = binary.parent.parent
    require(options.time_binary.is_absolute(), "--time-binary must be an absolute path")
    time_binary = options.time_binary.resolve()
    require(time_binary.is_file() and os.access(time_binary, os.X_OK),
            "GNU time is missing or not executable; select it with --time-binary (no dependency installation is performed)")
    for tool in ("bun", "node", "python3"):
        require(shutil.which(tool) is not None, f"{tool} is missing; harness does not install dependencies")
    for tool in ("scip-typescript", "scip-python"):
        require((swan_root / "tools/node_modules/.bin" / tool).is_file(), f"candidate's {tool} is missing")
    require((swan_root / "tools/scip-flatten.ts").is_file(), "candidate's SCIP flattener is missing")
    helper = options.mcp_helper.resolve(strict=True) if options.mcp_helper else None
    options.output_parent.mkdir(parents=True, exist_ok=True)
    folder = Path(tempfile.mkdtemp(prefix="swan-runtime-", dir=options.output_parent)).resolve()
    print(f"Evidence directory: {folder}", flush=True)
    # Do not change HOME or an existing trust list. The generated absolute repo
    # paths must be absent from Swan's existing list, and the global bypass is off.
    trust_file = swan_root / "data/trusted-repos"
    trust_before = sha(trust_file)
    env = {key: value for key, value in os.environ.items()
           if key in ("PATH", "HOME", "LANG", "LC_ALL", "TZ")}
    path_entries = env.get("PATH", "").split(os.pathsep)
    require(all(p and Path(p).is_absolute() for p in path_entries), "PATH must contain only absolute, nonempty entries")
    cache = folder / "cache"
    cache.mkdir()
    env.update(SWAN_JOBS=str(options.jobs), SWAN_TRUST_BUILD="0", XDG_CACHE_HOME=str(cache),
               npm_config_cache=str(cache / "npm"), npm_config_offline="true", PIP_NO_INDEX="1",
               PIP_DISABLE_PIP_VERSION_CHECK="1", PYTHONNOUSERSITE="1",
               PYTHONPYCACHEPREFIX=str(cache / "pycache"), TMPDIR=str(folder / "tmp"))
    Path(env["TMPDIR"]).mkdir()
    provenance = {"started_utc": datetime.now(timezone.utc).isoformat(),
                  "harness_sha256": sha(Path(__file__).resolve()),
                  "binary": str(binary), "binary_sha256": sha(binary), "platform": platform.platform(),
                  "cpu_count": os.cpu_count(), "load_average": list(os.getloadavg()),
                  "files_per_language": options.files, "jobs": options.jobs,
                  "trust_file_sha256_before": trust_before,
                  "tool_lock_sha256": sha(swan_root / "tools/package-lock.json"),
                  "mcp_helper": str(helper) if helper else None, "mcp_helper_sha256": sha(helper) if helper else None,
                  "conditions": ["fresh Swan map caches, existing tool installation", "OS page cache is not flushed",
                                 "no dependency installs or fetch commands", "no trust command", "HOME unchanged",
                                 "GNU time RSS is a maximum, not concurrent aggregate RSS", "generated fixtures only"]}
    tool_paths = {tool: Path(shutil.which(tool)).resolve() for tool in ("bun", "node", "python3")}
    tool_paths["time"] = time_binary
    for tool in ("scip-typescript", "scip-python"):
        tool_paths[tool] = (swan_root / "tools/node_modules/.bin" / tool).resolve()
    tool_paths["scip-flatten"] = swan_root / "tools/scip-flatten.ts"
    provenance["tools"] = {name: {"path": str(path), "sha256": sha(path)}
                           for name, path in tool_paths.items()}
    provenance["indexer_package_versions"] = {}
    for package in ("@sourcegraph/scip-typescript", "@sourcegraph/scip-python", "typescript"):
        metadata = swan_root / "tools/node_modules" / package / "package.json"
        if metadata.is_file():
            provenance["indexer_package_versions"][package] = json.loads(metadata.read_text()).get("version")
    for name, path in (("memory_max", Path("/sys/fs/cgroup/memory.max")),
                       ("cpu_max", Path("/sys/fs/cgroup/cpu.max"))):
        if path.is_file():
            provenance[name] = path.read_text().strip()
    save(folder / "provenance.json", provenance)
    summary = {"status": "running", "languages": {}, "optimization_decision": "pending semantic qualification and measured timings"}
    try:
        for language in ("typescript", "python"):
            area = folder / language
            area.mkdir()
            repository, map_dir = area / "repo", area / "map"
            suffix = fixture(repository, language, options.files)
            trusted = trust_file.read_text().splitlines() if trust_file.is_file() else []
            require(str(repository) not in trusted, "disposable fixture unexpectedly appears in trust list")
            save(area / "sources-before.json", source_hashes(repository))
            results = []
            baseline = None
            for number, label in enumerate(("cold", "unchanged-1", "unchanged-2", "unchanged-3", "edit", "new-file")):
                if label == "edit":
                    path = repository / f"m000.{suffix}"
                    path.write_text(("// edited\n" if suffix == "ts" else "# edited\n") + path.read_text().replace("x + 0", "x + 1000"))
                if label == "new-file":
                    text = ('import { bench_f000 } from "./m000";\nexport function bench_added(x: number): number {\n'
                            '  return bench_f000(x);\n}\n' if suffix == "ts" else
                            'from m000 import bench_f000\n\ndef bench_added(x: int) -> int:\n    return bench_f000(x)\n')
                    (repository / f"added.{suffix}").write_text(text)
                stage = area / f"{number:02d}-{label}"
                timing = measured_map(binary, repository, map_dir, stage, env, options.timeout, time_binary)
                known = known_answers(map_dir / "swan.db", repository, suffix, options.files, number >= 4, number >= 5)
                rows = canonical(map_dir / "swan.db")
                save(stage / "semantic-rows.json", rows)
                save(stage / "known-answers.json", known)
                if baseline is None:
                    baseline = rows
                if label.startswith("unchanged"):
                    require(rows == baseline, f"{language} unchanged map changed semantic rows")
                results.append({"stage": label, **timing, "known_answers_passed": True})
            # Fresh re-index of the SAME edited source path is the semantic oracle.
            # Distinct roots would legitimately change SCIP package identities.
            fresh_stage = area / "06-fresh-oracle"
            oracle = area / "fresh-map"
            oracle_timing = measured_map(binary, repository, oracle, fresh_stage, env, options.timeout, time_binary)
            oracle_rows = canonical(oracle / "swan.db")
            save(fresh_stage / "semantic-rows.json", oracle_rows)
            require(rows == oracle_rows, f"{language} refreshed map differs from a fresh map; timing conclusions are invalid")
            if helper:
                mcp_check(helper, binary, map_dir / "swan.db", fresh_stage, env, known, True)
            require(sha(binary) == provenance["binary_sha256"], "candidate binary changed during measurement")
            require(sha(trust_file) == trust_before, "trust list changed during measurement; no unchanged-list claim is valid")
            save(area / "sources-after.json", source_hashes(repository))
            summary["languages"][language] = {
                "samples": results, "fresh_oracle_timing": oracle_timing, "incremental_equals_fresh": True,
                "unchanged_median_seconds": statistics.median(item["wall_seconds"] for item in results[1:4]),
                "mcp_checked": bool(helper), "canonical_row_counts": {name: len(value) for name, value in rows.items()},
            }
            save(folder / "summary.json", summary)
        summary["status"] = "passed"
        require(all(sha(path) == provenance["tools"][name]["sha256"] for name, path in tool_paths.items()),
                "runtime or indexer executable changed during measurement")
        summary["optimization_decision"] = (
            "Evidence only: inspect phase reports and absolute user-visible cost. Do not optimize a cheap phase, "
            "rewrite SQLite, or split grammar packages without a measured material bottleneck and a semantic-preserving comparison.")
        print("PASS known semantics, unchanged equality, and incremental/fresh equality", flush=True)
    except BaseException as error:
        summary.update(status="failed", failure=f"{type(error).__name__}: {error}")
        raise
    finally:
        summary["trust_file_sha256_after"] = sha(trust_file)
        summary["binary_sha256_after"] = sha(binary)
        save(folder / "summary.json", summary)
        print(f"Evidence retained: {folder}", flush=True)


if __name__ == "__main__":
    main()
