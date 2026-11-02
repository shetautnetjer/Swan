# swan-code-check: provenance and how copies follow this repo

## Source
Written by Jabari (Khamani's Claude Code) on 2026-11-01 at Khamani's request,
with a Letta/AEON adaptation by Aya the same day. Merged into one file here
on 2026-11-02 (Khamani: "Yes, move it"). **This directory is the single
source.** Edit the skill only here, through a normal Swan PR.

The pattern pack (`references/patterns.json`) and fixture (`fixture/`) were
identical in both earlier copies. The self-test's scratch dir defaults to
`~/.cache/aya/tmp/swan-skill-selftest` (override: `SWAN_SELFTEST_OUT` or `--out`).

## Installed copies
Each host needs a skill directory it can load. Both follow this repo with a
copy (not a symlink), refreshed after a skill change merges:

- **Aya (Letta MemFS):** `$MEMORY_DIR/skills/swan-code-check/`. MemFS is a git
  repo that syncs off the machine, so a symlink into `~/aya/sandbox/swan`
  would break on any other host. Aya refreshes it with
  `rsync -a --delete --exclude __pycache__ ~/aya/sandbox/swan/skills/swan-code-check/ "$MEMORY_DIR/skills/swan-code-check/"`
  and commits only that path in MemFS.
- **Jabari (Claude Code on the PC):** `~/.claude/skills/swan-code-check/`.
  A symlink to `~/aya/sandbox/swan/skills/swan-code-check` would also work
  here (same machine), but a copy keeps a half-merged branch checkout from
  changing his skill underneath him. Refresh with
  `rsync -a --delete --exclude __pycache__ ~/aya/sandbox/swan/skills/swan-code-check/ ~/.claude/skills/swan-code-check/`.
  Not applied by this PR: Khamani or Jabari applies it after merge.

## How a later change reaches both
1. Change the skill here on a branch; run `python3 -I skills/swan-code-check/scripts/selftest.py`
   (exit 0) and Swan's usual review; merge.
2. `git -C ~/aya/sandbox/swan pull --ff-only` (the live checkout stays on main).
3. Run the two `rsync` lines above. Each agent re-reads its skill on its next session.

Host-specific wording (how each host calls MCP tools, who may run
`swan trust`) lives in the "Calling Swan (by host)" and step 1 sections of
`SKILL.md`, so one file serves both.
