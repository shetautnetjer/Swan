# Swan status

as_of: 2026-10-25

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

- `lsp/swanlsp.goose` is a language-server client compiled on its own
  (`goose --standalone`) to `build/swanlsp.c` and linked into swan through
  `native/lsp_glue.c`; scripts/build.sh regenerates it only when lsp/ changes.
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

## Next

1. Bake-off reported 2026-10-25 (README "Against the code-map bake-off"):
   Swan already has the SQLite fresh-start win; per-file refresh is next.
2. Register `bin/swan serve <db>` with AYA's MCP config once the owner says so.
3. Roadmap 3 to 8 in the README (tests for a symbol, SCIP relationships,
   dependency insight, live errors, git churn, more languages).
4. Files table to shrink the database; Python via scip-python.
