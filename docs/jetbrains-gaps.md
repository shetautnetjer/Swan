# Swan against JetBrains (WebStorm 2026.2.3's MCP server)

as_of: 2026-10-26. The tool list was read from WebStorm's own MCP server
(`tools/list`, 44 tools). The comparison used read-only calls only, against
AEON as WebStorm had it open, and Swan's map of the same checkout.

This records a historical comparison. The table below is the baseline
before the changes in "Built since"; it is not a current missing-feature
list or a claim of JetBrains parity. Swan's reference graph still includes
non-call uses and is coarser than an IDE's call hierarchy.

## Tool by tool (baseline before the follow-up)

| JetBrains tool | What it does | Swan | Status |
|---|---|---|---|
| `search_symbol` | find classes, functions and fields by name | `find_symbol` | done |
| `analyze_calls` (incoming / outgoing, depth) | call hierarchy tree | `get_callers` / `get_callees` | done, with differences below |
| `rename_refactoring` | rename across the project | `rename_symbol` (plan, then apply) | done for compiler-resolved uses |
| `get_symbol_info` | what is at file:line:column: declaration, type, docs | none: Swan looks symbols up by name only | **missing** |
| `get_file_problems`, `lint_files` | IDE inspections: errors plus warnings, style, unused, likely bugs | `get_diagnostics`: compiler errors only (tsc, pyright, cargo, javac, clang) | partial: no linters |
| `build_project` | build and report errors | `check_errors` | done (as a check, not a build) |
| `reformat_file` | apply the formatter | none | **missing** |
| `get_run_configurations`, `execute_run_configuration` | run tests and programs | none: `get_callers` lists the affected test files but cannot run them | **missing** |
| `get_project_dependencies`, `get_project_modules` | dependencies and modules | outside symbols carry package and version, but no listing tool | partial |
| `run_inspection_kts`, `generate_psi_tree` | custom inspections over the syntax tree | none; the map's SQL could serve as custom queries | missing (lower value) |
| `read_file`, `search_text`/`regex`/`file`, `list_directory_tree`, `create_new_file`, `apply_patch`, `open_file_in_editor` | files and text | the agent's own tools do this | out of scope |
| `git_status`, `get_repositories`, `execute_terminal_command`, database tools | VCS, shell, databases | the agent's own tools do this | out of scope |

## JetBrains as an oracle: callers on live AEON

Direct callers (depth 1) from `analyze_calls` against `get_callers`:

| Function | JetBrains | Swan | Both | What the difference is |
|---|---|---|---|---|
| `debugWarn` | 94 | 118 named + 66 at file top level | 85 | The 66 are Swan counting `import` lines, which JetBrains leaves out of a call hierarchy. The rest is granularity: JetBrains names the inner arrow function or callback a call sits in (`onComplete`, `recompile`), while Swan names the nearest named definition around it, because SCIP drops locals. |
| `setActiveRuntime` | 13 | 12 | 11 | the same granularity difference |
| `summarizeConversation` | 2 | 2 | 0 | the same two calls: JetBrains says the local `response` closure, Swan the function holding it |
| `getOrCreateScopedRuntime` | 6 | 50 | 1 | **a real gap**: nine functions share the name, and Swan merged all their callers where JetBrains picked one |
| `createRuntime` | 0 | 33 | 0 | four functions share the name; JetBrains returned nothing until given an exact signature, Swan merged them |

So, three findings:
1. A name matching several definitions merges their answers. JetBrains asks
   for an exact one instead.
2. Imports count as references, and so as callers. That is right for "who
   uses this", noisy for "who calls this".
3. A call is attributed to the nearest named definition, not to the
   anonymous function around it. That is coarser than JetBrains, but often
   what an impact question wants.

## Built since (2026-10-26)

1. Exact targets: impact questions with a shared name come back with the
   candidates. Import lines are found from the source and left out of
   callers. Re-checked on live AEON, per exact definition: Swan's caller
   files include every one WebStorm lists, plus calls WebStorm's hierarchy
   missed (checked with ripgrep).
2. `get_symbol_at`, with documentation prose: the definition, signature and
   docs agree with WebStorm's `get_symbol_info` at the spots compared.
3. `tools/modules.json`: ruff/biome/clippy into `get_diagnostics`,
   `format_file`, and `run_tests` for the tests that reach a symbol.

## Recommended next, by value when AYA edits code (as written before building)

1. **Exact targets and calls only.** When a name matches several
   definitions, answer per definition and say so, or ask for
   `relative_path`. Record SCIP's Import role, so `get_callers` can leave out
   import lines while `find_referencing_symbols` still shows them, flagged.
2. **`get_symbol_at`: what is at file:line:column.** The definition,
   signature, docs and kind, straight from the occurrences table: the
   reading-code question an agent asks most, and JetBrains' `get_symbol_info`.
3. **Tests, linters and formatters after an edit.** Run the affected tests
   that `get_callers` already finds (bun test, pytest, cargo test), and run
   linters (eslint, ruff, clippy) and formatters (prettier, ruff format,
   rustfmt) into the same diagnostics.
