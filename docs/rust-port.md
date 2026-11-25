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

- Until 2026-11-23: carried over line by line, not redesigned. From
  2026-11-23, on the owner's word (DECISIONS.md): the Rust already written
  is kept; what is left is written in Rust with the Goose source as its
  reference and not copied line by line, and the language-server client and
  the MCP server are built on Rust libraries. Sealing is the exception and
  is still carried to the letter. A better design of what Swan does is
  still a separate change after the port passes, with its own measurement.
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
| 3 | Syntax | `syntax`, `structural`, `stamp` and the code stamps of `change` (`cosmetic_lang`, `code_hash`); goose-treesitter's `treesitter.goose` (the matcher), with its `ts_shim.c`, the runtime and the grammars built as they are | 1,080 + 237 + some of 280 + 750 | the trees (`scripts/port-trees.sh`); `syntax-index` rows; `query pattern` bytes; `stamp-bench`'s stamps.tsv and `stamp-worker`. Done 2026-11-22: `scripts/port-trees.sh`, `port-pattern.sh`, `port-syntax.sh` and `port-stamp.sh` |
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

### From 2026-11-23

The owner's decision of that day (DECISIONS.md) changes what judges the
port. In order of weight:

1. A JetBrains IDE through its MCP server on the trial repos, as in the
   comparisons STATUS.md records from when Swan was built: the measure of a
   right answer.
2. Swan's own suite in the microVM, with the Rust program in `bin/`.
3. The Goose program's rows as the floor: a map the Rust program makes has
   the rows the Goose program's map of the same repo has
   (`scripts/port-tables.sh`), on the made-up repos of
   `scripts/port-map.sh` and on the trial repos. A difference is explained
   or mended; fewer uses resolved by a compiler is never accepted.

The byte comparisons of stages 0 to 4 stay and are run as they are. No new
case is owed for the wording of a report line. The provers
(`scripts/port-prove*.py`) stay in the repository and are no longer run or
extended: the 123 cases added to `port-map.sh` on 2026-11-22 have no
breaks. Sealing is judged as before, byte for byte.

Later the same day (DECISIONS.md, 14:15Z) the owner dropped the third:
the Goose program is no longer matched. The comparisons stay and are not
extended; a difference one shows is a question to look at. What is built
from here is Swan's own, in the styles of JetBrains (a map built ahead by
the indexers that exist, asked in milliseconds) and Serena (symbol tools
answered by live language servers), with SolidLSP as the way a language
server is started, configured and waited for.

For three hours that day `SWAN_PORT_GOOSE` let the Rust `swan map` start the
Goose program for its `lsp-index` child. The Rust program has that command
now (STATUS.md, 2026-11-23T15:00Z) and the variable is gone.

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
- **How `syntax-index` finds a name's definitions.** The Goose program
  keeps them in a table keyed by a 64-bit hash of the language and the
  name; the Rust program in a table of names for each language. The index
  is the same unless two different keys share that hash.
- **A step's program, with an empty PATH.** `swan_run` then looks nowhere
  and names whatever error was left over from before (`swan trust` says
  `swan_run: cannot run mkdir: Invalid argument`); the Rust program says
  `No such file or directory`. Exit 127 in both, and the judge compares
  only that each says something.
- **A line of /proc/meminfo with no unit.** How many indexers run at once
  is held down by `MemAvailable:`, read up to the space before "kB". With
  no space there the Goose program stops (it cuts the line where no space
  is); the Rust program passes the line over and lets memory allow eight.
  The kernel always writes the unit.
- **Stamping on threads** (`SWAN_STAMP_MODE=threads`). The stamp lines come
  back in the order the workers finish, in both programs, so `stamps.tsv`
  holds the same lines in an order that changes from run to run. How many
  threads a machine allows is each runtime's own count (Goose's
  `hardware_threads()` is held down by its stack budget; Rust asks the
  system), so the report can name another number when more threads are
  asked for than one of them allows. Worker processes, the default, give
  the same bytes.

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

### TypeScript with no tsconfig of its own is never split (seen 2026-11-22)

Swan's own config for such a repo has `"include": ["<repo>/**/*"]`, an
absolute path. tsc 6.0.3 `--showConfig` then prints no `"files"`, so
`ts_root_listing` finds no roots: tsc is asked twice on every map, nothing
is kept, and TypeScript runs whole, with no chunks and no layers (a code
edit indexes the whole program again). Tried by hand: the same config with
`"include": ["../repo/**/*"]`, a relative path, does get its files named.
A change for after the port, with its own check and a measure on a real
repo that has JavaScript or TypeScript and no tsconfig.

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
| 2026-11-22T06:15Z | `syntax-index` carried: `rust/src/syntax.rs` (src/syntax.goose). `scripts/port-syntax.sh`: 57 of 57 on a made-up repo of 62 files in the five languages (15 ways of asking), every fixture and this repository; 73 of 73 with eight repos given, one of 1,572 shell and Lua files (3,592 definitions, 91,170 occurrences, an index of 8.4 MB). `scripts/port-prove-syntax.py`: 107 of 107 breaks caught (105 of 107 at first; below). |
| 2026-11-22T06:15Z | The stamps carried: `rust/src/change.rs` (the code stamp of src/change.goose) and `rust/src/stamp.rs` (src/stamp.goose), the workers as processes and as threads. `scripts/port-stamp.sh`: 82 of 82 on a made-up repo of 340 files to stamp, every fixture and this repository; 94 of 94 with six repos given (rea: 7,784 files, the same bytes from one process and from 32 workers, the same lines from 4 threads). `scripts/port-prove-stamp.py`: 59 of 59 breaks caught. |
| 2026-11-22T06:15Z | Stage 3 done on branch `rust-stage-3`. Cost: `syntax-index` 52.6 ms against the Goose program's 54.0 on 1,572 files; `stamp-bench` on rea 6,241 ms against 6,282 in one process, 468 against 459 with 32 workers, 1,668 against 1,674 on 4 threads. |
| 2026-11-22T06:39Z | Stage 4 begun (branch `rust-stage-4`, on `rust-stage-3`). The indexer patches carried: `rust/src/pypatch.rs` and `rust/src/tspatch.rs`, their sites copied from the Goose sources by a script, and `write_file_atomic` in `sys.rs`. `scripts/port-patch.sh`: 105 of 105 on the three files Swan patches (pyright-internal.js 1.4 MB, scip-python.js, FileIndexer.js), each with and without its patch, and on nine kinds of file a patch must refuse or leave. `scripts/port-prove-patch.py`: 29 of 29 breaks caught. |
| 2026-11-22T06:49Z | Running a step carried: `sys::run` (native/swan_sys.c's `swan_run`: its own variables, the PATH it will have, a group of its own, both streams, the deadline), `rust/src/run.rs` (src/run.goose) and, with it, `swan trust` (`rust/src/pipeline.rs`, begun) and `swan doctor`. `scripts/port-run.sh`: 53 of 53 the same, each program in a made-up home, with a made-up `mkdir` and `doctor.py`; the ten-second deadline is waited for three times in each program, timed, and nothing a step started may be left running. `scripts/port-prove-run.py`: 39 of 39 breaks caught. |
| 2026-11-22T07:26Z | Reading JSON carried: `rust/src/json.rs`, from Goose's `stdlib/json.goose`. `scripts/port-json.sh`: 159 of 159 texts read the same by both (150 made up, of which 67 are JSON; 9 files of the repo). `scripts/port-prove-json.py`: 23 of 23 breaks caught. |
| 2026-11-22T07:26Z | The opening of `swan map` carried: `rust/src/seal.rs`, `wings.rs` (where spread-wings is), `survey.rs` (running it, and the report's lines), `Walk::refresh` (what git ignores) and, in `pipeline.rs`, the languages a repo holds, trust, an older map and a clean one. The Rust map then stops with exit 70. `scripts/port-map.sh`: 72 of 72 the same in the carried part, each program in a made-up home. `scripts/port-prove-map.py`: 74 of 74 breaks caught. |
| 2026-11-22T07:49Z | The content stamps of `swan map` carried (src/pipeline.goose to line 1163): `Stamps` in `pipeline.rs`, with `index_lines` in `change.rs`; `stamp_known` and `line_of_path`, carried at stage 3, are reached now. `scripts/port-map.sh`: 98 of 98 in the carried part, 26 of them for the stamps. `scripts/port-prove-map.py`: 99 of 99 breaks caught, the first time it was run. #78 (stage 3) merged into main on the owner's word; main merged into `rust-stage-4`. |
| 2026-11-22T09:21Z | `swan map` carried as far as the projects TypeScript is split into (src/pipeline.goose to line 1449, and src/tsproj.goose whole as `tsproj.rs`): the config probe, Swan's own tsconfig, `ensure_scip_typescript_patch` (`tspatch.rs`), `child_env`, `jobs_limit`, `ts_root_listing`, `lang_fingerprint`, the kept lists and their key, `ts_other_projects`. `scripts/port-map.sh` reworked (cases side by side, a home each, a made-up tsc, steps compared whole): 229 of 229, 131 of them new. `scripts/port-prove-map.py`: 256 of 256 breaks caught: 254 in a run of them all, and the two it missed by the case added for them (the other 254 were not run again after that case went in). |
| 2026-11-22T16:48Z | `swan map` carried to the end of TypeScript (src/pipeline.goose to line 1739): `plan_ts`, `same_file_set`, `dependents_of_changes`, the jobs' list (`Jobs`: `add_job`, `add_lang_job`), the plan (`TsPlan`), what the chunks share, the layers. Goose's sort carried as `rust/src/gsort.rs`: `scripts/port-sort.sh` 7,718 of 7,718 lists, `scripts/port-prove-sort.py` 30 of 30 (29 of 31 on its first run). `scripts/port-map.sh`: 317 of 317, 88 of them new. `scripts/port-prove-map.py` has 371 breaks, 115 new, all fitting the source, and has not run on this tree: the session was ended on the owner's word first. HANDOFF.md has it as the next thing. |
| 2026-11-22T18:10Z | The map's prover run on the tree of `7fc1276`, all 371 breaks in six parts side by side, 66 minutes: the unbroken program 317 of 317 in every part, 370 of 371 breaks caught on the first run. The one let through was no break ("Found while porting") and is taken out: 370 of 370. The 88 cases for TypeScript's chunks and layers are shown to catch what they were made for. |
| 2026-11-22T18:18Z | `swan map` carried to the end of Python (src/pipeline.goose to line 1920): `ensure_scip_python_patch` and `ensure_scip_python_site_patch` (`pypatch.rs`), `survey_python_envs` (`survey.rs`), `piece_target` (`pyplan.rs`) and, in `pipeline.rs`, the virtualenv kept aside for a repo that is not trusted, the stand-in interpreter, the two lists of packages, the src layout, each piece's key and which pieces are kept. `scripts/port-map.sh`: 395 of 395, 78 of them new (59 of 78 on the first run; the 19 were the judge's). The judge gives each home scip-python's two files as its own and compares how they are left. No breaks for this part in the prover yet: the owner is asked first whether it runs after every part or at the end of the stage. |
| 2026-11-22T18:45Z | `swan map` carried to where its jobs are run (src/pipeline.goose to line 2187): the cargo projects, Java, C#, C and CUDA, what waits for trust, the servers' languages (`modules.rs`, begun: `lsp_server_present`, `lang_of_path`; `survey_paths`) and the syntax index, each planned; and the two ways a map ends when nothing is left to run, the first maps the Rust program makes to their end. `scripts/port-map.sh`: 440 of 440, 45 new, 32 of the 440 compared whole (their rows too). No breaks for these parts in the prover yet. |
| 2026-11-23T14:15Z | `swan map` whole in Rust (src/pipeline.goose to its end): the jobs started and waited for (`spawn_job`, `wait_any`), what each took or how it failed, the records, the flattener, the store, rows moved after cosmetic edits (`shift_cosmetic`, `mark_edited`), the crates with no rows, the end of the report. `scripts/port-map.sh` compares whole maps: 440 of 440 the same, where 32 were made to their end before. Agent-Reach mapped sealed by both: every table's hash the same but `meta`. relate mapped by the Rust program in 38 s, its Go folder apart. A new map the Rust `index` left locked, found and mended (below). The same day, on the owner's word: no longer line by line, no provers, and then no more matching of the Goose program (DECISIONS.md). |
| 2026-11-23T15:00Z | `swan lsp-index` in Rust: `lsp.rs` (a synchronous client on `lsp-server` and `lsp-types`), `lspindex.rs` (SCIP written with the `scip` crate), a language's server read from tools/modules.json in `modules.rs`. Not copied from `lsp/golsp.goose`. cobra: the same rows as the Goose program's map, 4.7 s against 7.1 s. relate mapped whole. `port-map.sh` 440 of 440 with no Goose program behind the Rust one; `SWAN_PORT_GOOSE` is gone. Built by a worker agent with RustRover's MCP server; the crates chosen from a survey of the same day. |
| 2026-11-25T09:04Z | Languages through their servers (branch `rust-lsp-languages`). `"map_lsp"` in tools/modules.json, read by the Rust program only: Lua (lua-language-server) and PHP (PHPantom 1.1.0) are mapped by `swan lsp-index` through SolidLSP. Penlight: 17,796 references from the server in 18.7 s, where 11,895 were name matches. Slim: 1,119 definitions and 4,387 references in 1.2 s, where there were none. Shell and Ruby were measured and left with the syntax index. A language's files fall back to their by-name rows when its server fails. docs/languages-through-servers.md has the verdicts and the recipes. |
| 2026-11-25T12:15Z | Live answers (branch `rust-live-answers`). `swan lsp-ask` and `swan broke` in Rust, one process each, on the Rust client, from the `"lsp"` entries as they are: the client keeps what a server says unasked, `live.rs` holds one server and the three settles, one time budget per command under the hook's 120 s. Through the real hook on five trial repos and this repo's own Rust, the same words as the program that ships, in the same seconds or fewer (Go 0.9 s where it takes 3.3 s). A server no longer outlives a swan killed with SIGKILL. Found: both programs said "nothing new" for a Rust file whose check did not run; the Rust program now says "not settled" with rust-analyzer's words. No server stays running yet, PHP has no live entry, and Java, Kotlin and C# were not run. |

## What exists in Rust to build on (surveyed 2026-11-23T14:33Z)

Asked by the owner: "swan with rust dependencies should have the things
exist somewhere on the net to help us fill our gaps". A research agent read
each project's page and manifest that day; versions are as it fetched them
and are checked again when a crate is added.

| For | What | Licence | Verdict |
|---|---|---|---|
| Speaking to a language server | `lsp-server` 0.10 (its message reading and writing, synchronous) with `lsp-types` 0.97 | MIT / Apache-2.0 | depend |
| The same, asynchronous | `async-lsp` 0.2 | MIT / Apache-2.0 | only if the client goes async |
| Server side only | `tower-lsp`, `tower-lsp-server` | MIT / Apache-2.0 | no use to a client |
| Editors' clients | Helix's `helix-lsp` (not published, MPL-2.0); Zed's `lsp` (not published, GPL-3.0-or-later) | | read Helix's; do not copy Zed's |
| How to start each language's server | Helix's `languages.toml` (342 languages, 188 servers, MPL-2.0); mason-registry (608 packages with where to fetch them, Apache-2.0) | | usable as data |
| Starting a server and knowing when it is ready | SolidLSP (Python, MIT; about 80 language classes); multilspy (12) | MIT | SolidLSP, behind the bridge Swan has |
| serena-rs | Two codebases of that name: the repository (11 commits in one day, 12 servers written in, readiness by a short sleep) and the crate 0.1.7 (7 servers, its own JSON-RPC, 353 tests, 32 downloads). No LICENSE file in either | says MIT | read, not depended on |
| Others that give agents language-server answers | lsproxy (Rust, MIT, 8 languages, quiet since 2025-08), its MCP fork, mcp-language-server (Go), cclsp (TypeScript) | | read |
| SCIP | `scip` 0.10 (types, symbol parsing, writing; pins protobuf) | Apache-2.0 | depend |
| SCIP into SQLite | the `scip` CLI's experimental convert (Go): documents, chunks, global_symbols, mentions | Apache-2.0 | its schema is worth reading beside Swan's |
| Pattern search | `ast-grep-core` 0.51 | MIT | depend, when the matcher carried from Goose is next touched |
| Symbols by name where no compiler-grade tool exists | `tree-sitter-tags` 0.27 | MIT | depend, for the same reason |
| Name resolution without a compiler | stack-graphs | | archived 2025-09 |
| The MCP server | `rmcp` 3.11, the official SDK (stdio, tools by macro) | Apache-2.0 | depend |
| Watching files, walking by .gitignore | `notify` 9 with its debouncer; `ignore` 0.4 | CC0; Unlicense / MIT | depend, with the watcher |

What nothing found fills, and so stays Swan's own: a language server's
answers made into SCIP (`swan lsp-index`); SCIP made into rows in SQLite
with questions over them, in Rust; starting every language's server and
waiting until it is ready, in Rust (SolidLSP does it in Python, which is
why the bridge stays); and sealing a repo so its code does not run unasked.

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
- Stage 3: `syntax-index` gave the same bytes on its first build, on this
  repository, three fixtures and a clone of 1,572 shell and Lua files. Its
  first judge still caught only 105 of 107 breaks. The file meant to be
  exactly 1,000,000 bytes, the largest read, was one byte over, so both
  programs left it out whatever the limit said; and no made-up line showed
  a carriage return, which only counts where a line's length is written (a
  Go variable, a plain type, a body with no brace, a file's last line).
  Both have a case now, and the size of the big file is checked before
  anything is compared.
- Stage 3: four things in `syntax-index` and three in the stamps show
  nothing either command can see, so they have no break; each prover lists
  them at its head.
- Stage 3: the first Rust `syntax-index` took 63 ms where the Goose
  program took 53 (1,572 files). It looked each word up through Rust's
  standard hash with a key made for the lookup. With the hash the rest of
  the port uses and a table for each language, 52.6 ms against 54.0.
- Stage 3: `rust/src/main.rs` named stage 2 for `stamp-bench` and
  `stamp-worker` after they moved to stage 3. Both are carried now.
- Stage 3: `scripts/port-compare.sh` takes the time off `stamp-bench`'s
  last line ("stamp-bench: N ms"), which does not end in " in N ms".
- Stage 4: a step's account has its time in it ("mkdir: 3 ms", "doctor:
  exit 2 after 41 ms"), so `scripts/port-compare.sh` now takes the time
  off every line of those two shapes, not `stamp-bench`'s alone.
- Stage 4: `trust` and `doctor` write into Swan's own folder and read
  its scripts, so each program is judged from a made-up home of its own
  (a copy of the program in `home/bin/`). Neither touches an installed
  Swan. The program a step starts is replaced too: a made-up `mkdir` on
  PATH and a made-up `scripts/doctor.py` are how the judge sees what a
  step is given and what becomes of its exit code, its output, a signal
  and its deadline.
- Stage 4: the Rust side first let the system look a step's program up on
  PATH. `swan_run` tries each folder itself, in order, until one starts,
  and reports the last failure; the Rust side does the same now, so "may
  not be run" and "not there" are told apart the same way. A program file
  with no `#!` line is refused by both ("Exec format error").
- Stage 4: the line the suite ends on, `typescript test: exit 127 after 0
  ms`, is such an account: a step labelled `typescript test` whose program
  could not be started.
- Stage 4: the survey's answer is JSON, and the stage's list of sources
  did not name Goose's own `stdlib/json.goose` (1,663 lines, most of them
  for numbers with a fraction). Swan reads only strings, booleans and
  integers from JSON, so the Rust reader keeps no other number's value. It
  takes and refuses the same texts: 159 compared, 67 of them JSON.
- Stage 4: the JSON comparison's prover first caught 22 of 23 and could not
  judge one. Its comparisons run at once, and each built the Goose dumper
  again, over the others. The dumper is now built once and kept.
- Stage 4: a map patches Swan's own copy of two indexers, so the map is
  never judged from this checkout. Each program has a made-up home; the
  Goose program's holds links to the checkout's indexers, with real copies
  of the six files a map may write. The homes and the made-up repos are in
  `build/port-map/`, not in a temporary folder: the seal gives a step a
  /tmp of its own, where a made-up spread-wings would not be found.
- Stage 4: the Goose program runs every indexer for each case, about a
  minute for 71 cases, so what it said and wrote is kept, by the hash of
  the Goose program and of the judge. A run with it kept takes 5 s.
- Stage 4: the map judge's first run had 53 of 61 the same. All 8 were its
  own rules: it watched a file that a map of a Python repo writes later,
  and it took Goose's wrapper off an error only on the first line, where a
  map's first line is a step's account.
- Stage 4: a judge of a part must know where the part ends. The map judge
  first asked only that the Rust program's report be the start of the
  Goose program's, and its prover showed the hole: 69 of 74, with the two
  breaks that drop the opening's last line unseen. The judge now names the
  lines the carried part writes (`OPENING` in `scripts/port-map.sh`) and
  wants exactly those. The list grows with each part carried and goes when
  the map is whole.
- Stage 4: with nothing to index the Goose program says "no language found
  to index" and exits 1. The Rust map stops just before that, so it is the
  next thing to carry.
- Stage 4: the prover's first run on TypeScript's part caught 203 of 214,
  and the eleven showed three things. Eight breaks made the Rust program
  leave tsc unasked, and went unseen: the judge took the Rust program's
  standard error for good when it was only the start of the Goose
  program's, so saying less passed. The steps the carried part accounts
  for are now compared whole (`STEPS`). Two made-up answers of tsc did not
  single their rule out (a path that was real already; a spaced line
  another line stood in for). One break was no break: a list of files with
  a bad one in it is never read to its end, so "bad" and "ended" are never
  both true. The second run, on both TypeScript parts, caught 254 of
  256: the two were rules for Swan's own config at the root holding
  files, which the real tsc never gives it (below), and a made-up tsc now
  does.
- Stage 4: that run also judged up to 32 broken copies at once in each of
  six parts, every judge with its own cases side by side: a load of over a
  thousand on 32 cores. Nothing was caught wrongly that could be seen, and
  the prover now judges an eighth of the cores' worth at once
  (`PORT_PROVE_JUDGES`).
- Stage 4: seen in the Goose program while making the cases, and carried
  as it is: for a repo with no tsconfig of its own (or one tsc cannot
  read) Swan asks tsc for its files on every map and never uses the
  answer. Swan's own config names the repo by an absolute path, and tsc
  6.0.3's `--showConfig` names a config's files only when its `include` is
  a relative path, so no roots are found, no list is kept, and TypeScript
  runs as one job with no layers. Of the judge's 204 maps by the Goose
  program, the 32 that kept a list all had a tsconfig of their own. See
  "Held for after the port".
- Stage 4: also seen and carried as it is: where the root's config and one
  it names both list a file, `tsc --listFilesOnly` stops with TS6305 and
  the root's list is not taken; and a file that a later part stamps though
  no walk reaches it (in a hidden folder, or not there at all) has its
  text kept then, which the judge counts apart (`LATER_TEXTS`).
- Stage 4: the map judge runs its cases side by side now, each from a
  made-up home of its own, and keeps what the Goose program said case by
  case: 229 cases take about twelve seconds once the Goose program's
  answers are kept (three minutes the first time), where the 98 before
  took eight one after another and would have taken minutes with tsc in
  them. A home is links to the checkout's tools. The first design would
  have let a map write its mark through a hard link into the checkout's
  own copy of the indexer; a home now gets files of its own for whatever a
  map writes before any map runs, and only map folders are made writable
  when a run is cleared away.
- Stage 4: tsc can be a made-up program in a case's home, as spread-wings
  already could: it says what the case needs (an exit code, a list with
  none of the repo's files, a config with a backslash in it, another
  answer for each config below the root) and, asked, what it was given to
  run with, which is how `child_env` is judged.
- Stage 4: seen while making a case, in the Goose program and so in the
  port: Python planned for more places than a repo has top-level packages
  comes out as one piece (seven packages: seven pieces for six places, one
  for eight). Not looked into; `plan-python` is carried as it is.
- Stage 4: the map judge's pattern for a part's lines goes to awk as a
  variable, where `\(` loses its backslash: "file(s)" was read as a group
  and 16 of 93 cases came out different with the two programs saying the
  same. The pattern has no parentheses now.
- Stage 4: Jev (TypeSafe's typed decision model, asked through Composio)
  was given the port's state on the owner's word, 2026-11-22: 1,927 tokens
  in, 234 out, one call, six questions. That the carried commands behave
  the same: 3.67 on a scale of 0 to 4 (68% "near conclusive", 32%
  "strong"). That a judge of bytes should be a model instead: 0.11. Whether
  the way a partly carried map is judged is sound enough to build on: 0.74.
  The server client at stage 5: keep the mix while carrying and decide
  after, 100%. Next: go on with the map in order, 98%. The child of stage
  5: start the original for it 59%, compare only on repos without those
  languages 40%. It judged a summary written by the agent doing the work,
  so its answers are evidence, not decisions.
- Stage 4: Goose's sort is unstable, and a map holds the order it leaves
  equal elements in: a plan of TypeScript's chunks sorts a project's files
  by size, and which chunk each of two files of one size lands in follows.
  For twelve keys `3 1 2 1 3 1 2 1 3 1 2 1` sorted smallest first, Goose
  gives the places `1 9 3 5 7 11 10 2 6 0 8 4`, where a stable sort gives
  `1 3 5 7 9 11 2 6 10 0 4 8`. The sort is carried step by step
  (`rust/src/gsort.rs`, from `stdlib/std.goose`) and has a judge of its
  own (`scripts/port-sort.sh`). The two earlier sorts of the port are of
  keys that all differ, where any sort gives one order.
- Stage 4: the first lists made to take the sort to its heapsort did not.
  They were made by answering each comparison so that the pivot is the
  smallest element left, which defeats a plain quicksort; Goose's sort
  looks first for a list already in order, and to that glance such a list
  is in order. The prover showed it: a heap built one element short was
  not caught. The lists now start out of order, and what is left to the
  heapsort is scattered.
- Stage 4: a multi-line text in Goose (`"""`) ends without a line end. The
  Rust copies of the statements carried at stages 1 to 3 that are written
  over several lines (in `graph.rs`, `query.rs`, `diag.rs` and `index.rs`)
  end with one. A statement's text is said only when SQLite cannot prepare
  it, as on a map with a table missing, and there the Rust program says an
  empty line more: seen with `query <db> impls a` and `callers a` on a map
  whose `relationships` table was dropped (exit 1 in both). Found when
  the statement carried here differed in that one byte in a case made for
  it. The one carried here is right; the earlier ones are on main and are
  a change of their own ("Next" has it).
- Stage 4: a copy of a map says where its own indexes are
  (`index-manifest.tsv` holds whole paths), so the judge's second maps,
  which start from a copy of a map made elsewhere, never kept an index
  and "reused (no changes)" was never said in them. The judge now moves
  that record with the copy.
- Stage 4: left out of the carried opening until the part that reads them:
  the virtualenv of a repo that is not trusted (the Goose program keeps it
  aside as `venv_read` for the Python step), and four of the things
  `detect` notes (tsconfig, Maven and Gradle files at the top).
- Stage 4: the one break of 371 that the map's judge let through was no
  break. Where the files of earlier layers are counted, an empty name is
  passed over, and so is a name counted already. The second check passes
  over an empty name by itself: every list ends in a line end, and what
  follows the last line end is an empty line, so an empty name is always
  "counted already". The program without the first check does the same.
  The prover names it under "Not among the breaks".
- Stage 4: `python-pieces.tsv` holds whole paths, like `index-manifest.tsv`.
  The judge's second maps of Python start from a copy of a map made
  elsewhere, and kept their pieces only because the first map's index
  files were still where they were made. The copy's record is now moved
  with it.
- Stage 4: two things a later part of a map does to what Python's part
  writes, seen when the judge's first cases for them differed. Where the
  indexers' runs are read, a piece whose run failed is taken out of
  `python-pieces.tsv`; and at the end every `index-*.scip` that no job
  names is removed, whatever language's. Until those parts are carried the
  judge names the record as a later part's in the cases where scip-python
  fails, and watches a stale file that is no `.scip`.
- Stage 4: this machine's python3 has no pip, so every map of a Python
  repo without a virtualenv to read takes Python's own list of packages
  (`python packages (importlib.metadata)`), which holds whatever the
  machine has installed.
- Stage 4: a trusted map may write in the repo. cargo wrote a `Cargo.lock`
  into a made-up repo while the Goose program mapped it trusted, and the
  Rust program, run after, surveyed a repo that had a lock file. A judge
  that runs one program after the other on one repo needs repos a trusted
  run leaves as it found them: the made-up cargo projects carry their lock
  file.
- Stage 4: three fingerprints take in more than the repo. `lsp-index`'s
  and the syntax index's take in the program that made the index (its
  path and its size), so a new build of Swan maps those again, and the
  Rust program never keeps what the Goose program made. scip-java's takes
  in what it is to run, which names the map folder, so a copy of a map
  never keeps its Java index. Neither is a fault; both limit what a second
  map from a copy can show.
- Stage 4: the Goose program's `map_held` (what waits for trust, kept for
  `swan serve`) is a variable of the whole program, set in the middle of a
  map. It is left for the server's stage.
- Stage 4: the Rust `index` left a new map locked. `let Interner { syms,
  .. } = it;` takes `syms` out and leaves the rest of `it` alive to the
  end of the function, its two prepared statements with it; the comment
  beside it said they were finalized there. A connection closed with a
  statement still open stays open, and a new map is written with
  `locking_mode = EXCLUSIVE`, so every later read in the same process got
  "database is locked". `swan index` ends right after, so stages 1 to 4
  compared equal; it showed when the map ran to its end and read its own
  rows for `rust_unmapped`, which then named every crate. Mended, and
  `Db`'s close now stops the run when it does not close.
- Stage 4: what moves from run to run in a whole map, each seen before the
  judge was made to take it out. How many indexers run at once follows
  the free memory (`jobs_limit`, 3 GB a job). What a failed job said is
  the last 400 bytes of its log, so it starts elsewhere when the folder's
  path is longer. A TypeScript chunk that a changed file's users fall in
  has the time mixed into its fingerprint. scip-java's fingerprint takes
  in what it is run with, which names Swan's home and the map folder.
  scip-clang's index is not the same twice from the Goose program alone
  (c-plain: the same rows in another order; cu-plain: one symbol more in
  one run). scip-java gives its files back in an order that moves with the
  folder it writes in, the same files given it in the same order
  (fixtures/tiny-java; the two programs give the same bytes when both map
  into /tmp).

## Next

**As of 2026-11-25T12:15Z.** `swan lsp-ask` and `swan broke` are in Rust (HANDOFF.md, "The work, in order", says what is left of live answers: the server that stays running, PHP, and the three languages not run).

**As of 2026-11-25T09:04Z.** Items 1 to 3 of the list below are done for Go, Lua and
PHP; shell and Ruby were measured and left with the syntax index
(docs/languages-through-servers.md). What is next: PHP beside PhpStorm and
Go beside GoLand, then item 4. HANDOFF.md has it in full.

**As of 2026-11-23T14:15Z.** Stage 4's `swan map` is whole in Rust. What
follows in this section was written while it was carried and is kept as
the record of that. What is next is not a stage of the table as it was
drawn: the language servers, through SolidLSP (DECISIONS.md, 2026-11-23T14:15Z).
1. A language-server client in Rust, not copied from `lsp/golsp.goose`,
   that speaks to `tools/solidlsp/bridge.py` or to a server itself, sealed
   as now.
2. `swan lsp-index` on it, measured on cobra and fixtures/tiny-go beside
   the Goose program's map and beside GoLand; then `SWAN_PORT_GOOSE` goes.
3. More languages through the bridge, one at a time, each measured against
   its JetBrains IDE before it is kept.
4. Live answers on the same client; then checking and editing, and the
   server, on Rust libraries where one fits.
HANDOFF.md has it in full.

Beside the stages, a mend to what is on main, on its own branch from main
and with its own pull request: the statements of stages 1 to 3 that are
written over several lines end with a line end the Goose program's texts
do not have ("Found while porting", stage 4), so a statement SQLite cannot
prepare is said with an empty line after it. Take the last line end out of
each such text in `graph.rs`, `query.rs`, `diag.rs` and `index.rs`, with a
comparison of both programs on a map lacking each table in turn, seen
failing first.

Stage 3 is done on branch `rust-stage-3`; its pull request is opened when
the owner asks, after the full suite in the microVM on the commit that
merges.

Stage 4, the map, on branch `rust-stage-4` (from `rust-stage-3` until #78
is merged, then moved onto main): `seal`, `run`, `pipeline`, `pypatch`,
`tspatch`, `scip`, `wings`, `tsproj` and `survey`, judged by `swan map`
(table hashes, the report, "reused" on the second run). In this order,
each judged against the Goose program and seen failing before it is
trusted:
1. `pypatch` and `tspatch`, behind `scip-python-patch` and
   `scip-typescript-patch`. Done 2026-11-22: `scripts/port-patch.sh`. What
   makes sure of the patches before a map (the three `ensure_` functions)
   comes with the map.
2. `run` (Swan's home, running a step, the whole of `swan_run`), with the
   two commands that need only it: `trust` and `doctor`. Done 2026-11-22:
   `scripts/port-run.sh`.
3. Reading JSON: Goose's own `stdlib/json.goose`, the part Swan uses
   (`parse`, `member`, `each`, `as_string`, `as_bool`, `as_i64`). Done
   2026-11-22: `scripts/port-json.sh`.
4. `swan map`, a part at a time, in the map's own order. The Rust map
   stops where the carrying has got to, with what it would have said so
   far and exit 70, and `scripts/port-map.sh` compares as far as it gets:
   what is said, and the files of the map folder written by then. Each
   program maps from a made-up home of its own, in `build/port-map/`.
   - Done 2026-11-22: its opening. The seal (`seal`), where spread-wings is
     (`wings_bin`), the survey and what the report says of it (`survey`),
     the folders git ignores, the languages a repo holds, a virtualenv and
     trust, an older map and a clean one, the mark of when the map began.
   - Done 2026-11-22: the content stamps. What each file holds is stamped (by
     workers when there are enough files), the texts stamped by their code
     are kept, and a second map says which files changed only in comments
     or layout and which must be indexed again because their indexed text
     is unknown.
   - Done 2026-11-22: TypeScript as far as its projects. A repo's tsconfig that
     tsc cannot read is said and Swan's own config written; the indexer's
     patch is made sure of (`ensure_scip_typescript_patch`); how many
     places TypeScript may split into is worked out from the other
     languages and `$SWAN_JOBS`; tsc is asked for its files and their
     roots, or the kept list is used; and each file is given to the config
     that owns it (`tsproj.rs`, from `src/tsproj.goose`). With it: what a
     child is given to run with (`child_env`), `jobs_limit`,
     `ts_root_listing`, `lang_fingerprint`.
   - Done 2026-11-22: the rest of TypeScript, planned and not yet run. A
     project is cut into chunks by size (`plan_ts`, with Goose's own sort
     as `gsort.rs`), each project of several by itself; the last map's
     plan is kept while it holds the same files (`same_file_set`); what
     the chunks share is fingerprinted and each chunk by its files; an
     index is kept while the last map's record names it with the same
     fingerprint, and the report says so; the files changed since the last
     map and the files that use what they define (`dependents_of_changes`,
     from the last map's rows) are indexed as a layer over the chunks
     while layers are few and small. The jobs are listed (`Jobs`) and
     their configs written; nothing runs them yet.
   - Done 2026-11-22: Python's pieces, planned and not yet run. The two
     fixes to scip-python are made sure of; a virtualenv is read (or, in a
     trusted repo, run) for its packages and its Python; the pieces are
     planned and each keeps its index while its key and its files' users
     are unchanged. No breaks for it in the prover yet.
   - Done 2026-11-22: every other job, planned and not yet run: the cargo
     projects, Java, C#, C and CUDA, what waits for trust, the servers'
     languages and the syntax index; and a map with nothing to run, made
     to its end (an empty map, or "no language found").
   - Left, in order: running the jobs, at most so many at once; the
     flattener; `index` or `refresh`; the end of the report, with the
     record of the indexes (`index-manifest.tsv`).
   - A map starts its own program again as `syntax-index` (carried) and
     `lsp-index` (stage 5). Until stage 5 the Rust map is compared on
     repos with no language a server indexes, or starts the Goose program
     for that one child; say which when the jobs are carried. Carried in stage 3 and first used there, so judged there:
`stamp_known` and `line_of_path` (no stamp is known when `stamp-bench`
starts), and `Walk::load` with the `git-ignored.txt` a map writes.
Rebuild the Goose program first (`scripts/build.sh`), which also fetches
the goose-treesitter copy `rust/build.rs` builds from.
