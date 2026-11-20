# Swan in Rust: the bar, the stages, the log

Started 2026-11-19 on branch `rust`, on the owner's word ("for swan lets see
if we can turn it to rust ... it will be a complete overhaul"). Spread-Wings
was carried over the same way on 2026-11-18 (its `docs/rust-port.md`); this
follows that method.

The Goose program in `src/` is the one that ships until the owner says
otherwise. `rust/` is the port. Nothing here is merged, installed or pushed.

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
   on the fixtures and on the four trial repos in `~/Work/tries/jb-kit/`
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
| 1 | The store: reading flattened SCIP into a map, refresh, questions | `swan_sys.c`, `db`, `scip`, `index`, `fresh`, `graph`, `query`, `writer` | 2,110 | `index`, `refresh`: table hashes. `query`: bytes, all 14 kinds |
| 2 | Planning that runs nothing | `modules`, `survey`, `rustproj`, `tsproj`, `gradle`, `pyplan`, `stamp` | 2,007 | `cargo-projects`, `gradle-tasks`, `plan-python`, `stamp-bench`: bytes |
| 3 | Syntax | `syntax`, `structural` | 1,080 | `syntax-index` rows; `query pattern` bytes |
| 4 | The map | `seal`, `run`, `pipeline`, `pypatch`, `tspatch`, `scip`, `wings` | 3,681 | `swan map`: table hashes, the report, "reused" on the second run |
| 5 | Language servers | `golsp.goose`, `proc.c`, `glue.c`, `lspindex`, `live` | 1,815 | `lsp-index` SCIP output; `lsp-ask` answers |
| 6 | Checking and editing | `checkers`, `diag`, `broke`, `change`, `edit` | 1,549 | `check`, `broke`, `format`, `test`, `diagnostics`: reports and rows |
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

## Log

| When (UTC) | What |
|---|---|
| 2026-11-20T05:55Z | Branch `rust` from main `fb8df2a`. This file. |
| 2026-11-20T05:58Z | Stage 0. `rust/` builds with cargo 1.100.0 into `build/rust/` (451 KB, no crates yet). `scripts/port-compare.sh --wrong-calls`: 47 of 47 answered the same as the installed Goose build `fb8df2a4c199` (usage text and exit 2). Every command of the right shape exits 70, "not carried over yet", with its stage. |

## Found while porting

- Stage 0: `swan query <db> <kind> <arg>` opens the map before it looks at
  the kind, so a missing map is reported (exit 1) before an unknown kind
  (usage, exit 2). Kept in that order.
- Stage 0: the message for a missing map differs as expected. Goose:
  `goose runtime error: swan: no index at <path> (src/swan.goose:66)`.
  Rust: `swan: no index at <path>`. The exit code is 1 in both.

## Next

Stage 1, the store. Before writing it: find the SQLite version goose-sqlite
builds (commit `c759de7`) and pin `libsqlite3-sys` to a release that bundles
the same one; make flattened SCIP folders for the fixtures and the trial
repos with the Goose build, to index with both programs; write the table
hash (every table, a fixed order) as a script both stages 1 and 4 use.
