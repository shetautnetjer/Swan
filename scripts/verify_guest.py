#!/usr/bin/env python3
"""The verify gate's guest side (docs/superpowers/specs/2026-11-27-verify-gate.md): runs inside the throwaway microVM.

verify_guest.py <base-dir> <head-dir> [--timeout S] [--skip-base FILE]

Closes the private networks, then for each language found in <head-dir> runs the repo's own build, type check and
tests in <base-dir> and in <head-dir>, and prints one JSON object: what fails in head and not in base (new), what failed
in base and not in head (fixed), and how many failed in both. The repo is trusted here: its build scripts run, its
dependencies are fetched. --skip-base reads base results saved by an earlier run (a cache on the host) instead.
"""
import json, os, re, shutil, subprocess, sys, time
from pathlib import Path

# Private, link-local and shared address space: a blackhole route each, so nothing in the repo reaches the LAN or the
# tailnet. The guest's own link to its resolver is a more specific route and still works; so does the public internet.
PRIVATE = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16", "100.64.0.0/10"]
PRIVATE6 = ["fc00::/7"]
SWAN = Path("/home/cua/Work/Swan")


def close_private_networks() -> list[str]:
    done = []
    for net in PRIVATE:
        r = subprocess.run(["sudo", "-n", "ip", "route", "replace", "blackhole", net], capture_output=True, text=True)
        if r.returncode == 0:
            done.append(net)
    for net in PRIVATE6:
        r = subprocess.run(["sudo", "-n", "ip", "-6", "route", "replace", "blackhole", net], capture_output=True, text=True)
        if r.returncode == 0:
            done.append(net)
    return done


def run(cmd: list[str], cwd: Path, timeout: int, env: dict | None = None) -> tuple[int | None, str, float]:
    """Exit status (None when out of time), output, seconds."""
    t0 = time.time()
    try:
        r = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout, env=env)
        return r.returncode, r.stdout + r.stderr, time.time() - t0
    except subprocess.TimeoutExpired as e:
        out = (e.stdout or b"").decode("utf8", "replace") if isinstance(e.stdout, bytes) else (e.stdout or "")
        return None, out, time.time() - t0
    except FileNotFoundError as e:
        return 127, str(e), time.time() - t0


def languages(tree: Path) -> list[str]:
    found = []
    if (tree / "Cargo.toml").exists():
        found.append("rust")
    if (tree / "go.mod").exists():
        found.append("go")
    if (tree / "tsconfig.json").exists():
        found.append("typescript")
    if any((tree / f).exists() for f in ("pyproject.toml", "setup.py", "requirements.txt", "setup.cfg")) or \
            any(p for p in tree.glob("**/test_*.py") if "node_modules" not in p.parts):
        found.append("python")
    return found


# Each step: a name, how to run it, and how its output becomes failures: (kind, key, line, text). The key is what
# makes two failures the same in base and head (a test's name; an error's file and message, not its line, which
# moves when lines above it change).

def rust_check(out: str):
    for line in out.splitlines():
        try:
            m = json.loads(line)
        except ValueError:
            continue
        msg = m.get("message") or {}
        if m.get("reason") != "compiler-message" or msg.get("level") != "error":
            continue
        span = next((s for s in msg.get("spans", []) if s.get("is_primary")), (msg.get("spans") or [{}])[0])
        f = span.get("file_name", "")
        yield "error", f"{f}: {msg.get('message', '')}", span.get("line_start"), msg.get("rendered") or msg.get("message", "")


def rust_test(out: str):
    for m in re.finditer(r"^test (\S+) \.\.\. FAILED$", out, re.M):
        yield "test", m.group(1), None, test_output(out, m.group(1))


def go_errors(out: str):
    for m in re.finditer(r"^(?:\./)?(\S+\.go):(\d+):(?:\d+:)? (.+)$", out, re.M):
        yield "error", f"{m.group(1)}: {m.group(3)}", int(m.group(2)), m.group(0)


def go_test(out: str):
    for line in out.splitlines():
        try:
            m = json.loads(line)
        except ValueError:
            continue
        if m.get("Action") == "fail" and m.get("Test"):
            yield "test", f"{m.get('Package', '')}.{m['Test']}", None, ""
        elif m.get("Action") == "fail" and not m.get("Test") and m.get("Package"):
            yield "test", f"{m['Package']} (package)", None, ""


def ts_errors(out: str):
    for m in re.finditer(r"^(.+?)\((\d+),\d+\): error (TS\d+): (.+)$", out, re.M):
        yield "error", f"{m.group(1)}: {m.group(3)} {m.group(4)}", int(m.group(2)), m.group(0)


def pyright_errors(out: str):
    try:
        diags = json.loads(out[out.index("{"):]).get("generalDiagnostics", [])
    except ValueError:
        return
    for d in diags:
        if d.get("severity") == "error":
            f = d.get("file", "")
            yield "error", f"{f}: {d.get('message', '')}", (d.get("range", {}).get("start", {}).get("line", -1) + 1), d.get("message", "")


def pytest_failures(out: str):
    for m in re.finditer(r"^(?:FAILED|ERROR) (\S+)", out, re.M):
        yield "test", m.group(1), None, test_output(out, m.group(1).split("::")[-1])


def whole(name: str):
    """A step judged only by its exit status (npm test): one failure, named by the step."""
    def parse(out: str):
        yield "test", name, None, "\n".join(out.strip().splitlines()[-15:])
    return parse


def test_output(out: str, name: str) -> str:
    i = out.find(name, out.find("FAILURES") if "FAILURES" in out else 0)
    return out[i:i + 800] if i >= 0 else ""


def steps_for(lang: str, tree: Path):
    if lang == "rust":
        return [("cargo check", ["cargo", "check", "--all-targets", "--message-format=json"], rust_check, False),
                ("cargo test", ["cargo", "test", "--no-fail-fast"], rust_test, True)]
    if lang == "go":
        return [("go build", ["go", "build", "./..."], go_errors, False),
                ("go vet", ["go", "vet", "./..."], go_errors, False),
                ("go test", ["go", "test", "-json", "./..."], go_test, True)]
    if lang == "typescript":
        tsc = tree / "node_modules/.bin/tsc"
        cmd = [str(tsc)] if tsc.exists() else [str(SWAN / "tools/node_modules/.bin/tsc")]
        out = [("tsc", cmd + ["--noEmit", "-p", "."], ts_errors, False)]
        pkg = json.loads((tree / "package.json").read_text()) if (tree / "package.json").exists() else {}
        if (pkg.get("scripts") or {}).get("test"):
            out.append(("npm test", ["npm", "test", "--silent"], whole("npm test"), True))
        return out
    if lang == "python":
        pyright = SWAN / "tools/node_modules/.bin/pyright"
        return [("pyright", [str(pyright), "--outputjson", "."], pyright_errors, False),
                ("pytest", ["/tmp/verify-venv/bin/python", "-m", "pytest", "-q", "-rfE"], pytest_failures, True)]
    return []


def prepare(lang: str, tree: Path, timeout: int) -> str | None:
    """Fetch what the repo needs (trusted: this is the throwaway VM). A message when it could not."""
    if lang == "typescript" and (tree / "package.json").exists() and not (tree / "node_modules").exists():
        code, out, _ = run(["npm", "install", "--no-audit", "--no-fund", "--silent"], tree, timeout)
        if code != 0:
            return f"npm install failed: {out.strip().splitlines()[-1:] or ''}"
    if lang == "python":
        venv = Path("/tmp/verify-venv")
        if not venv.exists():
            run(["python3", "-m", "venv", str(venv)], tree, timeout)
            run([str(venv / "bin/pip"), "install", "-q", "pytest"], tree, timeout)
        for spec in (["-r", "requirements.txt"] if (tree / "requirements.txt").exists() else []), \
                (["-e", "."] if any((tree / f).exists() for f in ("pyproject.toml", "setup.py")) else []):
            if spec:
                run([str(venv / "bin/pip"), "install", "-q", *spec], tree, timeout)
    return None


def judge(tree: Path, langs: list[str], timeout: int) -> dict:
    """Every step's result in one tree: its failures by key, and how it ended."""
    result = {"steps": {}, "failures": {}}
    for lang in langs:
        note = prepare(lang, tree, timeout)
        for name, cmd, parse, is_test in steps_for(lang, tree):
            code, out, secs = run(cmd, tree, timeout)
            fails = list(parse(out)) if code is not None else []
            ended = "timeout" if code is None else "ok" if code == 0 else "failed"
            if code not in (None, 0) and not fails:
                # It failed and named nothing the parser knows: one failure for the whole step, with its last lines.
                fails = [("step", name, None, "\n".join(out.strip().splitlines()[-15:]))]
            result["steps"][name] = {"ended": ended, "exit": code, "seconds": round(secs, 1), **({"note": note} if note else {})}
            for kind, key, line, text in fails:
                result["failures"][f"{name}\t{key}"] = {"step": name, "kind": kind, "key": key, "line": line, "text": text[:1500]}
    return result


def main() -> int:
    args = sys.argv[1:]
    timeout = int(args[args.index("--timeout") + 1]) if "--timeout" in args else 600
    skip_base = args[args.index("--skip-base") + 1] if "--skip-base" in args else None
    base, head = Path(args[0]), Path(args[1])
    closed = close_private_networks()
    langs = languages(head)
    if not langs:
        print(json.dumps({"verdict": "error", "why": "no language the gate knows (Rust, Go, TypeScript, Python) in this tree"}))
        return 2
    base_r = json.loads(Path(skip_base).read_text()) if skip_base else judge(base, langs, timeout)
    head_r = judge(head, langs, timeout)
    new = [v for k, v in head_r["failures"].items() if k not in base_r["failures"]]
    fixed = [v for k, v in base_r["failures"].items() if k not in head_r["failures"]]
    timed_out = [s for s, v in head_r["steps"].items() if v["ended"] == "timeout"]
    verdict = "fail" if new else "error" if timed_out else "pass"
    print(json.dumps({"verdict": verdict, "languages": langs, "new": new, "fixed": fixed,
                      "already_failing": len(set(base_r["failures"]) & set(head_r["failures"])),
                      "timed_out": timed_out, "steps": {"base": base_r["steps"], "head": head_r["steps"]},
                      "closed_networks": closed, "base_result": base_r}))
    return 1 if verdict == "fail" else 2 if verdict == "error" else 0


if __name__ == "__main__":
    sys.exit(main())
