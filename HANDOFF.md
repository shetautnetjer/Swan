# Handoff: Swan in Rust (branch `rust-stage-4`)

Written 2026-11-20T07:25Z; stage 2 part rewritten 2026-11-20T16:21Z, stage 3 part 2026-11-20T23:51Z and again 2026-11-22T06:15Z, when stage 3 was finished; stage 4 part 2026-11-22T06:50Z and 2026-11-22T07:26Z. For the next session, any agent.

## The task
Carry Swan over from Goose to Rust, on the owner's word, as a complete
overhaul. Same behavior first; better design later, as its own change. The
bar, the rules, the nine stages, how a stage is judged and what differs on
purpose are in [docs/rust-port.md](docs/rust-port.md). Read it first.

## State
| | |
|---|---|
| Branch | Stages 0, 1 and 2 are on main. Each later stage is its own branch from main and its own pull request. Nothing of the port is built by `scripts/build.sh`, installed or shipped |
| What ships | The Goose program, unchanged. `rust/` is the port |
| Stage 0 | Done: 47 of 47 wrong calls answered as the Goose build answers them |
| Stage 1, the store | Done: `index`, `refresh` and 13 of the 14 `query` kinds. The same tables, refusals, staleness and answers as the Goose build `fb8df2a4c199` on four trial repos (STATUS.md has the counts) |
| Stage 2, planning | Done and on main (#76, merged 2026-11-20 on the owner's word): `cargo-projects`, `gradle-tasks`, `plan-python`. STATUS.md has the counts |
| Stage 3, syntax | Done and on main (#78, merged 2026-11-22 on the owner's word): the trees, `query pattern`, `syntax-index`, `stamp-bench` and `stamp-worker`. STATUS.md has the counts |
| Stage 4, the map | Under way on branch `rust-stage-4` (from main, pushed): `scip-python-patch`, `scip-typescript-patch`, `trust` and `doctor` carried, with what runs a step and reads JSON; of `swan map`, its opening, its content stamps, and TypeScript as far as the projects it is split into. The Rust map then stops with exit 70. Left: the rest of the map |
| Stages 5 to 8 | Not started. Every command of theirs exits 70 and names its stage |

## What passed, and how to see it again
```bash
scripts/build.sh                                                     # the Goose program of this commit, the judge's other side
CARGO_TARGET_DIR=$PWD/build/rust ~/.cargo/bin/cargo build --release --manifest-path rust/Cargo.toml
CARGO_TARGET_DIR=$PWD/build/rust ~/.cargo/bin/cargo test --release --manifest-path rust/Cargo.toml   # 9 tests
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
SWAN_OLD=bin/swan scripts/port-map.sh                                # stage 4: 229 of 229 in the carried part; 3 min the first time, 12 s after
SWAN_OLD=$PWD/bin/swan scripts/port-prove-map.py                     # stage 4: 256 of 256 breaks caught (over an hour in one go; see below for parts side by side)
```
`$TRIES` is the folder of trial repo copies the swan-change-loop skill
names, with the Goose program's maps of them under `maps/`. `port-store.sh`
takes a map folder (it holds the flattened rows) and the repo. Agent-Reach
takes 10 s, relate 2 minutes, rea 10 (three of its questions take over a
minute each in both programs). The provers take `--fit` (does every break
still match the source? nothing is built) and break numbers (only those).
The check suites judge the Goose program: the Rust program cannot run them
before stage 8.

## Next action: the rest of `swan map` (branch `rust-stage-4`)
Stage 3 is on main (#78). `rust-stage-4` was begun on `rust-stage-3` and
has main merged in since (`7e0647a`): main's tree was the tip it stood on,
so the merge keeps this branch's tree as it was.

Done in stage 4 (docs/rust-port.md, "Next", has the order): the two indexer
patches; running a step, with `trust` and `doctor`; reading JSON; and a
map as far as the projects TypeScript is split into (src/pipeline.goose
line 1449: the opening, the stamps, cosmetic edits found, files to index
again, the repo's tsconfig or Swan's own, the indexer's patch, tsc's files
and roots, which config owns each file).
`rust/src/pipeline.rs` ends there with what the map has said so far and
exit 70.

How the map is carried and judged, a part at a time:
- Carry the next part of `map_main_locked` (src/pipeline.goose, from line
  1450: TypeScript's chunks, `plan_ts` and `same_file_set`, then the
  layers and its jobs; the closures defined from line 961 to 1266 that the
  later parts call are `add_job`, `add_lang_job`, `note_indexed`,
  `kept_texts` and `finish_cosmetic`, none carried yet), move the place the
  Rust map stops, and add to `scripts/port-map.sh` the lines of the report
  that part writes (`OPENING`), the steps it accounts for on standard
  error (`STEPS`) and the files it writes (`WRITTEN`, or `CACHED` for what
  a clean map holds back). The judge wants exactly those lines and steps,
  no more and no fewer.
- Give each rule of the part a case only it gets right, then
  `scripts/port-prove-map.py` with a break for each. Its first run on the
  opening caught 69 of 74, and on TypeScript's part 203 of 214: each time
  the misses showed what the judge did not ask. Run it as six parts side
  by side: `PORT_MAP_JOBS=4 PORT_PROVE_JUDGES=2 CARGO_BUILD_JOBS=6
  scripts/port-prove-map.py $(seq 1 43)` and so on, about twenty minutes
  in all on 32 cores. More judges at once than that and the machine is
  swamped.
- The judge keeps the Goose program's side in `build/port-map/<hash>/`.
  The hash is of the Goose program and of the functions that make the
  repos and the homes (`make_repos`, `make_before`, `home_of`,
  `home_as_installed`): change one and the Goose program maps every case
  again, three minutes. Each case also has a signature (its repo, its
  settings, the `prep_` and `home_` functions there are when it is
  reached), so a new case, or a change to how the judge compares, maps
  nothing again. Add `prep_` functions after the cases that are already
  there, or those cases are mapped again. Made-up repos and homes must
  stay in `build/` and not in /tmp: the seal gives a step its own /tmp.
- Cases run side by side (`PORT_MAP_JOBS`, 8), each Rust run from a home
  of its own under `build/port-map/run.*/c/<case>/`; `PORT_MAP_KEEP=1`
  leaves those folders to look at. A home is links to the checkout's
  `tools/`, with files of its own for what a map writes (so far the
  TypeScript indexer's `FileIndexer.js` and its mark) and for what a case
  swaps (`tsc`). Never write through one of the links, and never `chmod
  -R` a home: the links are to the checkout's own files.
- `HOME_PREP="home_tsc <name>"` gives a case a made-up tsc that says what
  `repos/tsc/<name>/` holds; `HOME_PREP=home_plain` and the like set how
  the indexer's patch stands. After each case the judge also compares how
  the indexer was left. `CACHED` files are compared except for a clean
  map, which must not have written them yet. `LATER_TEXTS=<n>` on a case
  says how many texts the Goose program keeps that only a later part
  writes.

Next in the map's own order: the rest of TypeScript (chunks, layers, its
jobs), the jobs of the other languages, and "no language found to index"
after them (exit 1 from the Goose program); running them;
the flattener; `index` or `refresh`; the end of the report, where
content-stamps.tsv is written and `finish_cosmetic` moves rows
(`shift_cosmetic` of src/change.goose and `mark_edited` of src/edit.goose
are needed there, though the stage table has them at stage 6). Settle
before the jobs:
- **The children.** A map starts its own program again as `syntax-index`
  (carried) and `lsp-index` (stage 5, not carried: Go, Goose and the other
  languages a server indexes). Until stage 5 the Rust map can be compared
  only on repos with none of those languages, or it has to start the Goose
  program for that one child. The agent proposed the second to the owner
  on 2026-11-22 and he said "continue" without choosing; Jev leaned the
  same way, weakly (59 to 40). Say which in docs/rust-port.md before
  building on it.
- **The patches.** `ensure_scip_typescript_patch` is carried, and both
  homes hold their own `FileIndexer.js` and mark. The two `ensure_`
  functions of pypatch come with Python's step: give `home_of` the home's
  own copies of `scip-python/dist/pyright-internal.js`, `scip-python.js`
  and their two marks first (the scip-python package is one link to the
  checkout's today), and compare them in `home_state`.
- **Left out until the part that reads them**: the virtualenv of a repo
  that is not trusted (the Goose program keeps it as `venv_read` for the
  Python step), two things `detect` notes (Maven and Gradle files at the
  top of the repo), and what TypeScript's part has worked out and not yet
  used (`a`, `target`, `ts_fp`, `force_ts`, `listed`, `listing`,
  `ts_others`: named in one `let _` where the Rust map stops).
- **What trust adds to the seal** (the network, folders to write in) is
  first shown by an indexer that builds; nothing carried so far shows it.

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
- SolidLSP for every language a server maps, not Go alone? The owner asked
  on 2026-11-21 why it was not used "for everything else". Today Go is
  mapped through it (`tools/solidlsp/bridge.py`, Python, with a virtualenv
  of its own in `.tools/`), Goose through `goose lsp` and Swan's own
  client, and the other languages by SCIP indexers, which give a whole repo
  in one run where a server answers file by file. No record says why it
  stopped at Go. It is a question for stage 5, where the client is carried.
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
has a more developed ecosystem. The port uses none of it yet: it names
four libraries, and stays that way until the stage each would touch has
passed.

## Do not
- Change `src/*.goose` on this branch except to fix a bug found by the port
  (and then as its own change on main first).
- Redesign while carrying over. Note the idea in `docs/rust-port.md`.
- Edit a `scripts/port-*.sh` in place while it runs (bash reads a script
  as it goes). Write the new one beside it and `mv` it over.
- Take an IDE's "no problems" for a pass before it has resolved a call
  across two files: an IDE that has not loaded the project answers the same.
- Open a Java, Kotlin or C# file of this repository in an editor's own
  language server without a seal. On 2026-11-21 one such look started a
  Gradle import of every Gradle fixture: Gradle was downloaded, a daemon
  started and 99 files written into the fixtures. The fixtures hold build
  files made to be awkward; read them through Swan.
