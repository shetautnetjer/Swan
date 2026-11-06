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

## 2026-10-31 — The map folder is the registry; no registry file

`swan serve --maps <data-root>` finds a repo's map by scanning
`<data-root>/*/swan.db` and matching the `root` each map records in its own
meta, rather than keeping a name→repo index of our own. The maps are already
the source of truth: a registry file could only disagree with them (a moved
repo, a deleted map, a renamed folder), and every disagreement would be a
bug the scan cannot have. A path inside a mapped repo resolves to the
nearest recorded root above it, so an agent asking about
`repo/src/deep/file` lands on the right map without knowing where the root
is. New maps are named for the repo's basename, with a short path hash
appended when the name is another repo's, which keeps `data/` readable as a
list of projects. Cost: one sqlite open per map per `use_repo` — nothing
next to a map build.

## 2026-10-28 — Build-running tools wait for `swan trust`

A repo's build files can run any code (cargo build scripts and proc macros,
Gradle and Maven, MSBuild through `dotnet restore`). After Codex's review of
the C# PR, Mani chose to have every tool that runs them wait until a person
trusts the repo: `swan trust <repo>` adds the repo to Swan's own data/trusted-repos
(first kept in the map folder; moved out after Greptile showed a map folder
inside the checkout could ship its own record).
Candidates in tools/modules.json carry `runs_repo_code`; the map and check
pipelines gate their own jobs the same way and report what they skipped.
SWAN_TRUST_BUILD=1 trusts every repo (tests, CI). The MCP server has no
trust tool, so a repo's contents cannot get an agent to trust it. Test
runners stay ungated: running tests is an explicit request to run the code.

## 2026-11-06 — Describe platform evidence separately from portability goals

The public README must distinguish implemented/tested Linux x86-64 behavior
from Windows, macOS, WSL2 and ARM64 targets that have not been qualified.
Goose compiler distributions or MCP compatibility alone do not establish
Swan host support. Keep machine-specific paths out of public setup
requirements and preserve the existing installation and package boundaries.
The platform work in `docs/packages.md` is a proposal pending approval;
this decision authorizes accurate documentation, not a new platform port.
The live-Python trust fix is already in source and the inspected installed
Linux executable; no redundant rebuild is required to document it.

## 2026-11-06 — Approve a Linux package and portable existing skill

The user approved the PRD/HLD in `docs/packages.md` for implementation and
testing in CUA. Preserve the existing executable-relative tree and trust
storage. Build a candidate archive and standalone Python installer for a new
user-owned Linux x86-64 prefix; `core` avoids optional runtime downloads,
and `python-typescript` selects the existing frozen npm tools plus compatible
system or pinned private Node/Bun. System Python remains an explicit prerequisite.

Reuse `skills/swan-code-check/` and its corpus, removing machine/personal
defaults. Add read-only dependency reporting and keep automatic trust grants,
global system changes, agent configuration changes, upgrades, new registries
and platform ports out of this milestone. Both build-header defects are fixed
in their owning sources; Swan pins the corrected SQLite commit rather than
patching a compiler cache. A release export needs a clean source revision,
binary-bound build receipt, checksums and third-party notices. The receipt is
an attestation; real installation/runtime checks and independent review are
required separately. Public release publication and production replacement
are separate actions, not implied by the candidate build.

## 2026-11-06 — Approve ordered improvements and reviewed source merges

The owner approved the sequence and acceptance checks described in
`docs/improvements-2026-11-06.md`, including tests and merging when ready.
Keep focused changes in their owning repositories and preserve active
installations, trust/configuration and package identities. Investigate and
measure before introducing a new language adapter or changing architecture.

## 2026-11-06 — Bound concurrent-map guarantees to tested operations

Keep SQLite and the existing map pipeline. The stage 3 candidate in Swan
PR #15 serializes `map`/`index`/`refresh` using an OS advisory lock on a stable
adjacent lockfile, covering shared intermediate output as well as publication.
Preserve that file after release; its existence does not indicate ownership.
Resolve parent-directory aliases, refuse database-file symlink writes, and
inherit writer descriptors into indexer/flattener children so a parent death
does not release ownership while those children still write.

Use request-scoped database snapshots for the read-only whitelist and reopen
the selected path before subsequent requests. A complete old/new answer or
an explicit contention failure is acceptable; seamless concurrency is not
promised. Preserve source freshness checks because database snapshots do not
freeze on-disk source. Other stateful operations and saved trust-list updates
remain outside this contract and require coordination. No Windows/macOS,
network-filesystem or power-loss guarantee follows from the Linux tests.
See `docs/concurrency.md` for the qualified `ef03ba0` binary and test scope;
PR #15 is still open, and qualification does not authorize host replacement.

For Goose-language work, investigate the existing official grammar/compiler
server before proposing an adapter. The successful v2026.3 LSP probe only
confirms an entrypoint; grammar/live/semantic-map acceptance remain distinct.
Stage 5 measurements now support retaining the correctness change and
existing reuse without additional optimization: database loading took 6–23 ms,
reported indexer work 388–766 ms, and the reader median increased by only
0.082385 ms in the bounded 50,000-row fixture. Mapping equality and query
answers passed. These measurements do not justify a new backend, daemon,
parser, package split or speculative performance change; see
`docs/improvements-2026-11-06.md` for fixture scope and exact observations.

## 2026-11-06 — Release completed jobs while retaining failed-child ownership

Superseding the close-only successful-release behavior of the earlier stage-3
candidate, use `swan_writer_complete` only after successful cooperating jobs
and map publication. Explicit `LOCK_UN` releases inherited copies held by idle
build servers. Failure/timeout uses close-only `swan_writer_unlock`, while
abrupt termination relies on OS descriptor cleanup; surviving child writers
retain ownership. This does not promise protection against tools that report
success before finishing shared output. Preserve the automated implementation
at `8223ea6`, retain the lock-entry symlink refusal added in `5d41596`,
and independently qualify that final source.

Keep repository discovery fail-closed on busy/locked maps: an unreadable root
could be a nearer match than a readable ancestor. Keep the advisory lock's
owned/trusted-directory boundary explicit rather than claiming cross-user
isolation. For dependency/configuration changes, the skill must select its
fresh map through a private registry or exact-database CLI query; creation time
does not determine map selection. See the review-completion receipt and
`docs/concurrency.md` for final evidence and remaining limits.

## 2026-11-06 — Explicit per-request map selection policy

Following the independent optimization review, the user authorized the
recommended first implementation and pull request. Add optional boolean
`build` to all repository-selecting MCP tools, preserving omitted/true
behavior while honoring false on the common selection path. Reject supplied
nonbooleans, including null, before selection/reopening/tool effects. This
corrects the earlier skill assumption that `use_repo(build:false)` could
constrain subsequent ordinary `repo` calls.

Keep existing root-selection, snapshot, trust and explicit-tool semantics.
The control is not a general read-only mode; warm-up and explicit writes
retain their own effects. Older schemas require the exact-database or
controlled persistent-session fallback. See `docs/request-build-policy.md`.

Keep cache publication/recovery, test-path deduplication, skipped-check
diagnostic preservation, broader skill evaluation and performance work in
separate changes, as recommended by the review. No library upgrade, database
replacement, new service or installed-binary update is part of this PR.
