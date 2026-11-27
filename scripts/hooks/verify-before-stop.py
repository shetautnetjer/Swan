#!/usr/bin/env python3
"""Claude Code Stop hook: before a turn ends, the verify gate judges what it changed.

When the session's repo has uncommitted changes the gate has not judged yet, it runs scripts/swan-verify (build, type
check and tests in a throwaway microVM, against HEAD). If something newly fails, the stop is blocked and the failures go
to the agent as the reason, so the turn goes on with them in front of it. Each set of changes is judged once; a session
is blocked at most SWAN_VERIFY_MAX_BLOCKS times per repo (3), then it may stop. When the gate cannot judge (no VM, a
language it does not know) the turn ends as usual. Nothing runs on this machine but git and the gate's packing.

settings.json (the gate takes a minute or more on a real repo: give the hook time):
  {"hooks": {"Stop": [{"hooks": [{"type": "command", "timeout": 1800,
     "command": "python3 ~/.local/share/swan/current/scripts/hooks/verify-before-stop.py"}]}]}}

SWAN_VERIFY_HOOK=off turns it off. SWAN_VERIFY overrides the gate's path; SWAN_VERIFY_STATE its state folder
(~/.cache/swan-verify/hook); SWAN_VERIFY_MAX_BLOCKS the limit.
"""
import hashlib, json, os, subprocess, sys

def git(cwd, *args):
    r = subprocess.run(["git", "-C", cwd, *args], capture_output=True)
    return r.stdout if r.returncode == 0 else None

def fingerprint(root):
    """The changes as they are: the diff against HEAD and the new files' names and contents."""
    h = hashlib.sha256(git(root, "diff", "HEAD", "--binary") or b"")
    for name in sorted((git(root, "ls-files", "-z", "-o", "--exclude-standard") or b"").split(b"\0")):
        if not name: continue
        h.update(name)
        try:
            with open(os.path.join(root, name.decode("utf8", "surrogateescape")), "rb") as f: h.update(f.read())
        except OSError: pass
    return h.hexdigest()

def summary(result):
    lines = []
    for n in result.get("new", [])[:30]:
        where = f" (line {n['line']})" if n.get("line") else ""
        lines.append(f"- {n['step']}: {n['key']}{where}")
        text = (n.get("text") or "").strip()
        if text and n.get("kind") != "error":
            lines.extend("    " + t for t in text.splitlines()[:6])
    more = len(result.get("new", [])) - 30
    if more > 0: lines.append(f"- and {more} more")
    return "\n".join(lines)

def main():
    if os.environ.get("SWAN_VERIFY_HOOK") == "off": return 0
    try: event = json.load(sys.stdin)
    except Exception: return 0
    cwd = event.get("cwd") or os.getcwd()
    top = git(cwd, "rev-parse", "--show-toplevel")
    if not top: return 0
    root = top.decode().strip()
    if not (git(root, "status", "--porcelain") or b"").strip(): return 0
    fp = fingerprint(root)
    state_dir = os.environ.get("SWAN_VERIFY_STATE") or os.path.expanduser("~/.cache/swan-verify/hook")
    os.makedirs(state_dir, exist_ok=True)
    key = hashlib.sha256(f"{event.get('session_id', '')}\0{root}".encode()).hexdigest()[:24]
    state_file = os.path.join(state_dir, f"{key}.json")
    try:
        with open(state_file) as f: state = json.load(f)
    except (OSError, ValueError): state = {"judged": [], "blocks": 0}
    if fp in state["judged"]: return 0  # these exact changes were judged: the agent heard about them, or they passed
    limit = int(os.environ.get("SWAN_VERIFY_MAX_BLOCKS") or 3)
    if state["blocks"] >= limit: return 0
    here = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
    gate = os.environ.get("SWAN_VERIFY") or os.path.join(here, "swan-verify")
    r = subprocess.run([gate, root], capture_output=True, text=True)
    state["judged"] = (state["judged"] + [fp])[-50:]
    try: result = json.loads(next(l for l in r.stdout.splitlines() if l.startswith("{")))
    except (StopIteration, ValueError): result = {}
    if r.returncode == 1 and result.get("new"):
        state["blocks"] += 1
        with open(state_file, "w") as f: json.dump(state, f)
        reason = ("The verify gate built, type checked and tested your changes in a microVM against HEAD, and these fail "
                  f"now that did not before:\n{summary(result)}\nFix them before ending the turn, or say why they stay.")
        print(json.dumps({"decision": "block", "reason": reason}))
        return 0
    with open(state_file, "w") as f: json.dump(state, f)
    return 0

if __name__ == "__main__":
    sys.exit(main())
