"""Swan for Hermes: what an edit broke, said in the edit's own result.

Hermes's `write_file` and `patch` tools change a file; this plugin then asks
Swan which errors the language server reports in that file that it did not
report before (the same question Swan's Claude Code hook asks) and adds the
answer to the tool result the model reads. When a file has a configured
language server that could not check it, the hook's one-time notice (read
from its stdout `additionalContext` JSON on exit 0, or appended on stderr on
exit 2 alongside new errors) is added to the tool result the same way.
Nothing is added when the edit broke nothing and was checked (or has no live
server), when the same unchecked notice was already shown, when no Swan map
covers the file, or when Swan is not installed. An edit is never blocked or
changed.

The logic is Swan's own: this plugin runs
<swan>/scripts/hooks/what-broke-after-edit.py, so it follows the installed
Swan. <swan> is ~/.local/share/swan/current, or the folder named in a file
`swan-root` beside this one (written by `swan-up` for another install root),
or $SWAN_ROOT.
"""

import json
import os
import re
import subprocess
import sys
from pathlib import Path

EDIT_TOOLS = ("write_file", "patch")
# Asking can start a language server; an edit's result is not held longer.
ASK_SECONDS = 60
MAX_FILES = 5
_PATCH_FILE = re.compile(r"^\*\*\* (?:Update|Add) File: (.+?)\s*$", re.M)
_MOVE_FILE = re.compile(r"^\*\*\* Move File: .+? -> (.+?)\s*$", re.M)


def swan_root() -> Path:
    named = os.environ.get("SWAN_ROOT")
    if not named:
        note = Path(__file__).parent / "swan-root"
        if note.is_file():
            named = note.read_text().strip()
    return Path(named or "~/.local/share/swan/current").expanduser()


def edited_paths(tool_name: str, args: dict) -> list:
    """The files a write_file or patch call wrote, as given by the model."""
    if not isinstance(args, dict):
        return []
    found = []
    path = args.get("path")
    if isinstance(path, str) and path:
        found.append(path)
    patch = args.get("patch")
    if tool_name == "patch" and isinstance(patch, str):
        found += _PATCH_FILE.findall(patch) + _MOVE_FILE.findall(patch)
    seen, out = set(), []
    for p in found:
        if p not in seen:
            seen.add(p)
            out.append(p)
    return out[:MAX_FILES]


def session_cwd() -> Path:
    try:
        from agent.runtime_cwd import resolve_agent_cwd
        return Path(resolve_agent_cwd())
    except Exception:
        return Path(os.getcwd())


def what_broke(path: Path, root: Path) -> str:
    """Swan's line(s) about new errors or an unchecked file, or ''."""
    script = root / "scripts" / "hooks" / "what-broke-after-edit.py"
    if not script.is_file():
        return ""
    try:
        r = subprocess.run(
            [sys.executable, "-I", str(script)],
            input=json.dumps({"tool_input": {"file_path": str(path)}}),
            capture_output=True, text=True, timeout=ASK_SECONDS,
            env={**os.environ, "SWAN_BIN": os.environ.get("SWAN_BIN") or str(root / "bin" / "swan")},
        )
    except Exception:
        return ""
    if r.returncode == 2:
        return r.stderr.strip()
    if r.returncode == 0 and r.stdout.strip():
        try:
            parsed = json.loads(r.stdout)
        except Exception:
            return ""
        if isinstance(parsed, dict):
            hook = parsed.get("hookSpecificOutput")
            note = hook.get("additionalContext") if isinstance(hook, dict) else None
            if isinstance(note, str):
                return note.strip()
    return ""


def written_paths(parsed) -> list:
    """The files the tool says it wrote, where its result names them: Hermes's
    file tools answer with `files_modified` or `resolved_path`, already
    absolute, which is surer than resolving the model's argument here."""
    if not isinstance(parsed, dict):
        return []
    found = [p for p in (parsed.get("files_modified") or []) if isinstance(p, str)]
    one = parsed.get("resolved_path")
    if isinstance(one, str) and one not in found:
        found.append(one)
    return found[:MAX_FILES]


def after_edit(tool_name=None, args=None, result=None, status=None, **_):
    if tool_name not in EDIT_TOOLS or status in ("blocked", "error") or not isinstance(result, str):
        return None
    root = swan_root()
    if not (root / "bin" / "swan").exists():
        return None
    try:
        parsed = json.loads(result)
    except Exception:
        parsed = None
    if isinstance(parsed, dict) and parsed.get("error"):
        return None
    cwd = None
    notes = []
    for given in written_paths(parsed) or edited_paths(tool_name, args or {}):
        p = Path(given).expanduser()
        if not p.is_absolute():
            cwd = cwd or session_cwd()
            p = cwd / p
        if p.is_file():
            said = what_broke(p, root)
            if said:
                notes.append(said)
    if not notes:
        return None
    note = "\n".join(notes)
    if isinstance(parsed, dict):
        parsed["swan"] = note
        return json.dumps(parsed, ensure_ascii=False)
    return result + "\n\n" + note


def register(ctx):
    ctx.register_hook("transform_tool_result", after_edit)
    skill = swan_root() / "skills" / "swan-code-check" / "SKILL.md"
    if skill.is_file():
        ctx.register_skill("swan-code-check", skill)
