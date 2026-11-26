# Swan

**In plain words:** Swan gives an AI coding agent the understanding of a
codebase that an IDE like JetBrains has: where everything is defined, who
uses it, what a change would break, which tests to run, and what errors a
file has right now. The agent asks Swan instead of guessing from text, and
gets answers in milliseconds. Swan runs on your own machine, reads your code
without changing it (unless you ask it to edit), and talks to agents over
MCP, the standard way agents use tools. It is a take on
[Serena](https://github.com/oraios/serena): Serena's tool design, a different
engine underneath.

**Moving from Goose to Rust (started 2026-11-19, on the owner's word).**
The program that ships, builds and installs today is still written in
[Goose](https://aardappel.github.io/goose/) (`src/*.goose`). It is being
carried over to Rust, a complete overhaul done one stage at a time, in
`rust/`. The owner's reason: Rust has a more developed ecosystem
([DECISIONS.md](DECISIONS.md)). Done: stages 0 to 3, four of the nine.
Stage 0 (commands, usage text, exit codes), stage 1 (the store: `index`,
`refresh` and `query`) and stage 2 (planning that runs nothing:
`cargo-projects`, `gradle-tasks` and `plan-python`) were merged on
2026-11-20. Stage 3 (syntax: structural search behind `query <db> pattern`,
the syntax-level index behind `syntax-index`, and the stamps behind
`stamp-bench` and `stamp-worker`) was finished on 2026-11-22. Each was
checked against the Goose program answer by answer (the numbers are in
[STATUS.md](STATUS.md)). Not done: stages 4 to 8 (the map, language
servers, checking and editing, the server, the switch). Nothing of the Rust
program is built by `scripts/build.sh`, installed or shipped yet, and the
rest of this page describes the Goose program. The bar, the stages and the log are in
[docs/rust-port.md](docs/rust-port.md); the work in progress is in
[HANDOFF.md](HANDOFF.md).

**What it can do today (2026-10-26):**

| You want to know | Swan tool | How fast |
| --- | --- | --- |
| Where is this defined, and who uses it? | `find_symbol`, `find_referencing_symbols` | a few ms |
| What breaks if I change this, and which tests cover it? | `get_callers`, `run_tests` | about 70 ms (under 1 ms for the exact callers; the rest is Spread-Wings bringing its graph up to date for `possible_callers`) |
| What implements this interface or trait? | `find_implementations`, `get_type_hierarchy` | a few ms |
| What errors does this file have right now, after my edit? | `get_diagnostics` with `live` | 0.4 to 0.9 s |
| Every place that looks like `$X.unwrap()`, and rewrite them all | `search_pattern`, `rewrite_pattern` | 0.14 s over 2,361 files |
| Edit or rename a function by name, safely | `replace_symbol_body`, `rename_symbol` | refused if the file changed under it |

Languages: TypeScript and JavaScript, Python, Rust, Java, Kotlin (including
Android projects), C, C++ and CUDA, plus, for game and 3D work, C# (Unity,
Godot), Lua, GDScript (Godot), Blender Python and the GLSL, HLSL and WGSL
shading languages. Every one gets pattern search. Live errors come from a
real language server for Python (Blender scripts included), TypeScript and
JavaScript, Rust, Kotlin, C and C++, C#, Lua and the three shading languages.
"Who calls this" and the rest of the full map need an indexer, which exists
for TypeScript/JavaScript, Python, Rust, Java, Kotlin, C, C++, CUDA and C#
(PHP is planned). How deep each one goes depends on the tools installed
for it; see [parity and languages](docs/parity-and-languages.md).
Go, shell scripts (also ones known only by their `#!` line), Makefiles, Ruby
and Lua get a syntax-level map (`swan syntax-index`, built into Swan): definitions, bodies
and references found by name (marked `by_name`), so no repo maps to nothing.
A Python `src/` layout is put on `PYTHONPATH` so tests that import the package
link to it, and a `tsconfig.json` that cannot be read (it extends an npm
package that is not installed) is replaced by Swan's own config. See
[the modular design proposal](docs/modular-design.md) for where this is going.

**Keeping up with edits:** after a one-line edit, re-mapping a 2,361-file
TypeScript project takes about 2 s (it used to take 8 to 10 s), and nothing
changed takes 0.07 s. A language server can be started ahead of time
(`SWAN_WARM=auto`) so the first live error check takes 0.7 s instead of 3.6 s.

**Built from reusable pieces:** three Goose libraries came out of Swan and can
be used by any Goose program:
[goose-sqlite](https://github.com/shetautnetjer/goose-sqlite),
[goose-treesitter](https://github.com/shetautnetjer/goose-treesitter) and
[goose-lsp](https://github.com/shetautnetjer/goose-lsp). Each has its own
standalone tests.

**Try it without installing anything else:** after building,
`python3 scripts/demo-offline.py` runs a small known-answer demo on synthetic
data ([demo and test scope](docs/demo.md)).

The rest of this page is the technical detail.

## Where it's headed: a local JetBrains for agents

An IDE knows a codebase as a graph, not as text: where every symbol is
defined, who uses it, what it calls, what a change would break, and which
tests cover it. Swan aims to give an agent that understanding headlessly,
before it edits anything, from data a compiler produced rather than from
guesses. Languages change slowly; dependencies change constantly. SCIP
indexers cover both: they record references into dependencies with each
package's name and version. The roadmap, most valuable first:

1. Reference graph and impact radius: implemented (`get_callers`,
   `get_callees`). These include non-call uses; see the limits below.
2. Per-file refresh, so the map stays current while the agent edits: done
   (`swan refresh`, `scripts/refresh-repo.sh`).
3. Tests for a symbol (partly there: `get_callers` flags test files).
   Freshness flags and unused-code finding: done (`stale`, `find_unused_symbols`).
4. Implementations and type hierarchy, from SCIP relationships: done
   (`find_implementations`, `get_type_hierarchy`).
5. Dependency insight: which packages and versions the code leans on.
6. Batch checks and live diagnostics: implemented through external tools
   and language servers (not SCIP).
7. Hot and fragile code, from git history.
8. More languages: one SCIP indexer per language, into the same database.
   TypeScript/JavaScript, Python, Rust, Java, Kotlin and host-side CUDA
   have adapters; support depends on the project's toolchain.

## What "a Goose Serena" means here

(This is the design as built today. The Rust port keeps it, stage by stage;
see the note at the top.)

[Goose](https://aardappel.github.io/goose/) is Wouter van Oortmerssen's
systems language (not Go, and not Block's goose agent). Serena is a Python MCP
server driving live language servers over LSP. Goose v1 has no subprocesses
or networking in its standard library, so Swan reaches them through small C
shims; a literal port of Serena was not the aim. Swan's reading of the idea:

- **Semantic data comes from SCIP.** External indexers record resolved
  definitions and references. Coverage depends on the indexer and project;
  dynamic uses and some macro references need special treatment.
- **Goose builds the map.** It interns the symbols, parses SCIP symbol
  strings into names, kinds and Serena-style name paths (`Store/add`), and
  works out which symbol each reference sits inside.
- **SQLite stores and answers.** Goose imports `goose-sqlite`, whose
  `extern fn` bindings and C shim call its vendored SQLite amalgamation.
- **Goose also serves the MCP.** Goose v2026.3 ships `json`, stdin line
  reading and file IO, so the stdio MCP server is the same Goose binary.
  The original plan put a TypeScript/Bun layer here; it turned out not to be
  needed. Querying an existing map uses the native binary; mapping, checking,
  formatting, testing and live analysis require their external tools.

```
TS repo ──scip-typescript──▶ index.scip ──bin/swan-flatten (Rust)──▶ TSV rows
                                                                     │
                                         bin/swan index (Goose) ◀────┘
                                                │
                                         swan.db (SQLite) ◀── bin/swan serve (Goose, MCP stdio) ◀── AYA
```

The SCIP flattener is `bin/swan-flatten`, Rust in `native/swan-flatten/`,
using every core, and Swan's only flattener: `scripts/build.sh` needs cargo
(Rust) to build it. The syntax-level index is Goose (`swan syntax-index`),
so a map runs no Bun.
Native C also supplies SQLite,
tree-sitter and its grammars, process/file helpers and the LSP bridge.
The matcher and LSP client logic are Goose; the language servers they use
are separate programs, not Goose ports. See [package boundaries](docs/packages.md)
for independent use, cached build behavior and the tradeoffs.
The flattener's
`occurrences.tsv` columns match those of a separate code-map bake-off
(described below), so either side can read the other's rows.

## Tools

Names and arguments follow Serena's, so an agent that knows Serena knows Swan.
A name path is the chain of enclosing names joined by `/`: `add` matches any
symbol named `add`, `Store/add` any whose path ends that way, `/Store/add`
only that whole path. Lines and columns in answers are 1-based.

| Tool | Arguments | Answers |
|---|---|---|
| `find_symbol` | `name_path_pattern`, `relative_path?`, `substring_matching?`, `include_body?`, `max_results?` | kind, signature, file, line, body line range, optionally the body |
| `find_referencing_symbols` | `name_path`, `relative_path?`, `max_results?` | per matched symbol, every reference: file, line, column, the symbol it sits inside, and its line of source |
| `get_symbols_overview` | `relative_path` (file or directory) | every symbol defined there, in order |
| `get_symbol_at` | `relative_path`, `line`, `column` | what a position refers to: definition, signature, docs, the symbol around it (JetBrains' quick documentation) |
| `get_callers` | `name_path`, `relative_path?`, `depth?` (1 to 5), `max_results?` | who calls or uses the symbol (import lines left out), and who uses those: the impact radius, with each caller's distance, whether it is test code and its `call_sites` (exact file and line of each use, including uses inside anonymous callbacks and top-level code), and a summary of affected symbols, files and test files; plus a separate `possible_callers` list (distance 1 only, never merged into `callers` or `summary`) of call sites Spread-Wings ties by syntax that the compiler index does not cover (up to 50 sites with `total` and each site's `how`, omitted when none, or `checked: false` and `why` if Spread-Wings is unavailable or fails) |
| `get_callees` | `name_path`, `relative_path?`, `calls_only?`, `max_results?` | what the symbol's body uses, with counts (`calls_only` keeps functions, methods, constructors, macros and classes); dependency symbols show their package and version |
| `find_implementations` | `name_path`, `relative_path?`, `max_results?`, `live?` | what implements, extends or overrides it, with distance; `live` asks the configured language server, subject to that server's capabilities |
| `get_type_hierarchy` | `name_path`, `relative_path?`, `depth?`, `max_results?` | supertypes and subtypes, from SCIP relationships |
| `replace_symbol_body` | `name_path`, `relative_path`, `body` | replaces the whole definition; refused if the file changed since the map was built; reports how many places use the symbol |
| `insert_after_symbol`, `insert_before_symbol` | `name_path`, `relative_path`, `body` | adds code next to a definition |
| `rename_symbol` | `name_path`, `relative_path`, `new_name`, `apply?` | plans by default: every site, skipped aliases, conflicts, stale files; `apply` writes it |
| `what_broke` | `files` (the repo-relative paths just edited) | the errors the language server reports now in those files that it did not when last asked: what the edit broke, without the errors that were already there; files that could not be checked carry `"asked": false`, `"reason"` (`no_server`, `untrusted`, `unsettled`, `failed`), and (for reasons other than `no_server`) `"first_time"`. Also `swan broke <map-dir> <file>...` (exit 0 when every file was asked and clean, 1 when something is new, 3 when nothing is new and a file was not asked), which `scripts/hooks/what-broke-after-edit.py` runs as a Claude Code post-edit hook (silent for `no_server`, and otherwise saying once per file and reason when Swan could not check it) |
| `edit_batch` | `edits` (a list of `{op, ...}`: `rename_symbol`, `replace_symbol_body`, `insert_after_symbol`, `insert_before_symbol`, `rewrite_pattern`, each with that tool's arguments), `apply?` | several edits as one change, all or nothing: planned together without `apply`, with `touches`: what the renamed or rewritten symbols reach that the batch does not edit, and the tests to run (from [Spread-Wings](https://github.com/shetautnetjer/spread-wings), which ships with Swan); with it they run in order, each seeing the earlier ones, and if one fails the map and every file already written go back |
| `run_tests` | `name_path` or `relative_path`, `depth?` | runs the tests that reach a symbol through calls, overrides included, with the language's runner from `tools/modules.json` |
| `format_file` | `relative_path` | the language's formatter from `tools/modules.json` |
| `get_diagnostics` | `name_path?`, `relative_path?`, `depth?`, `errors_only?`, `live?` | compiler errors and lint findings pinned to symbols and their referencing symbols (see `docs/diagnostics.md`); `live` asks a configured server (Rust, Python, TS/JS or Kotlin) about one file |
| `search_pattern` | `pattern`, `language?`, `relative_path?`, `max_results?` | structural search, ast-grep style (`$X.unwrap()`, `console.log($$$A)`), via tree-sitter for TS/TSX/JS, Python, Rust, Java, Kotlin, C, C++ and CUDA: each match with what its metavariables captured and the symbol it is in |
| `rewrite_pattern` | `pattern`, `rewrite`, `language?`, `relative_path?`, `apply?` | structural rewrite: plans by default; `apply` writes it, refused for files changed since the map |
| `find_unused_symbols` | `relative_path?`, `include_tests?`, `max_results?` | functions, classes, methods, types and variables nothing references or implements: removal candidates, not proof |
| `index_info` | none | repo root, build time, counts, and the files changed since the SCIP run |
| `repo_projects` | none | the projects the repo holds, one per `package.json`, `pyproject.toml`, `Cargo.toml`, `go.mod`, Maven or Gradle build: folder, package manager, the versions it wants and the file that says so, its workspace, whether dependencies are installed, test script. Read fresh by Spread-Wings; nothing of the repo is run |
| `repo_overview` | none | the lay of a repo: its groups of files that import and call each other, with their main files, most-called definitions and tests. From Spread-Wings, by syntax, in seconds: where to start in a repo you do not know |
| `what_touches` | `name`, `relative_path?` | before changing a definition: the files that define it, call it or import its file, which are tests, and the groups they sit in. From Spread-Wings: broader than `find_referencing_symbols`, not compiler-checked, and it says how many call sites were matched by name only |
| `file_neighbors` | `relative_path` | the files a file imports, is imported by, and calls into. From Spread-Wings |
| `use_repo` | `path`, `build?` | choose the repo the tools answer about, building its map the first time; `path` is the repo's root or a path inside it |

Every answer about a file that changed after the SCIP run carries
`"stale": true`, so an agent knows to reread it or refresh the map.

The Spread-Wings answers (`repo_overview`, `what_touches`,
`file_neighbors`, and `touches` in a planned `edit_batch`) follow the files
instead: before each one Spread-Wings looks at every file's time and size
and reads the ones that changed. When some had, the answer says so under
`files_changed`: the files changed, added and gone, the files that import
or call into them, and the tests among them.

Every tool also takes an optional `repo` (a path): it switches to that
repo's map before answering, as `use_repo` would, and the choice persists.
Tools accepting `repo` also advertise optional boolean `build`: pass
`"build":false` on each request to forbid implicit map creation/rebuilding
during selection. Omitted/true retains first-use building. A prior
`use_repo(build:false)` does not constrain later calls. This is selection
policy, not a read-only mode for explicit updates, checks, tests, edits or
live analysis. Inspect the installed tool schema before relying on the field;
older servers may ignore it. See [request build policy](docs/request-build-policy.md)
for exact routing, legacy fallback and qualification.

## Platform support

Swan is intended to run on other people's machines, using their own
checkouts, tools and MCP clients. The current implementation and bootstrap
are **Linux x86-64**; native macOS and Windows support is not implemented.
A portable compiler and MCP interface do not make the native process layer
or downloaded language tools portable automatically.

| Host | Current status |
|---|---|
| Linux x86-64 | Development host verified; the package candidate also passed a fresh install and relocation in Ubuntu 24.04 CUA with real Python/TypeScript indexing and live diagnostics. Other distributions still need qualification |
| Windows with WSL2 x86-64 | Possible route through Linux; not separately verified here, and not native Windows support |
| macOS, Intel or Apple silicon | Not supported by the current bootstrap/native helpers; requires a port and platform tests |
| Native Windows | Not supported; requires Windows process, path and filesystem handling |
| Linux ARM64 | Not qualified; the bootstrap currently selects x86-64 binaries |

Use the installation paths on **your** machine in the MCP examples below.
Keep the checkout layout: `bin/swan` locates `tools/`, `.tools/` and
`data/trusted-repos` relative to its real executable, not your shell's
working directory. Copying only the binary is not a complete installation
for indexing or live diagnostics. Maps record absolute repository paths;
rebuild them for the repositories on a different machine rather than copying
another person's maps or trust list. See the
[portability proposal](docs/packages.md#platform-portability-proposal-2026-11-06)
for the remaining work and acceptance checks.

## Security update: live Python diagnostics

[PR #11](https://github.com/shetautnetjer/Swan/pull/11), merged November 2,
2026, fixes an execution-before-trust bug. Previously, a live Python
question could pass an untrusted repository's detected virtualenv to
Pyright, which could execute the interpreter supplied by that repository.
`live_start` now clears the detected virtualenv unless the repository is
trusted, before constructing the interpreter setting and child PATH.
Trusted repositories can still use their virtualenv.

The fix is in commit
[`821474f`](https://github.com/shetautnetjer/Swan/commit/821474fe12e06aaefd96580a4903ab8aba08568e).
**Updating source does not update an already-built or running Swan.**
Existing users must build a revision containing the fix, verify the exact
executable their MCP client launches, and restart that client's Swan
process after an executable replacement. `scripts/build.sh` overwrites
that checkout's `bin/swan`; preserve a binary backup and use a separate
build/test checkout before replacing an active installation. Keep its trust
list and maps intact. A source ancestry check alone is not binary proof:

```bash
git merge-base --is-ancestor 821474fe12e06aaefd96580a4903ab8aba08568e HEAD
# Exit 0 means this source history includes the fix; it says nothing about bin/swan.
```

<!-- coderabbit-ai-generated:v1 -->

<!-- coderabbit-ai-generated-section:v1:4a5b46aca3b744b82d0a1b7cd5e11e1e8c6c563b220004ff37c8fb0f836806ac -->

[The regression test](tests/check/trust_suite.goose) checks that the untrusted live
reply contains a `result` field without executing a planted interpreter,
and that a trusted control does execute it. The `result` assertion does not
establish successful diagnostics: MCP tool errors also contain that field.
It skips live Python checks if Pyright is missing;
a skip is not evidence that this protection works. Run the test only in a
separate installation with its own executable, dependencies and `data/`.
It can write and restore that installation's entire trust list. The full
`scripts/test.sh` also rebuilds its executable.

<!-- /coderabbit-ai-generated:v1 -->

A separate installed-binary check on November 6, 2026 used real Pyright
1.1.414 and a byte-identical isolated executable copy: untrusted, trusted
control, and fresh untrusted sessions all returned a deliberate Python type
error, with the planted interpreter executing only in the trusted control.
This verifies that tested Linux executable, not every user's installation
or every possible repository-code execution path.

`SWAN_TRUST_BUILD=1` explicitly trusts every repository for that process;
keep it out of normal untrusted-repository sessions. Do not launch those
sessions from an environment that already puts a repository-controlled
interpreter on PATH. The trust check is not an operating-system sandbox.
Test runners (`run_tests`) execute repository code by design.

**Remaining concurrency limitation:** `swan trust` still rewrites
`data/trusted-repos` without a lock, so simultaneous grants can lose an
entry. The regression test's whole-file restoration can also erase a
concurrent grant. Serialize trust changes and keep tests away from the live
installation; this limitation was not fixed by PR #11.

## Use

**Linux package candidate:** the dependency-aware installer and portable agent
skill are described in [Install the Linux package](docs/install.md). It supports
a new user-owned prefix, `core` or `python-typescript` profiles, verified local
runtime downloads, and a read-only `swan doctor` command. It does not replace
an active installation, grant repository trust or configure an agent. A built
candidate and its qualification receipt are separate from an official release.
The source-build instructions below retain the legacy full-tool bootstrap.

**Concurrent maps:** [PR #15](https://github.com/shetautnetjer/Swan/pull/15)
serializes map/index/refresh writers and keeps read-only database answers on
complete snapshots. The reviewed implementation passed bounded Linux CUA checks,
including successful build-server release and failed/interrupted child ownership.
Busy errors can require retry or a server restart; keep persistent `.lock`
files and serialize other stateful operations and saved trust changes.
See [concurrency scope and exact staged-binary tests](docs/concurrency.md):

```sh
python3 -m unittest discover -s tests -p 'test_writer_lock.py' -v
python3 tests/check_concurrency.py --binary /path/to/staged-swan/bin/swan --output-parent /path/to/disposable-output --rows 50000 --timeout 30
python3 tests/test_map_readers.py --binary /path/to/staged-swan/bin/swan --output-parent /path/to/disposable-output --timeout 15
```

Run from the matching reviewed source checkout with an existing disposable
output parent; these checks do not update the active installation.

**Clean rebuild:** use `swan map <exact-repo-root> <exact-map-dir> --clean`
after dependency/indexer changes or suspected stale generated output. MCP
`update_map` exposes the same operation through `clean:true` with an explicit
exact `repo` root. It bypasses all reuse metadata and merge layers, keeps the
stable writer lock, and replaces the selected database only after every
eligible indexer succeeds. Trust, other maps and source are preserved.
See [target checks, failure recovery and qualification](docs/clean-reindex.md).

<!-- coderabbit-ai-generated:v1 -->

<!-- coderabbit-ai-generated-section:v1:408c1072b178095036c667f595f53dd2aa9053552258c86a2411dc15c4baef78 -->

`scripts/fetch-tools.sh` checks these first and names any that are missing before it downloads anything. The documented bootstrap needs Bash, Git, a C toolchain, Node.js >=22.22.2
with npm, Bun,
Python 3, uv (used to create the tool virtualenvs), and the download/archive utilities used by
`scripts/fetch-tools.sh` (including curl, tar, unzip and SHA checksum tools).
It fetches pinned language tools into this checkout. The first Goose build
can fetch the pinned SQLite and tree-sitter packages. Individual language
adapters have additional requirements; the full integration suite exercises
those external tools. These are setup requirements, not proof of a clean
installation on every Linux distribution.

<!-- /coderabbit-ai-generated:v1 -->

```bash
git clone --recurse-submodules https://github.com/shetautnetjer/Swan   # lsp/ is the goose-lsp submodule
cd Swan
scripts/fetch-tools.sh                          # Goose and the indexers and servers (sha256-pinned) into .tools/, the npm tools into tools/
# SWAN_LANGS=rust,c scripts/fetch-tools.sh      # only some language groups (rust, java, c, game, csharp, go, php); TS/JS and Python always come
scripts/build.sh                                # bin/swan; the first build fetches goose-sqlite and goose-treesitter; bin/swan-flatten too when cargo is installed
# SWAN_FLATTEN_PROFILE=quick scripts/build.sh   # while changing native/swan-flatten: ~1.6 s rebuilds instead of ~8 s; plain build.sh is what ships
bin/swan map <repo> data/<name>                 # every indexer the repo needs -> map (refreshes if it exists)
bin/swan check <repo> data/<name>               # tsc / cargo check / pyright -> diagnostics in the map
bin/swan cargo-projects <repo>                  # the cargo projects map would run rust-analyzer in, with its settings (runs nothing)
scripts/index-repo.sh <ts-repo> data/<name>     # index.scip, TSV rows, swan.db
scripts/refresh-repo.sh <ts-repo> data/<name>   # after edits: rerun SCIP, rewrite only changed files
scripts/diagnose-repo.sh <ts-repo> data/<name>  # tsc / cargo check, loaded into the map
bin/swan serve data/<name>/swan.db              # MCP over stdio, one map
bin/swan serve --maps data                      # or one server for every map under a data root
bin/swan query data/<name>/swan.db refs getBackend   # the same answers on the command line
scripts/test.sh                                 # build, map the fixture, then every suite (bin/swan-check, Goose) and the shell checks
bin/swan-check mcp edit                         # one or more suites; bin/swan-check alone runs them all, totals at the end
scripts/space-test.sh                           # the same build and suite in a throwaway microVM (a clean Ubuntu), not on this machine
```

`scripts/space-test.sh` forks a saved microVM (a `cua` Space on Firecracker;
`scripts/space-base.sh` makes the checkpoint once, about five minutes),
copies the working tree into the fork, builds and runs the suite there, and
deletes the fork. A fork is ready in a few seconds. It is the normal place
to run the suite: nothing a test does can touch this machine, and a clean
Ubuntu catches what a developer's machine hides. Its first run found that
Rust maps failed wherever rustup is installed for all users (no
`~/.rustup`).

For a small offline demonstration after building, run
`python3 scripts/demo-offline.py`. It exercises map loading, queries and
structural rewriting with synthetic rows, without installing indexers or
language servers. See [demo and test scope](docs/demo.md). The full integration
suite above needs the external tools and can build fixture projects.

An MCP client entry looks like:

```json
{ "command": "/path/to/swan/bin/swan", "args": ["serve", "/path/to/swan/data/<name>/swan.db"] }
```

or, to let one registered server answer about any repo:

```json
{ "command": "/path/to/swan/bin/swan", "args": ["serve", "--maps", "/path/to/swan/data"] }
```

In that mode the server starts with no repo selected: `use_repo` with a
repo's path (or a path inside it) finds its map under the data root —
`<data>/<name>/swan.db`, matched by the `root` recorded in the map — builds
it with `swan map`'s rules when there is none (trust holds included), and
switches to it. Passing `repo` on any other tool's call switches the same
way, so an agent can keep one server and move between codebases. `index_info`
with nothing selected lists the known maps. `swan serve` alone is the same
with `<swan-home>/data` as the root.

## First numbers (2026-10-25, Linux x64, gcc 15.2)

A 2,309-file TypeScript agent harness (a fork of Letta Code), from the
bake-off's `index.scip`:

| Step | Time | Notes |
|---|---|---|
| scip-typescript | ~17 s | bake-off log; full rerun only |
| flatten | 0.6 s | 706,200 occurrences, 93,363 symbols, 15,791 extents |
| `swan index` | 1.25 s | 2,309 files; 135 MB database |
| `swan refresh`, one file edited | 0.23 s | 244 rows rewritten; result identical to a fresh build. 0.22 s of it is reading and fingerprinting all rows, so a no-op refresh costs the same |
| MCP cold start | 4.9 ms | spawn + initialize + first `find_referencing_symbols` |
| `find_symbol` | 0.03 to 0.05 ms median | |
| `find_referencing_symbols` | 1.0 to 2.1 ms median, p95 under 3.6 ms | 260 to 510 references, each with its source line |
| `get_callers`, depth 3 | 20 to 26 ms, fresh process | `getBackend`: 768 symbols in 355 files, 180 of them test files |
| `get_callees` | 0.9 ms, fresh process | 82 symbols used by `createRuntime` |
| `find_implementations` | 5 ms, fresh process | `Backend` interface: 9 implementing classes, several of them test fakes |
| `find_unused_symbols` | 20 ms, fresh process | 166 candidates outside tests; the three spot-checked with ripgrep appear only at their definitions |
| `index_info` with freshness | 2.6 ms | stats all 2,309 files |

These are historical first-slice measurements, not rerun by the standalone
contribution checks. They do not establish parity with Serena or JetBrains.
For reproducible compiler/cache measurements, see [package boundaries](docs/packages.md).

## Build speed

`swan map` runs every language's indexer at once, splits Python into
pieces that index side by side, and reuses what has not changed: a
2,853-file Python repo went from 159 s to 63 s for a first map, 8.8 s after
a one-file edit, and under a second when nothing changed. TypeScript is
split into chunks when it is the long pole (AEON: 18.6 s to 10.1 s).

After an edit, only the changed files and the files that use them are
indexed again, as a small extra run layered over the kept chunks. A big
project with no slot free to split into (on rea Python, Java and C take
all eight) runs as one chunk, so it gets the same layers: there a real
code edit re-maps in 6.6 s (52.6 s before), and an edit to a file 38
others use in 7.3 s. On AEON a one-line edit re-maps in 2.0 s (8.4 s
before), an edit to a file 266 others use in 7.8 s, and an unchanged repo
in 0.07 s. The result matches a fresh map on all but 35 of 713,268 rows
on AEON, those being scip-typescript's own numbering of anonymous types,
which also differs between two fresh maps, and on all but 88 of 1,876,863
on rea (two fresh maps there differ in 22 to 59).

`SWAN_WARM=<language>` or `SWAN_WARM=auto` starts a language server when
`swan serve` starts and opens one file, so the server loads the project
while the agent does other things. Off by default, since a resident server
holds 0.5 to 1.4 GB. Details in `docs/speed.md`.

## Per-language tools

Linters, formatters and test runners are not built in. `tools/modules.json`
lists them per language, with the conditions under which each applies and
how its output is read. Adding a language or swapping a tool is an edit to
that table. Today: ruff, ruff format and pytest for Python; biome and
`bun test` (vitest when configured) for TypeScript/JavaScript; clippy,
rustfmt and `cargo test` for Rust. The same table names the language
servers `swan serve` keeps running for live answers (`live: true`), among
them Eclipse JDT LS for Java: with a trusted repo it imports Gradle and
Maven builds; otherwise it opens the repo as plain folders (source folders
read from the files' `package` lines) inside the eggshell seal, so live
Java errors need no trust. A candidate marked `"sealed": true` runs that way.
Goose is there too: the compiler's own server (`goose lsp`), sealed, told
which files are the repo's programs (those with `fn main`) so a module is
checked as part of its program and not alone.

Go is mapped through [SolidLSP](https://github.com/oraios/serena), Serena's
language-server layer (MIT), which knows how to start, configure and wait for
each language's server: `tools/solidlsp/bridge.py` puts it behind Swan's own
client, sealed like everything else, with Swan's own Go toolchain and gopls
(`SWAN_LANGS=go scripts/fetch-tools.sh`). On spf13/cobra: 36 files, 789
definitions, 5,920 references and what implements each interface, in 7 s.
A Go repo with outside dependencies needs them in Swan's module cache: they
are fetched when the repo is trusted, and used offline after that.

A language with a server and no SCIP indexer can still get an exact map:
`"map": "lsp"` on its entry makes `swan map` run `swan lsp-index`, which
asks the server for every file's symbols and every definition's references
and writes them as a SCIP index. Goose is mapped this way (Swan's own 48
Goose files, 636 definitions and 3,887 references, in 15 s), so
`find_symbol`, `find_referencing_symbols`, `get_callers`, `rename_symbol`
and `edit_batch` work on Goose code. `swan lsp-ask <repo> <out-dir> <file>
<method> [line col] [more]` puts any one LSP request to a file's server.

A question about one symbol's impact (`get_callers`, `get_callees`,
`get_diagnostics`), asked with a name several symbols share, comes back with
the candidates rather than a merged answer.

## Storage and refresh

The map lives in SQLite on disk; queries read the index pages they need.
Short names and name paths are indexed. `swan refresh` fingerprints each
file's rows from a new SCIP run and rewrites changed files in a transaction,
including files whose resolution changed because of an edit elsewhere.
Producing the SCIP input remains a separate cost. The compiler/cache
measurements in [packages.md](docs/packages.md) compare only this Goose
toolchain's own build states, not other languages or package ecosystems.

`swan map` over an existing map reruns an indexer only when code changed
(src/change.goose). Files are stamped by what they hold, not by size and
mtime, so a save that changes nothing is skipped. For TypeScript, JavaScript
and Python the stamp is of the syntax tree with comments and layout left out:
an edit to comments, blank lines or spacing runs no indexer, and Swan moves
that file's rows to where the same code now sits, from a copy of the text
that was indexed (kept in the map folder's `texts/`). Doc comments, `@jsx` and
`@ts-` pragmas and Python's `# type:` comments count as code, since indexers
read them; so does Python indentation. On rea (6,787 files), a comment or
formatting edit to one TypeScript file took a refresh from 51 s to 5.7 s, the
same as a refresh with nothing changed; a real code change still reruns
scip-typescript over the whole program (52 s).

## Historical: the code-map bake-off (2026-10-25)

Kept as a dated record; these numbers were measured once and not rerun.
A separate bake-off compared a Goose in-memory snapshot with Rust + SQLite
on the same SCIP data for AEON. Both matched the TypeScript language server
on all 20 symbols it checked. Rust + SQLite won fresh-process lookups
(0.69 ms against 12.7 ms) because Goose's `from_bytes` verifies and copies
the whole 30 MB image on every start. Swan does not use that snapshot: its
map lives in SQLite on disk, and a query reads only the pages it touches.
On the same machine, `find_symbol getBackend` took 0.62 ms median (0.87 ms
p95) in a fresh process, against the bake-off's 0.69 / 0.83 ms for its own
query mix. The bake-off's two recommendations, lookup by short name and
per-file reindex, are both in Swan.

## Eggs: prebuilt packages, measured and parked

An idea from 2026-10-26: ship Goose packages prebuilt ("eggs", one per
language, such as `python-lsp.egg` or `java.egg`, listed in a registry
called the "nest", each described by an `egg.toml`). Measured: a cold build
of a program using goose-treesitter takes about 8 s and 0.2 s once Goose has
cached it, so prebuilding would save a few seconds once per machine. Parked
until a machine slow to compile or Goose's own prebuilt-package support makes
it worthwhile. A tree-sitter build with one grammar instead of ten took 2.9 s
instead of 7.7 s and made a 1.4 MB program instead of 20 MB; that split waits
for a user who needs only one language. See DECISIONS.md.

## Limits of this slice

- The graph includes non-call uses such as type references. Caller traversal
  excludes rows identified as imports, but is not a precise call graph.
  A class's callees are what its own body uses
  outside its methods; ask about a method for what that method uses.

- Tried with TypeScript, JavaScript (.js/.mjs/.cjs), Python, Rust, Java
  without a build tool, Kotlin through Gradle, and a host-side CUDA fixture
  without nvcc, and a small C# project with a .csproj (`swan map` picks the
  indexers). Go, general C/C++ projects, large C# solutions and Ruby are
  unqualified here. For C#, the map runs `dotnet restore`, which writes the
  project's obj/ folders as a build would.
- Some tools run the repo's own build files, and a repo can run any code
  that way: scip-java with Maven or Gradle, rust-analyzer and cargo (build
  scripts, proc macros), the Kotlin server (Gradle), JDT LS's build import and the C# map and
  server (MSBuild through `dotnet restore`). They wait until you trust the
  repo once: `swan trust <repo>` (kept in Swan's data/trusted-repos). Until then `swan map` and
  `swan check` say what they skipped and how to trust it, and a live
  question to those servers answers the same. The MCP server cannot trust
  a repo by itself. Test runners (`run_tests`) run the repo's code by
  design and are not held back.
- The CUDA fallback does not check device
  compilation. What each tried
  indexer misses is in `docs/parity-and-languages.md`.
- scip-typescript has no per-file mode. A real code change is indexed as a
  layer of the changed files and the files that use them (by the last map),
  over the kept full run; projects under 200 TypeScript/JavaScript files
  (`SWAN_TS_LAYER_MIN`) rerun whole, since that takes a few seconds. A change
  that makes code in a file that used nothing from it resolve differently (a
  newly added global, say) shows up at the next full run, which comes after
  6 layers or once layers cover a quarter of the files. An edit to a file
  the project imports from outside its tsconfig's include reruns the whole
  program. Edits to comments and layout run no indexer. Swan's own part
  is 0.23 s.
- Edits shift the map's positions for the edited file at once (checked against a
  fresh SCIP run in the `edit` suite, `bin/swan-check edit`), but uses inside new code only
  appear after a refresh. Renames cover what the compiler resolved, not
  strings or comments.
- A files table already tracks freshness; occurrence paths are still stored
  as text. Interning them is a possible storage change, not a measured saving.
- Document-local symbols (`local N`) are dropped, as in the bake-off.

## Layout

```
src/swan.goose       CLI: index | query | serve
src/index.goose      builds (atomic: writes .tmp, renames) or refreshes the map
src/change.goose     cosmetic or real edit: code stamps, and moving rows after a cosmetic edit
src/graph.goose      callers and callees
src/scip.goose       SCIP symbol grammar: name, kind, name path
src/query.goose      the tool queries, as JSON
src/serve.goose      MCP JSON-RPC over stdio
src/pipeline.goose   `swan map`: detects languages, runs the indexers, flattens, indexes
src/gradle.goose     reads a Gradle build without running it (modules, Android, the repo's own convention plugins, scip-java tasks)
src/seal.goose       runs children sealed (eggshell); toolchains a sealed child is told about
src/pyplan.goose     splits a Python repo into pieces for scip-python
src/stamp.goose      content stamps, computed one worker per core
src/checkers.goose   `swan check`: compilers and linters, their output parsed into diagnostics
src/lspindex.goose   `swan lsp-index`: a map for a language from its language server (Goose, Go)
src/rustproj.goose   the cargo projects of a repo: which folders rust-analyzer runs in, and its settings
src/tspatch.goose    Swan's fix to its copy of scip-typescript: one name for one object key in every process
src/tsproj.goose     the tsconfig projects of a repo: which config owns each file
src/wings.goose      Spread-Wings from Swan: its graph beside the map, what an edit plan reaches, and the three broad-map tools
src/survey.goose     the survey of a repo's projects (from Spread-Wings): kept as survey.json, said in the report, and where the Go server starts
integrations/hermes/ the Swan plugin for Hermes agents: what an edit broke, in the edit's result
tools/solidlsp/      the SolidLSP bridge, and Swan's stand-ins for the two helpers SolidLSP imports from Serena
src/db.goose         map helpers over the imported SQLite package
src/swan.build       Goose sidecar: native file/process helpers and LSP bridge
native/swan_sys.c    file/process helpers
native/swan-flatten/ the Rust SCIP flattener (bin/swan-flatten); release profile ships, quick profile for trying changes
lsp/                goose-lsp submodule; standalone Goose client + C bridge
wings/              Spread-Wings submodule, pinned to a commit; built as bin/spread-wings and shipped beside swan
tools/              modules.json, external npm tool manifest (the Node indexers and language servers)
tests/               MCP smoke test, refresh-vs-fresh check, latency bench
fixtures/tiny-ts/    a small repo with the tricky cases (re-export, rename, same-name method and function)
skills/swan-code-check/  the agent skill for using Swan (single source; copies follow it, see its PROVENANCE.md)
rust/                the port to Rust in progress (docs/rust-port.md); the Goose program above is what ships. So far the store: main.rs (commands), index.rs, scip.rs, fresh.rs, walk.rs, query.rs, graph.rs, diag.rs, db.rs, sys.rs and util.rs, each carried from the Goose file of its name; and from stage 2, rustproj.rs (`cargo-projects`), gradle.rs (`gradle-tasks`) and pyplan.rs (`plan-python`); from stage 3, treesitter.rs (tree-sitter through goose-treesitter's own C, which build.rs builds from the Goose build's copy, and the structural matcher), structural.rs (`swan query <db> pattern`), syntax.rs (`swan syntax-index`), change.rs (the stamp of a file's code; the rest of src/change.goose comes with editing, at stage 6), stamp.rs (`swan stamp-bench` and `stamp-worker`) and bin/port-trees.rs; from stage 4 so far, modules.rs (what tools/modules.json says of a language, as far as a map reads it), pypatch.rs and tspatch.rs (`swan scip-python-patch` and `scip-typescript-patch`), run.rs (Swan's home and running a step), json.rs (reading JSON, from Goose's own stdlib/json.goose), seal.rs (running a step sealed), wings.rs (where spread-wings is), survey.rs (the survey of a repo's projects), tsproj.rs (which tsconfig owns each TypeScript file), gsort.rs (Goose's own sort, from its stdlib/std.goose: it is unstable, and a plan of TypeScript's chunks holds the order it leaves files of one size in) modules.rs (what tools/modules.json says of a language's server), edit.rs (where a line and column sit in a text, and the mark of a file Swan changed; the edit commands are not in Rust yet), pipeline.rs (`swan trust`, and the whole of `swan map`: it plans, runs and waits for the indexers, flattens and stores; `swan doctor` is in main.rs), lsp.rs (a language-server client: a server started, sealed when its entry says so, asked with a time limit on every answer, keeping what it says unasked (published diagnostics, work in progress, its status), and killed with all it started when done, or by a watcher in its process group when swan itself is killed), lspindex.rs (`swan lsp-index`: a SCIP index made by asking a language's server, named as src/lspindex.goose names it), live.rs (`swan lsp-ask`, and the live server both live commands ask: one language's server for one repo, a file read from disk and sent once, each entry's settle (publish, quiet, pull, check) as a rule, while rust-analyzer says its health is not ok, its errors passed on and a file with none not settled, one time budget per command, 100 s or SWAN_LIVE_BUDGET_MS, and files outside the repo refused before a server starts) and broke.rs (`swan broke`: the errors new in the files since last asked, one server per language in turn, the Goose program's JSON and broke-seen.tsv, the seen file under a lock; exit 0 nothing new, 1 new errors, 3 a file could not be asked, 2 usage)
rust/tests/live.rs   swan lsp-ask and swan broke against a scripted server (rust/tests/fake_lsp.py): each settle settles on what it should and not before, a silent or dying server is never a clean answer, files outside the repo are refused, the seen file, its lock and the exit codes, and no server outlives a swan killed with SIGKILL
rust/tests/live_servers.rs  the same two commands with the real servers on copies of Swan's fixtures: Lua, Go (through SolidLSP, sealed), Python, TypeScript and Rust (tiny-rs, trusted): a clean file, a planted error, a definition in another file
rust/tests/lsp_languages.rs  swan map, sealed, on fixtures/lsp-lua and fixtures/lsp-php (two files each, cases a match by name gets wrong): their rows come from the language servers through SolidLSP (lua-language-server, PHPantom); what a Lua function declares inside it is not mapped; when Lua's server fails or is not fetched, its files get their by-name rows in the same map; a server fetched again maps again. Which languages are mapped this way, which were tried and left by name, and why: docs/languages-through-servers.md
scripts/port-compare.sh  one swan command run by the Goose program and by the Rust port: output, error text and exit code compared
scripts/port-store.sh    the store's comparison: the same map (table hashes), the same refusals, the same staleness, the same answers
scripts/port-tables.sh   a map's schema and tables as row counts and hashes
scripts/port-prove.py    the store's comparison seen failing: nine copies of the Rust program, each broken in one place on purpose, each to be caught
scripts/port-plan.sh     stage 2's comparison: the planning commands on the fixtures, made-up repos and any repos given (cargo-projects under three rustup homes)
scripts/port-prove-plan.py  stage 2's comparison seen failing: copies of the Rust program broken on purpose, each to be caught
scripts/port-trees.sh    stage 3's first comparison: every file with a grammar parsed by both programs (scripts/port-trees.goose, rust/src/bin/port-trees.rs), the trees compared by bytes
scripts/port-pattern.sh  stage 3's comparison for structural search: patterns asked of a made-up repo in all 17 languages and of any maps given
scripts/port-prove-pattern.py  that comparison seen failing: copies of the Rust program broken on purpose, each to be caught
scripts/port-syntax.sh   stage 3's comparison for the syntax-level index: `syntax-index` on a made-up repo in its five languages, on the fixtures, this repository and any repos given; the two index files compared by bytes
scripts/port-prove-syntax.py  that comparison seen failing: copies of the Rust program broken on purpose, each to be caught
scripts/port-stamp.sh    stage 3's comparison for the stamps: `stamp-bench` and `stamp-worker` with one process, worker processes and threads; the stamp lines and the kept texts compared
scripts/port-prove-stamp.py  that comparison seen failing: copies of the Rust program broken on purpose, each to be caught
scripts/port-patch.sh    stage 4's comparison for the indexer patches: `scip-python-patch` and `scip-typescript-patch` on the three files they patch and on files they must refuse; the file left compared by bytes and permissions
scripts/port-prove-patch.py  that comparison seen failing: copies of the Rust program broken on purpose, each to be caught
scripts/port-run.sh      stage 4's comparison for running a step: `trust` and `doctor` from a made-up home for each program, with a made-up `mkdir` and doctor.py to show what a step is given, its exit code, its output, a signal and the deadline
scripts/port-prove-run.py  that comparison seen failing: copies of the Rust program broken on purpose, each to be caught
scripts/port-json.sh     stage 4's comparison for reading JSON: made-up texts and the repo's .json files read by Goose's json::parse (scripts/port-json.goose) and by the Rust reader (rust/src/bin/port-json.rs), the dumps compared by bytes
scripts/port-prove-json.py  that comparison seen failing: copies of the Rust reader broken on purpose, each to be caught
scripts/port-sort.sh     stage 4's comparison for sorting: lists made up to take each way through Goose's sort, sorted by it (scripts/port-sort.goose) and by the Rust copy (rust/src/bin/port-sort.rs), the orders compared by bytes
scripts/port-prove-sort.py  that comparison seen failing: copies of the Rust sort broken on purpose, each to be caught
scripts/port-map.sh      stage 4's comparison for `swan map`, as far as it is carried: each program maps made-up repos and some fixtures from a made-up home of its own, the cases side by side; what the Rust program says, writes and leaves in its home so far against the Goose program's, which is kept in build/port-map/
scripts/port-prove-map.py  that comparison seen failing: copies of the Rust program broken on purpose, each to be caught
```

## License

MIT (`LICENSE`). The vendored SQLite is public domain; see `NOTICE`.

## Credits

- Tool names, arguments and name-path matching follow
  [Serena](https://github.com/oraios/serena) by Oraios AI. No Serena code or
  text is copied. SolidLSP, Serena's MIT-licensed language-server library,
  is fetched as an installed tool for Go and run behind `tools/solidlsp/bridge.py`. Serena's tools live in its GPL-3.0-or-later application
  (only its SolidLSP library is MIT), so Swan follows the interface only. See
  `NOTICE`.
- [SQLite](https://sqlite.org) is in the public domain.
- [SCIP](https://github.com/sourcegraph/scip) and scip-typescript are by
  Sourcegraph, Apache 2.0; Swan uses scip-typescript as a tool and reads the
  SCIP format.
- [Goose](https://github.com/aardappel/goose) by Wouter van Oortmerssen.

See `docs/parity-and-languages.md` for a tool-by-tool comparison with Serena
and what other languages would take.
