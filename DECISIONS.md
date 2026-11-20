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

## 2026-11-14 — Storage stays one SQLite file per repo; no vectors yet

Measured, not assumed. The user asked to try PGlite, SQLite and Postgres. The
same real maps (click, requests, ky, express, fzf and aeon-herdr, ~830k
occurrences) went into one SQLite file per repo, PGlite with one partition per
repo, and Postgres 16 with one partition per repo, in a throwaway 4 GB box.
Pass criteria were written before the run. All three passed every correctness
check: load, a refresh of 10% of files, removing a repo, and 14 cross-repo
questions with identical answers.

SQLite was fastest at everything: refresh 0.21 s against 0.58 s (Postgres) and
0.80 s (PGlite); cross-repo questions 14 ms against 55 ms and 340 ms; removing
a repo is deleting a file. It also used the least disk (225 MB against about
425 MB) and memory; PGlite peaked at 3.5 GB of the box's 4 GB. Cross-repo
questions work in SQLite by attaching each repo's file.

Vectors (local bge-small model, sqlite-vec, pgvector and PGlite's pgvector,
identical results) found the right file in the top 5 for 19 of 20 fuzzy
questions; keyword search found 18 to 19. That is under the 20-point bar set
beforehand, so no vector store is added. Vectors did pick the right file first
more often (12 against 9 to 11), so the next test is fuzzy questions on a large
repo, written by someone other than the session that built the search text.

Full numbers and the test code: the user's lab folder
`aya/projects/developmental-lab/swan-storage-test-20261114/` (RESULTS.md,
CRITERIA.md, box/). This supersedes the reasoning-only storage pick in
`docs/modular-design.md`, which reached the same answer.

## 2026-11-14 13:25 PT — A refresh reruns an indexer only when code changed

Pick #1 from the Understand-Anything and rea study. The user's question was
whether this belongs in Swan, a separate watcher for Brain, or a Rust core;
the answer that settled it (his "Yes", 12:57 PT) was where the time goes: on
rea's full map scip-typescript took 47 of 56 s and Swan's own steps about 8 s.
So the saving is in not running the indexer, wherever the code lives.

What changed: reuse used to key each file by size and mtime, so any save
reran its indexer, and on rea TypeScript is one whole-program job (the other
languages take all eight slots, so it is not split into chunks). Now each
file is stamped by its content (src/change.goose). TypeScript, JavaScript and
Python are stamped by their syntax tree with plain comments and layout left
out; other languages, and files that do not parse cleanly, by their bytes.
Comments indexers read stay in: doc comments become symbol docs, `@jsx` and
`@ts-` pragmas change how code resolves, and Python `# type:` comments are
read by pyright. C and C++ are bytes-only for now because scip-clang may read
ordinary comments too and the flattener reads C text for bodies.

A cosmetic edit leaves the indexed rows at old positions, so Swan keeps each
indexed text (map folder `texts/`, about the code's size) and moves the rows
token by token, as edit.goose does after Swan's own edits. The flattener now
reads the indexed text, not the current one, for rows it keeps
(markImports, cBodies, rustMacroUses), and says which index each document
came from (documents.tsv). When Swan does not know which text a file's rows
match (it changed while the indexers ran, or the copy is gone), that file is
reindexed in the same map: "unknown" is never treated as fresh.

Pass criteria, written before the run: a comment/format edit runs no
indexer and the map equals a fresh build of the edited repo; a doc comment,
a real change and a Python indent change do run the indexer and also equal a
fresh build (tests/cosmetic_check.sh, 23 checks). Measured on a private copy
of rea, unsealed on both sides (SWAN_SANDBOX=0: the seal cannot bind-mount
from the root shell used), same machine, one run each:

| Refresh | Before | After |
|---|---|---|
| full map | 57.2 s | 65.3 s (first run stamps and copies every file) |
| nothing changed | 5.7 s | 5.7 s |
| comment added to one .ts file | 51.3 s | 5.7 s |
| that file reformatted | 52.1 s | 5.7 s |
| real code added to it | 51.3 s | 52.0 s |
| comment added to one .py file | 6.0 s | 5.7 s |
| real code added to it | 5.8 s | 5.9 s |

On rea, comment and spacing edits to 40 files at once (30 TypeScript, 10
Python) left the map's rows for those files equal to a fresh map of the same
text, twice: 17,817 rows in a first run (where four of the TypeScript files
were stamped by bytes, so scip-typescript ran), and 19,724 rows in a second
run on files that all parse, after the refresh (7.7 s, no scip-typescript)
and one more refresh on top. None differed. Limit seen there: 213 of rea's TypeScript
files (about 3%) do not parse cleanly with Swan's tree-sitter TypeScript
grammar (which syntax trips it was not checked), so they are stamped by
bytes and any edit to one of them still reruns scip-typescript.

Not done here, and worth doing next: (1) a real TypeScript change on rea
still reruns the whole program; the existing "layer" path (index only the
changed files and their users) works only in chunk mode, and rea never gets
chunks. (2) About 4.4 s of every rea refresh, even with nothing changed, is
the flattener rerunning because scip-java fails on rea's Java files without a
build tool and is retried every map.

## 2026-11-14 14:10 PT — A real TypeScript edit reindexes only the changed files and their users

Phase 2 of the incremental reindex ("Build phase 2", the user, after phase 1
merged). Swan already had the mechanism: in chunk mode an edit is indexed as
a layer of just the changed files and the files that use them (by the last
map), over the kept chunks. rea never got chunks, because its Python, Java
and C take all eight job slots, so every code edit reran the whole program.

What changed, all in src/pipeline.goose's TypeScript planning:

- A project of 200 or more TypeScript/JavaScript files (`SWAN_TS_LAYER_MIN`)
  with no slot to split into runs as one chunk of all its files, so the
  layer path applies. Smaller projects keep the one whole run.
- `tsc --listFilesOnly` exits 1 on a repo whose node_modules are not
  installed (rea: "Cannot find type definition file for 'node'") but still
  lists the files; that listing is now used. Only tsc's own error exits
  (1, 2) with files in the listing count, not a timeout or crash.
- Chunks hold tsc's root files only, in the config's order (from
  `tsc --showConfig`). --listFilesOnly also lists every file the roots
  import, wherever it is; on rea that took in 118 .mts and .d.mts files
  outside its tsconfig's include, which a whole run does not index, and
  its order (the order tsc reached files) changed how scip-typescript
  numbers properties of inferred types. A first rea check found 55,561
  differing rows from these two; this was already true of split mode
  (AEON) and is fixed for both. The kept tsc list is keyed anew ("roots"),
  so a list from an earlier Swan is not reused.
- Those imported non-root files are still stamped, as shared inputs like
  the config and declarations: an edit to one reruns every chunk, since a
  layer cannot hold a file that is not a root (caught in review of PR 30).

Pass criteria, written before the run: a code edit on rea runs a layer, not
the whole program; the map after edits equals a fresh build of the edited
repo apart from rows that also differ between two fresh builds (scip-clang
picks and type-print order); tests/layer_check.sh (31 checks, one-chunk and
split modes, each map compared with a fresh build in one whole run) passes,
and fails on the old planner.

Measured on a private copy of rea, unsealed on both sides (SWAN_SANDBOX=0,
as for phase 1), one run each. Before is the phase-1 build:

| Refresh | Before | After |
|---|---|---|
| full map | 64.1 s | 65.9 s (adds tsc's file list, 3.3 s) |
| nothing changed | 5.7 s | 5.7 s |
| new export in one .ts file (3 users) | 52.6 s | 6.6 s (layer of 4 files, 1.1 s) |
| new export in a file 38 others use | 53.2 s | 7.3 s (layer of 39 files, 1.9 s) |
| nothing changed again | 5.6 s | 5.8 s |

After both edits the layered map differs from a fresh build of the same
text (phase-1 build, one whole run) in 88 of 1,876,863 rows (102 in an
earlier run of the same check); the phase-1 map after the same edits (whole
reruns) differs from that fresh build in 59 (22 earlier), and a fresh
one-chunk map in 29. So two whole runs already differ by tens of rows. The
rows are hover signatures that print a union's members in another order,
scip-clang's choice between duplicate C definitions, and a few references
to properties of inferred types (below).

Limits: a layer is indexed against the last map's view of every other
file, so a change that makes code in a file that used nothing from the
changed one resolve differently (a newly added global, say) shows up at
the next full run, after 6 layers or once layers cover a quarter of the
files. A layer file's reference to a property of an inferred type defined
outside the layer can get another number than the full run gave it; the
layered map differs from a one-chunk fresh map in 101 rows, these and
type-print order. About 5.7 s of every rea refresh is still Swan's own
steps and the flattener rerunning because scip-java fails on rea every map.

## 2026-11-15 12:20 PT — Swan's own steps use every core; the flattener is Rust

Asked: rebuild Swan in Rust on a branch and see whether it is faster.
Measured first (strace timeline of `swan map`, rea / Understand-Anything /
caura): 80 to 98% of a full map is the outside indexers (scip-typescript,
scip-python), which a Rust Swan would run just the same; Goose already
compiles to native code. Swan's own slow parts were three: stamping every
TS/JS/Python file on one core (6.6 s on a first rea map), the TypeScript
flattener under bun (4.4 to 6.7 s on every map that indexed anything), and
the SQLite write (3.9 s on a full rea map, left as it is).

Decided:
- Stamping runs on every core in Goose (`prestamp`, `swan stamp-worker`
  processes; `SWAN_STAMP_MODE=threads` does the same on Goose threads with
  typed queues). Not Rust: a stamp must be Goose's code_hash exactly, or
  every existing map would rebuild, and the same code in the workers makes
  content-stamps.tsv byte for byte what one core writes. Processes are the
  default because a failed worker only leaves its files to the main process.
- The flattener is Rust (native/swan-flatten, rayon), byte for byte the
  TypeScript one's output; build.sh builds it when cargo is there, and
  `SWAN_NATIVE_FLATTEN=0` keeps the TypeScript one.
- A refresh where only failed indexers ran (rea's scip-java on the PC) no
  longer reflattens the same index files (flattened-inputs.txt).

Measured in a throwaway Omarchy box (16 cores, 10 GB), rea, unsealed:

| | main | branch, 1 core | branch, 16 cores | branch, 16 threads |
|---|---|---|---|---|
| full map | 88.2 s | 74.9 s | 65.9 s | 65.5 s |
| code edit in one .ts file | 9.10 s | 3.95 s | 2.97 s | 2.73 s |
| flatten | 5.3 to 6.7 s | 1.5 s | 0.47 to 0.61 s | 0.40 s |
| stamping a first map | 7.0 s | 7.0 s | 0.60 s | 0.56 s |

scip-typescript alone took 57 to 67 s across these runs, so full-map wall
times carry about 10 s of indexer noise; the step times are the comparison.
Stamping by workers: 2: 3.6 s, 4: 1.85 s, 8: 0.98 s, 16: 0.60 s (threads
within 7%); 32 on the PC 0.48 s. A worker process costs 0.7 to 0.8 ms.
On the PC, where scip-java fails on rea, a nothing-changed refresh went
from 5.6 s to 0.57 s and a comment edit from 5.7 s to 0.65 s.

Accuracy: content stamps identical to main's in every run and mode. Maps
differ from main's in 8 to 12 of 1,880,390 rows in the box (38 on the PC,
where two runs of main differ in 30): scip-clang's choice between duplicate
C definitions, as before. Swan's checks pass with the workers on and forced
on (SWAN_STAMP_MIN=1), except mcp_smoke, structural_check and
kotlin_live_check, which fail the same way on main on the PC.

## 2026-11-16 — The seal covers every mount and hides host sockets

Found on an Omarchy (Arch, btrfs) machine, where `/home` is its own mount:
eggshell's own test failed "repo stayed read-only" and "network blocked".

- **Repo writable.** eggshell remounted only `/` read-only. Separate mounts
  (`/home`, `/tmp`, `/var`, data disks) stayed writable inside the seal, so a
  repo under `/home` could be changed by its indexer. The old README said a
  separate mount "can't be made read-only from an unprivileged user
  namespace"; that is only true for *clearing* an inherited read-only flag.
  Setting it works. eggshell now remounts every mount read-only (parents
  first) and refuses unless the repo's own mount reports `ro`.
- **Names resolved.** TCP was blocked by the network namespace, but
  `getent hosts github.com` still answered: glibc's `resolve` (and `mdns`)
  NSS modules ask systemd-resolved (or avahi) over unix sockets in `/run`,
  which a network namespace does not cut off. That is a DNS side channel out
  of the seal. Sealed runs now mount an empty read-only tmpfs over `/run`
  (and unset `XDG_RUNTIME_DIR` and the D-Bus addresses). `--allow-net`
  keeps `/run`, since a trusted build may need DNS.

The extended `eggshell/test.sh` has 13 checks; against the old runner 7
fail on this machine, against the new one all pass.

## 2026-11-16 — Seal everything; trust only loosens

Agents should never have to ask a person to trust a repo. The seal, not a
human, is what makes running a repo's build code safe.

- **Trusted runs are sealed too.** Before, `seal_argv` was used only for
  untrusted repos, so `swan trust` switched every protection off: network,
  writes anywhere in the home. Now every indexer launch is sealed; trust adds
  `--allow-net` and `--rw` grants for the repo (Gradle writes `build/`,
  dotnet `obj/`), Cargo's home and Swan's Gradle and .NET caches, through a
  new `eggshell --rw DIR`.
- **Rust needs no trust.** rust-analyzer scip (which runs build scripts and
  proc macros) runs sealed and offline (`CARGO_NET_OFFLINE`) for untrusted
  repos, with `RUSTUP_HOME`/`CARGO_HOME` passed in because the seal's HOME is
  scratch, and its target dir in the map. Cargo's home stays read-only, so a
  repo can't poison the crate cache. On a small Rust workspace the untrusted
  map went from 39 symbols (syntax only) to 825, with callers matching `rg`.
- **The map's probes are sealed.** `tsc --showConfig/--listFilesOnly` and
  the Python package probe ran unsealed with the repo as working directory;
  `python -m pip` and `python -c` would import a repo file named `pip.py` or
  `json.py`, running repo code before any trust check.
- **Still waiting for trust:** Gradle/Maven/MSBuild indexers (they need
  writable caches without cross-repo poisoning, likely an overlay over a
  shared cache, and an offline mode), `swan check`'s checkers and live
  language servers.

Two fixes the change needed, found by running the whole suite sealed:

- **Each variable once in a child's environment.** `swan_spawn` and
  `swan_run` passed Swan's entries *and then* the whole inherited
  environment, so `PATH` appeared twice. `getenv()` takes the first copy, a
  shell the last; eggshell is a shell script, so sealed runs got the host
  `PATH` without Swan's tool directories (scip-clang lost its `clang++`
  stand-in and indexed CUDA half). Inherited entries that Swan overrides are
  now dropped (`native/swan_sys.c`).
- **A private `/tmp` per sealed run.** scip-java writes to `/tmp` whatever
  `TMPDIR` says, and the seal had made `/tmp` read-only.

The test runner (`scripts/test.sh`, `set -e`) stopped at the long-standing
Rust macro failure, so nine checks after it had not run on main either; they
were run one by one for this change. `structural_check` (no `ast-grep` on
the test machine) and `kotlin_live_check` fail identically on main.

Ideas behind it: Pydantic Monty's "no ambient authority, the host grants
named capabilities", applied to OS processes, where Monty itself defers to an
OS layer.

## 2026-11-18 13:10 PT — The broad map follows the files; Swan asks before each answer

Spread-Wings' graph was rebuilt when Swan's map was newer and not
otherwise, so it was as old as the map and as slow to renew as a whole
index. With `spread-wings update` (the graph from the files that changed)
the two can part: the graph follows the files, the map stays what the
compilers last said.

Decided:

- **Two graphs beside the map.** `wings-rules.db` holds what the rules
  give, and is the one kept up to date. Swan's compiler answers go into a
  copy, `wings.db` (`compiler --into`), because an update has to redo the
  links those answers sit on. The other way, compiler answers as a layer
  that stays through an update, would be quicker after a change and is not
  built.
- **Swan asks before each answer; it keeps no watcher.** A look when
  nothing changed is 0.06 s on relate, sealed. A watcher would save that,
  and would be one more process for each repo, which some Swan has to
  start and which ends with it; with several `swan serve` on one map
  folder, which one is not obvious. To be measured before it is built.
- **Whether the copy is current is told by the rules graph's time and
  size** as Swan last left it (`wings.checked`), not by comparing times of
  the two graphs: `update` writes its file even when it finds nothing.
- **The answer says what changed** (`files_changed`), once. Swan does not
  refresh its own map from it: that runs the language tools, which is the
  agent's call (`swan map`).

## 2026-11-18 14:45 PT — A virtualenv is read, never run; a stand-in answers for its interpreter

A project's virtualenv holds what the project imports. Swan used it only
for trusted repos, because the one way it knew to use it was to put its
`bin` first on PATH, which runs the repo's python. Every other repo was
indexed against this machine's Python.

Decided:

- **Read it.** What scip-python needs from a virtualenv is two lists: the
  packages (name, version, files) and the folders to look in. Both are
  files to read: `*.dist-info` and `lib/python*/site-packages`. Nothing in
  the virtualenv has to run, so trust is not involved.
- **A stand-in interpreter, not a change to pyright.** scip-python's
  pyright learns the folders by running `python3 -c <script>`. Swan puts a
  small `python3` of its own first on that step's PATH; it runs the script
  in the machine's python3 with `sys.path` set from the virtualenv. The
  other ways were to patch the folders into Swan's copy of the bundle
  (breaks when the bundle changes) or to copy the virtualenv out of the
  repo (hundreds of megabytes).
- **The names are fixed in Swan's copy of scip-python.** Upstream names
  anything under the folder it runs in as the project, and a virtualenv
  sits there. A link or a copy outside does not help (pyright resolves
  links; a copy is the megabytes again). Five places, applied and checked
  the way the reachability memo is, and left alone when they do not fit.
- **The Python version comes from `pyvenv.cfg`**, through the same fix:
  scip-python never asks its interpreter.
- **One environment for a repo, for now.** A repo with several
  virtualenvs gets the union, the top first. One scip-python run for each
  project, as Go has one for each module, is the right shape and is not
  built: the pieces a Python repo is split into would have to follow
  project borders.
- **A trusted repo's top virtualenv is still run**, as it was. It gives
  the same names now; reading it instead is a later simplification.

## 2026-11-19 22:03 PT — Swan is carried over to Rust on a branch; Goose ships until the numbers are in

**Decision (the owner's):** carry Swan from Goose to Rust as a complete
overhaul, on branch `rust`.

**Why:** the owner chose Rust for Spread-Wings on 2026-11-18 after its trial
("I think I will stay rust": easier to build on, to carry other tools' ideas
into and to add languages to) and asked for the same for Swan.

**How:** the method that carried Spread-Wings: a bar written first
(docs/rust-port.md), the code carried line by line and not redesigned, each
stage held to the same output as the Goose build before the next is built on
it. The check suites stay as they are and judge the port from outside.

**Not decided:** when Rust becomes what is built. That is the owner's call
after stage 8, with the map hashes, the suite counts and the cost table.
Retiring the Goose sources is a change of its own.

## 2026-11-20T07:15Z — Speed in the Rust port: faster row scanning now; threads measured, and held until the port passes

**Decision (the agent's, inside the port's method; the owner can overrule
it):** while Swan is being carried over, a faster way to do the same step is
taken only when it runs on one thread and changes no byte of output.
`memchr` (finding tabs and line ends) is in. Threads are not: `rayon` for
Swan's own work on the rows, and SQLite's own sort threads, were both tried
in scratch copies, both write the same map, and both wait for the owner's
word and for stage 8, when the suite in the microVM can judge them.

**Asked by the owner (2026-11-19):** whether rayon, crossbeam "or something"
could speed things up; then rusqlite; then salsa and petgraph.

**Measured** (`swan index`, time and peak memory, medians of 7 runs on
relate and 5 on rea, turn about, one machine with 32 processors):

| | relate (742 thousand occurrences) | rea (1.5 million) |
|---|---|---|
| Goose | 1,093 ms, 346 MB | 3,835 ms, 831 MB |
| Rust, carried over | 1,065 ms, 338 MB | 3,521 ms, 795 MB |
| with memchr (in the tree) | 972 ms, 339 MB | 3,316 ms, 794 MB |
| and rayon (trial) | 839 ms, 362 MB | 3,103 ms, 840 MB |
| and SQLite's sort threads (trial) | 790 ms, 321 MB | 2,665 ms, 714 MB |

All five wrote the same tables on both repos, and on relate the same file
byte for byte (the time stamp aside).

**Why not threads now:**
- About 70% of `swan index` is SQLite's own work on one connection (40% is
  the nine indexes it builds at the end, timed step by step on relate). A
  thread crate reaches only the rest.
- A whole map is minutes of indexers; `index` is about a second of it.
- Threads behave differently on a small machine, and until stage 8 the
  microVM suite cannot run the Rust program: nothing would judge them there.
- The rayon trial peaked 16 MB above the Goose program on relate and 9 MB on
  rea; the bar is the same or better. Smaller batches would mend it; not
  done.
- SQLite's sort threads need temporary files on disk where Swan asks for
  memory today: a new way for a map to fail.

**Looked at and not taken:**
- **crossbeam.** rayon is built on it, and Rust's own library has scoped
  threads and channels now. Nothing here needs it by name.
- **rusqlite.** A Rust layer over the same C SQLite, through the crate the
  port already calls (`libsqlite3-sys`). The same engine at the same speed;
  it would change how the code reads, not what it costs.
- **salsa.** Keeps derived facts in memory and recomputes what changed,
  inside one long-running process (rust-analyzer is built on it). Swan keeps
  its facts in SQLite on disk, across processes, and gets them from
  compilers; its "only what changed" is `refresh` and the reuse
  fingerprints. Building on salsa would be a different Swan.
- **petgraph.** Graphs held in memory. Swan's graph questions run inside
  SQLite over indexed rows with nothing loaded first (2 to 6 ms for a
  question on relate); loading 742 thousand rows for each question would
  cost more than it saves. A fit, if ever, for a long-running server or for
  Spread-Wings' graph.

**Also true:** rayon is in Swan already. `native/swan-flatten` uses it.

## 2026-11-20T09:43Z — The port's first two stages go into main; each later stage is its own pull request

**Decision (the owner's):** asked which merge he meant by "get on rust do
the merge", he chose "Rust branch into main": commit stage 1, push the
branch and merge the port so far into main.

**What it means:** `rust/`, the port's scripts (`scripts/port-*`) and its
records are on main beside the Goose program. The Goose program is still
what `scripts/build.sh` builds and what ships. Nothing builds the Rust
program but the port's own commands, and nothing installs it.

**From here:** a stage is one branch from main and one pull request, like
any other change (AGENTS.md, rule 3). The long-lived `rust` branch ends
with this merge.

**Not decided by this:** when Rust becomes what is built (after stage 8);
threads in the store; whether the slow questions are fixed in the Goose
program now or carried into Rust later; and whether a folder is matched
loosely, as now, or exactly.
