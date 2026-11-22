# Handoff: Swan in Rust (branch `rust-stage-4`)

Written 2026-11-20T07:25Z; stage 2 part rewritten 2026-11-20T16:21Z, stage 3 part 2026-11-20T23:51Z and again 2026-11-22T06:15Z, when stage 3 was finished; stage 4 part 2026-11-22T06:50Z, 2026-11-22T07:26Z 2026-11-22T16:46Z and 2026-11-22T18:18Z, when the prover had run on TypeScript's chunks and Python's pieces were carried. For the next session, any agent. **Start at "Next action".**

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
| Stage 4, the map | Under way on branch `rust-stage-4` (from main, pushed): `scip-python-patch`, `scip-typescript-patch`, `trust` and `doctor` carried, with what runs a step and reads JSON; of `swan map`, its opening, its content stamps, all of TypeScript and Python's pieces (src/pipeline.goose to line 1920), planned and not run. The Rust map then stops with exit 70. The prover has run on everything but Python's pieces, which have no breaks yet (below). Left: the rest of the map |
| Stages 5 to 8 | Not started. Every command of theirs exits 70 and names its stage |

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
SWAN_OLD=bin/swan scripts/port-map.sh                                # stage 4: 395 of 395 in the carried part; 5 min the first time, under a minute after
SWAN_OLD=$PWD/bin/swan scripts/port-prove-map.py                     # stage 4: 370 of 370 breaks caught (an hour on 32 cores, six parts side by side); none yet for Python's pieces
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

### First: the owner's answer on the prover
On 2026-11-22 the owner asked why a prover is used, why Jev does not look
for what is wrong instead, and said the work is going into Python scripts
and not into moving Swan to Rust. He was told: the judge (a byte
comparison of the two programs) is what finds where the Rust program is
wrong; the prover tests the judge, on AGENTS.md rule 4; Jev reads a
summary an agent writes and cannot find a byte that differs (asked that
day, it put 0.11 on a model as the judge). The agent recommended keeping
the byte comparison, carrying the rest of the map with cases and no new
breaks, and running the prover once at the end of the stage, since a map
made end to end can be compared whole on real repos. That loosens rule 4
for the port, so it is his word to give. He had not answered when this was
written.

So, as the tree stands:

| | |
|---|---|
| TypeScript's chunks and layers | Proven: the prover ran on the tree of `7fc1276`, 370 of 371 caught, and the one let through (306) was no break. 370 of 370 |
| Python's pieces (`rust/src/pipeline.rs`, to src/pipeline.goose line 1920) | Carried. `scripts/port-map.sh`: 395 of 395, 78 cases new |
| `scripts/port-prove-map.py` for Python's pieces | No breaks written. The 370 there are fit the source (`--fit`) |

If he says the prover stays as it was: write a break for each rule of
Python's part (the cases are grouped in `scripts/port-map.sh` under
"Python:"; STATUS.md, 2026-11-22T18:18Z, lists what each group is for), run the new
ones by number in six parts, read each miss, and record it. If he says
once at the end of the stage: go on carrying, add cases as before, and
write DECISIONS.md's entry with his words. Either way, do not say Python's
cases are proven until a prover has run on them.

### Then
- A mend to what is on main, as its own branch from main and its own pull
  request (docs/rust-port.md, "Next" and "Found while porting"): the
  statements of stages 1 to 3 written over several lines end with a line
  end Goose's texts do not have, so a statement SQLite cannot prepare is
  said with one empty line more. It needs a comparison of both programs
  on a map lacking each table in turn, seen failing first. Ask the owner
  before opening its pull request; he has not been asked.
- The next part of the map: Rust, src/pipeline.goose lines 1922 to 2003.
  Most of what it calls is carried already in `rustproj.rs`
  (`cargo_manifest_dirs`, `rust_projects`, `rust_toolchain_dir`,
  `rust_std_source`, `rust_toolchain_override`, `rust_analyzer_config`,
  `cargo_inside`, `toolchain_home`) and in `pipeline.rs`
  (`lang_fingerprint`, `Jobs::add_lang`, `child_env`). Still to carry
  for it: `skipped` (the indexers that wait for trust, said later by
  `untrusted_note`), `add_toolchain_env`, and the removal of
  `index-rust*.scip` from a map of a repo that is not trusted and not
  sealed. It writes `rust-analyzer-<hash>.json` into the map folder
  (`WRITTEN` cannot name it ahead: compare it the way the chunks' configs
  are, wherever either program has one).
- After Rust, in the map's own order: Java (from line 2004), C#, C and
  CUDA, "not run:" (`untrusted_note`), the language servers' child,
  `syntax-index`, "no language found to index" (exit 1); running the
  jobs; the flattener; `index` or `refresh`; the end of the report, where
  `index-manifest.tsv` and content-stamps.tsv are written and
  `finish_cosmetic` moves rows (`shift_cosmetic` of src/change.goose and
  `mark_edited` of src/edit.goose are needed there, though the stage
  table has them at stage 6). Where the indexers' runs are read, a failed
  Python piece is taken out of `python-pieces.tsv`, and at the end every
  `index-*.scip` no job names is removed: the judge steps around both
  today (`LATER` on three cases, a stale file that is no `.scip`); take
  those steps out when the parts are carried.

### Where stage 4 stands
Stage 3 is on main (#78). `rust-stage-4` was begun on `rust-stage-3` and
has main merged in since (`7e0647a`): main's tree was the tip it stood on,
so the merge keeps this branch's tree as it was. No pull request is open
for stage 4; the owner asks for it.

Done in stage 4 (docs/rust-port.md, "Next", has the order): the two indexer
patches; running a step, with `trust` and `doctor`; reading JSON; Goose's
sort; and a map to the end of Python (src/pipeline.goose line 1920:
the opening, the stamps, cosmetic edits found, files to index again, the
repo's tsconfig or Swan's own, the indexer's patch, tsc's files and roots,
which config owns each file, the chunks, what they share, which indexes
are kept, the layers; scip-python's two fixes, a virtualenv read or run,
the pieces and which are kept). `rust/src/pipeline.rs` ends there with
what the map has said so far and exit 70. The jobs are in a list (`Jobs`) that nothing
runs yet.

### How the map is carried and judged, a part at a time
- Carry the next part of `map_main_locked`, move the place the Rust map
  stops, and add to `scripts/port-map.sh` the lines of the report that
  part writes (`OPENING`), the steps it accounts for on standard error
  (`STEPS`) and the files it writes (`WRITTEN`, or `CACHED` for what a
  clean map holds back). The judge wants exactly those lines and steps,
  no more and no fewer. The closures of src/pipeline.goose lines 961 to
  1266 still to carry are `note_indexed`, `kept_texts` and
  `finish_cosmetic`.
- Give each rule of the part a case only it gets right, then
  `scripts/port-prove-map.py` with a break for each. Run it as six parts
  side by side, each with `PORT_MAP_JOBS=4 PORT_PROVE_JUDGES=2
  CARGO_BUILD_JOBS=6 SWAN_OLD=$PWD/bin/swan scripts/port-prove-map.py
  $(seq 1 62)`, `$(seq 63 124)` and so on to 371. More judges at once than
  that and the machine is swamped. A part prints its verdicts only at its
  end, after building every copy. The working agent's own helper
  `swan-prove-parts map 6 [first last]`, where it is installed, starts the
  parts and prints one summary.
- Stopping a prover: its builds and judges are children of children. To
  kill what is left by name, write the pattern so that it does not match
  the shell that runs it (`pkill -f '[p]ort-prove-map\.py'`); a plain
  pattern kills that shell first. Then remove its folders (`port-prove-*`
  in the temporary folder, 5 GB for six parts) and `build/port-map/run.*`.
- The judge keeps the Goose program's side in `build/port-map/<hash>/`.
  The hash is of the Goose program and of the functions that make the
  repos and the homes (`make_repos`, `make_before`, `home_of`,
  `home_as_installed`): change one and the Goose program maps every case
  again, 4.5 minutes, the 23 maps of `make_before` among them. Each case
  also has a signature (its repo, its settings, the `prep_` and `home_`
  functions there are when it is reached), so a new case, or a change to
  how the judge compares, maps nothing again. Add `prep_` functions after
  the cases that are already there, or those cases are mapped again; name
  a helper that fills a map folder `prep_...` so that changing it counts.
  Made-up repos and homes must stay in `build/` and not in /tmp: the seal
  gives a step its own /tmp.
- Cases run side by side (`PORT_MAP_JOBS`, 8), each Rust run from a home
  of its own under `build/port-map/run.*/c/<case>/`; `PORT_MAP_KEEP=1`
  leaves those folders to look at. A home is links to the checkout's
  `tools/`, with files of its own for what a map writes (so far the
  TypeScript indexer's `FileIndexer.js` and its mark) and for what a case
  swaps (`tsc`). Never write through one of the links, and never `chmod
  -R` a home: the links are to the checkout's own files. scip-python's
  package is in a home as hard links to its files and links to its
  folders, with the two files a map patches and their two marks as the
  home's own; `HOME_PREP=home_py_plain` and the like set how they stand.
- `HOME_PREP="home_tsc <name>"` gives a case a made-up tsc that says what
  `repos/tsc/<name>/` holds; `HOME_PREP=home_plain` and the like set how
  the indexer's patch stands. After each case the judge also compares how
  the indexer was left. `CACHED` files are compared except for a clean
  map, which must not have written them yet. `LATER_TEXTS=<n>` on a case
  says how many texts the Goose program keeps that only a later part
  writes (no case needs it today).
- A second map. `PREP=<function>` fills the map folder first, from a map
  the Goose program made: `prep_copy <from> <to>` copies one and moves its
  records of where its indexes are (`index-manifest.tsv` and
  `python-pieces.tsv` hold whole paths; without that no index is ever
  "reused"). Python's repos that change after a first map are in
  `BEFORE_PY`, mapped with `SWAN_JOBS=6`; give a case of pieces that
  setting too, since without it the count follows the memory free at the
  time. `ALSO="<files>"` on a case names more files of the map folder to
  compare, `LATER="<files>"` those a later part writes over (not
  compared). `pkg` and `pyf` make a package in a site-packages folder
  and a Python file of an exact size; both count in the hash. A repo that is changed
  after its first map is in `BEFORE` (mapped as it is), `BEFORE_TWO`
  (with `SWAN_JOBS=2`: two chunks) or `BEFORE_FOUR` (four: the projects),
  and changed at the end of `make_before`; `prep_before` copies the map
  of the repo the case is named for. `prep_same`, `prep_edit`, `prep_lone`
  and `prep_chp` copy four of them for cases that then alter one thing:
  `prep_plan <folder> <command>` rewrites the kept plan, `prep_layers
  <folder> <id> <files>...` says the folder has layers.
- What the judge cannot compare, and says so in a comment where it skips
  it: with Swan's own config at the root, `typescript-shared.txt` holds a
  fingerprint that takes in the map folder's path, so only that both
  programs keep one. When both programs end the same way the whole map
  folder is compared, `index-manifest.tsv` with each program's folder
  taken out.

Settle before the jobs are run:
- **The children.** A map starts its own program again as `syntax-index`
  (carried) and `lsp-index` (stage 5, not carried: Go, Goose and the other
  languages a server indexes). Until stage 5 the Rust map can be compared
  only on repos with none of those languages, or it has to start the Goose
  program for that one child. The agent proposed the second to the owner
  on 2026-11-22 and he said "continue" without choosing; Jev leaned the
  same way, weakly (59 to 40). Say which in docs/rust-port.md before
  building on it.
- **Left out until the part that reads them**: two things
  `detect` notes (Maven and Gradle files at the top of the repo), and what
  is worked out and not yet read: the jobs' list, the new record of
  indexes and whether every index was kept (`jobs.list`,
  `jobs.index_manifest`, `jobs.reused_all`, named in one `let _` where the
  Rust map stops), and what a clean map holds back (`Cache::pending`).
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
- The mend to stages 1 to 3 (an empty line more when a statement cannot
  be prepared; "Next action", "Then"): do it now on its own branch, or
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
