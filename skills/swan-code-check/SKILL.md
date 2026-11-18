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

Swan runs every indexer sealed (no network, no host sockets, every mount
read-only, writes only to the map dir), trusted or not, so any repo can be
mapped headless. **Never ask the person to trust a repo.** Rust (Cargo build
scripts and proc macros included) maps sealed and offline with no trust step.
`swan trust <repo>` only loosens the seal (network plus writable repo and
build caches); today Gradle, Maven and MSBuild indexers still wait for it.

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

**Refreshing is cheap.** Since 2026-11-15 Swan stamps files on every core
and flattens indexes with a native Rust flattener (`bin/swan-flatten`), so a
refresh after a code edit takes a few seconds even on a large repo (about
3 s on rea, down from 9 s). Refresh after each batch of edits rather than
answering from a stale map. The outside indexers still take most of a first
map's time, and a code edit in Python reruns scip-python for its piece,
which starts the type checker cold: about 30 s on a 700-file repo (a
comment-only edit is free). Batch Python edits before refreshing. A map runs
no Bun: the flattener is Rust and the syntax-level index is built into
Swan. Leave Swan's speed settings at their defaults. To check whether
a wrong answer comes from the new steps, map once with
`SWAN_STAMP_JOBS=1` (the old one-process stamping) and compare. `SWAN_FLATTEN_PROFILE=quick` only matters
to someone changing Swan's own Rust code: it makes `scripts/build.sh`
rebuild the flattener faster and does not change how Swan answers. See
`docs/speed.md` for the numbers and every setting.

**Read the map report for what the map does not cover.** `use_repo` and
`update_map` return it as `report` (the CLI prints it). An answer of "no
references" means little for code the map never held, so before relying on
one, look for these lines and pass them on:

| Line in the report | What it means for your answers |
|---|---|
| `not mapped, git ignores these folders: ...` | Nothing under them is in the map (build output, generated code, leftovers). Uses of code generated there resolve to symbols with no definition. |
| `rust project <dir>: ... not mapped, the map goes on without it` | A cargo project inside the repo (a fuzz crate, an excluded tool) could not be loaded; cargo's reason follows. The rest of the map is sound. |
| `rust: no rows for these crates: ...` | These crates are in no cargo project that was mapped. Treat them as unmapped. |
| `rust: N more cargo projects not mapped` | The repo has more than twelve cargo projects; the rest were not run. |
| `rust: the repo pins toolchain ...` | The pinned Rust is missing or older than the installed default: Swan indexed with the default, or read the default's standard library. Answers hold; mention it if a Rust result looks odd. |
| `typescript: N more tsconfig projects own files ...; M could not be read by tsc` | Each package is indexed under its own tsconfig. The M unreadable ones (their config extends a package that is not installed) fall back to the root config, where their aliases and JSX settings do not apply. |
| `scip-typescript: Swan's stable names are not applied ...` | TypeScript ran as one slower process. Answers hold. |
| `(some indexers failed; see above)` | A whole language may be missing or stale. Say which, from the lines above it. |

Rust is indexed with every cargo feature on, so code under
`#[cfg(not(feature = "..."))]` is the part matched by name.
`<swan-binary> cargo-projects <repo>` prints which cargo projects a map
would run and with what settings, and runs nothing.

**Don't ask for trust; work with what the seal covers.** Rust maps sealed
and offline for any repo, against the crates already in Cargo's cache: a
crate that isn't cached leaves its uses unresolved, so say so. Gradle,
Maven and MSBuild indexers, `swan check`'s Cargo checks and a repo `.venv`
still wait for trust and appear under `skipped`; report them as not run.
Run `<swan-binary> trust <exact-repo>` only when the person has asked for it
for that repo. Even then the repo runs sealed: trust adds the network and
write access to the repo and its build caches, nothing else. Never set
`SWAN_TRUST_BUILD=1`.

## Find your way first

When the server lists them (Swan from 2026-11-18 on), four tools answer
from Spread-Wings, a syntax-level graph Swan builds beside the map in
seconds:

- `repo_overview` in a repo you do not know: its groups of files, their main
  files and most-called definitions. Start here, then use the exact tools on
  what looks relevant.
- `what_touches {"name": ...}` before changing a definition: the files that
  define, call or import it, which are tests, and the groups they sit in.
- `file_neighbors {"relative_path": ...}`: what a file imports, who imports
  it, where its calls go.
- These three, and `touches` in a planned `edit_batch`, are of the files as
  they are now, not as they were when the map was made. When files changed
  since the last such answer it carries `files_changed`: which files, the
  files that import or call into them (`reaches`), and the tests among
  them (`tests`): run those. The exact tools are not refreshed by this.
- `repo_projects`: the projects the repo holds (each `package.json`,
  `pyproject.toml`, `Cargo.toml`, `go.mod`), with the package manager and
  versions each wants and whether its dependencies are installed. Read it
  before running a project's tests or tools, so you use its own package
  manager in its own folder (`bun test` in a bun package, not `npm test` at
  the top), and before trusting an answer about a library call in a project
  whose dependencies are not installed.

They are broad and quick, not exact: report them as "broad map" evidence
(below), never as the list of sites an edit must change.

## Say what kind of evidence each answer is

Report every finding with its evidence kind. Never merge them into one
"supported" or "clean":

| Kind | Where it comes from | How sure |
| --- | --- | --- |
| Compiler | SCIP indexers: TypeScript/JavaScript, Python, Rust, Java, Kotlin, C, C++, CUDA, C# (only those the map report shows ran) | Resolved by the compiler: exact |
| Matched by name | Rows marked `by_name: true`; whole syntax-level languages below; Rust uses inside unresolved macros | An identifier with the same name: a lead, not proof. Two things with one name are not told apart |
| Structural pattern | `search_pattern` on on-disk syntax | Shape of the code only; check `files_searched`, `pattern_does_not_parse_in`, `truncated` |
| Broad map | `repo_overview`, `what_touches`, `file_neighbors`, and `touches` in a planned `edit_batch` (Spread-Wings, by syntax) | Links matched by import, by the type a call names, and by name: for finding your way and for "what might this reach". Each answer carries `"source":"spread-wings"`; confirm what matters with `find_referencing_symbols` or `get_callers` |
| Live diagnostics, checks, tests | The language server, checker or test runner actually run | Only what the call returned; "available" is not "passed" |

**Syntax-level languages** (definitions, bodies and references by name, no
compiler): Go, shell scripts (including ones known only by their `#!` line),
Makefiles, Ruby and Lua (`swan syntax-index`, built into Swan). Callers and
impact in these are name matches; say so.

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
- A change that reaches more than one place goes through `edit_batch`: a
  list of edits (`rename_symbol`, `replace_symbol_body`,
  `insert_after_symbol`, `insert_before_symbol`, `rewrite_pattern`) planned
  together without `apply`, then applied in order, all or nothing. If one
  edit fails, the map and every file already written go back. Renaming a
  method renames its family (what it implements or overrides, and their
  other implementations); the plan lists them as `also_renamed`.
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
