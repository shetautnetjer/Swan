# Swan

**In plain words:** Swan gives an AI coding agent the understanding of a
codebase that an IDE like JetBrains has: where everything is defined, who
uses it, what a change would break, which tests to run, and what errors a
file has right now. The agent asks Swan instead of guessing from text, and
gets answers in milliseconds. Swan runs on your own machine, reads your code
without changing it (unless you ask it to edit), and talks to agents over
MCP, the standard way agents use tools. It is built in
[Goose](https://aardappel.github.io/goose/) and is a take on
[Serena](https://github.com/oraios/serena): Serena's tool design, a different
engine underneath.

**What it can do today (2026-10-26):**

| You want to know | Swan tool | How fast |
| --- | --- | --- |
| Where is this defined, and who uses it? | `find_symbol`, `find_referencing_symbols` | a few ms |
| What breaks if I change this, and which tests cover it? | `get_callers`, `run_tests` | about 10 ms |
| What implements this interface or trait? | `find_implementations`, `get_type_hierarchy` | a few ms |
| What errors does this file have right now, after my edit? | `get_diagnostics` with `live` | 0.4 to 0.9 s |
| Every place that looks like `$X.unwrap()`, and rewrite them all | `search_pattern`, `rewrite_pattern` | 0.14 s over 2,361 files |
| Edit or rename a function by name, safely | `replace_symbol_body`, `rename_symbol` | refused if the file changed under it |

Languages: TypeScript and JavaScript, Python, Rust, Java, Kotlin (including
Android projects), C, C++ and CUDA. How deep each one goes depends on the
tools installed for it; see [parity and languages](docs/parity-and-languages.md).

**Keeping up with edits:** after a one-line edit, re-mapping a 2,361-file
TypeScript project takes about 2 s (it used to take 8 to 10 s), and nothing
changed takes 0.07 s. A language server can be started ahead of time
(`SWAN_WARM=auto`) so the first live error check takes 0.7 s instead of 3.6 s.

**Built from reusable pieces:** three Goose libraries came out of Swan and can
be used by any Goose program:
[goose-sqlite](https://github.com/shetautnetjer/goose-sqlite),
[goose-treesitter](https://github.com/shetautnetjer/goose-treesitter) and
[goose-lsp](https://github.com/shetautnetjer/goose-lsp). Each has its own
standalone tests.

**Try it without installing anything else:** after building,
`python3 scripts/demo-offline.py` runs a small known-answer demo on synthetic
data ([demo and test scope](docs/demo.md)).

The rest of this page is the technical detail.

## Where it's headed: a local JetBrains for agents

An IDE knows a codebase as a graph, not as text: where every symbol is
defined, who uses it, what it calls, what a change would break, and which
tests cover it. Swan aims to give an agent that understanding headlessly,
before it edits anything, from data a compiler produced rather than from
guesses. Languages change slowly; dependencies change constantly. SCIP
indexers cover both: they record references into dependencies with each
package's name and version. The roadmap, most valuable first:

1. Reference graph and impact radius: implemented (`get_callers`,
   `get_callees`). These include non-call uses; see the limits below.
2. Per-file refresh, so the map stays current while the agent edits: done
   (`swan refresh`, `scripts/refresh-repo.sh`).
3. Tests for a symbol (partly there: `get_callers` flags test files).
   Freshness flags and unused-code finding: done (`stale`, `find_unused_symbols`).
4. Implementations and type hierarchy, from SCIP relationships: done
   (`find_implementations`, `get_type_hierarchy`).
5. Dependency insight: which packages and versions the code leans on.
6. Batch checks and live diagnostics: implemented through external tools
   and language servers (not SCIP).
7. Hot and fragile code, from git history.
8. More languages: one SCIP indexer per language, into the same database.
   TypeScript/JavaScript, Python, Rust, Java, Kotlin and host-side CUDA
   have adapters; support depends on the project's toolchain.

## What "a Goose Serena" means here

[Goose](https://aardappel.github.io/goose/) is Wouter van Oortmerssen's
systems language (not Go, and not Block's goose agent). Serena is a Python MCP
server driving live language servers over LSP. Goose v1 has no subprocesses
or networking in its standard library, so Swan reaches them through small C
shims; a literal port of Serena was not the aim. Swan's reading of the idea:

- **Semantic data comes from SCIP.** External indexers record resolved
  definitions and references. Coverage depends on the indexer and project;
  dynamic uses and some macro references need special treatment.
- **Goose builds the map.** It interns the symbols, parses SCIP symbol
  strings into names, kinds and Serena-style name paths (`Store/add`), and
  works out which symbol each reference sits inside.
- **SQLite stores and answers.** Goose imports `goose-sqlite`, whose
  `extern fn` bindings and C shim call its vendored SQLite amalgamation.
- **Goose also serves the MCP.** Goose v2026.3 ships `json`, stdin line
  reading and file IO, so the stdio MCP server is the same Goose binary.
  The original plan put a TypeScript/Bun layer here; it turned out not to be
  needed. Querying an existing map uses the native binary; mapping, checking,
  formatting, testing and live analysis require their external tools.

```
TS repo ──scip-typescript──▶ index.scip ──tools/scip-flatten.ts──▶ TSV rows
                                                                     │
                                         bin/swan index (Goose) ◀────┘
                                                │
                                         swan.db (SQLite) ◀── bin/swan serve (Goose, MCP stdio) ◀── AYA
```

The SCIP flattener is TypeScript run by Bun. Native C also supplies SQLite,
tree-sitter and its grammars, process/file helpers and the LSP bridge.
The matcher and LSP client logic are Goose; the language servers they use
are separate programs, not Goose ports. See [package boundaries](docs/packages.md)
for independent use, cached build behavior and the tradeoffs.
The flattener's
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
| `get_symbol_at` | `relative_path`, `line`, `column` | what a position refers to: definition, signature, docs, the symbol around it (JetBrains' quick documentation) |
| `get_callers` | `name_path`, `relative_path?`, `depth?` (1 to 5), `max_results?` | who calls or uses the symbol (import lines left out), and who uses those: the impact radius, with each caller's distance and whether it is test code, and a summary of affected symbols, files and test files |
| `get_callees` | `name_path`, `relative_path?`, `max_results?` | what the symbol's body uses, with counts; dependency symbols show their package and version |
| `find_implementations` | `name_path`, `relative_path?`, `max_results?`, `live?` | what implements, extends or overrides it, with distance; `live` asks the configured language server, subject to that server's capabilities |
| `get_type_hierarchy` | `name_path`, `relative_path?`, `depth?`, `max_results?` | supertypes and subtypes, from SCIP relationships |
| `replace_symbol_body` | `name_path`, `relative_path`, `body` | replaces the whole definition; refused if the file changed since the map was built; reports how many places use the symbol |
| `insert_after_symbol`, `insert_before_symbol` | `name_path`, `relative_path`, `body` | adds code next to a definition |
| `rename_symbol` | `name_path`, `relative_path`, `new_name`, `apply?` | plans by default: every site, skipped aliases, conflicts, stale files; `apply` writes it |
| `run_tests` | `name_path` or `relative_path`, `depth?` | runs the tests that reach a symbol through calls, overrides included, with the language's runner from `tools/modules.json` |
| `format_file` | `relative_path` | the language's formatter from `tools/modules.json` |
| `get_diagnostics` | `name_path?`, `relative_path?`, `depth?`, `errors_only?`, `live?` | compiler errors and lint findings pinned to symbols and their referencing symbols (see `docs/diagnostics.md`); `live` asks a configured server (Rust, Python, TS/JS or Kotlin) about one file |
| `search_pattern` | `pattern`, `language?`, `relative_path?`, `max_results?` | structural search, ast-grep style (`$X.unwrap()`, `console.log($$$A)`), via tree-sitter for TS/TSX/JS, Python, Rust, Java, Kotlin, C, C++ and CUDA: each match with what its metavariables captured and the symbol it is in |
| `rewrite_pattern` | `pattern`, `rewrite`, `language?`, `relative_path?`, `apply?` | structural rewrite: plans by default; `apply` writes it, refused for files changed since the map |
| `find_unused_symbols` | `relative_path?`, `include_tests?`, `max_results?` | functions, classes, methods, types and variables nothing references or implements: removal candidates, not proof |
| `index_info` | none | repo root, build time, counts, and the files changed since the SCIP run |

Every answer about a file that changed after the SCIP run carries
`"stale": true`, so an agent knows to reread it or refresh the map.

## Use

```bash
git clone --recurse-submodules https://github.com/shetautnetjer/Swan   # lsp/ is the goose-lsp submodule
cd Swan
scripts/fetch-tools.sh                          # Goose and the indexers and servers (sha256-pinned) into .tools/, the npm tools into tools/
scripts/build.sh                                # bin/swan; the first build fetches goose-sqlite and goose-treesitter
bin/swan map <repo> data/<name>                 # every indexer the repo needs -> map (refreshes if it exists)
bin/swan check <repo> data/<name>               # tsc / cargo check / pyright -> diagnostics in the map
scripts/index-repo.sh <ts-repo> data/<name>     # index.scip, TSV rows, swan.db
scripts/refresh-repo.sh <ts-repo> data/<name>   # after edits: rerun SCIP, rewrite only changed files
scripts/diagnose-repo.sh <ts-repo> data/<name>  # tsc / cargo check, loaded into the map
bin/swan serve data/<name>/swan.db              # MCP over stdio
bin/swan query data/<name>/swan.db refs getBackend   # the same answers on the command line
scripts/test.sh                                 # build, map the fixture, drive the MCP end to end, check refresh
```

For a small offline demonstration after building, run
`python3 scripts/demo-offline.py`. It exercises map loading, queries and
structural rewriting with synthetic rows, without installing indexers or
language servers. See [demo and test scope](docs/demo.md). The full integration
suite above needs the external tools and can build fixture projects.

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

These are historical first-slice measurements, not rerun by the standalone
contribution checks. They do not establish parity with Serena or JetBrains.
For reproducible compiler/cache measurements, see [package boundaries](docs/packages.md).

## Build speed

`swan map` runs every language's indexer at once, splits Python into
pieces that index side by side, and reuses what has not changed: a
2,853-file Python repo went from 159 s to 63 s for a first map, 8.8 s after
a one-file edit, and under a second when nothing changed. TypeScript is
split into chunks when it is the long pole (AEON: 18.6 s to 10.1 s).

After an edit, only the changed files and the files that use them are
indexed again, as a small extra run layered over the kept chunks: on AEON a
one-line edit re-maps in 2.0 s (8.4 s before), an edit to a file 266 others
use in 7.8 s, and an unchanged repo in 0.07 s. The result matches a fresh map
on all but 35 of 713,268 rows, those being scip-typescript's own numbering of
anonymous types, which also differs between two fresh maps.

`SWAN_WARM=<language>` or `SWAN_WARM=auto` starts a language server when
`swan serve` starts and opens one file, so the server loads the project
while the agent does other things. Off by default, since a resident server
holds 0.5 to 1.4 GB. Details in `docs/speed.md`.

## Per-language tools

Linters, formatters and test runners are not built in. `tools/modules.json`
lists them per language, with the conditions under which each applies and
how its output is read. Adding a language or swapping a tool is an edit to
that table. Today: ruff, ruff format and pytest for Python; biome and
`bun test` (vitest when configured) for TypeScript/JavaScript; clippy,
rustfmt and `cargo test` for Rust.

A question about one symbol's impact (`get_callers`, `get_callees`,
`get_diagnostics`), asked with a name several symbols share, comes back with
the candidates rather than a merged answer.

## Storage and refresh

The map lives in SQLite on disk; queries read the index pages they need.
Short names and name paths are indexed. `swan refresh` fingerprints each
file's rows from a new SCIP run and rewrites changed files in a transaction,
including files whose resolution changed because of an edit elsewhere.
Producing the SCIP input remains a separate cost. The compiler/cache
measurements in [packages.md](docs/packages.md) compare only this Goose
toolchain's own build states, not other languages or package ecosystems.

## Historical: the code-map bake-off (2026-10-25)

Kept as a dated record; these numbers were measured once and not rerun.
A separate bake-off compared a Goose in-memory snapshot with Rust + SQLite
on the same SCIP data for AEON. Both matched the TypeScript language server
on all 20 symbols it checked. Rust + SQLite won fresh-process lookups
(0.69 ms against 12.7 ms) because Goose's `from_bytes` verifies and copies
the whole 30 MB image on every start. Swan does not use that snapshot: its
map lives in SQLite on disk, and a query reads only the pages it touches.
On the same machine, `find_symbol getBackend` took 0.62 ms median (0.87 ms
p95) in a fresh process, against the bake-off's 0.69 / 0.83 ms for its own
query mix. The bake-off's two recommendations, lookup by short name and
per-file reindex, are both in Swan.

## Eggs: prebuilt packages, measured and parked

An idea from 2026-10-26: ship Goose packages prebuilt ("eggs", one per
language, such as `python-lsp.egg` or `java.egg`, listed in a registry
called the "nest", each described by an `egg.toml`). Measured: a cold build
of a program using goose-treesitter takes about 8 s and 0.2 s once Goose has
cached it, so prebuilding would save a few seconds once per machine. Parked
until a machine slow to compile or Goose's own prebuilt-package support makes
it worthwhile. A tree-sitter build with one grammar instead of ten took 2.9 s
instead of 7.7 s and made a 1.4 MB program instead of 20 MB; that split waits
for a user who needs only one language. See DECISIONS.md.

## Limits of this slice

- The graph includes non-call uses such as type references. Caller traversal
  excludes rows identified as imports, but is not a precise call graph.
  A class's callees are what its own body uses
  outside its methods; ask about a method for what that method uses.

- Tried with TypeScript, JavaScript (.js/.mjs/.cjs), Python, Rust, Java
  without a build tool, Kotlin through Gradle, and a host-side CUDA fixture
  without nvcc (`swan map` picks the indexers). Go, general C/C++ projects,
  C# and Ruby are unqualified here. The CUDA fallback does not check device
  compilation. What each tried
  indexer misses is in `docs/parity-and-languages.md`.
- scip-typescript has no per-file mode, so every refresh reruns it over the
  whole repo (~17 s on the repo above). Swan's own part is 0.23 s.
- Edits shift the map's positions for the edited file at once (checked against a
  fresh SCIP run in `tests/edit_check.ts`), but uses inside new code only
  appear after a refresh. Renames cover what the compiler resolved, not
  strings or comments.
- A files table already tracks freshness; occurrence paths are still stored
  as text. Interning them is a possible storage change, not a measured saving.
- Document-local symbols (`local N`) are dropped, as in the bake-off.

## Layout

```
src/swan.goose       CLI: index | query | serve
src/index.goose      builds (atomic: writes .tmp, renames) or refreshes the map
src/graph.goose      callers and callees
src/scip.goose       SCIP symbol grammar: name, kind, name path
src/query.goose      the tool queries, as JSON
src/serve.goose      MCP JSON-RPC over stdio
src/db.goose         map helpers over the imported SQLite package
src/swan.build       Goose sidecar: native file/process helpers and LSP bridge
native/swan_sys.c    file/process helpers
lsp/                goose-lsp submodule; standalone Goose client + C bridge
tools/              scip-flatten.ts, modules.json, external npm tool manifest
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
