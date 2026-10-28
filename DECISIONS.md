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

## 2026-10-26 — Language-server clients as separately compiled Goose libraries

Goose compiles whole programs, so every module added to swan adds to its
build. The live client is instead its own Goose program compiled with
`--standalone` to C and linked like SQLite: swan's build caches the compiled
C, so a core edit stays at about 4.3 s. The library's runtime is separate;
the glue starts it once (goose_init) and only slices cross. Native helpers
it calls (native/proc.c) touch no Goose runtime state, because builders from
one runtime must not be grown by the other. The server dying is reported,
never fatal, since the library runs inside swan serve. Pyright and the
TypeScript server go in the same library next (one goose_init per binary).

## 2026-10-26 — Tree-sitter as a cached Goose package, matching in Goose

The grammars are 90 MB of generated C. A Goose package's native part is
built once per C compiler and cached, so they live in pkg/treesitter rather
than swan's own sidecar, whose C is rebuilt whenever any of it changes. Each
grammar source is included from a uniquely named file under grammars/,
because the package's objects are named after their sources (parser.c and
scanner.c would collide). Trees cross to Goose as flat int arrays from an
opaque handle; tree-sitter's by-value TSNode never does. Matching follows
ast-grep's default rules, found by probing ast-grep itself: target
punctuation the pattern leaves out is skipped, a pattern's last sibling may
be followed by more (an if with an else), `$X` is one named node, and a
metavariable that the grammar wraps (an expression statement) or reports as
an error still counts as one.

## 2026-10-26 — Swan's reusable parts as their own Goose packages

Goose has no package registry: a package is a git repository and a tag,
imported from the root file. SQLite, tree-sitter structural search and the
language-server client are useful beyond Swan, so they are goose-sqlite,
goose-treesitter and goose-lsp under shetautnetjer, MIT. The two packages
build their C once per compiler in Goose's cache; goose-lsp is a submodule
because Swan compiles it standalone (its Goose would otherwise join Swan's
whole-program build). The language adapters (rust-analyzer, pyright, the TS
and Kotlin servers) are configuration in tools/modules.json and stay in Swan.
No third-party binaries are re-hosted: kotlin-lsp, the JDK and the Android
SDK are fetched from their makers, pinned.

## 2026-10-26 — Eggs (prebuilt Goose packages) measured and parked

An "egg" would ship a Goose package's native part prebuilt (archives per OS
and CPU, an egg.toml with checksums), linked through a CMake IMPORTED
target, since Goose itself defers prebuilt binaries. The pilot built
goose-treesitter's archives (scripts/build-egg.sh on its local `egg`
branch): 11 archives, 20 MB for linux-x64, made in 2.4 s. Then the cost it
would save was measured: a clean build of a program using goose-treesitter,
the Goose runtime included, takes 8.2 s from an empty cache on 32 cores and
8.3 s pinned to 2, and 0.2 s once cached. An egg could save at most those
few seconds, once per machine, for a CMake dependency, release assets per
target and a runtime-version check. Not worth it now. The names stay for
later: an egg is a package, the nest its registry, egg.toml its manifest.
Mani's naming for per-language eggs, if tree-sitter or the language servers
are ever split by language: `python-lsp.egg`, `java.egg` and so on, one per
language. Measured for that split (2026-10-26): goose-treesitter with only
the Rust grammar builds in 2.9 s against 7.7 s for all ten, and makes a
1.4 MB program against 20.2 MB; Swan needs all ten, so it waits for a
one-language user.
Worth revisiting if Goose adds prebuilt packages itself or a target turns
out slow to compile on (a phone, a small CI runner).
## 2026-10-26 — Bounded contribution preparation

Keep the existing package APIs and repository/ref imports. Add independent
tests and explicit build evidence before proposing a larger packaging change.
SQLite and tree-sitter remain C-backed Goose packages; LSP remains a
separately generated Goose client with POSIX C helpers and external servers.
The offline Swan demo uses synthetic flattened rows and does not qualify
SCIP or live language servers. Historical comparisons are not fresh evidence.

Do not introduce a registry or new package manager. Splitting tree-sitter
grammars or changing the standalone LSP/runtime boundary would alter build
and API assumptions and needs a separate design review (docs/packages.md).

## 2026-10-27 — C# through scip-dotnet and csharp-ls

Use Sourcegraph's scip-dotnet for the C# map and csharp-ls for live errors,
both as dotnet tools under .tools with Swan's own .NET SDK, rather than
Roslyn wrappers of our own. scip-dotnet needs `dotnet restore`, which
writes the repo's obj/ folders; that is accepted as build output (the map
leaves obj/ out). It needs a solution or project at the repo root; deeper
layouts are not detected yet.
