# Swan vs Serena, and the road to IDE-level understanding

as_of: 2026-10-25. Serena's tool list was read from the installed
`serena-agent` package (its `serena/tools/*.py` classes). SCIP indexer status
was checked on GitHub the same day. Language maturity notes are working
judgement, not measured.

This page combines the original comparison with later implementation notes.
External-product observations and private-repo timings below are historical;
they have not been rerun by the standalone contribution checks. Similar tool
names do not establish equivalent behavior, language coverage or safety.

## 1. Interface coverage

Serena has two back ends: language servers over LSP, and a JetBrains plugin.
The JetBrains back end adds refactoring tools that LSP lacks.

### Reading code

| Serena tool | Swan today | Status |
|---|---|---|
| `find_symbol` | `find_symbol` (name paths, substring, body) | done |
| `find_referencing_symbols` | `find_referencing_symbols` (with enclosing symbol and source line) | done |
| `get_symbols_overview` | `get_symbols_overview` (file or directory) | done |
| `find_declaration` | `find_symbol` by name and `get_symbol_at` by file/position | index-dependent; not a complete declaration/definition distinction |
| `find_implementations` | `find_implementations` (classes, subclasses, method overrides, any depth) | done |
| JetBrains `type_hierarchy` | `get_type_hierarchy` (supertypes and subtypes) | done |
| `get_diagnostics_for_file` / `_for_symbol` | `get_diagnostics` over stored checks/lints, plus optional live language-server requests | configured live adapters for Python (with Blender's stubs), TS/JS, Rust, Kotlin, C/C++ (clangd), Lua (lua-language-server) and GLSL/HLSL/WGSL (shader-validator); see diagnostics.md |
| JetBrains `list_inspections` / `run_inspections` | missing | missing |
| (no Serena equivalent) | `get_callers` impact radius, `get_callees`, `index_info` | Swan only |

### Editing code

| Serena tool | Swan today | Status |
|---|---|---|
| `replace_symbol_body` | `replace_symbol_body` (exact SCIP span; refuses stale files; shifts the map) | done |
| `insert_before_symbol` / `insert_after_symbol` | same names | done |
| `rename_symbol` (LSP), JetBrains `rename` | `rename_symbol`: plan first, checks each site's text, skips aliases, refuses conflicts and stale files; strings and comments not covered | done, compiler-resolved uses only |
| JetBrains `move`, `safe_delete` | missing; zero indexed references is not proof that deletion is safe | missing |
| `replace_content`, `replace_lines`, `delete_lines`, `insert_at_line`, `replace_in_files`, `create_text_file` | not Swan's job: AYA's harness already edits files | out of scope |

### Around the code

| Serena tool | Swan today | Status |
|---|---|---|
| `read_file`, `list_dir`, `find_file`, `search_for_pattern`, `execute_shell_command` | harness already has these | out of scope |
| memories (`write/read/list/edit/delete/rename_memory`) | AYA has her own memory owner (MemoryD) | out of scope |
| projects and config (`activate_project`, `query_project`, `get_current_config`, `onboarding`, dashboard, REPL, `restart_language_server`) | one database per repo; `index_info` | partial |

Swan implements the listed map queries and bounded edits, but this table is
not a parity test. Implementations, hierarchy, symbol edits and live
diagnostics exist now. Full IDE inspections, move refactoring and safe delete
remain outside the implemented interface. The reference graph includes
non-call uses and some Rust macro uses are marked `by_name`.

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
  4.4 GB, so `swan map` raises it (`SWAN_NODE_HEAP_MB`, default
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
  - It needs `pip` to list installed packages. Without pip, `swan map` now
    builds the same list from Python's own `importlib.metadata`, and uses the
    repo's `.venv`/`venv` when there is one. Outside symbols then carry their
    package and version (`requests 2.32.5` in `fixtures/tiny-py`). Some
    standard-library members still come out labelled with the project's
    name instead of `python-stdlib`: a scip-python quirk, harmless to
    queries.
  - Rechecked on 2026-10-25 with the new pipeline: the same 10 functions,
    the same result (110 of rg's 122 lines, every one real). `swan map` took
    159 s, 139 s of it scip-python. `swan check` (pyright) took 56 s.
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
  - Uses through a path (`Shape::Square`, `Tile::new`) count as
    uses of the variant or function, not of the type. Fixed with
    `find_referencing_symbols` and `include_members`: uses through variants,
    fields and impl functions count, each marked `via`.
  - No relationships: trait impls (`impl Area for Tile`) are not emitted.
    Fixed in the flattener. rust-analyzer's symbol for a trait-impl method
    (`impl#[Tile][Area]area().`) names both types, and the
    impl header's references resolve them. All 4 impls in the workspace are
    found, with their methods.
  - Uses inside macro calls, above all nested ones (`assert!(matches!(..))`,
    `vec![Tile::new(..)]`), are mostly missing. This was the real cause of
    the misses. Now handled by name: the flattener reads each Rust file,
    finds macro arguments by their brackets, and matches names against the
    repo's own definitions. Ambiguous names are skipped, and these rows say
    `by_name`. With both fixes, five of the workspace's types checked against ripgrep were
    found on every line where they really occur (79/79, 24/24, 39/39,
    32/32). A type sharing its name with a
    standard-library type correctly stays at 8 of ripgrep's 17 lines, because
    the other 9 are the standard one.
  - Impl members are named by their type (`Tile/area`), not
    `impl/Tile/Area/area`.
  - rust-analyzer logs "definition should have been in an SCIP document"
    for a few symbols (6 here).
  - It runs `cargo` and writes build output. `swan map` points
    `CARGO_TARGET_DIR` into the output folder. Cargo still writes a
    `Cargo.lock` into a repo that has none, so map a copy of such a repo.

**Java: scip-java 0.13.2 with a user-local Temurin JDK 21, on
`fixtures/tiny-java` (no build tool).**
- With no Maven or Gradle, `swan map` writes a `scip-java.json` outside the
  repo, and scip-java compiles the sources itself (0.5 s). Diagnostics come
  from `javac` (0.2 s), parsed with the column from its caret line.
- Found and handled:
  - scip-java writes SCIP's newer typed ranges (Occurrence fields 8-11), not
    the packed `range`. The flattener reads both.
  - It writes method implementation links in both directions. The reverse
    ones are dropped, using the classes' own `implements` link.
  - `new Square(2)` references `Square#<init>()`, not the class. Constructors
    now count as uses of their class in references, callers and diagnostics.
- Verified: implementations, overrides, constructor uses,
  `replace_symbol_body` on a constructor with javac's error landing in the
  caller, and `rename_symbol` on a method.
- Not covered yet: Maven and Gradle repos. scip-java drives those build
  tools itself, but neither is installed here, and `swan check` skips javac
  for them.

**CUDA (and C/C++): scip-clang 0.4.1 on `fixtures/tiny-cuda` (two .cu files
and a .cuh header). No nvcc, no CUDA toolkit, no GPU here.**
- scip-clang supports CUDA through clang's CUDA mode. It needs clang's
  builtin CUDA headers (`__clang_cuda_runtime_wrapper.h`) and the CUDA
  headers. Swan gets both without installing either:
  - clang 21's header folder from a sparse checkout (8 MB), plus a stand-in
    `clang++` that answers the two questions scip-clang asks it;
  - NVIDIA's pip wheels (runtime, nvcc's libdevice, cccl, curand), linked
    into the layout `--cuda-path` expects.
- With no compile_commands.json, `swan map` writes one outside the repo:
  host-side CUDA, `sm_80`, the repo root on the include path.
- scip-clang writes no enclosing ranges, so the flattener finds each
  function's body by matching its braces in the source. Callers, edits and
  diagnostics then work as in other languages.
- Verified: the call chain `main` -> `launch_scaled` -> `scaled_kernel`
  (through a `<<<...>>>` launch) -> the `__device__` function `scale`.
  Kernel launches count as references. `replace_symbol_body` works in a
  `.cuh`. Diagnostics come from clang's own frontend, run by scip-clang with
  `--show-compiler-diagnostics`: changing `scale`'s signature puts the error
  in `scaled_kernel`.
- Limits: host-side only (device-only code paths are parsed, not checked as
  nvcc would), one GPU architecture, and repos with their own build flags
  should provide a compile_commands.json (CMake:
  `-DCMAKE_EXPORT_COMPILE_COMMANDS=ON`).

What Swan must change for many languages: run the right indexer per
language (detect by files present), store a `language` column, and fix two
TypeScript-specific spots. `kind_word` reads scip-typescript's signature
wording, and test-file detection uses JS naming. Done 2026-10-25: a
`language` column, kinds from the signature, then SCIP's kind, then the
descriptor (so Python's `def` is a function or method), Python test-file
names, and `swan map` running every indexer a repo needs.

## 3. Implementation status and remaining work

| Feature | Value to AYA | Data source | Effort |
|---|---|---|---|
| Find implementations, type hierarchy | high: "who implements this interface" before changing it | SCIP relationships | done 2026-10-25 |
| Symbol-level edits (`replace_symbol_body`, `insert_after_symbol`) | high: edits by symbol, not by line number | Swan's body ranges; refresh afterwards | implemented |
| Dead-code finding | medium: exported symbols with zero references | SCIP, one SQL query | done 2026-10-25 |
| Hover docs | medium | `get_symbol_at`, including stored documentation | implemented; index-dependent |
| Rename plan/apply | high | SCIP occurrences, stale/conflict checks; strings/comments are outside coverage | implemented within those limits |
| Live diagnostics | high after edits | external servers through goose-lsp | implemented for configured adapters; not full IDE inspection parity |
| Freshness on every answer | high: says when the map is older than the file | file mtime vs the SCIP run | done 2026-10-25 |
| Git churn and blame | medium | git | small |
| Real rename, move, safe delete | high but risky | needs a language server or JetBrains; SCIP alone is not enough to rewrite safely | large |

## 4. Bounded contribution priorities

1. Run independent library tests and the offline demo, with explicit
   passed/failed/skipped results.
2. Measure package cold builds and cache reuse separately from indexing.
3. Qualify each real language-server adapter on its own toolchain before
   expanding supported-server claims.
4. Discuss grammar selection and a normal importable LSP package only after
   measuring their build tradeoffs; see [packages.md](packages.md).
