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

## Next

1. Bake-off reported 2026-10-25 (README "Against the code-map bake-off"):
   Swan already has the SQLite fresh-start win; per-file refresh is next.
2. Register `bin/swan serve <db>` with AYA's MCP config once the owner says so.
3. Per-file refresh: rerun SCIP, replace one file's rows in SQLite.
4. Files table to shrink the database; Python via scip-python.
