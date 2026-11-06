#!/usr/bin/env python3
"""Read-only Swan dependency report. Never indexes, downloads or grants trust."""

import argparse
import json
from pathlib import Path
import subprocess
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
from package_support import (PROFILES, elf_x64, platform_error, probe, read_json,
                             run_checked, runtime_tool, system_tool, within)


def report(home, profile="python-typescript"):
    """Probe the selected installation profile without installing tools or granting trust."""
    home = home.resolve()
    checks = []

    def add(name, group, status, detail, path=None, version=None, required=True):
        """Append one dependency result with its required or optional status."""
        checks.append(dict(name=name, group=group, status=status, detail=detail,
                           path=str(path) if path else None, version=version, required=required))

    error = platform_error()
    add("platform", "core", "unsupported" if error else "ready",
        error or "Linux x86_64/glibc; runtime behavior requires the separate smoke checks.")
    add("swan", "core", "ready" if elf_x64(home / "bin/swan") else "missing",
        "Executable ELF x86_64 required; rerun the verified archive installer if missing or incompatible.",
        home / "bin/swan")
    for relative in ("tools/modules.json", "tools/scip-flatten.ts", "skills/swan-code-check/SKILL.md"):
        present = (home / relative).is_file() and within(home / relative, home)
        add(relative, "core", "ready" if present else "missing", "Required packaged resource.", home / relative)
    selected = profile == "python-typescript"
    for name in ("python3", "node", "bun"):
        if not selected and name != "python3":
            add(name, "indexing", "unselected", "Select the python-typescript profile to install indexing dependencies.", required=False)
            continue
        # The Python interpreter is always a system prerequisite. Never inspect
        # .venv or a project-controlled python, even with an explicit home.
        path = system_tool(name) if name == "python3" else runtime_tool(home, name)
        result = probe(path, name, home=home)
        add(name, "core" if name == "python3" else "indexing", **result)
    if selected:
        try:
            manifest = read_json(home / "tools/package.json")
            lock = read_json(home / "tools/package-lock.json")
            node = runtime_tool(home, "node")
            node_ready = next(c for c in checks if c["name"] == "node")["status"] == "ready"
            commands = {"@sourcegraph/scip-python": "scip-python", "@sourcegraph/scip-typescript": "scip-typescript",
                        "pyright": "pyright", "typescript-language-server": "typescript-language-server",
                        "@biomejs/biome": "biome"}
            for package, command in commands.items():
                root = home / "tools/node_modules" / package
                expected = manifest["dependencies"][package]
                launcher = home / "tools/node_modules/.bin" / command
                try:
                    metadata = read_json(root / "package.json")
                    target = launcher.resolve(strict=True)
                    if not within(target, home / "tools/node_modules"):
                        raise ValueError("Vendor launcher escapes the installation's node_modules.")
                    if metadata["version"] != expected or lock["packages"]["node_modules/" + package]["version"] != expected:
                        raise ValueError("Installed/locked package version differs from the pinned manifest.")
                    if not node_ready:
                        raise ValueError("A compatible Node runtime is required before probing this vendor tool.")
                    # Biome's launcher itself is a Node script. Explicit Node
                    # avoids every /usr/bin/env shebang and caller PATH.
                    output = run_checked([node, target, "--version"], home=home)
                    add(command, "python-typescript", "ready", "Pinned package and vendor version probe; real map/check is separate.", target, output)
                except (OSError, KeyError, ValueError, RuntimeError, subprocess.TimeoutExpired) as failure:
                    add(command, "python-typescript", "missing", f"Rerun the verified installer with --profile python-typescript: {failure}", launcher)
        except (OSError, KeyError, ValueError) as failure:
            add("locked npm tools", "python-typescript", "missing", f"Missing or invalid package manifests: {failure}")
    for name in ("Python ruff/pytest", "Rust/Cargo", "Java/Kotlin", "C#/.NET", "CUDA/C++", "game/shader adapters"):
        add(name, "optional", "unselected", "Not installed or qualified by this profile; use explicit adapter setup and qualification.", required=False)
    ready = all(item["status"] == "ready" for item in checks if item["required"])
    return {"home": str(home), "profile": profile, "ready": ready,
            "scope": "Dependency availability/version probes only; no repository code, indexing, downloads or trust changes.",
            "checks": checks}


def main(argv=None):
    """Parse command-line options and return or report the operation status."""
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    parser.add_argument("--home", type=Path, required=True)
    parser.add_argument("--profile", choices=PROFILES, default="python-typescript")
    parser.add_argument("--json", action="store_true")
    options = parser.parse_args(argv)
    result = report(options.home, options.profile)
    if options.json:
        print(json.dumps(result, indent=2))
    else:
        print(f"Swan doctor: {result['home']} ({result['profile']})")
        for check in result["checks"]:
            print(f"{check['status']:12} {check['name']}: {check['version'] or check['detail']}")
        print(result["scope"])
    return 0 if result["ready"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
