#!/usr/bin/env python3
"""Claude Code PostToolUse hook: after an edit, tell the agent what it just broke.

Reads the hook's JSON on stdin, takes the edited file, finds the Swan map
that covers it and runs `swan broke`. New errors go to stderr with exit 2,
which Claude Code shows to the agent; otherwise it is silent (exit 0). It
never blocks an edit, and does nothing for files no map covers.

settings.json:
  {"hooks": {"PostToolUse": [{"matcher": "Edit|Write|MultiEdit",
     "hooks": [{"type": "command", "command": "~/.local/share/swan/current/scripts/hooks/what-broke-after-edit.py"}]}]}}

SWAN_BIN and SWAN_MAPS override the swan binary and the maps folder.
"""
import json, os, sqlite3, subprocess, sys

def main():
    try: event = json.load(sys.stdin)
    except Exception: return 0
    path = (event.get("tool_input") or {}).get("file_path") or ""
    if not path or not os.path.isabs(path) or not os.path.isfile(path): return 0
    path = os.path.realpath(path)
    here = os.path.dirname(os.path.dirname(os.path.dirname(os.path.realpath(__file__))))
    swan = os.environ.get("SWAN_BIN") or os.path.join(here, "bin", "swan")
    maps = os.environ.get("SWAN_MAPS") or os.path.expanduser("~/.local/share/swan/maps")
    best, best_root = None, ""
    try: names = os.listdir(maps)
    except OSError: return 0
    for name in names:
        db = os.path.join(maps, name, "swan.db")
        if not os.path.isfile(db): continue
        try:
            c = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
            root = c.execute("SELECT value FROM meta WHERE key = 'root'").fetchone()[0]
            c.close()
        except Exception: continue
        if path.startswith(root + "/") and len(root) > len(best_root): best, best_root = os.path.join(maps, name), root
    if not best: return 0
    try:
        r = subprocess.run([swan, "broke", best, path], capture_output=True, text=True, timeout=120)
        answer = json.loads(r.stdout)
    except Exception: return 0
    lines = []
    for f in answer.get("files", []):
        for e in f.get("new_errors", []):
            lines.append(f"{f['relative_path']}:{e['line']}:{e['col']}: {e['message'].splitlines()[0]}")
    if not lines: return 0
    print("Swan: this edit introduced " + ("an error" if len(lines) == 1 else f"{len(lines)} errors") + " the language server did not report before:\n" + "\n".join(lines), file=sys.stderr)
    return 2

sys.exit(main())
