# Swan in Rust: the bar, the stages, the log

Started 2026-11-19 on branch `rust`, on the owner's word ("for swan lets see
if we can turn it to rust ... it will be a complete overhaul"). Spread-Wings
was carried over the same way on 2026-11-18 (its `docs/rust-port.md`); this
follows that method.

The Goose program in `src/` is the one that ships until the owner says
otherwise. `rust/` is the port. Stages 0 and 1 were merged into main on
2026-11-20, on the owner's word, as files beside the Goose program:
`scripts/build.sh` does not build the Rust program, and nothing installs or
ships it. Each later stage is its own branch and pull request.

## What is carried over

| Part | Lines | What it is |
|---|---|---|
| `src/*.goose` | 11,621 | Swan itself, 31 files |
| `lsp/golsp.goose` | 889 | the language-server client (the `lsp/` submodule) |
| `native/swan_sys.c`, `lsp/native/proc.c`, `lsp/native/glue.c` | 664 | files, processes and the door to the client |
| `native/swan-flatten` | 2,249 | already Rust; joins the same cargo workspace |

About 13,200 lines to carry, not counting what is already Rust.

Not carried in the first pass: the check suites (`tests/check/*.goose`,
4,264 lines) and the Python tests. They drive `bin/swan` from outside, so
they are the judge of the port and stay as they are until it passes them.
The Python scripts (`scripts/install.py`, `package.py`, `doctor.py`) stay
Python.

## The bar, written before any Rust

The port is done when all of these hold, and each is reported with its
number:

1. **The same map.** `swan map` with the Rust program writes the rows the
   Goose program writes, compared by hash of every table in a fixed order,
   on the fixtures and on the four trial repos kept outside this repository
   (relate, Understand-Anything, rea, Agent-Reach) and cobra.
2. **The same answers.** Every `swan query` kind, and every MCP tool through
   `swan serve`, gives the same bytes on those maps.
3. **The same checks.** The full suite in the microVM with only the Rust
   program in `bin/`: the counts the Goose program gets (58 + 302 checks and
   56 Python tests when this was written; the baseline is taken again
   before the comparison).
4. **The same or better cost.** Time and peak memory for `map`, a reused
   `map`, a `query` and a `serve` answer, medians, both programs turn about
   on one machine.
5. **Either program reads the other's map.** The schema version and the
   reuse fingerprints are the same numbers, so an installed map is not
   redone because the program changed language.
6. **What differs is written down.** Error wording, and anything else found.

A stage that does not meet its own comparison is not built on.

## Rules for the port

- Carried over line by line, not redesigned. A better design is a separate
  change after the port passes, with its own measurement.
- Text is bytes (`&[u8]`), as in Spread-Wings: a source file need not be
  UTF-8.
- SQL and fixed text keep the comment that stood above them in the Goose
  source.
- Crate versions are pinned exactly where the output depends on them:
  SQLite, the tree-sitter runtime and each grammar. They must be the
  versions goose-sqlite and goose-treesitter build, or the trees and the
  query plans can differ.
- Third-party repos stay sealed. No `swan trust`, `SWAN_TRUST_BUILD=1` or
  `SWAN_SANDBOX=0` on someone else's repo to make a comparison easier.
- Suites run in the microVM, not on this machine.

## Stages

Each stage ends with the comparison named in its last column, on the Goose
build and the Rust build of the same commit.

| # | Stage | Goose sources | Lines | Compared by |
|---|---|---|---|---|
| 0 | Skeleton: commands, usage text, exit codes, the compare script | `swan.goose` | 248 | usage and exit code for every wrong call |
| 1 | The store: reading flattened SCIP into a map, refresh, questions | `swan_sys.c`, `db`, `scip`, `index`, `fresh`, `graph`, `query`, `writer` | 2,110 | `index`, `refresh`: table hashes. `query`: bytes, 13 of the 14 kinds (`pattern` reads source with tree-sitter: stage 3). Done 2026-11-20: `scripts/port-store.sh` |
| 2 | Planning that runs nothing | `rustproj`, `gradle`, `pyplan` (and the toolchain helpers of `seal` that `rustproj` uses) | 934 | `cargo-projects`, `gradle-tasks`, `plan-python`: bytes. Done 2026-11-20: `scripts/port-plan.sh`. `stamp`, `tsproj`, `survey` and `modules` moved to the stage of their first user (2026-11-20, "Found while porting") |
| 3 | Syntax | `syntax`, `structural`, `stamp` and the code stamps of `change` (`cosmetic_lang`, `code_hash`); goose-treesitter's `treesitter.goose` (the matcher), with its `ts_shim.c`, the runtime and the grammars built as they are | 1,080 + 237 + some of 280 + 750 | the trees (`scripts/port-trees.sh`); `syntax-index` rows; `query pattern` bytes; `stamp-bench`'s stamps.tsv and `stamp-worker` |
| 4 | The map | `seal`, `run`, `pipeline`, `pypatch`, `tspatch`, `scip`, `wings`, `tsproj`, `survey` | 3,681 + 387 | `swan map`: table hashes, the report, "reused" on the second run |
| 5 | Language servers | `golsp.goose`, `proc.c`, `glue.c`, `lspindex`, `live` | 1,815 | `lsp-index` SCIP output; `lsp-ask` answers |
| 6 | Checking and editing | `checkers`, `diag`, `broke`, `change`, `edit`, `modules` | 1,549 + 449 | `check`, `broke`, `format`, `test`, `diagnostics`: reports and rows |
| 7 | The server | `serve` | 890 | every MCP tool's answer; the `mcp` suite |
| 8 | Build and suite | `scripts/build.sh`, `space-test.sh`, `swan-flatten` into the workspace | | the full suite in the microVM; the cost table |

After stage 8 the owner decides, with the numbers, whether Rust becomes
what is built. Retiring the Goose sources is a change of its own.

## Known before starting

- `wings/` is pinned to a Spread-Wings commit from before its Rust port, and
  `scripts/build.sh` builds it with Goose. Moving the pin to Spread-Wings'
  Rust main is its own change (named as not done in Spread-Wings' STATUS).
- `cargo` is not on this machine's PATH in a plain shell; it is at
  `~/.cargo/bin/cargo`, which is where `scripts/build.sh` already looks.
- Errors will read differently: no `goose runtime error:` before a message
  and no source line after. Whatever reads those needs a look at stage 8.

## How a stage is judged

`scripts/port-compare.sh <swan arguments>` runs one command with both
programs and compares output, error text and exit code. Three things are
taken out first, because they differ by design: the Goose runtime's wrapper
around an error (the message inside it is compared), the time a command says
it took, and the name of each program's own work folder.

`scripts/port-store.sh <flattened-dir> [repo]` is stage 1's judge (with
`PORT_SLOW=<ms>` it also says how long each kind of question took in each
program, and lists the questions over that), and
`scripts/port-tables.sh <swan.db>` the table hash it uses (stage 4 will use
it too): the schema as SQLite stores it, and every table's rows in rowid
order with the rowid. Only the two meta rows that are the time of writing
are left out.

A judge is trusted once it has been seen to fail.
`scripts/port-prove.py <flattened-dir> <repo>` builds nine copies of the
Rust program, each broken in one place on purpose (the list is at its
head), runs `port-store.sh` against each and says which step caught it. A
step added to the judge gets a break added there.

## What differs, and is meant to

- **The wrapper around an error.** Goose: `goose runtime error: <message>
  (<file>.goose:<line>)`. Rust: `<message>`. The exit code is 1 in both.
  The messages themselves are the same words, compared for 12 refusals.
- **A row with too few fields.** Goose stops at its own bounds check
  (`index 6 out of bounds (length 5)`); Rust says `swan index: a row with
  too few fields: '<row>'`. Exit 1 in both, and nothing is written.
- **A file name with a line end in it** would be read as two names by the
  Goose program's walk of a repo (its folder listing is lines). Rust reads
  it as one. Not met in any repo tried.
- **How SQLite is built.** The same release (3.54.1, the same source id) in
  both. goose-sqlite builds it for one thread, with no allocation counts,
  no `file:` paths and no double-quoted strings; the Rust crate builds it
  the other way in all four, and the Rust program sets the four back when
  it opens a database (`rust/src/db.rs`). Left as the crate has them,
  because nothing Swan does reaches them: full-text search, R-trees and the
  other built-in extras; `STAT4` (Swan never runs `ANALYZE`); foreign keys
  on by default (the schema has none).
- **`swan query <db> pattern`** exits 70 from the Rust program until
  stage 3.

## Speed: what was measured, and what waits

`swan index` on relate, step by step, in the Rust program (2026-11-20):
reading the rows 19 ms, fingerprints 102 ms, symbols and extents 99 ms,
occurrences 371 ms (163 ms of it SQLite taking the rows, 52 ms finding the
symbol each reference sits in), updating symbols 48 ms, and **452 ms, 40%,
building the nine indexes at the end**. About 70% of the whole is SQLite's
own work on one connection.

Taken: `memchr` for finding tabs and line ends (one thread, the same
bytes): 9% off relate, 6% off rea.

Tried in scratch copies, the same tables written, and waiting for the
owner's word and for stage 8 (DECISIONS.md, 2026-11-20, has the table and
the reasons):

- `rayon` for hashing the rows and reading occurrences on every processor:
  a further 14% off relate and 6% off rea, for 16 MB and 9 MB more memory
  than the Goose program uses.
- SQLite's own sort threads for the nine indexes (`PRAGMA threads`, with
  its sorts on disk in 8 MB runs): a further 6% off relate and 14% off rea,
  and less memory. The map file comes out byte for byte the same. It needs
  temporary files on disk, where Swan asks SQLite for memory today.

Looked at and not taken, with reasons in the same entry: crossbeam,
rusqlite, salsa, petgraph.

Not tried: skipping the lookup of each new symbol when the map is new (the
map cannot hold it yet). On rea that lookup and insert is 788 ms of 3.6 s.

## Slow questions in the program that ships

Found 2026-11-20 with the judge, not caused by the port: the SQL is the
Goose program's, and the Rust program runs the same SQL. A change of its
own, on main first; the Rust side then carries the same statements.

Milliseconds a question took in the Goose program, median and longest, of
about 160 questions of each kind (`PORT_SLOW=300 PORT_JOBS=8`):

| Kind | Understand-Anything (11 thousand symbols) | relate (60 thousand) | rea (438 thousand) |
|---|---|---|---|
| `uses` | 59, longest 1,901 | 313, longest 14,680 | 2,400, longest 87,902 |
| `diag` | 97, longest 121 | 184, longest 208 | 4,487, longest 7,537 |
| `callers` | 4, longest 6 | 21, longest 28 | 221, longest 356 |
| `overview` | 2, longest 5 | 7, longest 11 | 47, longest 54 |
| `hierarchy` | 2, longest 4 | 6, longest 8 | 35, longest 62 |
| `impls` | 1, longest 2 | 3, longest 8 | 18, longest 43 |
| every other kind | 1 to 2 | 1 to 8 | 1 to 20 |

Each of these reads every symbol in the map to answer about one. SQLite's
plan says where (`EXPLAIN QUERY PLAN`, a `SCAN` of `symbols`):

1. **`uses`**: the members of a symbol are found by comparing the start of
   every symbol's name (`substr(s.scip, 1, length(t.scip)) = t.scip`, and
   the two `impl#[` forms). Asked as a range on the `symbols_scip` index
   (`s.scip >= X AND s.scip < X || char(1114111)`, the comparison kept
   after it), the statement goes from 1.9 s to 0.5 ms on rea. A name twenty
   symbols share runs the statement twenty times: that is the 88 s.
2. **`diag`** on a symbol: the join that takes in what a symbol holds has
   an either-or condition (a module, or a body inside the caller's body),
   and SQLite answers it from the wrong end: every symbol, then its whole
   file. Written as two joins that start from the walk, 5.1 s to 0.4 ms.
3. **`callers`**, twice. The methods a method implements are listed in name
   order, and SQLite walks every symbol in that order to find the handful
   (225 ms to 1.2 ms on rea, with the join pinned to start from the handful
   and `s.id` added to the order to keep ties as they are). The walk up is
   grouped by symbol and read from the symbols' end (30 ms to 11 ms).
4. **`impls` and `hierarchy`**: the same grouping (20 ms to 1.7 ms).
5. **`overview`, `unused` and `diagfile` of a folder, and `symbol` by part
   of a path**: `LIKE` on a path or a name path. No index serves it as
   written (43 to 53 ms each on rea).

For 1 to 4 the rewritten statement was run beside the old one in `sqlite3`
on relate and rea: the same rows in the same order for `uses` on 372
symbols (13,204 rows), `diag` on 156, the walk up on 112 (119,853 rows),
the implemented methods on 125, and the hierarchy on 123 each way. Those
are plan mistakes, and mending them changes no answer.

5 is different. `LIKE` matches without regard to case and treats `_` and
`%` in the folder's name as wild, so `overview my_dir` also takes a folder
named `myXdir`, and `src` takes `SRC`. A range on the index would be exact
instead: faster, and a different answer in those corners. The owner's call.

The owner's jevgrep (`jg "question" src`, which reads source and names the
files that bear on a question) was asked the same of `src/`. In 12 s it
named seven of the eight files a plain search finds these shapes in, and
three that have none; for Goose it gives locations, not excerpts. It reads
code and cannot see a time or a plan, so it says where to look, and the
timed judge and the plans say what is slow. Its leads past `query`, `graph`
and `diag` were followed with plans on rea: test selection (`run_tests`)
starts from the walk and takes 0.1 ms; rename's two family walks use their
indexes; rename's list of the family in name order has the `callers` shape
(every name path read to find a handful) and takes 9 ms.

Not looked at: the statements behind checking and the server's own tools
(stages 6 and 7), and the rest of editing.

## Held for after the port

The port carries Swan over as it is; a better design is its own change once
the port passes, with its own measurement (rules above). These are written
down so they are not lost.

### serena-rs, a Rust rewrite of Serena (noted 2026-11-20T16:33Z)

[flobsx/serena-rs](https://github.com/flobsx/serena-rs), published as the
crate `serena-rs` (0.1.7, 2026-10; young: no stars, 32 downloads when
noted). Serena's tools in one Rust binary, answered by asking a live
language server each time: definition, references, rename, hover,
completion, code actions, diagnostics, formatting. Its README names
`tower-lsp` for the client and `rmcp` for the MCP server. Smaller trials of
the same name: GeorgePearse/serena-rs (2025), cp-yu/serena-rs-cli.

How it differs from Swan: Swan answers from a map built ahead of time by
compiler-grade indexers and stored in SQLite (milliseconds, and the
questions a map makes cheap: callers, impact, tests, unused code,
implementations, pattern search), uses live servers only for errors now,
and seals a repo so its code does not run unasked. Its README says nothing
about sealing.

Use: a reference at stage 5, when the language-server client
(`lsp/golsp.goose`) is carried, to see which Rust libraries it uses and how.
Read on 2026-11-20: its crates.io entry (0.1.7) says MIT, while its
repository has no LICENSE file and its Cargo.toml names none, so anything
borrowed keeps its copyright notice and the source is named. Its client
(`crates/serena-lsp`) is built on `lsp-types` 0.95, `lsp-server` 0.7 and
`tokio`: crates the port could use itself, whatever is taken from
serena-rs.

### The owner's direction for after the port (noted 2026-11-20T16:33Z)

In the owner's words, shortened: adopt serena-rs's methods where they make
Swan behave better, so the code base "literally talks to you" and can be
searched; Spread-Wings incorporated into Swan; a file watcher such as the
`notify` crate, so Spread-Wings keeps up the way Graphify does; index
everything except hidden files and what git ignores, to keep people's
information private; and spell out the areas left untouched because of
Swan's own rules, unless the owner trusts the repo to run.

What is already there, so the change starts from facts:
- The walk leaves out hidden folders and the folders git ignores
  (`rust/src/walk.rs`, from `src/pipeline.goose`). Hidden files are not
  left out today: only folders are checked for a leading dot, so a `.env`
  at the top of a repo is walked (whether anything reads it then depends
  on its language).
- Spread-Wings ships inside Swan (`wings/`, pinned) and has `watch`
  (inotify, one watch a folder, a look every 30 s as well;
  `wings/docs/DESIGN.md`). It is Linux only; without events it looks every
  two seconds. `notify` would bring macOS and Windows events.
- Some areas left out are named already: Rust projects past the limit
  ("not mapped"), crates with no rows (`rust_unmapped`), a repo's build
  code not run until `swan trust` (sealing).

What would be new: one report of every area left out and why (hidden,
git-ignored, sealed and untrusted, past a limit, no indexer), the watcher
keeping Swan's own map current, and hidden files left out as hidden
folders are.

## Log

| When (UTC) | What |
|---|---|
| 2026-11-20T05:55Z | Branch `rust` from main `fb8df2a`. This file. |
| 2026-11-20T05:58Z | Stage 0. `rust/` builds with cargo 1.100.0 into `build/rust/` (451 KB, no crates yet). `scripts/port-compare.sh --wrong-calls`: 47 of 47 answered the same as the installed Goose build `fb8df2a4c199` (usage text and exit 2). Every command of the right shape exits 70, "not carried over yet", with its stage. |
| 2026-11-20T07:33Z | Stage 1, the store. `rust/src/`: `db`, `sys`, `scip`, `index`, `fresh`, `walk`, `query`, `graph`, `diag` (the question; loading is stage 6) and `util`. `libsqlite3-sys` 0.40.0 bundles SQLite 3.54.1 with the source id goose-sqlite's copy has. `scripts/port-store.sh`, rows from maps the Goose build `fb8df2a4c199` wrote, on Agent-Reach, Understand-Anything, relate, rea, the 20 fixtures and cobra: tables the same at 150 of 150 points, 350 of 350 refusals the same, 22,255 of 22,255 questions answered the same. `--wrong-calls` 47 of 47. 5 unit tests. |
| 2026-11-20T07:33Z | The judge seen failing: `scripts/port-prove.py` on Agent-Reach, 9 of 9 breaks caught. |
| 2026-11-20T07:33Z | Cost (STATUS.md has the table): `index` 947 ms against the Goose program's 1,054 on relate and 3,264 against 3,830 on rea, with less memory in both; an unchanged `refresh` 156 ms against 240; questions the same to the millisecond. |
| 2026-11-20T08:00Z | The judge times every question (`PORT_SLOW`). On Understand-Anything, relate and rea it found two kinds over 300 ms (`uses`, `diag`), and the plans three more that read every symbol (`callers`, `impls` and `hierarchy`, and the folder and path kinds). Rewrites for the first four were run beside the old statements: the same rows in the same order. Section above. |
| 2026-11-20T09:43Z | Stages 0 and 1 go into main on the owner's word (asked which merge he meant, he chose "Rust branch into main"). The full suite ran in the microVM on the commit that merges; its counts are in the pull request. |
| 2026-11-20T16:20Z | Stage 2 begun, one command at a time. `cargo-projects` carried: `rust/src/rustproj.rs` (src/rustproj.goose, with the five toolchain helpers it uses from src/seal.goose), and in `sys.rs` `env`, `write_stderr`, `realpath` and `run_capture` (only `rustup show home`; the full `swan_run` is stage 4). The Goose program judged is `bin/swan` built from main `8d3417a` in a cloud container (no trial repos there). `scripts/port-plan.sh`: 93 of 93 the same, on the 20 fixtures, four made-up repos, a missing repo, and relate, tokio, ripgrep, cargo (660 manifests, 366 lines out), bevy and cobra, each with RUSTUP_HOME unset, made up and missing. `--wrong-calls` 47 of 47. |
| 2026-11-20T16:20Z | The judge seen failing: `scripts/port-prove-plan.py`, 11 of 11 breaks caught. The first judge caught 4 of 11; the made-up repos were widened until every break was caught (below). |
| 2026-11-20T16:41Z | `gradle-tasks` carried: `rust/src/gradle.rs` (src/gradle.goose), sharing `scip::is_ident`. `scripts/port-plan.sh` now judges it on every repo, each case of fixtures/gradle-android and 31 made-up Gradle repos: 181 of 181 the same, with relate, tokio, ripgrep, cargo, bevy, cobra, nowinandroid, architecture-samples, okhttp and RxJava. `scripts/port-prove-plan.py`: 36 of 36 breaks caught (the first run 36 of 37; the one missed cannot change any answer, below). |
| 2026-11-20T19:40Z | Fix, not the port's: Android through convention plugins (Now in Android). In `src/gradle.goose` first, then `rust/src/gradle.rs`; from here the Goose program judged is the fixed one. `scripts/port-plan.sh` 201 of 201 with 14 more made-up repos; `scripts/port-prove-plan.py` 56 of 56 (two breaks of before re-anchored, their text now in two places). |
| 2026-11-20T20:19Z | Stage 2 done. `plan-python` carried: `rust/src/pyplan.rs` (src/pyplan.goose). `scripts/port-plan.sh` with 21 made-up Python repos, each at six values of k: 577 of 577 the same, with the 14 public repos (requests, flask, pytest and django among them; django 2,943 .py files, 239 pieces, 22 to 28 ms in both). `scripts/port-prove-plan.py`: 76 of 76. `stamp`, `tsproj`, `survey` and `modules` moved to stages 3, 4 and 6 (stage table). |
| 2026-11-20T21:10Z | Stage 3 begun (branch `rust-stage-3`, on #75). Tree-sitter in Rust: `rust/build.rs` builds goose-treesitter's own C (its `ts_shim.c`, the runtime 0.25.10 and 17 grammars) from the Goose build's copy at the commit `src/swan.goose` imports, with the lists of that package's `treesitter.build`; `rust/src/treesitter.rs` calls the shim. `scripts/port-trees.sh` (dumpers `scripts/port-trees.goose` and `rust/src/bin/port-trees.rs`): 25,300 of 25,300 files the same tree, 46 million nodes, every grammar. Seen failing: a `.h` file taken for C++, and a column one too far in a changed shim, each caught. |
| 2026-11-20T23:53Z | `query pattern` carried: `rust/src/treesitter.rs` (goose-treesitter's matcher) and `rust/src/structural.rs` (src/structural.goose). `scripts/port-pattern.sh`: 182 of 182 on a made-up repo in all 17 languages, 1630 of 1630 with eight maps (swan-rust, django, laravel, godot-demo-projects, wgpu, ripgrep, shadcn-ui, flask). `scripts/port-prove-pattern.py`: 33 of 33 breaks caught, after the first judge caught 23 of 34 (below). About as fast as the Goose program (STATUS.md). |

## Found while porting

- Stage 0: `swan query <db> <kind> <arg>` opens the map before it looks at
  the kind, so a missing map is reported (exit 1) before an unknown kind
  (usage, exit 2). Kept in that order.
- Stage 0: the message for a missing map differs as expected. Goose:
  `goose runtime error: swan: no index at <path> (src/swan.goose:66)`.
  Rust: `swan: no index at <path>`. The exit code is 1 in both.
- Stage 1: the order of the `files` table is the order Goose's dictionary
  walks its slots, which is no order a reader would guess. The Rust program
  keeps a copy of that dictionary (`Dict` in `rust/src/util.rs`) for that
  one table, so the rows land in the same order and the table hash can
  include the rowid.
- Stage 1: SQLite keeps each `CREATE` statement's text in the map, spaces
  and comments included, so the schema text is carried byte for byte.
- Stage 1: the fingerprint of a file's rows is made of Goose's `hash` and
  `hash_combine`. Carried step for step (and tested against numbers a
  Goose program printed), so a map written by either program is not redone
  by the other.
- Stage 1: the first judge passed two faults it should not have. It had no
  repo with a file edited, gone or added since the map, so nothing was ever
  stale; and it compared error text only by whether there was any. Found by
  breaking the Rust program on purpose: calling every edited file fresh,
  and walking hidden folders, both passed. The judge now makes such a repo
  and compares the words.
- Stage 1: a unit test written from a reading of the code expected
  `store.ts/Store/add` for a TypeScript method; the Goose program gives
  `Store/add` (the file is a namespace). The program was right and the test
  wrong. The test now holds ten symbols as Goose-written maps name them.
- Stage 1: RustRover, with Swan's folder open, does not load `rust/` as a
  Cargo project: it answers "no problems" for every file and knows no
  types. A copy of `rust/` opened as its own project loads. Its findings
  there: no errors, no warnings, three style notes left on purpose (Goose's
  hash kept in its two near-alike loops; a lifetime it would drop that the
  borrow needs).
- Stage 1, not the port's: some questions take seconds in the Goose
  program on a large map, and the Rust program takes the same time to the
  same answer. The judge was made to time every question
  (`PORT_SLOW=<ms> scripts/port-store.sh ...`), and every statement behind a
  question was asked for its plan. "Slow questions in the program that
  ships", below, has what that found.
- Stage 1: a refresh that changes nothing peaked 92 MB above the Goose
  program on relate (243 MB against 151), found by the cost table and not
  by any comparison: the rows file was read into one buffer and copied into
  another. Read straight into its place now: 146 MB.
- Stage 2: the first judge for `cargo-projects`, the fixtures and three
  made-up repos, passed 7 of 11 breaks. None of its repos had a crate named
  inside another word (`mypath = "..."`), a `..` that leaves the repo
  before coming back in, a crate under an excluded folder, a pinned
  toolchain newer than the default, a library path that needs JSON escapes,
  a quoted folder name in a comment, or a repo that does not exist. Each
  is a case in `scripts/port-plan.sh` now.
- Stage 2: `rustup show home`, asked when $RUSTUP_HOME and ~/.rustup hold
  no toolchains, is run by `run_capture`, which inherits the environment
  and waits 10 s as `swan_run` does. The rest of `swan_run` (environment
  entries, standard error, sealing) is carried with the map at stage 4.

- Stage 2: `is_ident` is one function for the whole Goose program
  (`src/scip.goose`), and it counts `+`, `-` and `$` as name characters.
  `src/gradle.goose` uses it too: Goose files share one namespace. The
  Rust side shares `scip::is_ident` rather than writing a plain letters
  and digits test, which would read a Groovy slash after `x-` or `$` as
  the start of a string where the Goose program reads division, and the
  reverse.
- Stage 2: one rule of `src/gradle.goose` has no effect any input can
  show: the version catalog's commented lines are skipped
  (`!starts_with(line, "#")`), but a commented key would keep its `#` in
  the alias it makes (`libs.plugins.#android.app`), and a build file
  cannot name such an alias (`#` is not a name character). Carried as it
  is. The break that drops it passed the judge (36 of 37 caught on the
  first run) and was taken out of `scripts/port-prove-plan.py`, since no
  judge could catch it.
- Stage 2, not the port's: Now in Android (android/nowinandroid) applies
  Android through convention plugins of its own (`alias(libs.plugins.
  nowinandroid.android.application)`; the Kotlin in its `build-logic`
  applies `com.android.application`). Swan read build files only, so both
  programs called it a plain JVM build and named `scipPrintDependencies`,
  which the comment in `src/gradle.goose` says dies on an Android build.
  Fixed on the owner's word the same day (DECISIONS.md), in the Goose
  program first and then carried: the repo's own build logic (buildSrc and
  each `includeBuild`) is read for precompiled script plugins and
  registered plugin classes, followed through plugins that apply other
  such plugins. From that commit on, the Goose program the port is judged
  against is the fixed one.

- Stage 2: four of its seven files had no command of the stage to judge
  them by, so they move to the stage of their first user (2026-11-20T19:43Z).
  `stamp` (`stamp-bench`, `stamp-worker`) stamps a file by its code with
  `code_hash` in `src/change.goose`, which parses with tree-sitter: a stamp
  is the same bytes only with the same tree-sitter runtime and grammars,
  which stage 3 pins. `tsproj` and `survey` are used only by the map (and
  `survey` by the server: it starts Spread-Wings); `modules` only by
  `check`, `format`, `test` and live errors. Carried without a judge, they
  would be Rust no comparison has seen.

- Stage 2: the judge had a hole of my making, found by its prover. The
  made-up Python repos were written in loops over `g`, the name that also
  held the made-up Gradle repos' folder, so after them no Gradle repo was
  judged and 37 Gradle breaks passed (a run said "the same: 381 of 381").
  The loops use another name; every count from then on is after it.
- Stage 2: two rules of `plan-python` were seen to matter only once a case
  was made for each: which of two equally big groups is split first (only
  when the 40-group room runs out between them: `tie`), and an empty file
  counting as one byte (only beside files that are not empty:
  `empty-mix`). One rule shows nothing any input can see, so it has no
  break: at the root, a folder of too many loose files gives "the whole
  repo in one run" both by its own return and by falling through, since
  nothing else is in the plan or the queue yet.

- Stage 3: tree-sitter comes from the very C the Goose program builds:
  `rust/build.rs` reads the goose-treesitter commit from the import line in
  `src/swan.goose` and its file and include lists from that package's
  `treesitter.build`, so the two cannot drift. The cost: until stage 8 the
  Rust build needs the Goose build to have fetched the package (into
  `.tools/goose-home`, or `SWAN_TREESITTER_SRC`). The provers (`scripts/port-prove.py`, `port-prove-plan.py`) build their
  copies of `rust/` beside a copy of `src/swan.goose` for that reason. Stage 8 decides how the
  Rust program gets these sources once Goose is not built (a submodule of
  goose-treesitter, or the C copied in).
- Stage 3: goose-treesitter's own `treesitter.goose` (the structural
  matcher behind `query pattern`, 750 lines) is Goose to carry too; it
  was not in the stage's list of sources.
- Stage 3: the first judge for `query pattern` caught 23 of 34 breaks.
  Its made-up strings held `$` only where the plain string rule already
  kept it, so the rules for Lua long brackets, C# verbatim strings,
  Python's and Kotlin's triple quotes and comments changed nothing it
  asked. Each now has a case only its own rule gets right: a quote or a
  backslash inside (`'''it's $X'''`, `@"a\"`, `# don't`). Also added: a
  trailing comma, an empty `$$$` before a comma, a C++ `if` only the
  function context finds, and `$X` alone (every node), asked of the
  made-up map only.
- Stage 3: one rule shows nothing any pattern can see, so it has no
  break. A GDScript pattern's further lines are indented into the function
  (context 7). The grammar at the pinned commit reads the same statements
  at the top of a file as inside a function, so a pattern that would parse
  there has already parsed bare. 22 texts parsed both ways had the same
  errors, and 10 multi-line patterns on godot-demo-projects gave the same
  bytes from the Goose program and a copy without the rule. Carried as it
  is.
- Stage 3: `fill_template` (the rewrite half of the matcher) is not used
  by `query pattern`. It goes with `rewrite_pattern`, in the server's
  stage.

## Next

Stage 3, syntax, on branch `rust-stage-3`. Done: the trees, and the
matcher with `swan query <db> pattern` (above). Left, in this order, each
judged against the Goose program and seen failing before it is trusted:
1. `src/syntax.goose`, behind `swan syntax-index` (its rows).
2. `src/stamp.goose` with `cosmetic_lang` and `code_hash` from
   `src/change.goose`, behind `stamp-bench` and `stamp-worker`; the
   workers as processes.
Rebuild the Goose program first (`scripts/build.sh`), which also fetches
the goose-treesitter copy `rust/build.rs` builds from.
