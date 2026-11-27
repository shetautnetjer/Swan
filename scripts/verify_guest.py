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


def pyright_errors(tree: Path):
    """pyright names files by absolute path; the key takes them relative to the tree, so base and head agree."""
    def parse(out: str):
        try:
            diags = json.loads(out[out.index("{"):]).get("generalDiagnostics", [])
        except ValueError:
            return
        for d in diags:
            if d.get("severity") == "error":
                f = d.get("file", "")
                f = os.path.relpath(f, tree) if os.path.isabs(f) else f
                yield "error", f"{f}: {d.get('message', '')}", (d.get("range", {}).get("start", {}).get("line", -1) + 1), d.get("message", "")
    return parse


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


def changed_files(base: Path, head: Path) -> list[str]:
    """Files that differ between the two trees (added, removed or changed), relative to them."""
    r = subprocess.run(["diff", "-rq", str(base), str(head)], capture_output=True, text=True)
    out = []
    for line in r.stdout.splitlines():
        m = re.match(r"^Files (.+) and (.+) differ$", line) or re.match(r"^Only in (.+): (.+)$", line)
        if not m:
            continue
        p = m.group(1) if line.startswith("Files") else os.path.join(m.group(1), m.group(2))
        for root in (str(base), str(head)):
            if p.startswith(root + "/") or p == root:
                out.append(os.path.relpath(p, root))
    return out


def rust_packages(tree: Path, changed: list[str]) -> list[str]:
    """The workspace packages that hold a changed file: the nearest Cargo.toml above it with a [package] name. Empty
    means a single-package repo or a change outside every package: then the whole workspace is judged."""
    names = set()
    for f in changed:
        d = (tree / f).parent
        while d != tree.parent:
            toml = d / "Cargo.toml"
            if toml.exists():
                m = re.search(r'^\[package\][^\[]*?^name\s*=\s*"([^"]+)"', toml.read_text(errors="replace"), re.M | re.S)
                if m:
                    names.add(m.group(1))
                    break
            d = d.parent
    return sorted(names)


def steps_for(lang: str, tree: Path, packages: list[str] = ()):
    if lang == "rust":
        # A workspace's crates can need features the others do not (relate tests each crate on its own), so only the
        # crates the change touches are built and tested, each with every feature it defines.
        scope = [a for p in packages for a in ("-p", p)] + ["--all-features"] if packages else ["--workspace"]
        return [("cargo check", ["cargo", "check", *scope, "--all-targets", "--message-format=json"], rust_check, False),
                ("cargo test", ["cargo", "test", *scope, "--no-fail-fast"], rust_test, True)]
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
        return [("pyright", [str(pyright), "--outputjson", "."], pyright_errors(tree), False),
                ("pytest", ["/tmp/verify-venv/bin/python", "-m", "pytest", "-q", "-rfE"], pytest_failures, True)]
    return []


def prepare(lang: str, tree: Path, timeout: int) -> str | None:
    """Fetch what the repo needs (trusted: this is the throwaway VM). A message when it could not."""
    if lang == "rust":
        # The checkpoint's toolchains live in root-owned /opt/rust: the repo's pinned one (rust-toolchain.toml) is
        # installed by rustup on first use, so the folders go to this user first (a throwaway VM).
        for d in ("/opt/rust/rustup", "/opt/rust/cargo"):
            if os.path.isdir(d) and not os.access(d, os.W_OK):
                subprocess.run(["sudo", "-n", "chown", "-R", f"{os.getuid()}:{os.getgid()}", d], capture_output=True)
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


def judge(tree: Path, langs: list[str], timeout: int, packages: list[str] = ()) -> dict:
    """Every step's result in one tree: its failures by key, and how it ended."""
    result = {"steps": {}, "failures": {}}
    for lang in langs:
        note = prepare(lang, tree, timeout)
        for name, cmd, parse, is_test in steps_for(lang, tree, packages):
            code, out, secs = run(cmd, tree, timeout)
            fails = list(parse(out)) if code is not None else []
            ended = "timeout" if code is None else "ok" if code == 0 else "failed"
            if code not in (None, 0) and not fails:
                # It failed and named nothing the parser knows: one failure for the whole step, with its last lines.
                fails = [("step", name, None, "\n".join(out.strip().splitlines()[-15:]))]
            result["steps"][name] = {"lang": lang, "ended": ended, "exit": code, "seconds": round(secs, 1), **({"note": note} if note else {})}
            for kind, key, line, text in fails:
                result["failures"][f"{name}\t{key}"] = {"step": name, "kind": kind, "key": key, "line": line, "text": text[:1500]}
    return result


def main() -> int:
    args = sys.argv[1:]
    timeout = int(args[args.index("--timeout") + 1]) if "--timeout" in args else 600
    skip_base = args[args.index("--skip-base") + 1] if "--skip-base" in args else None
    base, head = Path(args[0]), Path(args[1])
    closed = close_private_networks()
    # Room for a large repo's two builds (a fork has about 8 GB free): Swan's own .tools (6 GB of indexers and language
    # servers the gate does not use; tsc and pyright come from tools/node_modules) goes, and both trees share one cargo
    # target folder, so the second build compiles only what differs. Both are safe in a throwaway VM.
    shutil.rmtree(SWAN / ".tools", ignore_errors=True)
    os.environ.setdefault("CARGO_TARGET_DIR", "/tmp/v-cargo-target")
    langs = languages(head)
    if not langs:
        print(json.dumps({"verdict": "error", "why": "no language the gate knows (Rust, Go, TypeScript, Python) in this tree"}))
        return 2
    packages = rust_packages(head, changed_files(base, head)) if "rust" in langs else []
    base_r = json.loads(Path(skip_base).read_text()) if skip_base else None
    if base_r is None or base_r.get("packages", []) != packages:  # a cached base judged other crates
        base_r = judge(base, langs, timeout, packages)
    base_r["packages"] = packages
    # Both trees share one cargo target folder, and cargo decides what to rebuild by file times: so every head file
    # is made newer than the base build just finished. Without it a type error passed (2026-11-27). Dependencies,
    # fingerprinted by content, stay compiled.
    now = time.time()
    for p in head.rglob("*"):
        if p.is_file() and not p.is_symlink():
            os.utime(p, (now, now))
    head_r = judge(head, langs, timeout, packages)
    new = [v for k, v in head_r["failures"].items() if k not in base_r["failures"]]
    fixed = [v for k, v in base_r["failures"].items() if k not in head_r["failures"]]
    timed_out = [s for s, v in head_r["steps"].items() if v["ended"] == "timeout"]
    # A step that failed in both trees and named nothing (it could not run: a toolchain, a dependency) judged
    # nothing. It is reported; the verdict is an error only when no step judged anything.
    unjudged = sorted({v["step"] for k, v in head_r["failures"].items() if v["kind"] == "step" and k in base_r["failures"]})
    # A language none of whose steps judged anything is one the gate cannot vouch for: the verdict says so, even when
    # another language passed (relate's Rust could not build while its Python helper scripts type checked).
    blind = sorted({v["lang"] for v in head_r["steps"].values()} - {v["lang"] for s, v in head_r["steps"].items()
                                                                  if s not in unjudged and s not in timed_out})
    verdict = "fail" if new else "error" if timed_out or blind else "pass"
    why = f"could not judge {', '.join(blind) or 'it'}: {', '.join(timed_out + unjudged)} did not run in either tree" if verdict == "error" else None
    print(json.dumps({"verdict": verdict, "languages": langs, "new": new, "fixed": fixed,
                      "already_failing": len(set(base_r["failures"]) & set(head_r["failures"])),
                      "timed_out": timed_out, "unjudged": unjudged, **({"why": why} if why else {}),
                      "steps": {"base": base_r["steps"], "head": head_r["steps"]},
                      "closed_networks": closed, "base_result": base_r}))
    return 1 if verdict == "fail" else 2 if verdict == "error" else 0


if __name__ == "__main__":
    sys.exit(main())
