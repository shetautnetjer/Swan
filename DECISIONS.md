# Swan decisions

## 2026-10-25 — Engine split: SCIP → Goose → SQLite, served by Goose

Goose v1 has no subprocesses, so Swan cannot drive language servers the way
Serena does. Precise data comes from SCIP indexers; Goose builds the map;
SQLite stores and queries it. The coordinator's brief assumed Goose had no
JSON and proposed a TypeScript/Bun MCP layer. Goose v2026.3 ships `json`,
`read_line` and file IO, so the MCP server is the Goose binary itself: one
artifact, no extra runtime. The flattener stays in Bun because reading
protobuf in Goose buys nothing.

## 2026-10-25 — SQLite through a vendored amalgamation and a C shim

No `sqlite3.h` on the development machine and no root access, and an `extern fn` cannot
carry C pointers, so `native/swan_sqlite.c` passes databases and statements
as i64 handles and returns text by appending to Goose builders. The
amalgamation is compiled through the Goose sidecar (`src/swan.build`), which
also makes the build reproducible without system packages.

## 2026-10-25 — Serena's interface, none of its code

Serena's tools live in its GPL-3.0-or-later application (only SolidLSP is
MIT). Swan follows the tool names, arguments and name-path rules so agents
can switch between them, and copies no code or descriptions.

## 2026-10-25 — Shared row format with the bake-off

`occurrences.tsv` uses the bake-off's columns (symbol, file, 0-based
start/end line/col, def|ref). Swan adds `symbols.tsv` (signature) and
`extents.tsv` (definition spans, from SCIP's enclosing_range), which is how it
reports the symbol each reference sits inside. One difference: Swan replaces
tabs and newlines in symbol names with spaces; the bake-off escapes them.

## 2026-10-25 — Refresh by fingerprinting each file's rows

scip-typescript only reruns whole repos, so `swan refresh` takes the full
new rows, hashes each file's rows, and rewrites the files whose hash differs
(plus removed files), in one transaction. This catches files changed
indirectly by an edit elsewhere, which an edited-files list would miss.
Enclosing symbols are file-local, so unchanged files need no rework, and
symbol ids stay stable (looked up by SCIP symbol, unique index). A full build
uses the same code with every file marked changed. Cost: reading every row
(0.22 s on AEON) even when nothing changed; fine next to the 16.5 s SCIP run.
