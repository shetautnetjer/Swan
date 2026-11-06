---
name: swan-code-check
description: >-
  Use Swan for compiler-indexed symbol lookup, references, change impact,
  diagnostics, targeted tests, structural pattern search and planned renames
  when editing or reviewing a code repository. Use the existing Swan
  connection or installation; report incomplete indexing and missing tools.
---

# Swan code check

Swan answers "where is it, who uses it, what breaks, which tests" from a
compiler-produced SCIP map, with live diagnostics and syntax-tree pattern
search. Use `rg` to cross-check completeness. Available languages and live
features depend on the installed indexers, checkers and language servers.

This directory is maintained in the Swan repository at
`skills/swan-code-check/`; see [PROVENANCE.md](PROVENANCE.md).

## Find the available Swan

1. Discover a **configured Swan MCP connection** in the host's available
   tools and read its actual tool schemas. Use its advertised names and
   arguments; tool discovery and MCP naming differ by agent. Do not assume
   another agent's CLI or API exists, or install/configure a server as part
   of using this skill.
2. If no connection is available, use an explicitly supplied executable,
   `SWAN_BINARY`, or `swan` on `PATH`. Resolve a command name with the host's
   executable lookup before treating it as a file path. Use the exact
   installation's binary throughout; a checkout, package prefix and `PATH`
   can contain different versions. The bundled self-test follows this rule.
3. With a packaged binary, run that exact executable's
   `doctor --profile core --json`, or `doctor --profile python-typescript --json`
   for this skill's fixture. Doctor reports dependency availability; it does
   not prove a repository is indexed or a language feature works. Read any
   missing dependencies and the map report before claiming readiness. If an
   older binary has no `doctor`, report that limitation and inspect its
   actual command help and build output.

CLI fallback: `<swan-binary> query <db> symbol|refs|callers|callees|impls|unused|diag|pattern <arg> [relative_path]`.
A new stdio MCP process can be launched with
`<swan-binary> serve --maps <explicit-map-root>` when the caller has authorized
that execution. Choose a writable map directory; preserve existing maps.
The package includes this skill for copying to the caller's chosen skill
location; it does not register agent settings or an MCP connection.

## Start once per repo per task

- Resolve the target repository's absolute path. Call
  `use_repo {"path":"<repo>"}`; use `"build":false` when only an existing
  map may be read. First-use building writes a map and can run indexers.
- **Pass `"repo":"<repo>"` on every subsequent repository tool call**, even
  if a persistent server remembers `use_repo`. Stateless host wrappers start
  fresh processes; selection in an earlier call does not carry over.
- Confirm the returned repo root and map path cover the intended worktree;
  another branch's checkout is not interchangeable. Give a brief initial
  coverage summary for the task's languages/files from the actual tool
  schemas, `use_repo`/map report, `index_info`, and doctor when available.
  Distinguish these modes rather than reporting one overall "supported":

  | Mode | Evidence and boundary |
  | --- | --- |
  | Structural patterns | Advertised grammar plus an applicable search; reads on-disk syntax, not compiler-resolved references. Inspect `files_searched`, `pattern_does_not_parse_in` and `truncated`. |
  | Indexed symbols/references | Map report and a known-symbol/reference check; limited to files and languages the SCIP indexers actually included. |
  | Live diagnostics/checks/tests | Installed adapter/runner plus the actual call result; availability alone does not prove execution or success. |

  Mark unverified, skipped, failed or not-installed coverage explicitly.
  Doctor's selected profile covers dependencies only; `unselected` does not
  establish that an optional tool is absent. An existing map's empty
  `skipped`/`report` does not prove every indexer ran. Do not invent a
  capability API, or call an unsearched/unindexed area clean.
  If `truncated` is true, increase `max_results` or narrow `relative_path`
  and repeat until the relevant matches are inspected before calling a
  structural sweep complete.
- Read the map report and its `skipped` entries. Some indexers run the repo's
  build files, and a repo-local Python environment can execute repo code.
  **Never grant trust automatically.** Run `<swan-binary> trust <exact-repo>`
  only with the user's explicit authorization to trust that repository and
  run its build code. Repository ownership or an agent's identity does not
  grant trust. Never enable the global `SWAN_TRUST_BUILD=1` override. If trust
  is absent, continue within the available coverage and report what skipped.
- Check a known symbol with `find_symbol` and confirm its file and line.
  Cross-check relevant references with a focused `rg -l <name>` search;
  mismatches require investigating stale or partial coverage. Expand scope
  when the evidence requires it, rather than repeating full-repo scans.

## Refresh at task boundaries

- Read `index_info {"repo":"<repo>"}` at task start and after a relevant
  change batch, not before every lookup. Refresh with `update_map` within the
  caller's execution scope when files are stale or added, or the repository
  has changed since the map's `refreshed_at`/`built_at`.
- Recheck repo/map identity after switching branches, revisions or worktrees.
  Refresh before relying on indexed answers when that switch changes source,
  or generated sources change. Zero stale files is not proof of an
  unchanged compiler view: freshness primarily uses file timestamps;
  `new_file_count` only sees newer files with extensions already indexed.
  Languages never indexed and deliberately excluded files can remain outside
  coverage even after refresh. If `new_file_count` is absent, refresh on new
  files rather than trusting the older binary's freshness count.
- Dependency, lockfile, compiler/indexer configuration and other build-input
  changes need more than freshness checks: `update_map` can reuse cached
  SCIP output. For example, TypeScript cache keys omit `package-lock.json`
  and `node_modules`. Within the caller's execution scope, create a new private
  registry root and build its sole map child with
  `<swan-binary> map <repo> <private-root>/fresh`. Use canonical absolute paths.
  Map discovery selects by repo-root matches, not creation time: launch a
  private `<swan-binary> serve --maps <private-root>`, call
  `use_repo {"path":"<repo>","build":false}` on it, and verify the returned
  `root` is exactly `<repo>`, `map` is exactly `<private-root>/fresh/swan.db`,
  and `built` is false. Send every subsequent `repo` call to this private
  server; stateless wrappers must launch with the same private `--maps` root.
  Preserve configured maps and server settings. If the host cannot route to
  that private server, use the exact database directly, for example
  `<swan-binary> query <private-root>/fresh/swan.db symbol <name> [relative_path]`.
  Otherwise mark affected indexed answers unverified; refresh success alone
  is insufficient.
- Batch coherent edits and refresh once before the next indexed impact query,
  rename/rewrite plan, or affected-test selection that depends on a changed
  graph. Avoid rebuilding after every edit; on-disk pattern searches and
  supported live diagnostics can inspect intermediate changes. Read the
  refresh result and verify the relevant known symbol/coverage again; a
  completed refresh does not prove excluded files are now indexed.

## Editing and review

All examples below also require `repo` as above. Read the advertised schema
for exact argument names.

- Before changing a shared symbol, use `get_callers` with `name_path` and
  `depth:2`. `summary.files` is the impact radius; `summary.test_files` guide
  validation and any coding handoff. Use `find_implementations` for
  interfaces/base classes and `get_callees` for dependencies. Disambiguate
  with an exact name path such as `/Store/add` or `relative_path`.
- After editing, request `get_diagnostics` with `relative_path` and `live:true`
  if supported, or `check_errors` for the repo. `run_tests` with `name_path`
  or `relative_path` runs affected tests through the repo's runner. Checkers,
  live servers and tests execute code: stay within the caller's task
  authorization and report unavailable or skipped coverage. Diagnostics and
  map freshness are separate: successful live diagnostics or `check_errors`
  does not refresh the reference graph, and refreshing the map does not prove
  diagnostics or tests passed.
- For a diff, inspect changed files (`git diff --name-only <base>...HEAD`),
  their symbols (`get_symbols_overview` or `get_symbol_at`) and callers beyond
  the diff, then diagnostics. For a security/quality sweep, run applicable
  entries in [references/patterns.json](references/patterns.json) through
  `search_pattern`, passing `language` and the intended `relative_path`.
  Cross-check with
  `rg -n 'shell:\s*true|rejectUnauthorized:\s*false|NODE_TLS_REJECT_UNAUTHORIZED|verify\s*=\s*False'`.
  A hit is a lead to read, not a finding. Report findings with file:line and
  the relevant Swan evidence; disclose incomplete coverage.
- `rename_symbol` and `rewrite_pattern` plan first (omit `apply` or use false).
  Read the plan before applying. Apply only edits covered by the caller's
  task authorization; a review-only request does not authorize mutation.
  Other editing tools, formatting and deletion have the same scope boundary.
  Stale-file refusal requires refresh and replanning. Strings, comments and
  runtime-by-name uses are outside compiler-resolved rename coverage.
- `find_unused_symbols` returns candidates: entry points, code reached by
  name and build output such as `dist/` bundles can appear.

At completion, report the actual repo/worktree and map used, observed map
freshness and any refresh, checks/tests actually run and their results, and
remaining language/file or adapter limitations. Tie "no findings/errors" to
the inspected scope and successful checks; unavailable, skipped, stale or
unverified coverage remains unknown.

## Pattern rules and self-test

The unchanged fixture and 24-pattern pack are checked by
`scripts/selftest.py`.

- Use complete code patterns and pass `language`. `shell: true` alone parses
  as a JS label; `{ a: 1, $$$ }` at statement start parses as a block.
  **`files_searched:0` means "didn't apply", never "clean".**
- Wildcards inside template literals do not match: search `execSync($$$)`
  and read the first argument.
- Known matcher canaries track the empty-`$$$`-beside-a-comma issue observed
  in Swan 839c4b0: `os.system($X, $$$)` misses `os.system(x)` and
  `{ $$$, shell: true }` misses `{ shell: true }`. Keep both variants or an
  `rg` check. The self-test reports PRESENT, FIXED or CHANGED; the JS-label
  canary reports TRAP. These are observations to verify on the chosen binary.
- For new patterns, add tagged fixture lines and a pack entry, then run
  `python3 -I <skill-directory>/scripts/selftest.py --swan <exact-binary>`.
  Omit `--swan` to use `SWAN_BINARY`, then `swan` on `PATH`.
  The default output is a new disposable temporary directory, removed at
  exit. `--out DIR` (or `SWAN_SELFTEST_OUT`) retains a new, empty output
  directory for inspection. The map is `DIR/map/swan.db`; the test requires
  that exact existing map and refuses to build a replacement during searches.
  It selects the map once with `build:false` in its private persistent server,
  then omits `repo` during searches to prevent implicit rebuilding. This is
  specific to the self-test; normal host wrappers still pass `repo` each call.
  `--map-swan` may choose a separate builder, whose map must be compatible
  with the server binary. Never point the output at shared maps.
  Exit 0 means all 24 patterns match exactly; it does not qualify
  live diagnostics or index completeness for another repository.
