# Handoff: Swan in Rust (branch `rust`)

Written 2026-11-20T06:02Z. For the next session, any agent.

## The task
Carry Swan over from Goose to Rust, on the owner's word, as a complete
overhaul. Same behavior first; better design later, as its own change. The
bar, the rules and the nine stages are in
[docs/rust-port.md](docs/rust-port.md). Read it first: it was written before
any Rust.

## State
| | |
|---|---|
| Branch | `rust`, from main `fb8df2a`. Nothing committed, pushed or installed |
| New files | `docs/rust-port.md`, `rust/` (Cargo.toml, src/main.rs), `scripts/port-compare.sh`, and these home files |
| What ships | The Goose program, unchanged. `rust/` is the port |
| Stage 0 | Done. The Rust program answers 47 of 47 wrong calls as the installed Goose build `fb8df2a4c199` does (usage text, exit 2) |
| Stages 1 to 8 | Not started. Every real command exits 70 and names its stage |

## What passed, and how to see it again
```bash
CARGO_TARGET_DIR=$PWD/build/rust ~/.cargo/bin/cargo build --release --manifest-path rust/Cargo.toml
scripts/port-compare.sh --wrong-calls          # 47 of 47
scripts/port-compare.sh query /no/such.db symbol x   # differs in wording only; see below
```
Not run: any suite. Nothing that the suites cover has changed.

## Known differences so far
- A missing map: Goose prints `goose runtime error: swan: no index at <path>
  (src/swan.goose:66)`, Rust prints `swan: no index at <path>`. Exit 1 in
  both.

## Next action: stage 1, the store
`native/swan_sys.c`, `src/db.goose`, `scip.goose`, `index.goose`,
`fresh.goose`, `graph.goose`, `query.goose`, `writer.goose` (2,110 lines).
Before writing it:
1. Find the SQLite version goose-sqlite builds at commit `c759de7` and pin
   `libsqlite3-sys` to a release that bundles the same one.
2. Make flattened SCIP folders with the Goose build for the fixtures and the
   trial repos in `~/Work/tries/jb-kit/`, to index with both programs.
3. Write the table hash (every table, a fixed order) as a script. Stages 1
   and 4 both use it.
Stage 1 passes when `index` and `refresh` write the same table hashes and
all 14 `query` kinds give the same bytes.

## Decisions waiting on the owner
- Commit the work on `rust` locally? (Not pushed either way.)
- Stages 2 and 3 do not depend on each other and could be carried in
  parallel by several agents. Faster, costs more.
- `wings/` still points at Spread-Wings from before its Rust port. Moving
  the pin is its own change.

## Do not
- Change `src/*.goose` on this branch except to fix a bug found by the port
  (and then as its own change on main first).
- Redesign while carrying over. Note the idea in `docs/rust-port.md`.
