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
- Read the map report and its `skipped` entries. Some indexers run the repo's
  build files, and a repo-local Python environment can execute repo code.
  **Never grant trust automatically.** Run `<swan-binary> trust <exact-repo>`
  only with the user's explicit authorization to trust that repository and
  run its build code. Repository ownership or an agent's identity does not
  grant trust. Never enable the global `SWAN_TRUST_BUILD=1` override. If trust
  is absent, continue within the available coverage and report what skipped.
- `index_info {"repo":"<repo>"}`: refresh when `stale_file_count > 0` or the
  repo has commits since `refreshed_at`/`built_at`, using `update_map` within
  the caller's execution scope. New files count in `new_file_count`; if that
  field is absent, refresh on any new file because older maps can miss it.
  Languages never indexed can remain outside freshness coverage.
- Check a known symbol with `find_symbol` and confirm its file and line.
  Before acting on references, compare their files with `rg -l <name>`;
  mismatches require investigating stale or partial coverage.

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
  authorization and report unavailable or skipped coverage. Refresh stale
  maps before relying on structural answers about changed files.
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
  directory for inspection. The map is `DIR/map/swan.db`. Never point it at
  shared maps. Exit 0 means all 24 patterns match exactly; it does not qualify
  live diagnostics or index completeness for another repository.
