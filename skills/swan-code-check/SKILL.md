---
name: swan-code-check
description: Use Swan, the local compiler-accurate code map (MCP server `swan`), whenever you touch code in a repo or review one: before editing a shared function, class or type (who uses it, what breaks, which tests to run), after editing (live compiler errors, only the affected tests), when reviewing a diff or PR (impact plus a validated security/quality pattern sweep), before handing coding to another agent (blast radius and tests go in its prompt), for renames, implementations, dead code. TS/JS, Python, Rust, Java, Kotlin, C/C++/CUDA, C#, Lua, GDScript, shaders. Trigger on "who calls", "what breaks", "impact", "find usages", "code review", "security review", "find errors", "rename", "unused code", or any non-trivial code edit.
---

# Swan code check

Swan answers "where is it, who uses it, what breaks, which tests" from the
compiler's own index (SCIP) in milliseconds, plus live diagnostics, targeted
tests and syntax-tree pattern search. Ask Swan before grep for structure; use
`rg` to cross-check completeness.

This file's single source is the Swan repo (`skills/swan-code-check/`); see
`PROVENANCE.md` there for how installed copies follow it.

- Binary `~/aya/sandbox/swan/bin/swan`; maps in `~/aya/sandbox/swan/data/<name>/swan.db`.
- Swan is Khamani's project, maintained with Aya (repo `~/aya/sandbox/swan`,
  github shetautnetjer/Swan). The maps are shared: don't delete them.
- Register it as `swan serve --maps ~/aya/sandbox/swan/data`: one server,
  every map. Every tool takes an optional `repo` (a path in the repo); a call
  without one fails loudly ("no repo selected") instead of answering about
  some other repo.

## Calling Swan (by host)

- **Claude Code (Jabari):** tools are `mcp__swan__*` (if deferred, load them
  with ToolSearch `+swan`). One server stays up for the session, so `use_repo`
  carries over between calls.
- **Letta / AEON (Aya):** `letta mcp call mcp__swan__<tool> --args '<json>'`.
  Each call starts a fresh server, so a `use_repo` switch does not carry over:
  **pass `"repo": "<path in the repo>"` on every call.** Batch questions into
  fewer calls (`depth`, `max_results`); each call costs about 0.5 s of CLI start.
- **No MCP:** `swan query <db> symbol|refs|callers|callees|impls|unused|diag|pattern <arg> [relative_path]`.

## 1. Start (once per repo per task)

1. `use_repo {"path": "<repo>"}`: picks the repo's map, building one on first
   use. Indexers that run the repo's own build files (Gradle for Kotlin/Java,
   Python virtualenvs) wait for `swan trust <repo>`; the answer's `skipped`
   says which. Trusting runs those build files: Aya decides for Khamani's own
   repos; other agents say what was skipped and ask Khamani. Pattern search
   works without an index.
2. `index_info {"repo"}`: refresh when `stale_file_count > 0` **or when the
   repo has commits since `refreshed_at`/`built_at`**. Files added after a
   build count as stale too and are listed in `new_file_count` (Swan #9,
   839c4b0, live since 2026-11-01). If `new_file_count` is missing, the
   binary predates #9 and new files are invisible, so refresh on any new file.
   - Small repo: `update_map {"repo"}`.
   - Large repo (AEON, ~2.4k files) from a shell, one build at a time
     (`pgrep -f "swan map"` first), memory-capped:
     `systemd-run --user --scope -q -p MemoryMax=8G ~/aya/sandbox/swan/bin/swan map <repo> ~/aya/sandbox/swan/data/<name>`
     (AEON ~13 s, evolve ~2 s). `<name>` is the map dir `use_repo` reported.
3. Known-answer check: `find_symbol` on a symbol you can see, confirm file and
   line. Before acting on a reference list, compare its files once with
   `rg -l <name>`; a mismatch means a stale or partial map.

## 2. Before editing (or briefing another coding agent)

- `get_callers {"repo","name_path","depth":2}`: `summary.files` is the blast
  radius; `summary.test_files` go into the test run and the coder's prompt.
- `find_implementations` for interfaces, base classes, overridable methods.
- `get_callees` shows what a symbol depends on, with dependency package versions.
- An `ambiguous` answer needs the exact path (`/Store/add`) or `relative_path`.

## 3. After editing

- `get_diagnostics {"repo","relative_path","live":true}` per touched file
  (real language server, 0.4–4 s), or `check_errors {"repo"}` for everything.
- `run_tests {"repo","name_path"}` (or `relative_path`) runs only the tests
  that reach the change, with the repo's own runner (pytest, bun/vitest, cargo).
- Answers about edited files carry `stale: true`; refresh (`update_map`)
  before more structural questions about them.

## 4. Reviewing a diff or PR

1. `git diff --name-only <base>...HEAD`; `get_symbols_overview` per changed
   file (or `get_symbol_at` on hunk lines).
2. `get_callers {"depth":2}` per changed shared symbol; read the callers the
   diff didn't touch (that's where regressions hide).
3. `get_diagnostics {"live":true}` on changed files.
4. Pattern sweep: every entry in `references/patterns.json` via
   `search_pattern {"repo","pattern","language","relative_path"}`, plus
   `rg -n 'shell:\s*true|rejectUnauthorized:\s*false|NODE_TLS_REJECT_UNAUTHORIZED|verify\s*=\s*False'`.
   A hit is a lead to read, not a finding.
5. Report each finding with file:line and the Swan evidence (callers, test files).

## Pattern rules (verified by `scripts/selftest.py`)

- Patterns are complete code in the target language; pass `language`.
  Fragments mislead silently: `shell: true` alone parses as a JS label and
  matches nothing anywhere; `{ a: 1, $$$ }` at statement start parses as a
  block. **`files_searched: 0` means "didn't apply", never "clean".**
- Wildcards inside template literals don't match: search `execSync($$$)` and
  read the first argument.
- Matcher bug (open as of Swan 839c4b0): a `$$$` beside a comma must match at
  least one node, though the docs say none is fine. `os.system($X, $$$)`
  misses `os.system(x)`; `{ $$$, shell: true }` misses `{ shell: true }`. The
  pack carries both variants; the self-test's canaries say PRESENT until the
  goose-treesitter fix lands, then FIXED.
- New pattern: add a tagged line to `fixture/sec.*` and an entry to
  `patterns.json`, then `python3 -I scripts/selftest.py` (exit 0 = every
  pattern hits exactly its tags; `--swan PATH` picks the binary,
  `SWAN_SELFTEST_OUT` or `--out` the scratch dir).

## Editing tools and limits

- `rename_symbol` and `rewrite_pattern` plan first (no `apply`); apply only
  after reading the plan. Both refuse stale files. Strings, comments and
  run-time-by-name uses are not covered.
- On AEON keep Swan read-only (no apply, rename, rewrite, format) unless
  Khamani okays edits.
- `find_unused_symbols` gives candidates only: entry points, code reached by
  name and build output such as `dist/` bundles appear too.
- Swan answers from the map: changed or new files are only right after a refresh.
