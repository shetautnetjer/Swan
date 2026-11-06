#!/usr/bin/env python3
"""Check the Swan pattern pack against the known-answer fixture.

Maps fixture/ with `swan map` into a scratch dir, runs every pattern in
references/patterns.json through `swan serve` (MCP over stdio), and compares the
matched lines with the fixture tags each pattern must hit. Exits 1 on any
mismatch, so a pattern that silently stops matching is caught.

Also reports the known-bug canaries as PRESENT, FIXED or CHANGED.

Usage: python3 -I selftest.py [--swan PATH] [--map-swan PATH] [--out DIR]
"""
import argparse
from contextlib import contextmanager
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent
FIXTURE = HERE / "fixture"
PACK = HERE / "references" / "patterns.json"
TAG = re.compile(r"(?://|#)\s*([TP]\d\d)\b")


def tag_lines():
    """Map each fixture tag to (file name, 1-based line)."""
    tags = {}
    for f in sorted(FIXTURE.glob("sec.*")):
        for n, line in enumerate(f.read_text().splitlines(), 1):
            m = TAG.search(line)
            if m:
                tags[m.group(1)] = (f.name, n)
    return tags


class Swan:
    def __init__(self, swan, maps):
        """Start one private persistent server using only the supplied map registry."""
        self.p = subprocess.Popen([swan, "serve", "--maps", str(maps)], stdin=subprocess.PIPE,
                                  stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        self.n = 0
        self.rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                "clientInfo": {"name": "swan-selftest", "version": "1"}})
        self._send({"jsonrpc": "2.0", "method": "notifications/initialized"})

    def _send(self, msg):
        """Write and flush a newline-delimited JSON-RPC message."""
        self.p.stdin.write(json.dumps(msg) + "\n")
        self.p.stdin.flush()

    def rpc(self, method, params):
        """Send a request and decode its response, failing when the server exits early."""
        self.n += 1
        self._send({"jsonrpc": "2.0", "id": self.n, "method": method, "params": params})
        line = self.p.stdout.readline()
        if not line:
            raise SystemExit("swan serve exited")
        return json.loads(line)

    def search(self, lang, pattern):
        """Search the already selected map without repository reselection or implicit map building."""
        r = self.rpc("tools/call", {"name": "search_pattern",
                                    "arguments": {"pattern": pattern, "language": lang}})
        text = r.get("result", {}).get("content", [{}])[0].get("text", "")
        try:
            d = json.loads(text)
        except ValueError:
            return None, text[:200]
        return d, None

    def select_fixture_map(self, expected):
        """Require the builder's exact map without allowing an implicit rebuild."""
        reply = self.rpc("tools/call", {"name": "use_repo",
                                       "arguments": {"path": str(FIXTURE), "build": False}})
        result = reply.get("result")
        if "error" in reply or not isinstance(result, dict) or result.get("isError"):
            raise ValueError("cannot select fixture map without rebuilding")
        try:
            selected = json.loads(result["content"][0]["text"])
            map_path = selected["map"]
            if not isinstance(map_path, str) or selected.get("built") is not False:
                raise ValueError("expected an existing map")
            actual = Path(map_path).resolve(strict=True)
            expected = expected.resolve(strict=True)
        except (KeyError, IndexError, TypeError, ValueError, OSError, RuntimeError) as error:
            raise ValueError("cannot select fixture map: invalid or missing map") from error
        if actual != expected:
            raise ValueError("server selected a different fixture map")

    def close(self):
        """Close the private server input and require its timely exit."""
        self.p.stdin.close()
        self.p.wait(timeout=10)


def hits(d, by_line):
    """Translate matched source locations into fixture tags, retaining unexpected locations."""
    out = set()
    for m in d.get("matches", []):
        name = Path(m["relative_path"]).name
        tag = by_line.get((name, m["line"]))
        out.add(tag or f"{name}:{m['line']}")
    return out


def resolve_swan(candidate=None):
    """Resolve an explicit binary, SWAN_BINARY, then swan on PATH.

    A selected but invalid binary is an error: silently falling back could
    test a different installation from the one the caller requested.
    """
    candidate = os.path.expanduser(candidate or os.environ.get("SWAN_BINARY") or "swan")
    executable = shutil.which(candidate)
    if executable is None or not (os.path.isfile(executable) and os.access(executable, os.X_OK)):
        raise ValueError(f"swan binary not found or not executable: {candidate} "
                         "(pass --swan PATH, set SWAN_BINARY, or add swan to PATH)")
    return str(Path(executable).resolve())


@contextmanager
def output_directory(requested=None):
    """Allocate disposable output, or retain an explicitly chosen empty dir."""
    if requested:
        folder = Path(requested).expanduser().resolve()
        folder.mkdir(parents=True, exist_ok=True)
        if any(folder.iterdir()):
            raise ValueError(f"self-test output must be a new or empty directory: {folder}")
        yield folder
    else:
        with tempfile.TemporaryDirectory(prefix="swan-skill-selftest-") as folder:
            yield Path(folder).resolve()


def main():
    """Parse command-line options and return or report the operation status."""
    ap = argparse.ArgumentParser()
    ap.add_argument("--swan", help="binary path or command (default: SWAN_BINARY, then swan on PATH)")
    ap.add_argument("--map-swan", help="binary that builds the fixture map (default: --swan)")
    ap.add_argument("--out", default=os.environ.get("SWAN_SELFTEST_OUT"),
                    help="retain a new/empty output directory (default: disposable temporary directory)")
    a = ap.parse_args()
    try:
        a.swan = resolve_swan(a.swan)
        a.map_swan = resolve_swan(a.map_swan) if a.map_swan else a.swan
        with output_directory(a.out) as out:
            print(f"Self-test output: {out}" + (" (retained)" if a.out else " (disposable)"))
            return run(a.swan, a.map_swan, out)
    except ValueError as error:
        ap.error(str(error))


def run(binary, map_binary, out):
    """Build and select the exact fixture map, then check patterns and report matcher canaries."""
    built = subprocess.run([map_binary, "map", str(FIXTURE), str(out / "map")], capture_output=True, text=True)
    if built.returncode != 0:
        print(built.stdout[-800:], built.stderr[-800:])
        raise SystemExit("swan map failed")

    tags = tag_lines()
    by_line = {v: k for k, v in tags.items()}
    pack = json.loads(PACK.read_text())
    swan = Swan(binary, out)
    fails = 0
    try:
        swan.select_fixture_map(out / "map" / "swan.db")
        # This private client keeps one server alive. Omit repo after selection
        # so pattern calls cannot implicitly build or switch to another map.
        for e in pack["patterns"]:
            d, err = swan.search(e["lang"], e["pattern"])
            want = set(e["expect"])
            if d is None:
                print(f"FAIL  {e['lang']:10} {e['pattern']!r}: error {err}")
                fails += 1
                continue
            got = hits(d, by_line)
            alt = set(e.get("expect_if_fixed", e["expect"]))
            ok = got in (want, alt) and d.get("files_searched", 0) > 0
            fails += not ok
            note = " (fixed matcher)" if ok and got == alt and alt != want else ""
            print(f"{'ok  ' if ok else 'FAIL'}  {e['lang']:10} {e['pattern']!r}: got {sorted(got)}{note}"
                  + ("" if ok else f" want {sorted(want)} files_searched={d.get('files_searched')}"))
        print()
        for c in pack.get("known_bug_canaries", []):
            d, err = swan.search(c["lang"], c["pattern"])
            got = hits(d, by_line) if d else None
            if c["docs_expect"] == c["bug_result"]:
                state = "TRAP" if got == set(c["bug_result"]) else "CHANGED"
            else:
                state = ("FIXED" if got == set(c["docs_expect"])
                         else "PRESENT" if got == set(c["bug_result"]) else "CHANGED")
            print(f"canary {state:8} {c['lang']:10} {c['pattern']!r}: got {sorted(got) if got is not None else err}"
                  f" ({c['bug']})")
    finally:
        swan.close()
    print(f"\n{len(pack['patterns']) - fails}/{len(pack['patterns'])} patterns match the fixture exactly")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
