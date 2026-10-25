# Swan

A code map for agents. Swan answers the questions an agent asks about a
codebase ("where is `Store.add` defined?", "who calls `getBackend`?", "what
does this file define?") as MCP tools for AYA. It is a Goose take on
[Serena](https://github.com/oraios/serena): it keeps Serena's agent-facing
tool design and replaces the engine underneath.

## Where it's headed: a local JetBrains for agents

An IDE knows a codebase as a graph, not as text: where every symbol is
defined, who uses it, what it calls, what a change would break, and which
tests cover it. Swan aims to give an agent that understanding headlessly,
before it edits anything, from data a compiler produced rather than from
guesses. Languages change slowly; dependencies change constantly. SCIP
indexers cover both: they record references into dependencies with each
package's name and version. The roadmap, most valuable first:

1. Call graph and impact radius: done (`get_callers`, `get_callees`).
2. Per-file refresh, so the map stays current while the agent edits: done
   (`swan refresh`, `scripts/refresh-repo.sh`).
3. Tests for a symbol (partly there: `get_callers` flags test files).
   Freshness flags and unused-code finding: done (`stale`, `find_unused_symbols`).
4. Implementations and type hierarchy, from SCIP relationships: done
   (`find_implementations`, `get_type_hierarchy`).
5. Dependency insight: which packages and versions the code leans on.
6. Live errors, from `tsc` or a language server (not SCIP).
7. Hot and fragile code, from git history.
8. More languages: one SCIP indexer per language, into the same database.
   Python and Rust: done.

## What "a Goose Serena" means here

[Goose](https://aardappel.github.io/goose/) is Wouter van Oortmerssen's
systems language (not Go, and not Block's goose agent). Serena is a Python MCP
server driving live language servers over LSP. Goose v1 has no subprocesses
or networking, so it cannot drive a language server, and a literal port of
Serena is not possible. Swan's reading of the idea:

- **Precise data comes from SCIP.** A SCIP indexer (here `scip-typescript`)
  runs the real compiler once and records every definition and reference,
  resolved the way the compiler resolves them, re-exports and renamed imports
  included.
- **Goose builds the map.** It interns the symbols, parses SCIP symbol
  strings into names, kinds and Serena-style name paths (`Store/add`), and
  works out which symbol each reference sits inside.
- **SQLite stores and answers.** Goose calls the SQLite C API through
  `extern fn` and a thin shim (`native/swan_sqlite.c`); SQLite is vendored.
- **Goose also serves the MCP.** Goose v2026.3 ships `json`, stdin line
  reading and file IO, so the stdio MCP server is the same Goose binary.
  The original plan put a TypeScript/Bun layer here; it turned out not to be
  needed, which leaves one binary and no runtime dependencies.

```
TS repo ──scip-typescript──▶ index.scip ──tools/scip-flatten.ts──▶ TSV rows
                                                                     │
                                         bin/swan index (Goose) ◀────┘
                                                │
                                         swan.db (SQLite) ◀── bin/swan serve (Goose, MCP stdio) ◀── AYA
```

The only non-Goose code is the SCIP flattener (Bun, no dependencies: a
small protobuf reader) and the 100-line C shim. The flattener's
`occurrences.tsv` columns match those of a separate code-map bake-off
(described below), so either side can read the other's rows.

## Tools

Names and arguments follow Serena's, so an agent that knows Serena knows Swan.
A name path is the chain of enclosing names joined by `/`: `add` matches any
symbol named `add`, `Store/add` any whose path ends that way, `/Store/add`
only that whole path. Lines and columns in answers are 1-based.

| Tool | Arguments | Answers |
|---|---|---|
| `find_symbol` | `name_path_pattern`, `relative_path?`, `substring_matching?`, `include_body?`, `max_results?` | kind, signature, file, line, body line range, optionally the body |
| `find_referencing_symbols` | `name_path`, `relative_path?`, `max_results?` | per matched symbol, every reference: file, line, column, the symbol it sits inside, and its line of source |
| `get_symbols_overview` | `relative_path` (file or directory) | every symbol defined there, in order |
| `get_callers` | `name_path`, `relative_path?`, `depth?` (1 to 5), `max_results?` | who uses the symbol, and who uses those: the impact radius, with each caller's distance and whether it is test code, and a summary of affected symbols, files and test files |
| `get_callees` | `name_path`, `relative_path?`, `max_results?` | what the symbol's body uses, with counts; dependency symbols show their package and version |
| `find_implementations` | `name_path`, `relative_path?`, `max_results?` | what implements, extends or overrides it (classes behind an interface, overrides of a method), with distance |
| `get_type_hierarchy` | `name_path`, `relative_path?`, `depth?`, `max_results?` | supertypes and subtypes, from SCIP relationships |
| `replace_symbol_body` | `name_path`, `relative_path`, `body` | replaces the whole definition; refused if the file changed since the map was built; reports how many places use the symbol |
| `insert_after_symbol`, `insert_before_symbol` | `name_path`, `relative_path`, `body` | adds code next to a definition |
| `rename_symbol` | `name_path`, `relative_path`, `new_name`, `apply?` | plans by default: every site, skipped aliases, conflicts, stale files; `apply` writes it |
| `get_diagnostics` | `name_path?`, `relative_path?`, `depth?`, `errors_only?` | compiler errors (tsc, cargo check) pinned to symbols; for a symbol, also those in its callers, with distance (see `docs/diagnostics.md`) |
| `find_unused_symbols` | `relative_path?`, `include_tests?`, `max_results?` | functions, classes, methods, types and variables nothing references or implements: removal candidates, not proof |
| `index_info` | none | repo root, build time, counts, and the files changed since the SCIP run |

Every answer about a file that changed after the SCIP run carries
`"stale": true`, so an agent knows to reread it or refresh the map.

## Use

```bash
scripts/fetch-tools.sh                          # Goose and rust-analyzer (sha256-pinned) into .tools/, scip-typescript and scip-python into tools/
scripts/build.sh                                # bin/swan
scripts/index-repo.sh <ts-repo> data/<name>     # index.scip, TSV rows, swan.db
scripts/refresh-repo.sh <ts-repo> data/<name>   # after edits: rerun SCIP, rewrite only changed files
scripts/diagnose-repo.sh <ts-repo> data/<name>  # tsc / cargo check, loaded into the map
bin/swan serve data/<name>/swan.db              # MCP over stdio
bin/swan query data/<name>/swan.db refs getBackend   # the same answers on the command line
scripts/test.sh                                 # build, map the fixture, drive the MCP end to end, check refresh
```

An MCP client entry looks like:

```json
{ "command": "/path/to/swan/bin/swan", "args": ["serve", "/path/to/swan/data/<name>/swan.db"] }
```

## First numbers (2026-10-25, Linux x64, gcc 15.2)

A 2,309-file TypeScript agent harness (a fork of Letta Code), from the
bake-off's `index.scip`:

| Step | Time | Notes |
|---|---|---|
| scip-typescript | ~17 s | bake-off log; full rerun only |
| flatten | 0.6 s | 706,200 occurrences, 93,363 symbols, 15,791 extents |
| `swan index` | 1.25 s | 2,309 files; 135 MB database |
| `swan refresh`, one file edited | 0.23 s | 244 rows rewritten; result identical to a fresh build. 0.22 s of it is reading and fingerprinting all rows, so a no-op refresh costs the same |
| MCP cold start | 4.9 ms | spawn + initialize + first `find_referencing_symbols` |
| `find_symbol` | 0.03 to 0.05 ms median | |
| `find_referencing_symbols` | 1.0 to 2.1 ms median, p95 under 3.6 ms | 260 to 510 references, each with its source line |
| `get_callers`, depth 3 | 20 to 26 ms, fresh process | `getBackend`: 768 symbols in 355 files, 180 of them test files |
| `get_callees` | 0.9 ms, fresh process | 82 symbols used by `createRuntime` |
| `find_implementations` | 5 ms, fresh process | `Backend` interface: 9 implementing classes, several of them test fakes |
| `find_unused_symbols` | 20 ms, fresh process | 166 candidates outside tests; the three spot-checked with ripgrep appear only at their definitions |
| `index_info` with freshness | 2.6 ms | stats all 2,309 files |

These are a first slice's numbers, not a qualified benchmark. Correctness
against Serena is the bake-off's job and is not claimed here.

## Against the code-map bake-off

A separate bake-off compared a Goose in-memory snapshot with Rust + SQLite on
the same SCIP data for that repository. Both matched the TypeScript language
server on all 20 symbols. Rust + SQLite won fresh-process lookups (0.69 ms vs 12.7 ms) because Goose's
`from_bytes` verifies and copies the whole 30 MB image on every start.

Swan already has that SQLite fresh-start benefit. Its Goose code builds and
queries the map, but the map lives in SQLite on disk, and each process reads
only the index pages a query touches. Nothing loads the whole map. These are
fresh-process timings on the same machine (`bin/swan query`, 40 runs each,
process spawn floor 0.16 ms):

| Query | Swan median / p95 | Bake-off Rust + SQLite |
|---|---|---|
| `find_symbol getBackend` | 0.62 / 0.87 ms | 0.69 / 0.83 ms (its query mix) |
| `find_referencing_symbols debugWarn` (260 refs) | 2.33 / 2.75 ms | n/a |
| `find_referencing_symbols isRecord` (21 definitions) | 1.65 / 1.97 ms | n/a |

The reference queries do more than the bake-off's: each reference comes with
the symbol it sits inside and its line of source, read from the repo.

The bake-off made two recommendations:
- **Lookup by short name:** already in Swan. Its `name` and `name_path`
  columns are indexed, so `find_symbol isRecord` returns the candidates and
  `relative_path` picks one.
- **Incremental per-file reindex:** built, following its safe-update advice.
  `swan refresh` fingerprints each file's rows from the new SCIP run and
  rewrites only the files whose rows changed, in one transaction. Those
  include files whose resolution changed because of an edit elsewhere. On the
  same one-file edit it took 0.23 s against the bake-off's 17 ms, because
  Swan reads and fingerprints every row instead of being handed the edited
  file's rows. Either way the SCIP rerun (~16.5 s) is the real cost.

## Limits of this slice

- The graph counts every reference as a use: SCIP does not tell a call from
  a type use or an import. A class's callees are what its own body uses
  outside its methods; ask about a method for what that method uses.

- Tried with TypeScript, Python and Rust (`scripts/scip-run.sh` picks the
  indexers). Go, Java, C/C++, C# and Ruby are untried. What each tried
  indexer misses is in `docs/parity-and-languages.md`.
- scip-typescript has no per-file mode, so every refresh reruns it over the
  whole repo (~17 s on the repo above). Swan's own part is 0.23 s.
- Edits shift the map's positions for the edited file at once (checked against a
  fresh SCIP run in `tests/edit_check.ts`), but uses inside new code only
  appear after a refresh. Renames cover what the compiler resolved, not
  strings or comments.
- File paths are stored as text on every row; a files table would shrink the
  database severalfold.
- Document-local symbols (`local N`) are dropped, as in the bake-off.

## Layout

```
src/swan.goose       CLI: index | query | serve
src/index.goose      builds (atomic: writes .tmp, renames) or refreshes the map
src/graph.goose      callers and callees
src/scip.goose       SCIP symbol grammar: name, kind, name path
src/query.goose      the tool queries, as JSON
src/serve.goose      MCP JSON-RPC over stdio
src/db.goose         extern fn bindings to the shim
src/swan.build       Goose sidecar: compiles the shim and SQLite with the program
native/swan_sqlite.c the shim
vendor/sqlite/       SQLite 3.54.1 amalgamation (public domain)
tools/               scip-flatten.ts, scip-typescript
tests/               MCP smoke test, refresh-vs-fresh check, latency bench
fixtures/tiny-ts/    a small repo with the tricky cases (re-export, rename, same-name method and function)
```

## License

MIT (`LICENSE`). The vendored SQLite is public domain; see `NOTICE`.

## Credits

- Tool names, arguments and name-path matching follow
  [Serena](https://github.com/oraios/serena) by Oraios AI. No Serena code or
  text is copied. Serena's tools live in its GPL-3.0-or-later application
  (only its SolidLSP library is MIT), so Swan follows the interface only. See
  `NOTICE`.
- [SQLite](https://sqlite.org) is in the public domain.
- [SCIP](https://github.com/sourcegraph/scip) and scip-typescript are by
  Sourcegraph, Apache 2.0; Swan uses scip-typescript as a tool and reads the
  SCIP format.
- [Goose](https://github.com/aardappel/goose) by Wouter van Oortmerssen.

See `docs/parity-and-languages.md` for a tool-by-tool comparison with Serena
and what other languages would take.
