# Handoff: Swan in Rust (branch `rust-live-answers`, on `rust-lsp-languages`, on `rust-stage-4`)

Written 2026-11-20T07:25Z; stage 2 part rewritten 2026-11-20T16:21Z, stage 3 part 2026-11-20T23:51Z and again 2026-11-22T06:15Z, when stage 3 was finished; stage 4 part 2026-11-22T06:50Z, 2026-11-22T07:26Z 2026-11-22T16:46Z, 2026-11-22T18:18Z and 2026-11-22T18:45Z, when the prover had run on TypeScript's chunks and every job of a map was planned in Rust. For the next session, any agent. **Start at "Next action".** The end of the map, and the owner's two changes of direction: 2026-11-23T14:15Z. `lsp-index` in Rust: 2026-11-23T15:00Z. The languages mapped through their servers: 2026-11-25T09:04Z. Live answers (`lsp-ask`, `broke`): 2026-11-25T12:15Z.

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
| Languages through servers | Done on branch `rust-lsp-languages` (from `rust-stage-4`, pushed; no pull request): Lua and PHP are mapped by `swan lsp-index` through SolidLSP, each from a `"map_lsp"` entry in tools/modules.json that only the Rust program reads; shell and Ruby were measured and left with the syntax index. docs/languages-through-servers.md has each verdict; STATUS.md, 2026-11-25, the numbers |
| Live answers | Done on branch `rust-live-answers` (from `rust-lsp-languages`, pushed; no pull request): `swan lsp-ask` and `swan broke`, one process each, on the Rust client, from the `"lsp"` entries of tools/modules.json as they are. Go, Lua, Python, TypeScript and Rust were run against their real servers and beside the program that ships; C, the shader languages and Goose by hand; Java, Kotlin and C# not at all. STATUS.md, 2026-11-25T12:15Z, has the numbers |
| What is left | A server that stays running and is told of edits (with the MCP server), checking and editing, the MCP server, the build and the suite. Every command of theirs exits 70 and names the stage it was drawn in |

## What passed, and how to see it again
```bash
scripts/build.sh                                                     # the Goose program of this commit, the judge's other side
CARGO_TARGET_DIR=$PWD/build/rust ~/.cargo/bin/cargo build --release --manifest-path rust/Cargo.toml
CARGO_TARGET_DIR=$PWD/build/rust ~/.cargo/bin/cargo test --release --manifest-path rust/Cargo.toml   # 46 tests; 5 map fixtures/lsp-lua and lsp-php sealed, 6 ask real language servers (about 20 s in all)
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

## Next action: the two IDE judges; then the server that stays running (a new branch from `rust-live-answers`)

The owner, 2026-11-23: "i wouldn't try to match goose, i would try to
create your own solutions using jetbrains and serena styles and what lsp
scip exist this is why i also keep mentioning just having a stable way by
using solidlsp just like serena". And on 2026-11-25: "ok keep going with
the next languages", and later that day "continue".

### What is there to build on
- SolidLSP (src/solidlsp of oraios/serena, pinned in
  `scripts/fetch-tools.sh`, a uv virtualenv) behind
  `tools/solidlsp/bridge.py`: it starts, configures, waits for and stops the
  real server; the bridge speaks LSP to Swan. Three settings reach it
  through a server entry's `env`: `SWAN_SOLIDLSP_SETTINGS` (SolidLSP's own
  per-language settings as JSON, so a server fetched ahead is named and
  nothing is downloaded at map time), `SWAN_SOLIDLSP_HOLD_OPEN=1` (a file
  stays open across questions: a map only) and `SWAN_SOLIDLSP_UNOPENED=1`
  (each question goes to the server as asked, no file opened: PHPantom).
- `tools/modules.json`: a language is mapped through its server by the
  Rust program when its entry has `"map_lsp"` candidates (Lua, PHP) or says
  `"map": "lsp"` (Go, Goose: the Goose program reads that one too). A
  candidate's `"needs"` is the real server's path. Which files are a
  language's is its `"match"` list.
- In Rust: `rust/src/lsp.rs` (the client), `rust/src/lspindex.rs` (`swan
  lsp-index`), `rust/src/modules.rs` (`Entry`: `holds`, `missing`,
  `map_server`, the fingerprint's text), the planning in
  `rust/src/pipeline.rs` (search `map_entries`: a job per language, the
  syntax index's skip list, the second syntax run when a server fails),
  `rust/tests/lsp_languages.rs` (maps fixtures/lsp-lua and lsp-php sealed
  and asserts rows).
- **A language is added with data:** a `"map_lsp"` entry, a pinned fetch, a
  two-file fixture with a case a name match gets wrong, its rows asserted.
  Then the measure on a real repo, sealed: is the server's answer better
  than the name match, and what does it cost. docs/languages-through-servers.md
  has the four that were measured, two of them not kept, and why.
- One command maps a repo with two builds and prints the table:
  `swan-map-table` in the owner's tools folder (`--ext lua,php <repo>
  before=<home> after=<home>`; a home is a folder with `bin/swan`, `tools`
  and `.tools` beside it, as the tests make one).
- Live answers: `rust/src/live.rs` (`Live`: one server for one language of
  one repo; the file on disk is the truth; the three settles; one budget
  per command) and `rust/src/broke.rs`. The client's `Heard` in
  `rust/src/lsp.rs` is what a server said unasked. `rust/tests/fake_lsp.py`
  is a scripted server with a mode per case; `rust/tests/live_servers.rs`
  asks the real ones on copies of the fixtures.
- One command puts the post-edit hook through one planted error with two
  builds and prints one table: `swan-broke-probe` in the owner's tools
  folder (`OUT=<scratch> swan-broke-probe <repo> <file> '<line>'
  goose=<repo>/bin/swan rust=<home>/bin/swan`; `--own` only for this repo's
  own code). It copies the repo per build: on this machine the session's
  scratch folder is memory, so delete the copies when the table is read.
- RustRover helps while building: `./jb open rustrover <this repo>/rust` in
  the jetbrains kit, then `./jb call rustrover get_file_problems` (or
  `lint_files`, `get_symbol_info`) with `projectPath` the `rust` folder.
  Open `rust/` itself, never the repo's top. Only its tools that read.

### The work, in order
1. **PHP beside PhpStorm, Go beside GoLand.** Neither language's map has
   been put to an IDE, and the rule was that each is before it is kept
   (DECISIONS.md, 2026-11-25, says so). Both wait on the owner ("Decisions
   waiting"). Then: the `jetbrains-reference` skill; the clones are in the
   trial repos' folder (Slim, cobra); map each with the Rust program,
   sealed; `compare/refs_vs_ide.py`; read every difference that is not an
   import line or a constructor; a fault becomes a fixture and a fix.
2. **Live answers: the two commands are done; what is left of them:**
   - The server that stays running. It belongs with the MCP server (item
     4): `Live` must then tell a server that a file changed (didChange and
     didSave), with a real server's test (Lua: plant an error, ask, mend it
     on disk, ask again in the same `Live`, expect none). Until then a
     second question about a changed file is refused. `live_implementations`
     and `live_warm` of `src/live.goose` come with it.
   - PHP. It has no `"lsp"` entry. The bridge's `textDocument/diagnostic`
     branch has no `unopened` path and opens the file through SolidLSP,
     which `SWAN_SOLIDLSP_UNOPENED` exists to avoid: the bridge first, then
     the entry, on its own branch. The program that ships maps no file name
     to PHP, so an `"lsp"` entry is inert for it; show that with its
     `lsp-ask` on a .php file, old data file and new.
   - Java, Kotlin, C#: not run. Java's entry holds `{java_source_paths}`,
     which nothing fills in, so its init is not JSON and it is refused. The
     Kotlin server needs the wait for its import that `lsp/golsp.goose`
     has (`importing`, near its line 615); it was not written blind. Their
     turn is when the suite in the microVM can judge the Rust program.
   - A live server must not set `SWAN_SOLIDLSP_HOLD_OPEN` (a held file is
     not read from disk again).
3. **More languages, one at a time, by the measure.** Kotlin is the next
   candidate: it has no indexer in the map (tree-sitter only), SolidLSP
   knows a server for it, and IntelliJ IDEA can judge it; its server may run
   Gradle, which is the repo's code, so the question is what it answers
   sealed and not trusted. After it: GDScript, the shader languages, C#.
   Ruby and shell are measured: Ruby has two ways on written in the doc,
   shell's server is for live errors only.
4. Checking and editing, and the MCP server on `rmcp`.

Known and small, for whoever is next in these files:
- **The program that ships says "nothing new" for a Rust file whose check
  did not run** (a build script that fails, cargo that cannot start). The
  Rust program does not: with rust-analyzer's health not ok, errors are
  passed on and no errors is "not settled". "Decisions waiting" has it.
- The hook prints only new errors, so a file that could not be asked reaches
  an agent as silence. The JSON says `"asked": false` and why.
- `swan broke` and `lsp-ask` pass line and column as given, in the
  server's units (UTF-16); nothing was tried with a character outside ASCII
  before the column.
- One budget per command: a silent server uses up the time of the languages
  asked after it.
- What didOpen calls a JavaScript file (`javascript`, not the entry's
  `typescript`) is a rule in `live.rs`, not data: the data file is shared
  with the program that ships.
- The watcher that kills a server's group when swan is killed is a
  `/bin/sh` in that group. A server not sealed whose children start a
  session of their own would escape it; none was seen.
- **`swan map` gives its sealed children its whole environment** (indexers
  and language servers alike). Inside the seal there is no network, but a
  child can write what it reads into the map folder, and a secret in the
  shell's environment is something it reads. A sealed child wants a short
  list of variables. Its own branch; the Goose program does the same.
- One changed file of a language redoes that language's whole `lsp-index`
  job (Penlight: 19 s).
- Stopping `swan map` alone leaves its indexers running to their end: each
  is in its own process group.
- The report's first line still says "(syntax only)" of Go and Lua.
- An install (`SWAN_RUNTIME_ONLY`) fetches neither lua-language-server nor
  PHPantom: the Goose program maps through neither. Both fetches lose their
  dev-checkout-only test in `scripts/fetch-tools.sh` when the Rust program
  ships.
- From before: a silent server is given 120 s before `lsp-index` fails;
  `{java_source_paths}` is not filled in for a server's settings; the
  client's reader thread is not joined, which a long-lived `swan serve` will
  care about; the Rust program carries Apache-2.0 libraries, and what a
  shipped binary must say of them is for when it ships.

### How it is judged now
A JetBrains IDE on the trial repos, and Swan's own suite in the microVM
once the Rust program can stand in `bin/`. The comparisons with the Goose
program stay and cost a minute; they are not extended, and a difference one
shows is a question to look at, not a fault to mend. Since 2026-11-25
`scripts/port-map.sh` says 14 of 440 differ, each in the report's text (an
lsp-index line carries its counts; Lua and PHP are mapped): as meant. No prover is run.
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
- The program that ships tells an agent "nothing new" for a Rust file when
  the compiler check did not run (STATUS.md, 2026-11-25T12:15Z: a planted
  type error, exit 0). Mend it there too (the fault is in the client
  library, the `lsp/` submodule, then a pin and the suite), or leave it to
  the Rust program?
- The post-edit hook is silent when a file could not be asked. Have it say
  so once (it is a script of the program that ships), or leave it?
- A pull request for `rust-live-answers`: it is the third on the stack
  (`rust-stage-4`, `rust-lsp-languages`, this). Each is opened when he
  asks, the lowest first.
- PhpStorm and GoLand, to judge the PHP and the Go map: neither has the
  trial repos' folder among its trusted locations, so opening a clone stops
  at "Trust project?". For the owner to run in the jetbrains kit, each IDE
  closed: `./jb trust-location phpstorm <the trial repos' folder>` and
  `./jb trust-location goland <the trial repos' folder>`. A first launch of
  either may also stop at a dialog only he can answer.
- A pull request for `rust-lsp-languages`: it sits on `rust-stage-4`, which
  has none. Both are opened when he asks, the lower first.
- Ruby: left matched by name, on the measure. Leave it so, or build one of
  the two ways on (the server's symbols with references still by name; or
  Solargraph, by type, for a trusted repo only)?
- The environment a sealed child is given ("Known and small"): cut it down
  on its own branch now, in both programs, or when the Rust program ships?
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
- Turn `"map": "lsp"` on for another language in tools/modules.json: the
  Goose program reads it. A language new to the Rust program's map gets
  `"map_lsp"`.
- Set `SWAN_SOLIDLSP_HOLD_OPEN` on a server that answers live: a held file
  is answered from the copy opened before the edit.
- Give an empty answer for a settle that did not happen, or for a build the
  server itself calls broken. "Not settled" with the reason is the answer.
- Put a language server or its runtime on the machine's PATH to make a
  measurement easier. An editor's own plugin then starts it unsealed on the
  trial repos (ruby-lsp evaluates a repo's Gemfile).
