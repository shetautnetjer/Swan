#!/usr/bin/env python3
"""Check scip-java reuse and command changes with disposable synthetic tools.

Run with --legacy-binary to verify migration from the pre-repair executable.
"""

import argparse
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", type=Path, default=Path("bin/swan"))
    parser.add_argument("--legacy-binary", type=Path)
    args = parser.parse_args()
    binary = args.binary.resolve(strict=True)
    legacy = args.legacy_binary.resolve(strict=True) if args.legacy_binary else None
    flatten = Path("tools/scip-flatten.ts").resolve(strict=True)

    with tempfile.TemporaryDirectory(prefix="swan-java-reuse-") as tmp:
        root = Path(tmp)
        repo, out, log = root / "repo", root / "map", root / "calls"
        repo.mkdir()
        (repo / "Main.java").write_text("class Main {}\n")
        build = repo / "build.gradle.kts"
        build.write_text('plugins { id("com.notroid.application") }\n')
        env = dict(os.environ, SWAN_TRUST_BUILD="1", SWAN_REUSE_LOG=str(log))

        def install(home, exe):
            (home / "bin").mkdir(parents=True, exist_ok=True)
            (home / "tools").mkdir(exist_ok=True)
            tool = home / ".tools/scip-java/v0.14.1/scip-java"
            tool.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(exe, home / "bin/swan")
            shutil.copy2(flatten, home / "tools/scip-flatten.ts")
            tool.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$SWAN_REUSE_LOG"\n'
                            'for arg do case "$arg" in --output=*) : > "${arg#--output=}";; esac; done\n')
            tool.chmod(0o755)

        def run(home, expected_calls, task):
            result = subprocess.run([str(home / "bin/swan"), "map", str(repo), str(out)],
                                    env=env, capture_output=True, text=True)
            if result.returncode:
                raise AssertionError(f"map failed: {result.stdout}\n{result.stderr}")
            calls = log.read_text().splitlines()
            assert len(calls) == expected_calls, (calls, result.stdout, result.stderr)
            assert task in calls[-1], calls[-1]

        home = root / "home"
        install(home, legacy or binary)
        run(home, 1, "scipPrintDependencies")
        run(home, 1, "scipPrintDependencies")
        if legacy:
            shutil.copy2(binary, home / "bin/swan")
            run(home, 2, "scipPrintDependencies")
            run(home, 2, "scipPrintDependencies")
        count = 2 if legacy else 1

        # Only the selected arguments change: keep file size and nanosecond
        # timestamp identical, so the old file-only fingerprint would match.
        st = build.stat()
        build.write_text(build.read_text().replace("com.notroid.application", "com.android.application"))
        os.utime(build, ns=(st.st_atime_ns, st.st_mtime_ns))
        assert build.stat().st_size == st.st_size and build.stat().st_mtime_ns == st.st_mtime_ns
        run(home, count + 1, "compileDebugKotlin")
        run(home, count + 1, "compileDebugKotlin")

        other = root / "other-home"
        install(other, binary)
        run(other, count + 2, "compileDebugKotlin")
        run(other, count + 2, "compileDebugKotlin")
        print("scip-java reuse: old fingerprint, changed tasks, command path and unchanged reuse passed"
              if legacy else "scip-java reuse: changed tasks, command path and unchanged reuse passed")


if __name__ == "__main__":
    main()
