# Swan status

as_of: 2026-10-26

This is a chronological development log. Earlier "not done" statements,
private-repo timings and "all tests pass" entries describe their original
runs, not the current contribution's validation. The current standalone
test/demo scope is in docs/demo.md and package boundaries in docs/packages.md.

## State: experiment, first slice working

- Built: `bin/swan` (Goose v2026.3 → C → gcc 15.2, SQLite 3.54.1 vendored).
- Verified: `scripts/test.sh` passes (build, map `fixtures/tiny-ts`, drive the
  MCP server over stdio: initialize, tools/list, all four tools, unknown method).
- Verified at scale: a 2,309-file TypeScript repo's SCIP index (from the
  code-map bake-off, read only)
  maps in 0.6 s flatten + 0.75 s `swan index`; MCP cold start 4.9 ms;
  `find_referencing_symbols` 1 to 2 ms median for 260 to 510 references.
  Map under `data/` (not in git).
- Not verified: correctness against Serena on that repo (the bake-off checked its own backends: 20/20),
  any language besides TypeScript, incremental refresh.
- Not done: registered as an MCP server for AYA (no AYA config was changed).

## 2026-10-25 (later): roadmap steps 1 and 2

- Call graph: `get_callers` (impact radius to depth 5, test flags, summary)
  and `get_callees` (with dependency package versions). Covered by the MCP
  smoke test. AEON depth-3 impact: 20 to 26 ms.
- Per-file refresh: `swan refresh` / `scripts/refresh-repo.sh`. Schema 3
  (files table with row fingerprints; ids stable across refreshes).
  `tests/refresh_check.sh` edits the fixture, reruns SCIP, and checks the
  refreshed map equals a fresh build. On AEON a simulated one-file edit
  refreshed in 0.23 s and matched a fresh build on all 802,618 dumped rows.
- Published: github.com/shetautnetjer/Swan (public, MIT).

## 2026-10-25 (later still): implementations and type hierarchy

- Flattener writes `relationships.tsv` from SCIP relationships; schema 4
  adds a `relationships` table, refreshed per file like occurrences.
- Tools `find_implementations`, `get_type_hierarchy`; smoke test and
  refresh check cover them. AEON: 471 relationships; `Backend` has 9
  implementations (5 ms).

## 2026-10-25 (night): freshness and unused code

- `stale: true` on any answer whose file changed after the SCIP run
  (`scip_time` in meta = index.scip mtime; stat via the C shim);
  `index_info` lists stale files.
- `find_unused_symbols`: AEON 166 candidates outside tests, 20 ms; three
  spot-checked with rg are referenced nowhere else.

## 2026-10-25 (late): Python and Rust

- scip-python 0.6.8 and rust-analyzer 2026-10-19 wired in through
  `scripts/scip-run.sh` (since replaced by `swan map`; language detection, empty pip env, Node heap,
  CARGO_TARGET_DIR kept out of the repo). Schema 5 adds `symbols.language`;
  kinds are portable across languages.
- Tested on two private repos: a Python research repo, and a copy of a
  Rust workspace (Rust + Python). Their maps live under data/private/
  (gitignored, never pushed). Findings, without private
  content, are in docs/parity-and-languages.md.

## 2026-10-25 (late night): editing by symbol

- `replace_symbol_body`, `insert_after_symbol`, `insert_before_symbol`,
  `rename_symbol` (plan, then apply). Schema 6: body columns, and
  `files.edited_mtime` so Swan's own edits are not "stale".
- `tests/edit_check.ts` edits a fixture copy, runs tsc, and checks every
  position Swan shifted matches a fresh SCIP run.

## 2026-10-25 (late night): better Rust

- Trait impls recovered from rust-analyzer symbol names in the flattener;
  impl members named by type; `include_members` on find_referencing_symbols
  (CLI `uses`); macro-argument uses matched by name (`by_name`, schema 7).
- `fixtures/tiny-rs` + `tests/rust_check.ts`. On the private Rust workspace
  types are now found on every line ripgrep finds them (excluding lines that
  are really other crates' same-named types).

## 2026-10-25 (late night): diagnostics

- `tools/diagnostics.ts` (since replaced by `swan check`) + `swan diagnostics` +
  `get_diagnostics` with caller depth; `scripts/diagnose-repo.sh`.
  `tests/diag_check.ts` breaks fixture copies (TS and Rust) and checks the
  errors land in the callers. Design notes: docs/diagnostics.md.

## 2026-10-26: Goose runs the pipeline; Python done properly; JS without tsconfig

- C shim gains `swan_run` (fork/exec, pipes, timeout) and realpath; Goose
  orchestrates `swan map` and `swan check`, also exposed as the MCP tools
  `update_map` and `check_errors`. scip-run.sh and tools/diagnostics.ts are
  gone; the scripts now call swan.
- Python: venv detection, importlib.metadata package list when pip is
  missing, pyright 1.1.414 diagnostics. fixtures/tiny-py + tests/lang_check.ts.
- JS: .js/.mjs/.cjs repos without a tsconfig mapped with a generated one
  outside the repo. fixtures/tiny-js.

## 2026-10-26: speed pass

- Parallel indexers (swan_spawn/swan_wait_any), Python split into
  --target-only pieces, per-piece and per-language reuse by fingerprint
  plus dependents from the last map, no-change shortcut. Flattener
  re-roots paths from SCIP metadata and drops repeated documents.
  Numbers in docs/speed.md.

## 2026-10-26: JetBrains-style gaps

- Exact targets for impact questions; imports found from source and left
  out of callers; get_symbol_at with docs (schema 9); per-language tool
  modules (tools/modules.json): ruff/biome/clippy lint, format_file,
  run_tests. Compared with WebStorm's MCP on live AEON (read-only).

## 2026-10-26: live answers from rust-analyzer, as a separate Goose library

- The language-server client (now `lsp/golsp.goose`) is compiled on its own
  (`goose --standalone`) to `build/golsp.c` and linked through
  `lsp/native/glue.c`; scripts/build.sh regenerates it when lsp/ changes.
  Two Goose runtimes share the binary; nothing crosses but slices.
- `get_diagnostics` and `find_implementations` take `live: true`: swan serve
  keeps rust-analyzer running (tools/modules.json "lsp") and answers from it.
- Measured: core build after a core edit 4.34 s (4.16 s before: flat); after
  a library edit 17.4 s (gcc on 650 KB of C, rare). tiny-rs: a new E0061
  seen 0.40 s after asking; a new impl seen live while the map has the old
  two. A private Rust workspace (copy): RA ready 9.5 s, E0308 seen 0.52 s after an
  edit, live impls = SCIP impls (same 4; live points at the impl blocks,
  SCIP at the types), RA ~1.1 GB resident, stopped when serve exits.
- Parallel indexing now also caps jobs by free memory (about 3 GB a job).
- Same evening: pyright and typescript-language-server (6.0.2, pinned) in the
  same library, configured in tools/modules.json; a server that publishes
  is waited on per file ("settle": "publish"), rust-analyzer on its check.
  tiny-py: a pyright reportReturnType error 0.57 s after asking; tiny-ts:
  TS2322 0.66 s. Asking about another language swaps the server.
- Limits: one live server per process (swapped by language); files edited elsewhere are seen by
  rust-analyzer's own watcher, the asked file is always resynced.

## 2026-10-26: structural search and rewrite (tree-sitter, ast-grep style)

- `search_pattern` and `rewrite_pattern`: patterns with `$X`, `$$$X`, `$_`,
  matched on tree-sitter trees with ast-grep's default ("smart") rules.
  pkg/treesitter is a Goose package: the runtime and 9 grammars (npm
  tarballs, pinned by sha256 in fetch-tools.sh) compile once and are cached;
  ts_shim.c hands trees to Goose as flat int arrays (no TSNode crosses) and
  parses batches on up to 16 threads.
- Checked against ast-grep 0.45.3 (tests/structural_check.ts, a ledger of
  cases): same matches on the fixtures, on AEON (read-only; e.g. 15465
  `await $X`, 18614 `return $X`) and on private Python and Rust copies. The
  only differences are in files .gitignore names, which ast-grep's walk
  skips and Swan reads. CUDA has no ast-grep grammar; checked by hand.
- Speed on AEON (2358 files): search_pattern runs on a pool of Goose
  worker threads (thread_fn + typed queues, up to 16; each copies the
  compiled pattern at the spawn): 0.05 s for a pattern with a rare word
  (files without the pattern's words are never parsed), 0.27 to 0.33 s when
  every file must be parsed and 16 to 20 thousand matches written out (was
  0.7 s single-threaded); ast-grep takes 0.1 s on 32 threads. Core build after
  a core edit 5.0 s (4.3 s before), the matcher being Goose in the core.

## 2026-10-26: Kotlin, step 1 (structural search)

- The Kotlin grammar (@tree-sitter-grammars/tree-sitter-kotlin 1.1.0, MIT,
  pinned in fetch-tools.sh) is in pkg/treesitter. A Kotlin-only repo maps
  to an empty map (no SCIP indexer runs yet), so search_pattern and
  rewrite_pattern work on .kt/.kts.
- A pattern node holding only punctuation and a $$$ run (`{ $$$B }`) may
  match a node of another kind: Kotlin parses `{ __swan_mvm_B }` as a
  different node than a class body.
- fixtures/tiny-kt: same matches as ast-grep on 5 Kotlin cases. On
  android/nowinandroid (350 .kt files): equal counts on 4 patterns in about
  0.01 s each; `@Composable fun $F($$$P) { $$$B }` finds 80 where ast-grep
  finds 75, the 5 more being composables whose parameter lists end with a
  trailing comma, which ast-grep's `$$$P` does not take.

## 2026-10-26: Kotlin, step 2 (live answers from kotlin-lsp)

- JetBrains' standalone Kotlin language server 263.7084.0 (its own JBR,
  1.5 GB in .tools/kotlin-lsp, sha256-pinned in fetch-tools.sh) is the
  Kotlin "lsp" entry in tools/modules.json, run with --stdio and its caches
  under the map folder (--system-path). Gradle's home is .tools/gradle-home,
  whose daemons quit after 10 idle minutes and keep to 2 GB.
- It imports the Gradle build before it analyses anything; the swan-lsp
  library now waits for that (intellij/importLog), up to 15 minutes, and
  reports import_failed.
- tiny-kt: the first call took 169 s (Gradle fetching itself and the
  Kotlin plugin, 324 MB, once), later sessions start in about 5 s. An
  INITIALIZER_TYPE_MISMATCH error came back 5.6 s after the edit on the
  first analysis and 0.9 s on the next. The server takes about 1.4 GB.
- proc.c starts servers in their own process group and kills the group on
  close: the Kotlin launcher runs its JVM as a child, which otherwise
  outlived swan serve. The Gradle daemon is in a session of its own and is
  left to its idle timeout.

## 2026-10-26: Kotlin, step 3 (the full map through Gradle)

- `swan map` runs scip-java on Kotlin Gradle projects too (it indexes Java
  and Kotlin), with Swan's Gradle home and, once its license is accepted,
  Swan's Android SDK (.tools/android-sdk; Mani accepted Google's terms
  himself). Configuration cache and isolated projects are turned off for
  the run (scip-java's init script cannot run with them), the build JVMs
  keep to 3 GB, and scip-java's `clean` rebuilds the repo's build/ output.
- tiny-kt (Kotlin 2.4.21): mapped in 5.6 s warm, about 1.2 GB peak;
  find_implementations and get_callers answer from it. Kotlin symbols are
  labelled kotlin by their file.
- android/nowinandroid does not index yet: it uses Kotlin 2.3.0, and
  scip-java 0.13.2's Kotlin compiler plugin follows Kotlin 2.4
  (ClassNotFoundException: ExtensionPointDescriptor in kotlinc). A project
  on current Kotlin works; Mani's new app will start there. Its Gradle
  build otherwise ran (3.6 min first time, 3.5 GB peak).

## 2026-10-26: the reusable parts as Goose packages

- goose-sqlite (SQLite + shim), goose-treesitter (tree-sitter, grammars as
  pinned submodules, the matcher and worker pool) and goose-lsp (the
  language-server client) are their own public repos, tagged v0.1.0
  (goose-treesitter v0.1.1: the CUDA grammar is copied in, because its
  repository's nested submodule breaks a recursive clone). Swan imports the
  first two by tag (goose fetches them into its cache and builds their C
  once) and has goose-lsp as the lsp/ submodule, compiled standalone.
- Goose has no registry: a package is a git repo and a tag.
- A fresh build fetching both packages took 69 s; a core edit builds in
  5.0 s, as before. All tests pass.

## Contribution preparation (2026-10-26)

The bounded contribution adds standalone library checks, an offline Swan
demo and reproducible compiler/cache measurements, and corrects stale
architecture descriptions. It preserves existing APIs, language-server
processes and Goose's repository/ref packaging. No deployment or upstream
publication is part of this work. See docs/contribution-proposal.md.
The local validation record is docs/validation.md; it distinguishes passed
checks from the complete integration suite that was not rerun.

## Remaining work

1. Qualify real server adapters and indexers separately from the mock LSP
   and synthetic-row tests; existing integrations need their full toolchains.
2. Dependency listing, git churn, broader language coverage and stronger
   refactoring semantics remain candidates, not completed features.
3. Grammar-specific native packages and an importable LSP facade need a
   design decision supported by build measurements; see docs/packages.md.
