---
name: swan-code-check
description: >-
  Use Swan for symbol lookup, references, callers, change impact,
  diagnostics, targeted tests, structural pattern search and planned renames
  when editing or reviewing a code repository. Build the repo's map on first
  use and refresh it after edits; say which answers came from the compiler
  and which were matched by name.
---

# Swan code check

Swan answers "where is it, who uses it, what breaks, which tests" from a
map of the repository, with live diagnostics and syntax-tree pattern search.
Use `rg` to cross-check completeness. Available languages and live features
depend on the installed indexers, checkers and language servers.

This directory is maintained in the Swan repository at
`skills/swan-code-check/`; see [PROVENANCE.md](PROVENANCE.md).

## Find the available Swan

1. Use the **configured Swan MCP connection** if the host has one, and read
   its actual tool schemas; tool names and prefixes differ by agent.
2. Otherwise use `swan` on `PATH`, `SWAN_BINARY`, or the standard install at
   `~/.local/share/swan/current/bin/swan`. Use one exact binary throughout;
   a checkout, a package prefix and `PATH` can hold different versions.
3. `<swan-binary> doctor --profile python-typescript --json` reports which
   indexers and language servers are installed. It does not prove a repo is
   indexed; the map report does that.

Install or update Swan, its MCP entry for Claude Code and pi, and this skill
with one command from a Swan package folder:
`swan-up install --dist <package-folder>` (see the Swan repo's
`docs/install.md`). Running Swan servers keep their old version until their
agent restarts.

CLI fallback: `<swan-binary> query <db> symbol|refs|callers|callees|impls|unused|diag|pattern <arg> [relative_path]`,
and `<swan-binary> map <repo> <map-dir>` to build or refresh a map.

## Build and refresh maps yourself

Maps are how Swan answers. Build and refresh them without asking:

- **First use:** call `use_repo {"path":"<absolute-repo-root>"}`. It builds a
  map when none covers the repo (`build` defaults to true). The map goes in
  the server's map directory (`serve --maps <dir>`), never inside the repo.
- **After edits, a branch or worktree switch, or a pull:** call `update_map`
  before the next indexed answer (callers, impact, rename plans, affected
  tests). Batch a set of edits and refresh once, not after every keystroke.
- **After dependency, lockfile or indexer-config changes:** refresh with
  `update_map {"repo":"<exact-repo-root>","clean":true}` (CLI:
  `<swan-binary> map <repo> <map-dir> --clean`), because a plain refresh can
  reuse cached compiler output. A failed clean rebuild keeps the old map;
  report the failure rather than calling old answers current.
- Read `index_info {"repo":"<repo>"}` at task start and after a change batch.
  Freshness uses file timestamps; `new_file_count` only sees new files with
  extensions already indexed.
- Confirm the returned repo root and map cover the worktree you are in;
  another branch's checkout is not interchangeable.
- Check one known symbol with `find_symbol` and confirm its file and line,
  then cross-check important references with `rg -l <name>`.

**Trust is separate from maps.** Some indexers and checkers run the repo's
own build files (Cargo, Maven, Gradle, MSBuild, a repo `.venv`). Swan skips
those until the repo is trusted, and lists them under `skipped`. Run
`<swan-binary> trust <exact-repo>` only when the person has said that repo
may run its build code. Never set `SWAN_TRUST_BUILD=1`. Without trust, keep
working within the coverage you have and report what was skipped.

## Say what kind of evidence each answer is

Report every finding with its evidence kind. Never merge them into one
"supported" or "clean":

| Kind | Where it comes from | How sure |
| --- | --- | --- |
| Compiler | SCIP indexers: TypeScript/JavaScript, Python, Rust, Java, Kotlin, C, C++, CUDA, C# (only those the map report shows ran) | Resolved by the compiler: exact |
| Matched by name | Rows marked `by_name: true`; whole syntax-level languages below; Rust uses inside unresolved macros | An identifier with the same name: a lead, not proof. Two things with one name are not told apart |
| Structural pattern | `search_pattern` on on-disk syntax | Shape of the code only; check `files_searched`, `pattern_does_not_parse_in`, `truncated` |
| Live diagnostics, checks, tests | The language server, checker or test runner actually run | Only what the call returned; "available" is not "passed" |

**Syntax-level languages** (definitions, bodies and references by name, no
compiler): Go, shell scripts (including ones known only by their `#!` line),
Makefiles, Ruby and Lua. Callers and impact in these are name matches; say so.

**Known blind spots: never call these areas clean.**

- Express-style calls made through a local name (`const r = express.Router();
  r.get(...)`, an aliased `app`): the route and its handler may not be linked.
- Shell scripts that hand off to another language (`python x.py`, `node`,
  `bun`, heredocs): the call into the other file is not followed.
- Unnamed callbacks and inline functions passed as arguments: they have no
  name path, so callers/callees through them are incomplete.
- Strings, comments, config and anything reached by name at run time
  (reflection, `getattr`, dynamic imports, routing tables).

When a question touches one of these, check with `rg` and read the code, and
say in the answer which part rests on that check.

If `files_searched` is 0, the pattern did not apply: that is "not checked",
never "clean". If `truncated` is true, raise `max_results` or narrow
`relative_path` before calling a sweep complete.

## Editing and review

- Before changing a shared symbol, use `get_callers` with `name_path` and
  `depth:2`. `summary.files` is the impact radius; `summary.test_files`
  guide validation. Use `find_implementations` for interfaces and base
  classes and `get_callees` for dependencies. Disambiguate with an exact
  name path such as `/Store/add` or `relative_path`.
- After editing, refresh the map, then `get_diagnostics` with
  `relative_path` and `live:true` if supported, or `check_errors`.
  `run_tests` with `name_path` or `relative_path` runs affected tests.
  Diagnostics and map freshness are separate: passing diagnostics do not
  refresh the graph, and a refreshed map does not prove tests pass.
- For a diff: changed files (`git diff --name-only <base>...HEAD`), their
  symbols (`get_symbols_overview`), callers beyond the diff, then
  diagnostics. For a security or quality sweep, run the entries in
  [references/patterns.json](references/patterns.json) through
  `search_pattern` with `language` and `relative_path`, and cross-check with
  `rg -n 'shell:\s*true|rejectUnauthorized:\s*false|NODE_TLS_REJECT_UNAUTHORIZED|verify\s*=\s*False'`.
  A hit is a lead to read, not a finding.
- `rename_symbol` and `rewrite_pattern` plan first (omit `apply`). Read the
  plan, then apply edits that are part of your task. A review-only request
  does not ask for edits. A stale-file refusal means refresh and replan.
  Strings, comments and by-name uses are outside rename coverage.
- `find_unused_symbols` returns candidates: entry points, code reached by
  name and build output such as `dist/` bundles can appear.

At completion, report the repo/worktree and map used, its freshness and any
refresh, checks and tests actually run with their results, which answers
were compiler-resolved and which were matched by name, and any blind spot
the task touched.

## Pattern rules and self-test

The unchanged fixture and 24-pattern pack are checked by
`scripts/selftest.py`.

- Use complete code patterns and pass `language`. `shell: true` alone parses
  as a JS label; `{ a: 1, $$$ }` at statement start parses as a block.
- Wildcards inside template literals do not match: search `execSync($$$)`
  and read the first argument.
- Known matcher canaries track the empty-`$$$`-beside-a-comma issue observed
  in Swan 839c4b0: `os.system($X, $$$)` misses `os.system(x)` and
  `{ $$$, shell: true }` misses `{ shell: true }`. Keep both variants or an
  `rg` check. The self-test reports PRESENT, FIXED or CHANGED; the JS-label
  canary reports TRAP.
- For new patterns, add tagged fixture lines and a pack entry, then run
  `python3 -I <skill-directory>/scripts/selftest.py --swan <exact-binary>`.
  Omit `--swan` to use `SWAN_BINARY`, then `swan` on `PATH`. Output goes to
  a disposable temporary directory unless `--out DIR` is given; never point
  it at shared maps. Exit 0 means all 24 patterns match; it does not qualify
  live diagnostics or index completeness for another repository.
