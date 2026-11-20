# Handoff: Swan in Rust (branch `rust`)

Written 2026-11-20T07:25Z; stage 2 part rewritten 2026-11-20T16:21Z. For the next session, any agent.

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
| Stage 2, planning | Done 2026-11-20: `cargo-projects`, `gradle-tasks`, `plan-python`. Pull request #75 (branch `rust-stage-2`, stacked on #74); not on main. STATUS.md has the counts |
| Stages 3 to 8 | Not started (stage 3 now holds `stamp` too). Every command of theirs exits 70 and names its stage; `query pattern` waits for stage 3 |

## What passed, and how to see it again
```bash
CARGO_TARGET_DIR=$PWD/build/rust ~/.cargo/bin/cargo build --release --manifest-path rust/Cargo.toml
CARGO_TARGET_DIR=$PWD/build/rust ~/.cargo/bin/cargo test --release --manifest-path rust/Cargo.toml   # 5 tests
scripts/port-compare.sh --wrong-calls                                       # 47 of 47
scripts/port-store.sh $TRIES/maps/relate $TRIES/relate               # ends "the same: ..."
scripts/port-prove.py $TRIES/maps/Agent-Reach $TRIES/Agent-Reach     # 9 of 9 breaks caught
SWAN_OLD=bin/swan scripts/port-plan.sh [repo...]                     # stage 2: ends "the same: N of N"
SWAN_OLD=$PWD/bin/swan scripts/port-prove-plan.py                    # stage 2: 76 of 76 breaks caught (about 30 min on 4 cores)
```
`$TRIES` is the folder of trial repo copies the swan-change-loop skill
names, with the Goose program's maps of them under `maps/`. `port-store.sh`
takes a map folder (it holds the flattened rows) and the repo. Agent-Reach
takes 10 s, relate 2 minutes, rea 10 (three of its questions take over a
minute each in both programs). The full suite ran in the microVM on the
commit that went into main. It judges the Goose program: the Rust program
cannot run it before stage 8.

## Next action: stage 3, syntax
Stage 2 is done: `cargo-projects`, `gradle-tasks` and `plan-python`
(`rust/src/rustproj.rs`, `gradle.rs`, `pyplan.rs`), judged by
`scripts/port-plan.sh [repo...]` and seen failing with
`scripts/port-prove-plan.py`. `stamp`, `tsproj`, `survey` and `modules`
moved to the stage of their first user (docs/rust-port.md, the stage
table and "Found while porting").
1. Read docs/rust-port.md, "Next": stage 3 builds tree-sitter and its
   grammars from the same C sources goose-treesitter vendors at
   `59313e9da0b9`, so the trees are the Goose program's.
2. Compare trees first (each grammar's snippets), then carry `syntax`,
   `structural`, `stamp` and the code stamps of `change`.
3. Its own branch and pull request from main, as each stage is.
Rebuild the Goose program from the branch first (`scripts/build.sh`;
Spread-Wings needs libcurl's headers) and pass it as `SWAN_OLD=bin/swan`.

## Decisions waiting on the owner
- Merging #74 (the Now in Android fix, convention plugins, in the Goose
  program) and then #75 (stage 2, stacked on #74; its base becomes `main`
  once #74 is in). Both were opened on the owner's word; the microVM suite
  has not run on either.
- "Ask drex max when unsure" (the owner, 2026-11-20): no drex model or
  service token reached the cloud session, so nothing was asked. Questions
  for it: none came up for `cargo-projects`; the port is line by line.
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

## Held for after the port
The owner's direction of 2026-11-20 (DECISIONS.md): Spread-Wings in Swan,
a file watcher such as `notify`, hidden files and git-ignored folders left
out for privacy, and one report of every area left out and why; serena-rs
as a reference at stage 5. docs/rust-port.md, "Held for after the port".

## Do not
- Change `src/*.goose` on this branch except to fix a bug found by the port
  (and then as its own change on main first).
- Redesign while carrying over. Note the idea in `docs/rust-port.md`.
- Edit `scripts/port-store.sh` in place while it runs (bash reads a script
  as it goes). Write the new one beside it and `mv` it over.
- Take an IDE's "no problems" for a pass before it has resolved a call
  across two files: an IDE that has not loaded the project answers the same.
