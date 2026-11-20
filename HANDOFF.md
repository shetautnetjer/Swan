# Handoff: Swan in Rust (branch `rust`)

Written 2026-11-20T07:25Z. For the next session, any agent.

## The task
Carry Swan over from Goose to Rust, on the owner's word, as a complete
overhaul. Same behavior first; better design later, as its own change. The
bar, the rules, the nine stages, how a stage is judged and what differs on
purpose are in [docs/rust-port.md](docs/rust-port.md). Read it first.

## State
| | |
|---|---|
| Branch | Stages 0 and 1 are on main, merged 2026-11-20 on the owner's word. Each later stage is its own branch from main and its own pull request. Nothing of the port is built by `scripts/build.sh`, installed or shipped |
| What ships | The Goose program, unchanged. `rust/` is the port |
| Stage 0 | Done: 47 of 47 wrong calls answered as the Goose build answers them |
| Stage 1, the store | Done: `index`, `refresh` and 13 of the 14 `query` kinds. The same tables, refusals, staleness and answers as the Goose build `fb8df2a4c199` on four trial repos (STATUS.md has the counts) |
| Stages 2 to 8 | Not started. Every command of theirs exits 70 and names its stage; `query pattern` waits for stage 3 |

## What passed, and how to see it again
```bash
CARGO_TARGET_DIR=$PWD/build/rust ~/.cargo/bin/cargo build --release --manifest-path rust/Cargo.toml
CARGO_TARGET_DIR=$PWD/build/rust ~/.cargo/bin/cargo test --release --manifest-path rust/Cargo.toml   # 5 tests
scripts/port-compare.sh --wrong-calls                                       # 47 of 47
scripts/port-store.sh $TRIES/maps/relate $TRIES/relate               # ends "the same: ..."
scripts/port-prove.py $TRIES/maps/Agent-Reach $TRIES/Agent-Reach     # 9 of 9 breaks caught
```
`$TRIES` is the folder of trial repo copies the swan-change-loop skill
names, with the Goose program's maps of them under `maps/`. `port-store.sh`
takes a map folder (it holds the flattened rows) and the repo. Agent-Reach
takes 10 s, relate 2 minutes, rea 10 (three of its questions take over a
minute each in both programs). The full suite ran in the microVM on the
commit that went into main. It judges the Goose program: the Rust program
cannot run it before stage 8.

## Next action: stage 2, planning that runs nothing
`modules`, `survey`, `rustproj`, `tsproj`, `gradle`, `pyplan`, `stamp`
(2,007 lines), behind `cargo-projects`, `gradle-tasks`, `plan-python`,
`stamp-bench` and `stamp-worker`. Compared by bytes.
1. Read the seven files and list what they call outside themselves
   (`seal`, `run`, the walk). The walk is carried (`rust/src/walk.rs`);
   `abs_path` needs `realpath` back in `rust/src/sys.rs`.
2. `stamp` starts `swan stamp-worker` processes. Carry it as processes.
   Threads are a question waiting on the owner (below).
3. Write the stage's judge beside `port-store.sh`: each command on every
   fixture and trial repo through `scripts/port-compare.sh`, and break the
   Rust program on purpose to see each step fail before trusting it.
Stage 2 passes when the four commands print the same bytes on the fixtures,
the four trial repos and cobra.

## Decisions waiting on the owner
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
- Stages 2 and 3 do not depend on each other and could be carried in
  parallel by several agents. Faster, costs more.
- `wings/` still points at Spread-Wings from before its Rust port. Moving
  the pin is its own change.
- RustRover does not load `rust/` while Swan's folder is the project. To
  have the IDE judge the Rust in that window, attach `rust/Cargo.toml`
  there (the Cargo tool window). Until then a copy of `rust/` is opened as
  its own project, beside the trial repos.

## Do not
- Change `src/*.goose` on this branch except to fix a bug found by the port
  (and then as its own change on main first).
- Redesign while carrying over. Note the idea in `docs/rust-port.md`.
- Edit `scripts/port-store.sh` in place while it runs (bash reads a script
  as it goes). Write the new one beside it and `mv` it over.
- Take an IDE's "no problems" for a pass before it has resolved a call
  across two files: an IDE that has not loaded the project answers the same.
