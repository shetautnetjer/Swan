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
| Stage 4, the map | Under way on branch `rust-stage-4` (from main, pushed): `scip-python-patch`, `scip-typescript-patch`, `trust` and `doctor` carried, with what runs a step and reads JSON; of `swan map`, its opening. The Rust map then stops with exit 70. Left: the rest of the map |
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
SWAN_OLD=bin/swan scripts/port-map.sh                                # stage 4: 72 of 72 in the carried part; a minute the first time, 5 s after
SWAN_OLD=$PWD/bin/swan scripts/port-prove-map.py                     # stage 4: 74 of 74 breaks caught (about 16 min; halves can run side by side)
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
patches; running a step, with `trust` and `doctor`; reading JSON; and the
opening of a map, up to the mark of when it began (`scip-started`,
src/pipeline.goose line 959). `rust/src/pipeline.rs` ends there with what
the map has said so far and exit 70.

How the map is carried and judged, a part at a time:
- Carry the next part of `map_main_locked` (src/pipeline.goose, from line
  961: the jobs), move the place the Rust map stops, and add to
  `scripts/port-map.sh` the lines of the report that part writes
  (`OPENING`) and the files it writes (`WRITTEN`). The judge wants exactly
  those lines, so a part that says nothing more needs no change there.
- Give each rule of the part a case only it gets right, then
  `scripts/port-prove-map.py` with a break for each. Its first run on the
  opening caught 69 of 74; the five showed what the judge did not ask.
- The judge keeps the Goose program's side in `build/port-map/<hash>/` (the
  hash is of the Goose program and of the judge itself), so each edit of
  the judge costs one minute of the Goose program mapping every case.
  Made-up repos and homes must stay there and not in /tmp: the seal gives
  a step its own /tmp.

Next in the map's own order: "no language found to index" (exit 1 from the
Goose program; the Rust map stops just before it); the content stamps and
cosmetic edits (`stamp_known`, `line_of_path` and `index_lines` are first
used here); the jobs of each language; running them; the flattener;
`index` or `refresh`; the end of the report. Settle before the jobs:
- **The children.** A map starts its own program again as `syntax-index`
  (carried) and `lsp-index` (stage 5, not carried: Go, Goose and the other
  languages a server indexes). Until stage 5 the Rust map can be compared
  only on repos with none of those languages, or it has to start the Goose
  program for that one child. Say which in docs/rust-port.md before
  building on it.
- **The patches.** The three `ensure_` functions of pypatch and tspatch
  patch Swan's own copy of an indexer before a map. The Rust program's
  made-up home links to the checkout's `tools/` today; it needs copies of
  the six files a map may write, as the Goose program's home has, before
  the Rust map reaches them.
- **Left out of the opening until the part that reads them**: the
  virtualenv of a repo that is not trusted (the Goose program keeps it as
  `venv_read` for the Python step), and four things `detect` notes
  (tsconfig, Maven and Gradle files at the top of the repo).
- **What trust adds to the seal** (the network, folders to write in) is
  first shown by an indexer that builds; nothing carried so far shows it.

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
