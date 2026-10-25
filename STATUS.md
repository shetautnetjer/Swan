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
  `scripts/scip-run.sh` (language detection, empty pip env, Node heap,
  CARGO_TARGET_DIR kept out of the repo). Schema 5 adds `symbols.language`;
  kinds are portable across languages.
- Tested on two private repos: a Python research repo, and a copy of a
  Rust workspace (Rust + Python). Their maps live under data/private/
  (gitignored, never pushed). Findings, without private
  content, are in docs/parity-and-languages.md.

## Next

1. Bake-off reported 2026-10-25 (README "Against the code-map bake-off"):
   Swan already has the SQLite fresh-start win; per-file refresh is next.
2. Register `bin/swan serve <db>` with AYA's MCP config once the owner says so.
3. Roadmap 3 to 8 in the README (tests for a symbol, SCIP relationships,
   dependency insight, live errors, git churn, more languages).
4. Files table to shrink the database; Python via scip-python.
