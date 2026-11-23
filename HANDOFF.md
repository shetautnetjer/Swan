# Handoff: Swan in Rust (branch `rust-stage-4`)

Written 2026-11-20T07:25Z; stage 2 part rewritten 2026-11-20T16:21Z, stage 3 part 2026-11-20T23:51Z and again 2026-11-22T06:15Z, when stage 3 was finished; stage 4 part 2026-11-22T06:50Z, 2026-11-22T07:26Z 2026-11-22T16:46Z, 2026-11-22T18:18Z and 2026-11-22T18:45Z, when the prover had run on TypeScript's chunks and every job of a map was planned in Rust. For the next session, any agent. **Start at "Next action".** The end of the map, and the owner's two changes of direction: 2026-11-23T14:15Z. `lsp-index` in Rust: 2026-11-23T15:00Z.

## The task
Swan in Rust, on the owner's word. Until 2026-11-23 it was carried over
from the Goose program line by line and held to its bytes. That day the
owner changed it twice (DECISIONS.md, 13:36Z and 14:15Z): the Rust
written so far is kept; what is left is built Swan's own way, in the styles
of JetBrains (a map built ahead by the indexers that exist, asked in
milliseconds) and Serena (symbol tools answered by live language servers),
with SolidLSP as the one way a language server is run; the Goose program is
no longer matched, and the provers are no longer run. Sealing stays exact.
The stages as they were drawn, what was judged and how are in
[docs/rust-port.md](docs/rust-port.md): read its "From 2026-11-23" and its
"Next" first.

## State
| | |
|---|---|
| Branch | Stages 0, 1 and 2 are on main. Each later stage is its own branch from main and its own pull request. Nothing of the port is built by `scripts/build.sh`, installed or shipped |
| What ships | The Goose program, unchanged. `rust/` is the port |
| Stage 0 | Done: 47 of 47 wrong calls answered as the Goose build answers them |
| Stage 1, the store | Done: `index`, `refresh` and 13 of the 14 `query` kinds. The same tables, refusals, staleness and answers as the Goose build `fb8df2a4c199` on four trial repos (STATUS.md has the counts) |
| Stage 2, planning | Done and on main (#76, merged 2026-11-20 on the owner's word): `cargo-projects`, `gradle-tasks`, `plan-python`. STATUS.md has the counts |
| Stage 3, syntax | Done and on main (#78, merged 2026-11-22 on the owner's word): the trees, `query pattern`, `syntax-index`, `stamp-bench` and `stamp-worker`. STATUS.md has the counts |
| Stage 4, the map | Done on branch `rust-stage-4` (from main, pushed; no pull request): `scip-python-patch`, `scip-typescript-patch`, `trust`, `doctor`, and the whole of `swan map`: it plans, starts and waits for the indexers, flattens, stores, moves rows after cosmetic edits and ends its report. `scripts/port-map.sh`: 440 of 440 whole maps the same as the Goose program's. Its `lsp-index` child is in Rust too since 2026-11-23T15:00Z (below). Not in Rust: `map_held`, and what `src/wings.goose` and `src/seal.goose` hold that a map does not use |
| What is left | The language servers (next, and through SolidLSP: "Next action"), checking and editing, the MCP server, the build and the suite. Every command of theirs exits 70 and names the stage it was drawn in |

## What passed, and how to see it again
```bash
scripts/build.sh                                                     # the Goose program of this commit, the judge's other side
CARGO_TARGET_DIR=$PWD/build/rust ~/.cargo/bin/cargo build --release --manifest-path rust/Cargo.toml
CARGO_TARGET_DIR=$PWD/build/rust ~/.cargo/bin/cargo test --release --manifest-path rust/Cargo.toml   # 9 and 2 tests
SWAN_OLD=bin/swan scripts/port-compare.sh --wrong-calls              # 47 of 47
scripts/port-store.sh $TRIES/maps/relate $TRIES/relate               # ends "the same: ..."
scripts/port-prove.py $TRIES/maps/Agent-Reach $TRIES/Agent-Reach     # 9 of 9 breaks caught
SWAN_OLD=bin/swan scripts/port-plan.sh [repo...]                     # stage 2: ends "the same: N of N"
SWAN_OLD=$PWD/bin/swan scripts/port-prove-plan.py                    # stage 2: 76 of 76 breaks caught (about 30 min on 4 cores)
SWAN_OLD=bin/swan scripts/port-trees.sh [repo...]                    # stage 3: the same trees
SWAN_OLD=bin/swan scripts/port-pattern.sh [map.db...]                # stage 3: 182 of 182 on the made-up repo alone
SWAN_OLD=$PWD/bin/swan scripts/port-prove-pattern.py                 # stage 3: 33 of 33 breaks caught (about 6 min)
SWAN_OLD=bin/swan scripts/port-syntax.sh [repo...]                   # stage 3: 57 of 57 with no repo given
SWAN_OLD=$PWD/bin/swan scripts/port-prove-syntax.py                  # stage 3: 107 of 107 breaks caught (about 6 min on 32 cores)
SWAN_OLD=bin/swan scripts/port-stamp.sh [repo...]                    # stage 3: 82 of 82 with no repo given
SWAN_OLD=$PWD/bin/swan scripts/port-prove-stamp.py                   # stage 3: 59 of 59 breaks caught (about 5 min on 32 cores)
SWAN_OLD=bin/swan scripts/port-patch.sh                              # stage 4: 105 of 105
SWAN_OLD=$PWD/bin/swan scripts/port-prove-patch.py                   # stage 4: 29 of 29 breaks caught
SWAN_OLD=bin/swan scripts/port-run.sh                                # stage 4: 53 of 53, about a minute (PORT_RUN_QUICK=1: 3 s)
SWAN_OLD=$PWD/bin/swan scripts/port-prove-run.py                     # stage 4: 39 of 39 breaks caught
scripts/port-json.sh                                                 # stage 4: 159 of 159 texts
scripts/port-prove-json.py                                           # stage 4: 23 of 23 breaks caught
scripts/port-sort.sh                                                 # stage 4: 7,718 of 7,718 lists, under a second
scripts/port-prove-sort.py                                           # stage 4: 30 of 30 breaks caught (under a minute)
SWAN_OLD=bin/swan scripts/port-map.sh                                # stage 4: 440 of 440 whole maps; 6 min the first time, a minute after (the Goose program's side is kept in build/port-map/)
SWAN_OLD=$PWD/bin/swan scripts/port-prove-map.py                     # no longer run (the owner, 2026-11-23); its breaks fit the tree of ec0109a, not this one
```
`$TRIES` is the folder of trial repo copies the swan-change-loop skill
names, with the Goose program's maps of them under `maps/`. `port-store.sh`
takes a map folder (it holds the flattened rows) and the repo. Agent-Reach
takes 10 s, relate 2 minutes, rea 10 (three of its questions take over a
minute each in both programs). The provers take `--fit` (does every break
still match the source? nothing is built) and break numbers (only those).
The check suites judge the Goose program: the Rust program cannot run them
before stage 8.

## Next action: more of the language servers through SolidLSP, in Rust (branch `rust-stage-4`, or a new one from it)

The owner, 2026-11-23: "i wouldn't try to match goose, i would try to
create your own solutions using jetbrains and serena styles and what lsp
scip exist this is why i also keep mentioning just having a stable way by
using solidlsp just like serena".

### What is there to build on
- SolidLSP has been in Swan since 2026-11-17, for Go alone.
  `tools/solidlsp/bridge.py` (162 lines of Python) speaks LSP on stdin and
  stdout and answers from SolidLSP, which starts, configures and waits for
  the real server. `scripts/fetch-tools.sh` fetches it pinned
  (src/solidlsp of oraios/serena at one commit, a uv virtualenv);
  `tools/solidlsp/shim` stands in for the two helpers SolidLSP imports
  from the GPL application (NOTICE). STATUS.md, 2026-11-17, has what was
  measured.
- `tools/modules.json` says, per language, how it is mapped and which
  server answers live. Today: Go by `"map": "lsp"` through the bridge;
  Goose by `"map": "lsp"` through `goose lsp` and Swan's own client;
  eleven more languages have a server for live answers through Swan's own
  client.
- The Goose program's side: `lsp/golsp.goose` (889 lines, the client),
  `lsp/native/proc.c` and `glue.c`, `src/lspindex.goose` (388: a map made
  by asking a server for every definition and its references, written as
  SCIP) and `src/live.goose` (268: errors as the code stands).
- In Rust since 2026-11-23T15:00Z (STATUS.md has the numbers): `rust/src/lsp.rs`, a
  synchronous client on `lsp-server` and `lsp-types` (start, sealed as
  `src/live.goose` seals; ask with a time limit; kill the server's whole
  group when done); `rust/src/lspindex.rs`, `swan lsp-index <repo> <out>
  <lang> <target> [--within dir]`, SCIP written with the `scip` crate;
  `lsp_server` in `rust/src/modules.rs`, which reads a language's entry.
  Go (through the bridge) and Goose (through `goose lsp`) are mapped by the
  Rust program alone: cobra gives the Goose program's rows in 4.7 s
  against 7.1 s.
- RustRover helps while building: `cd <the jetbrains kit> && ./jb open
  rustrover <this repo>/rust`, then `./jb call rustrover get_file_problems`
  (or `lint_files`, `get_symbol_info`) with `projectPath` the `rust`
  folder. Open `rust/` itself, never the repo's top: the fixtures hold
  build files an IDE would import. Only its tools that read are used.
- docs/rust-port.md, "What exists in Rust to build on": the crates surveyed
  on 2026-11-23 and what none of them does.

### The work, in order
1. Go beside GoLand. cobra's Go rows are the Goose program's, and those
   were never put to an IDE. `jetbrains-reference`: map the copy, open it
   in GoLand, `compare/refs_vs_ide.py`. It waits on the owner: GoLand has
   no trusted folder for the trial repos ("Decisions waiting").
2. More languages through the bridge, one at a time, each measured against
   its JetBrains IDE before it is kept. The order put to the owner on
   2026-11-23 and answered "anyways sure": the languages with no SCIP
   indexer that are only searched today (Ruby, PHP, Lua, shell), then live
   answers for the languages that have an indexer. Each is an entry in
   tools/modules.json and a pinned fetch in `scripts/fetch-tools.sh`
   (SolidLSP knows about 80 languages; Helix's `languages.toml` and
   mason-registry say how each server is started and fetched). A language
   keeps its SCIP indexer for the map unless the measure says otherwise.
3. Live answers on the same client: `swan lsp-ask`, and `src/live.goose`
   (errors as the code stands, implementations). The client's `settle`
   (how a server says it is done: pull, publish or check) belongs here; it
   was left out of `ServerSpec` until something reads it.
4. Checking and editing, and the MCP server on `rmcp`.

Known and small, for whoever is next in these files: a silent server is
given 120 s (the old client's limit) before `lsp-index` fails;
`{java_source_paths}` is not filled in for a server's settings; the
client's reader thread is not joined, which a long-lived `swan serve` will
care about; the Rust program now carries Apache-2.0 libraries, and what a
shipped binary must say of them is for when it ships.

### How it is judged now
A JetBrains IDE on the trial repos, and Swan's own suite in the microVM
once the Rust program can stand in `bin/`. The comparisons with the Goose
program stay and cost a minute; they are not extended, and a difference one
shows is a question to look at, not a fault to mend. No prover is run.
AGENTS.md's rules hold as they are for the program that ships.

### What a whole map taught the judge on 2026-11-23
So it is not learned again (docs/rust-port.md, "Found while porting"):
- scip-clang's index is not the same twice from one program: C and CUDA
  rows are compared without it.
- scip-java gives its files back in an order that moves with the folder it
  writes in: fixtures/tiny-java is compared in any order.
- A TypeScript chunk that a changed file's users fall in has the time in
  its fingerprint; the syntax index's, scip-java's and, with Swan's own
  config, scip-typescript's take in a path of each program's own.
- "up to N indexers at once" follows the free memory.
- What a failed job said moves with the length of the folder's path.
- A Rust statement that outlives its connection keeps the map open and,
  for a new map, locked. `Db`'s close now stops the run when it does not
  close; if a command dies with "a map was closed with a statement still
  open", a statement is being dropped after its database.

### Also open, small
- `scripts/port-map.sh` still holds what judged a partly carried map
  (`OPENING`, `STEPS`, `WRITTEN`, `CACHED`, `LATER`, `ALSO`, the branch
  for exit 70). No map ends with 70 now; it can go when the script is next
  touched.
- The mend to main (stages 1 to 3: an empty line more when a statement
  cannot be prepared) and the locked new map (above; the fault is in the
  Rust on main, the mend on this branch) both wait for the owner's word on
  how the Rust on main is brought up to date.

## Jev's judgement, 2026-11-22 (evidence, not decisions)
Asked on the owner's word, one call, of a summary the working agent wrote:
the carried commands behave the same, 3.67 of 4; the judge should stay a
byte comparison (0.11 that it should be a model); the way a partly carried
map is judged is sound enough to build on, 0.74; keep the mix of server
clients while carrying and decide after, 100%; go on with the map in
order, 98%; for stage 5's child, start the original 59%, compare only on
repos without those languages 40%. docs/rust-port.md, "Found while
porting", has the call.

## Decisions waiting on the owner
- GoLand, to judge the Go map: it has no trusted folder for the trial
  repos, so opening one stops at "Trust project?". For the owner to run,
  with GoLand closed: `./jb trust-location goland <the trial repos'
  folder>` in the jetbrains kit. A first launch of GoLand may also stop at
  a dialog only he can answer.
- A pull request for stage 4 is opened when the owner asks, after the
  suite in the microVM on the commit that would merge.
- The next experiment after the port's stage 3, proposed in
  docs/agent-gaps-2026-11-20.md (branch `ccr-6c949a09-uhlhfn`): "sealed
  dependencies". Without a repo's packages, 70% of flask's errors, 93% of
  requests' are false, and real ones are hidden (34 in flask, 22 in pytest).
  The owner approved the rule on 2026-11-21 (AGENTS.md rule 1 on that
  branch): indexing needs no trust, and declared packages may be downloaded
  with install scripts off. The build is not started; that branch is not
  merged.
- The microVM suite ran on `rust-stage-3` at `2a75e1c` on 2026-11-22: 58
  + 322 checks, 0 failed, 56 Python tests OK. Its Goose sources are main's,
  so main has now been run since #74 and #76 in all but name. Run it on
  main itself as well, or take this?
- `plan-python`'s overflow on an enormous piece count (Graphify, #75, #76):
  the same in Goose and Rust; a one-line fix to both (`sizes.len / 2 < k`)
  as its own pull request, or not?
- Threads in the store. Measured, the same map written: `rayon` takes a
  further 14% off `index` on relate, SQLite's own sort threads 6% more
  (14% on rea). Held until stage 8 so the microVM suite can judge them;
  DECISIONS.md, 2026-11-20, has the table. Now, at stage 8, or not at all?
- Slow questions in the Goose program that ships. On rea `uses` takes
  2.4 s (median) and up to 88 s, `diag` 4.5 s, `callers` 0.2 s; each reads
  every symbol to answer about one. Four of the five causes have a rewrite
  that gives the same rows in the same order (docs/rust-port.md, "Slow
  questions in the program that ships"). Fix on main now and carry the same
  statements into the Rust side (the port's reference build moves to that
  commit), or hold until the port is done? And for folders: keep `LIKE`'s
  loose matching, or make it exact and fast?
- The mend to stages 1 to 3 (an empty line more when a statement cannot
  be prepared; "Next action", "Also open, small"): do it now on its own branch, or
  with stage 8? It is on main today, and shows only on a damaged map.
- `wings/` still points at Spread-Wings from before its Rust port. Moving
  the pin is its own change.
- The installed Swan is `fb8df2a4c199`, three merges behind main. Updating
  it is the owner's word (AGENTS.md rule 6).
- RustRover does not load `rust/` while Swan's folder is the project. To
  have the IDE judge the Rust in that window, attach `rust/Cargo.toml`
  there (the Cargo tool window). Until then a copy of `rust/` is opened as
  its own project, beside the trial repos.

## Held for after the port
Seen 2026-11-22 while carrying TypeScript, in the Goose program and so in the
port: a repo with no tsconfig of its own never has its TypeScript split or
layered, because tsc does not name the files of Swan's own config
(docs/rust-port.md, "Held for after the port"). A fix is its own branch
after the port, with a check and a measure on a real repo.

The owner's direction of 2026-11-20 (DECISIONS.md): Spread-Wings in Swan,
a file watcher such as `notify`, hidden files and git-ignored folders left
out for privacy, and one report of every area left out and why; serena-rs
as a reference at stage 5. docs/rust-port.md, "Held for after the port".
The owner's reason for the port (DECISIONS.md, 2026-11-22): Rust
has a more developed ecosystem. Up to the end of the map the port names
four libraries (libc, memchr, libsqlite3-sys, cc); from 2026-11-23 a Rust
library is used where one fits.

## Do not
- Change `src/*.goose` on this branch except to fix a bug found by the port
  (and then as its own change on main first).
- Go back to matching the Goose program's bytes, or run or extend a prover:
  the owner ended both on 2026-11-23 (DECISIONS.md).
- Loosen the seal for a language server. SolidLSP's servers run inside it,
  as gopls does now.
- Edit a `scripts/port-*.sh` in place while it runs (bash reads a script
  as it goes). Write the new one beside it and `mv` it over.
- Take an IDE's "no problems" for a pass before it has resolved a call
  across two files: an IDE that has not loaded the project answers the same.
- Open a Java, Kotlin or C# file of this repository in an editor's own
  language server without a seal. On 2026-11-21 one such look started a
  Gradle import of every Gradle fixture: Gradle was downloaded, a daemon
  started and 99 files written into the fixtures. The fixtures hold build
  files made to be awkward; read them through Swan.
