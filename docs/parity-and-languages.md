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
| `replace_symbol_body` | `replace_symbol_body` (exact SCIP span; refuses stale files; shifts the map) | done |
| `insert_before_symbol` / `insert_after_symbol` | same names | done |
| `rename_symbol` (LSP), JetBrains `rename` | `rename_symbol`: plan first, checks each site's text, skips aliases, refuses conflicts and stale files; strings and comments not covered | done, compiler-resolved uses only |
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

### Tried on 2026-10-25

Both runs used private repos, read-only. Only the findings are recorded here.

**Python: scip-python 0.6.8 on a 2,853-file research repo (22 MB of .py).**
- SCIP run: 132 s and 10 GB of memory. The default Node heap ran out at
  4.4 GB, so `scripts/scip-run.sh` raises it (`SWAN_NODE_HEAP_MB`, default
  16000).
- Swan's own work: flatten 1.5 s, `swan index` 2.6 s. The map has 1,162,302
  occurrences, 3,186 inheritance links and 150,745 symbols.
- Queries took about 1 ms per call.
- Ten functions, picked at random, checked against ripgrep. Every line Swan
  reported was a real use, and Swan found 110 of rg's 122 lines. The other 12
  were the name inside docstrings and strings (expected), plus two real
  dynamic uses SCIP cannot see: `patch('module.func')` and
  `hasattr(obj, 'name')`.
- Gaps:
  - scip-python sets no SCIP kind, so Swan reads `def`/`class` from the
    signature.
  - It needs `pip` to list installed packages. Without pip, Swan passes an
    empty environment, and third-party packages resolve as names only.
  - String-based dynamic access is invisible.
- Inheritance works: `find_implementations` on `TestCase` lists its 1,727
  subclasses.

**Rust: rust-analyzer 2026-10-19 (`rust-analyzer scip`) on a 4-crate
workspace (21 .rs files), mapped together with its one Python file.**
- rust-analyzer: 5 to 7 s. Swan: 17 ms. One map holds both languages;
  `language` tells them apart.
- Eight types and functions checked against ripgrep. Swan only listed real
  uses. It correctly left out `std::process::Command`, which ripgrep can't
  tell apart from the crate's own `Command` enum.
- Gaps found, and what Swan does about them now:
  - Uses through a path (`ProviderError::Timeout`, `Message::new`) count as
    uses of the variant or function, not of the type. Fixed with
    `find_referencing_symbols` and `include_members`: uses through variants,
    fields and impl functions count, each marked `via`.
  - No relationships: trait impls (`impl Provider for X`) are not emitted.
    Fixed in the flattener. rust-analyzer's symbol for a trait-impl method
    (`impl#[HttpProvider][Provider]complete().`) names both types, and the
    impl header's references resolve them. All 4 impls in the workspace are
    found, with their methods.
  - Uses inside macro calls, above all nested ones (`assert!(matches!(..))`,
    `vec![Message::new(..)]`), are mostly missing. This was the real cause of
    the misses. Now handled by name: the flattener reads each Rust file,
    finds macro arguments by their brackets, and matches names against the
    repo's own definitions. Ambiguous names are skipped, and these rows say
    `by_name`. With both fixes, five types checked against ripgrep were
    found on every line where they really occur (79/79, 24/24, 39/39,
    32/32). `Command` correctly stays at 8, because the other 9 lines are
    `std::process::Command`.
  - Impl members are named by their type (`HttpProvider/complete`), not
    `impl/HttpProvider/Provider/complete`.
  - rust-analyzer logs "definition should have been in an SCIP document"
    for a few symbols (6 here).
  - It runs `cargo` and writes build output. `scripts/scip-run.sh` points
    `CARGO_TARGET_DIR` into the output folder. Cargo still writes a
    `Cargo.lock` into a repo that has none, so map a copy of such a repo.

What Swan must change for many languages: run the right indexer per
language (detect by files present), store a `language` column, and fix two
TypeScript-specific spots. `kind_word` reads scip-typescript's signature
wording, and test-file detection uses JS naming. Done 2026-10-25: a
`language` column, kinds from the signature, then SCIP's kind, then the
descriptor (so Python's `def` is a function or method), Python test-file
names, and `scripts/scip-run.sh` running every indexer a repo needs.

## 3. IDE features beyond the finished roadmap steps

| Feature | Value to AYA | Data source | Effort |
|---|---|---|---|
| Find implementations, type hierarchy | high: "who implements this interface" before changing it | SCIP relationships | done 2026-10-25 |
| Symbol-level edits (`replace_symbol_body`, `insert_after_symbol`) | high: edits by symbol, not by line number | Swan's body ranges; refresh afterwards | small to medium |
| Dead-code finding | medium: exported symbols with zero references | SCIP, one SQL query | done 2026-10-25 |
| Hover docs | medium | SCIP `documentation` (first line kept now; keep all of it) | small |
| Rename safety check | high | SCIP occurrences: list every site, flag re-export aliases and string mentions; leave the edit to AYA | medium |
| Live diagnostics | high after edits | `tsc --noEmit` / pyright / `cargo check` per language, cached by file | medium |
| Freshness on every answer | high: says when the map is older than the file | file mtime vs the SCIP run | done 2026-10-25 |
| Git churn and blame | medium | git | small |
| Real rename, move, safe delete | high but risky | needs a language server or JetBrains; SCIP alone is not enough to rewrite safely | large |

## 4. Recommended next steps

1. ~~Implementations and type hierarchy~~: done.
2. ~~Freshness and dead code~~: done.
   **Freshness and dead code:** stamp each answer with whether its file
   changed since indexing, and add `find_unused_symbols`. Both are small, and
   freshness is what makes the map safe to trust.
3. ~~Python~~: done, plus Rust (see "Tried on 2026-10-25").
4. **Symbol edits:** `replace_symbol_body` and `insert_after_symbol`, each
   followed by a refresh.
5. **Diagnostics:** wrap `tsc --noEmit` per changed file.
6. **Rename and move:** later. Start with a rename *plan* (every site
   listed); don't rewrite code from SCIP alone.
