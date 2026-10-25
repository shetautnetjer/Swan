# Swan vs Serena, and the road to IDE-level understanding

as_of: 2026-10-25. Serena's tool list was read from the installed
`serena-agent` package (its `serena/tools/*.py` classes). SCIP indexer status
was checked on GitHub the same day. Language maturity notes are working
judgement, not measured.

## 1. Parity with Serena

Serena has two back ends: language servers over LSP, and a JetBrains plugin.
The JetBrains back end adds refactoring tools that LSP lacks.

### Reading code

| Serena tool | Swan today | Status |
|---|---|---|
| `find_symbol` | `find_symbol` (name paths, substring, body) | done |
| `find_referencing_symbols` | `find_referencing_symbols` (with enclosing symbol and source line) | done |
| `get_symbols_overview` | `get_symbols_overview` (file or directory) | done |
| `find_declaration` | covered by `find_symbol`; no "declaration at this file and line" lookup | partial |
| `find_implementations` | `find_implementations` (classes, subclasses, method overrides, any depth) | done |
| JetBrains `type_hierarchy` | `get_type_hierarchy` (supertypes and subtypes) | done |
| `get_diagnostics_for_file` / `_for_symbol` | missing (needs `tsc` or a language server; SCIP has no live errors) | missing |
| JetBrains `list_inspections` / `run_inspections` | missing | missing |
| (no Serena equivalent) | `get_callers` impact radius, `get_callees`, `index_info` | Swan only |

### Editing code

| Serena tool | Swan today | Status |
|---|---|---|
| `replace_symbol_body` | missing; Swan already knows each symbol's body lines | missing, easy |
| `insert_before_symbol` / `insert_after_symbol` | missing; same data | missing, easy |
| `rename_symbol` (LSP), JetBrains `rename` | missing; every occurrence is known, but a safe rename must also handle strings, re-export aliases and shadowing | missing, hard |
| JetBrains `move`, `safe_delete` | missing; `safe_delete` = "zero references" check plus a delete | missing |
| `replace_content`, `replace_lines`, `delete_lines`, `insert_at_line`, `replace_in_files`, `create_text_file` | not Swan's job: AYA's harness already edits files | out of scope |

### Around the code

| Serena tool | Swan today | Status |
|---|---|---|
| `read_file`, `list_dir`, `find_file`, `search_for_pattern`, `execute_shell_command` | harness already has these | out of scope |
| memories (`write/read/list/edit/delete/rename_memory`) | AYA has her own memory owner (MemoryD) | out of scope |
| projects and config (`activate_project`, `query_project`, `get_current_config`, `onboarding`, dashboard, REPL, `restart_language_server`) | one database per repo; `index_info` | partial |

**Verdict:** for reading code, Swan already matches Serena's core and adds
an impact-radius tool, at 0.6 to 3 ms per call against Serena's ~96 ms in the
bake-off. Implementations and type hierarchy are cheap to add next. Missing
for real: live diagnostics and symbol-level editing. Rename and move are the
hardest; they are where Serena leans on JetBrains.

## 2. Languages

Every indexer below writes the same SCIP format, so Swan's flattener,
schema, tools and refresh work unchanged. A multi-language repo runs one
indexer per language and loads every result into one database: SCIP symbols
start with scheme and package manager, so languages cannot collide.

| Language | Indexer | State on 2026-10-25 | Gives | Gaps to expect |
|---|---|---|---|---|
| TypeScript / JavaScript | scip-typescript (Sourcegraph) | in use here; pushed 2026-10-23 | defs, refs, signatures, enclosing ranges, dependency symbols with versions | whole-repo reruns only (16.5 s on AEON); JS without types resolves less |
| Python | scip-python (Sourcegraph, built on Pyright) | active; pushed 2026-10-24 | defs, refs, Pyright types, dependency symbols | dynamic code (getattr, monkeypatching) is invisible; needs the virtualenv present |
| Java, Scala, Kotlin | scip-java (now `scip-code/scip-java`) | active; pushed 2026-10-22. The separate scip-kotlin repo is archived; Kotlin goes through scip-java | defs, refs, types, dependency symbols | needs a real build (Gradle, Maven, sbt), so it is slow and needs a working toolchain |
| Go | scip-go (now `scip-code/scip-go`) | active; pushed 2026-10-22 | defs, refs, implementations (Go interfaces), module symbols | needs `go` and the module cache |
| Rust | rust-analyzer's built-in `rust-analyzer scip` | rust-analyzer is very active | defs, refs, types, crate symbols | macro-heavy code resolves partly; slow on big workspaces |
| C / C++ | scip-clang (Sourcegraph) | active; pushed 2026-10-24 | defs, refs, headers | needs `compile_commands.json`; whatever the build system hides stays hidden |
| C# | scip-dotnet (Sourcegraph) | active; pushed 2026-10-25 | defs, refs, NuGet symbols | needs a buildable solution and the .NET SDK |
| Ruby | scip-ruby (Sourcegraph, built on Sorbet) | active but small (22 stars) | defs, refs | quality depends on Sorbet types; untyped Ruby resolves less |
| PHP and others | no maintained Sourcegraph indexer found | n/a | n/a | fall back to tree-sitter (names only) |

What Swan must change for many languages: run the right indexer per
language (detect by files present), store a `language` column, and fix two
TypeScript-specific spots. `kind_word` reads scip-typescript's signature
wording, and test-file detection uses JS naming. SCIP's own `kind` field is
already flattened and is the portable replacement. Not tried yet: nothing
but TypeScript has been run through Swan.

## 3. IDE features beyond the finished roadmap steps

| Feature | Value to AYA | Data source | Effort |
|---|---|---|---|
| Find implementations, type hierarchy | high: "who implements this interface" before changing it | SCIP relationships | done 2026-10-25 |
| Symbol-level edits (`replace_symbol_body`, `insert_after_symbol`) | high: edits by symbol, not by line number | Swan's body ranges; refresh afterwards | small to medium |
| Dead-code finding | medium: exported symbols with zero references | SCIP, one SQL query | small |
| Hover docs | medium | SCIP `documentation` (first line kept now; keep all of it) | small |
| Rename safety check | high | SCIP occurrences: list every site, flag re-export aliases and string mentions; leave the edit to AYA | medium |
| Live diagnostics | high after edits | `tsc --noEmit` / pyright / `cargo check` per language, cached by file | medium |
| Freshness on every answer | high: says when the map is older than the file | file mtime vs `index_info` | small |
| Git churn and blame | medium | git | small |
| Real rename, move, safe delete | high but risky | needs a language server or JetBrains; SCIP alone is not enough to rewrite safely | large |

## 4. Recommended next steps

1. ~~Implementations and type hierarchy~~: done.
2. **Freshness and dead code:** stamp each answer with whether its file
   changed since indexing, and add `find_unused_symbols`. Both are small, and
   freshness is what makes the map safe to trust.
3. **Python:** run scip-python on a real AYA Python project end to end,
   adding the `language` column and portable kinds. That makes Swan
   multi-language for real.
4. **Symbol edits:** `replace_symbol_body` and `insert_after_symbol`, each
   followed by a refresh.
5. **Diagnostics:** wrap `tsc --noEmit` per changed file.
6. **Rename and move:** later. Start with a rename *plan* (every site
   listed); don't rewrite code from SCIP alone.
