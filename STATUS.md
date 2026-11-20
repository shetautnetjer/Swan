# Swan status

as_of: 2026-11-07

This is a chronological development log. Earlier "not done" statements,
private-repo timings and "all tests pass" entries describe their original
runs, not the current contribution's validation. The current standalone
test/demo scope is in docs/demo.md and package boundaries in docs/packages.md.

## State: experiment, first slice working

- Built: `bin/swan` (Goose v2026.3 → C → gcc 15.2, SQLite 3.54.1 vendored).
- Verified: `scripts/test.sh` passes (build, map `fixtures/tiny-ts`, drive the
  MCP server over stdio: initialize, tools/list, all four tools, unknown method).
- Verified at scale: a 2,309-file TypeScript repo's SCIP index (from the
  code-map bake-off, read only)
  maps in 0.6 s flatten + 0.75 s `swan index`; MCP cold start 4.9 ms;
  `find_referencing_symbols` 1 to 2 ms median for 260 to 510 references.
  Map under `data/` (not in git).
- Not verified: correctness against Serena on that repo (the bake-off checked its own backends: 20/20),
  any language besides TypeScript, incremental refresh.
- Not done: registered as an MCP server for AYA (no AYA config was changed).

## 2026-10-25 (later): roadmap steps 1 and 2

- Call graph: `get_callers` (impact radius to depth 5, test flags, summary)
  and `get_callees` (with dependency package versions). Covered by the MCP
  smoke test. AEON depth-3 impact: 20 to 26 ms.
- Per-file refresh: `swan refresh` / `scripts/refresh-repo.sh`. Schema 3
  (files table with row fingerprints; ids stable across refreshes).
  `tests/refresh_check.sh` edits the fixture, reruns SCIP, and checks the
  refreshed map equals a fresh build. On AEON a simulated one-file edit
  refreshed in 0.23 s and matched a fresh build on all 802,618 dumped rows.
- Published: github.com/shetautnetjer/Swan (public, MIT).

## 2026-10-25 (later still): implementations and type hierarchy

- Flattener writes `relationships.tsv` from SCIP relationships; schema 4
  adds a `relationships` table, refreshed per file like occurrences.
- Tools `find_implementations`, `get_type_hierarchy`; smoke test and
  refresh check cover them. AEON: 471 relationships; `Backend` has 9
  implementations (5 ms).

## 2026-10-25 (night): freshness and unused code

- `stale: true` on any answer whose file changed after the SCIP run
  (`scip_time` in meta = index.scip mtime; stat via the C shim);
  `index_info` lists stale files.
- `find_unused_symbols`: AEON 166 candidates outside tests, 20 ms; three
  spot-checked with rg are referenced nowhere else.

## 2026-10-25 (late): Python and Rust

- scip-python 0.6.8 and rust-analyzer 2026-10-19 wired in through
  `scripts/scip-run.sh` (since replaced by `swan map`; language detection, empty pip env, Node heap,
  CARGO_TARGET_DIR kept out of the repo). Schema 5 adds `symbols.language`;
  kinds are portable across languages.
- Tested on two private repos: a Python research repo, and a copy of a
  Rust workspace (Rust + Python). Their maps live under data/private/
  (gitignored, never pushed). Findings, without private
  content, are in docs/parity-and-languages.md.

## 2026-10-25 (late night): editing by symbol

- `replace_symbol_body`, `insert_after_symbol`, `insert_before_symbol`,
  `rename_symbol` (plan, then apply). Schema 6: body columns, and
  `files.edited_mtime` so Swan's own edits are not "stale".
- `tests/edit_check.ts` edits a fixture copy, runs tsc, and checks every
  position Swan shifted matches a fresh SCIP run.

## 2026-10-25 (late night): better Rust

- Trait impls recovered from rust-analyzer symbol names in the flattener;
  impl members named by type; `include_members` on find_referencing_symbols
  (CLI `uses`); macro-argument uses matched by name (`by_name`, schema 7).
- `fixtures/tiny-rs` + the `rust` suite (`tests/check/rust_suite.goose`; was `tests/rust_check.ts`). On the private Rust workspace
  types are now found on every line ripgrep finds them (excluding lines that
  are really other crates' same-named types).

## 2026-10-25 (late night): diagnostics

- `tools/diagnostics.ts` (since replaced by `swan check`) + `swan diagnostics` +
  `get_diagnostics` with caller depth; `scripts/diagnose-repo.sh`.
  `tests/diag_check.ts` breaks fixture copies (TS and Rust) and checks the
  errors land in the callers. Design notes: docs/diagnostics.md.

## 2026-10-26: Goose runs the pipeline; Python done properly; JS without tsconfig

- C shim gains `swan_run` (fork/exec, pipes, timeout) and realpath; Goose
  orchestrates `swan map` and `swan check`, also exposed as the MCP tools
  `update_map` and `check_errors`. scip-run.sh and tools/diagnostics.ts are
  gone; the scripts now call swan.
- Python: venv detection, importlib.metadata package list when pip is
  missing, pyright 1.1.414 diagnostics. fixtures/tiny-py + tests/lang_check.ts.
- JS: .js/.mjs/.cjs repos without a tsconfig mapped with a generated one
  outside the repo. fixtures/tiny-js.

## 2026-10-26: speed pass

- Parallel indexers (swan_spawn/swan_wait_any), Python split into
  --target-only pieces, per-piece and per-language reuse by fingerprint
  plus dependents from the last map, no-change shortcut. Flattener
  re-roots paths from SCIP metadata and drops repeated documents.
  Numbers in docs/speed.md.

## 2026-10-26: JetBrains-style gaps

- Exact targets for impact questions; imports found from source and left
  out of callers; get_symbol_at with docs (schema 9); per-language tool
  modules (tools/modules.json): ruff/biome/clippy lint, format_file,
  run_tests. Compared with WebStorm's MCP on live AEON (read-only).

## 2026-10-26: live answers from rust-analyzer, as a separate Goose library

- The language-server client (now `lsp/golsp.goose`) is compiled on its own
  (`goose --standalone`) to `build/golsp.c` and linked through
  `lsp/native/glue.c`; scripts/build.sh regenerates it when lsp/ changes.
  Two Goose runtimes share the binary; nothing crosses but slices.
- `get_diagnostics` and `find_implementations` take `live: true`: swan serve
  keeps rust-analyzer running (tools/modules.json "lsp") and answers from it.
- Measured: core build after a core edit 4.34 s (4.16 s before: flat); after
  a library edit 17.4 s (gcc on 650 KB of C, rare). tiny-rs: a new E0061
  seen 0.40 s after asking; a new impl seen live while the map has the old
  two. A private Rust workspace (copy): RA ready 9.5 s, E0308 seen 0.52 s after an
  edit, live impls = SCIP impls (same 4; live points at the impl blocks,
  SCIP at the types), RA ~1.1 GB resident, stopped when serve exits.
- Parallel indexing now also caps jobs by free memory (about 3 GB a job).
- Same evening: pyright and typescript-language-server (6.0.2, pinned) in the
  same library, configured in tools/modules.json; a server that publishes
  is waited on per file ("settle": "publish"), rust-analyzer on its check.
  tiny-py: a pyright reportReturnType error 0.57 s after asking; tiny-ts:
  TS2322 0.66 s. Asking about another language swaps the server.
- Limits: one live server per process (swapped by language); files edited elsewhere are seen by
  rust-analyzer's own watcher, the asked file is always resynced.

## 2026-10-26: structural search and rewrite (tree-sitter, ast-grep style)

- `search_pattern` and `rewrite_pattern`: patterns with `$X`, `$$$X`, `$_`,
  matched on tree-sitter trees with ast-grep's default ("smart") rules.
  pkg/treesitter is a Goose package: the runtime and 9 grammars (npm
  tarballs, pinned by sha256 in fetch-tools.sh) compile once and are cached;
  ts_shim.c hands trees to Goose as flat int arrays (no TSNode crosses) and
  parses batches on up to 16 threads.
- Checked against ast-grep 0.45.3 (tests/structural_check.ts, a ledger of
  cases): same matches on the fixtures, on AEON (read-only; e.g. 15465
  `await $X`, 18614 `return $X`) and on private Python and Rust copies. The
  only differences are in files .gitignore names, which ast-grep's walk
  skips and Swan reads. CUDA has no ast-grep grammar; checked by hand.
- Speed on AEON (2358 files): search_pattern runs on a pool of Goose
  worker threads (thread_fn + typed queues, up to 16; each copies the
  compiled pattern at the spawn): 0.05 s for a pattern with a rare word
  (files without the pattern's words are never parsed), 0.27 to 0.33 s when
  every file must be parsed and 16 to 20 thousand matches written out (was
  0.7 s single-threaded); ast-grep takes 0.1 s on 32 threads. Core build after
  a core edit 5.0 s (4.3 s before), the matcher being Goose in the core.

## 2026-10-26: Kotlin, step 1 (structural search)

- The Kotlin grammar (@tree-sitter-grammars/tree-sitter-kotlin 1.1.0, MIT,
  pinned in fetch-tools.sh) is in pkg/treesitter. A Kotlin-only repo maps
  to an empty map (no SCIP indexer runs yet), so search_pattern and
  rewrite_pattern work on .kt/.kts.
- A pattern node holding only punctuation and a $$$ run (`{ $$$B }`) may
  match a node of another kind: Kotlin parses `{ __swan_mvm_B }` as a
  different node than a class body.
- fixtures/tiny-kt: same matches as ast-grep on 5 Kotlin cases. On
  android/nowinandroid (350 .kt files): equal counts on 4 patterns in about
  0.01 s each; `@Composable fun $F($$$P) { $$$B }` finds 80 where ast-grep
  finds 75, the 5 more being composables whose parameter lists end with a
  trailing comma, which ast-grep's `$$$P` does not take.

## 2026-10-26: Kotlin, step 2 (live answers from kotlin-lsp)

- JetBrains' standalone Kotlin language server 263.7084.0 (its own JBR,
  1.5 GB in .tools/kotlin-lsp, sha256-pinned in fetch-tools.sh) is the
  Kotlin "lsp" entry in tools/modules.json, run with --stdio and its caches
  under the map folder (--system-path). Gradle's home is .tools/gradle-home,
  whose daemons quit after 10 idle minutes and keep to 2 GB.
- It imports the Gradle build before it analyses anything; the swan-lsp
  library now waits for that (intellij/importLog), up to 15 minutes, and
  reports import_failed.
- tiny-kt: the first call took 169 s (Gradle fetching itself and the
  Kotlin plugin, 324 MB, once), later sessions start in about 5 s. An
  INITIALIZER_TYPE_MISMATCH error came back 5.6 s after the edit on the
  first analysis and 0.9 s on the next. The server takes about 1.4 GB.
- proc.c starts servers in their own process group and kills the group on
  close: the Kotlin launcher runs its JVM as a child, which otherwise
  outlived swan serve. The Gradle daemon is in a session of its own and is
  left to its idle timeout.

## 2026-10-26: Kotlin, step 3 (the full map through Gradle)

- `swan map` runs scip-java on Kotlin Gradle projects too (it indexes Java
  and Kotlin), with Swan's Gradle home and, once its license is accepted,
  Swan's Android SDK (.tools/android-sdk; Mani accepted Google's terms
  himself). Configuration cache and isolated projects are turned off for
  the run (scip-java's init script cannot run with them), the build JVMs
  keep to 3 GB, and scip-java's `clean` rebuilds the repo's build/ output.
- tiny-kt (Kotlin 2.4.21): mapped in 5.6 s warm, about 1.2 GB peak;
  find_implementations and get_callers answer from it. Kotlin symbols are
  labelled kotlin by their file.
- android/nowinandroid does not index yet: it uses Kotlin 2.3.0, and
  scip-java 0.13.2's Kotlin compiler plugin follows Kotlin 2.4
  (ClassNotFoundException: ExtensionPointDescriptor in kotlinc). A project
  on current Kotlin works; Mani's new app will start there. Its Gradle
  build otherwise ran (3.6 min first time, 3.5 GB peak).

## 2026-10-26: the reusable parts as Goose packages

- goose-sqlite (SQLite + shim), goose-treesitter (tree-sitter, grammars as
  pinned submodules, the matcher and worker pool) and goose-lsp (the
  language-server client) are their own public repos, tagged v0.1.0
  (goose-treesitter v0.1.1: the CUDA grammar is copied in, because its
  repository's nested submodule breaks a recursive clone). Swan imports the
  first two by tag (goose fetches them into its cache and builds their C
  once) and has goose-lsp as the lsp/ submodule, compiled standalone.
- Goose has no registry: a package is a git repo and a tag.
- A fresh build fetching both packages took 69 s; a core edit builds in
  5.0 s, as before. All tests pass.

## Contribution preparation (2026-10-26)

The bounded contribution adds standalone library checks, an offline Swan
demo and reproducible compiler/cache measurements, and corrects stale
architecture descriptions. It preserves existing APIs, language-server
processes and Goose's repository/ref packaging. No deployment or upstream
publication is part of this work. See docs/contribution-proposal.md.
The local validation record is docs/validation.md; it distinguishes passed
checks from the complete integration suite that was not rerun.

## 2026-10-26 (evening): speed, warm servers, validation merged

- TypeScript edits reindex only the changed files and their users (AEON
  one-line edit: 2.0 s, was 8.4 s); `SWAN_WARM` starts a language server
  early (first live answer 0.7 s, was 3.6 s); search_pattern 0.14 s.
- Mufasa's standalone validation merged: library tests (SQLite 43,
  tree-sitter 52, goose-lsp 11 against a mock server), an offline Swan demo
  and a build benchmark script. Rechecked on merged copies, plus the full
  suite with the real servers, Kotlin and the ast-grep ledger.
- Libraries released: goose-sqlite v0.1.1, goose-treesitter v0.1.2,
  goose-lsp v0.1.2 (output read on a thread, an `open` question).
- Eggs measured and parked (DECISIONS.md).

## 2026-10-26 (night): fixes from the Greptile review

Greptile (through Composio) reviewed main at b429ce7 on a review-only PR
(Swan#1, closed). Its 14 Swan findings, checked against the source, are in
~/aya/sandbox/briefs/SWAN_GOOSE_GREPTILE_REVIEW_20261026.md. Fixed on
branch fix/greptile-review:

- Edits move the map by (line, column), so code after an edit on the same
  line follows it; symbols defined inside replaced code are dropped until
  the next refresh; a rename moves only the sites it wrote; a rename to a
  name no language accepts (`123`, `foo-bar`) is refused.
- `rewrite_pattern` moves the map for each cut instead of marking the file
  fresh with old positions.
- A Swan edit clears the file's fingerprint, so the next refresh rebuilds
  its rows whatever SCIP says; the fingerprint also covers the symbols'
  docs and signatures (one full refresh after upgrading).
- `run_tests` no longer reloads freshness (it doubled the repo path and
  then refused every edit); `update_map` reloads it (the new SCIP time).
- `check_errors` keeps the saved diagnostics when a checker could not run
  (missing, timed out, killed) instead of reporting a clean result.
- `swan_run` keeps its deadline after the program closes its output.
- TypeScript layers are used only while tsconfig, package.json and the
  declarations are unchanged; a failed Python piece is not reused.
- The flattener drops typeLiteral counters only in a symbol's unquoted
  parts, so a file named typeLiteral1.ts keeps its name.
- Tests: tests/edit_check.ts (same-line edits, a dropped method, bad
  names, edit after run_tests) and tests/structural_check.ts (edit after a
  rewrite that adds lines). These fail on b429ce7 and pass on the fix.
  Not covered by a test: the check_errors, timeout, tsconfig, Python-piece,
  typeLiteral and doc-fingerprint changes (reviewed by reading only).

## 2026-10-27: game and 3D languages, wave 1

- Pattern search for Lua, GLSL, HLSL, WGSL, GDScript, C# and PHP (goose-treesitter,
  107 package checks); the ast-grep ledger agrees on C#, Lua and PHP, and
  the shader and GDScript cases are checked by hand.
- Live errors through real servers, each in .tools and pinned in
  fetch-tools.sh: clangd 23.1.0 (C, C++), lua-language-server 3.19.2,
  shader-validator's server 1.6.2 (GLSL, HLSL, WGSL), and pyright with
  Blender 5.0 stubs (fake-bpy-module-5.0 20260730). tests/game_live_check.ts:
  each deliberate error came back in 0.3 to 0.6 s.
- goose-lsp answers after `quiet_ms` of silence for servers that publish
  nothing on a clean file (lua-language-server): 4 s instead of 120 s.
- Lua, shaders, GDScript, C# and PHP have no SCIP indexer here yet: a repo
  of only those maps to an empty map, searched and checked live.

## 2026-10-27: C#, wave 2

- The .NET SDK 10.0.402, csharp-ls 0.28.0 and scip-dotnet 0.2.14 live in
  .tools (pinned in fetch-tools.sh; dotnet's homes and NuGet's cache too).
- Full map for C#: `swan map` runs scip-dotnet when a .sln, .slnx or
  .csproj is at the repo root. scip-dotnet gives no body ranges, so the
  flattener finds method bodies by braces, as for C++; without that,
  callers come back empty (checked by removing it). Generated obj/ files are
  left out of the map, and obj/ is skipped like build/. fixtures/tiny-cs
  maps in about 1.6 s; scip-dotnet's `dotnet restore` writes obj/ into the
  repo, as a build would.
- Live C# errors through csharp-ls: the deliberate error came back in about
  0.5 s; the first, clean check takes about 2.5 s while it loads the project.
- tests/game_live_check.ts covers both; the full suite passes.

- Review follow-up: the body finder handles C# `=>` methods and verbatim and
  raw strings. Tools that run a repo's own build files (scip-java with Maven
  or Gradle, rust-analyzer scip, cargo check and clippy, the Rust, Kotlin
  and C# servers, scip-dotnet) now wait for `swan trust <repo>`
  (Mani's decision, 2026-10-28); `scripts/test.sh` sets SWAN_TRUST_BUILD=1
  for the fixtures, and game_live_check checks the untrusted path too.
  Existing maps of Rust, Gradle, Maven or C# repos need one `swan trust`
  each before their next map.

## 2026-10-31: one server answers about any repo

- `swan serve --maps <data-root>` (bare `swan serve` uses `<swan-home>/data`)
  starts with no repo selected; `swan serve <db>` is unchanged.
- New tool `use_repo` (`path`, `build?`): finds the map for a repo path or a
  path inside it by matching the `root` each `<data-root>/*/swan.db` records
  (DECISIONS.md), builds it with `swan map`'s rules when there is none —
  trust holds reported as `skipped` — closes the old map, stops the live
  server, opens the new one, and warms lazily on the next call. Returns
  `root`, `map`, `symbols`, `files`, `built`, `stale_file_count`, `skipped`
  and the timed map `report`.
- Every tool takes `repo`: a switch for that call (and after) on top of the
  same machinery. With nothing selected the tools say to call `use_repo` or
  pass `repo`, and `index_info` lists the known maps.
- tests/maps_check.ts drives `swan serve --maps` over stdio: the guidance
  error, building and switching between tiny-ts and tiny-rs, a per-call
  `repo`, an inside-the-repo path, missing path and `build:false` refusals,
  and `swan serve <db>` unchanged. Both mutation checks run: no-switch
  fails the tiny-rs checks, exact-match-only fails the inside-path check.

## 2026-11-01: files added after a build count as stale

- `index_info` and `use_repo` now count files added since the map was built
  in `stale_file_count`. Such a file is in the repo (walked with `swan map`'s
  skip list), absent from the map, has an ending the map already holds files
  of, and was written after the SCIP run. `index_info` lists these files in
  `stale_files` and adds `new_file_count`. Before this, `is_stale` only
  checked mapped files, so a new file was missing from every answer while
  the map said stale 0. Seen twice: AEON's new
  `app-server-openai-chat-key-store.ts` was absent from
  `acquireDurableFileLock`'s references, and evolve's map missed 5 files
  after #16 merged.
- Languages the map never indexed (no indexer, or waiting for `swan trust`)
  don't count. A file the indexers leave out on purpose shows only until
  the next refresh moves the SCIP time past it.
- tests/mcp_smoke.ts: a new `.ts` file is stale and new. A new `.lua` file
  (no Lua in the map) and `node_modules/dep/index.ts` are not. All three are
  gone after removal. Mutation: `new_files` returning 0 fails the check.
  `scripts/test.sh` passes.
- Cross-checked on the live maps against an independent Python walk:
  evolve has 5 new files (the #16 merge), AEON 0. `index_info` on AEON
  (2,716 files walked) takes 7 ms.

## 2026-11-06: live-Python fix verified; platform support documented

- PR #11 (`821474f`, merged November 2) already contains the live virtualenv
  trust guard. The installed Linux executable was independently checked on
  November 6 using real Pyright 1.1.414: untrusted, process-only trusted
  control, then fresh untrusted sessions returned the deliberate type error;
  only the trusted control ran the planted interpreter. Production binary,
  module configuration and trust-list hashes stayed unchanged. No rebuild
  or production configuration change was needed for this documentation work.
- README now identifies the fix, source-versus-binary distinction, safe test
  isolation, global trust override and unresolved trust-list concurrency
  concern. It also states Linux x86-64 implementation scope, setup/layout
  requirements and the unqualified Windows/macOS/ARM64 targets.
- `docs/packages.md` contains a portability proposal and target acceptance
  checks. No host port is implemented or approved by this documentation
  change. Next: review the proposal before detailed design or implementation;
  qualify clean-machine Linux setup before making broader support claims.
- This change affects documentation only. Verification: source/evidence
  comparison, Markdown local-link/anchor checks and `git diff --check`.
  Full build/integration suites are not rerun for documentation-only edits.

## 2026-11-06: fresh-install investigation and package proposal

- A fresh Swan checkout at `583e665` in CUA's Ubuntu 24.04 x86-64 VM
  fetched Goose v2026.3, the LSP submodule and native packages into a private
  initially empty cache. No host Swan executable or compiled cache was copied.
  The existing VM supplied GCC 13.3, Python 3.12.3 and Node 24.21.0.
- Unmodified source failed: Swan's C helper omits `<stdbool.h>`. Correcting
  it in the lab exposed the same defect in `goose-sqlite@v0.1.2/src/gsq.c`.
  Two local include corrections produced a working candidate. The SQLite
  change is experimental cache content, not a published package fix; both
  fixes must reach their owning sources and the dependency pin before release.
- Fresh locked npm installation and lab-local Bun 1.3.14 succeeded. Candidate
  SHA-256: `2fe81c794cc411457015f9e58943b4d8c21ae0b32444aa5eeabbf3fe72b7f1e0`.
  It passed 24/24 skill pattern checks, 11 offline assertions, and real Python
  diagnostics with false/true/false repository-interpreter markers. Pattern
  tests do not by themselves validate SCIP definition/reference correctness.
- Source/logs/patches/results: `docs/evidence/swan-install-2026-11-06.json`.
  Guest work retained at `/home/cua/swan-fresh-NHb1m01M`; the VM was returned
  to its stopped state. Host installed Swan/configuration/trust remain untouched.
- PRD/HLD appended to `docs/packages.md`: a user-space Linux x86-64 package,
  dependency checker, selected tool installation, and a portable revision of
  the existing skill. No new installer/doctor/skill behavior is implemented.
  Next owner/action: Khamani approves or revises this scope; implementation then
  fixes both source owners, builds the package, verifies the selected profiles
  and copied skill, and obtains independent review before release acceptance.

## 2026-11-06: Linux package implemented and qualified in CUA

- The approved candidate implements archive export, a staged new-prefix
  installer, read-only `swan doctor`, private Node/Bun dependencies, and the
  portable existing skill. SQLite's source header fix merged in goose-sqlite
  PR #4; Swan pins immutable commit `80a4e713`. Swan's header is fixed too.
- Tested source: `bae3873bfd8dfecae5eb5ab64bf0cf45bde9998f`, clean checkout,
  Goose v2026.3 and GCC 13.3, Ubuntu 24.04 x86-64/glibc 2.39. The private
  dependency cache fetched the corrected source; no dependency cache patches
  were used. Build/archive/install receipts and hashes are in
  `docs/evidence/swan-package-2026-11-06.json`.
- The actual archive installed into a new path with spaces, downloaded private
  Bun, reused compatible system Node/npm, installed the locked npm tools, and
  passed its offline demo. Moving the entire tree preserved dependency checks
  and real Python/TypeScript mapping, known definitions/references and live
  clean/error/fixed diagnostics. A separately copied skill passed 24/24 patterns.
- The Bubblewrap-isolated Python regression passed real diagnostics with
  interpreter markers false/true/false. No persistent trust grant was needed.
  A separate core-only installation passed; wrong hashes, existing prefixes,
  doctor home-argument abbreviation and missing selected dependencies failed
  as expected. Local checks: 18 installer/doctor, 10 archive, 7 skill portability.
- Host production executable, trust list and module configuration matched
  their pre-test SHA-256 snapshots. The active installation was not replaced.
  No agent configuration or public binary release was created. Trust-list
  concurrency remains a separate known limitation; serialize trust grants.
- Stage: implemented, installed and qualified for these bounded CUA checks;
  not accepted as a production replacement or cross-platform public release.
  Next: review PR #13 and this evidence; any host activation or public binary
  distribution is a separate decision. Native Windows/macOS/ARM64 remain ports,
  and WSL and other Linux distributions need their own tests.

## 2026-11-06: PR #13 review correction

- Confirmed review comment `4493026973`: a successful `--map-swan` command
  producing no map could be masked by `search_pattern` implicitly building
  another map. The self-test now selects with `build:false`, requires the
  exact existing `out/map/swan.db`, and keeps pattern calls on that selection.
- CUA reproduction used `/usr/bin/true` as a builder returning success without
  output. Before: false 24/24 pass with a replacement `fixture/swan.db`. After:
  exit 2, no replacement map. The real builder still passed 24/24 against
  `map/swan.db`. Evidence: `docs/evidence/swan-pr13-review-2026-11-06.json`.
- Preserved CodeRabbit's concurrent fix commit `26edbfc` and its three
  regression tests, adapting them to the stricter map-selection helper.
  Added four regressions: map identity/no-build selection; missing, wrong,
  rebuilt and malformed results; no repository reselection; no searches after
  a builder leaves no usable map. Local checks pass 28 packaging tests and
  14 skill tests. Added function documentation in response to the review's
  docstring coverage warning; those edits preserve executable AST behavior.
- This changes the source self-test and documentation, not the Swan native
  executable or production state. The previously shared candidate archive
  remains the recorded `bae3873` artifact and predates this review fix; export
  a new candidate from the final reviewed revision before release.

## 2026-11-06: ordered improvements approved

The owner approved tests and merges for the sequence in
`docs/improvements-2026-11-06.md`: skill coverage/refresh guidance, matcher
correctness, concurrent-map qualification, Goose-language investigation, then
measured optimization. Stage 1 now distinguishes structural/index/live
coverage, batches refresh across coherent edits, checks branch/worktree and
compiler-input changes, and reports actual verification limits. Skill format,
relative links and whitespace checks pass; executable behavior is unchanged.
The active installation and saved trust remain outside these source merges.

## Remaining work

1. Qualify real server adapters and indexers separately from the mock LSP
   and synthetic-row tests; existing integrations need their full toolchains.
2. Dependency listing, git churn, broader language coverage and stronger
   refactoring semantics remain candidates, not completed features.
3. Grammar-specific native packages and an importable LSP facade need a
   design decision supported by build measurements; see docs/packages.md.

## 2026-11-06: ordered stages 1–3 evidence and Goose investigation

This entry supersedes the earlier ordered-improvements progress statement
that matcher work and concurrency execution were still pending.

- Stage 1 merged in Swan PR #13 (`b569146`). The portable skill describes
  actual structural/index/live coverage, refresh triggers/batching and
  verification limits. Stage 2 merged in goose-treesitter PR #5 (`590107`)
  and Swan PR #14 (`b3bd50c`); the matcher receipt is
  `docs/evidence/swan-matcher-2026-11-06.json`.
- Stage 3 is implemented and qualified for bounded Linux local-filesystem
  checks, with Swan PR #15 still open at candidate
  `ef03ba0e13e357316e318a2384b58c5ec0b222d3`. CUA binary SHA-256:
  `597dd20e6b58919a703249e9f77c55783a2c2a04a7a8d8bd66739b7617b4a5f8`.
  Passed 9/9 concurrency scenarios, five reader regressions, 36 local
  package/native tests including eight locks, 24/24 skill patterns and real
  Python/TypeScript definition/reference/live checks. Independent review
  identified orphaned child writes and database-file symlink identity;
  inherited lock descriptors and file-symlink refusal address those cases.
- `docs/concurrency.md` records writer serialization, read snapshots,
  persistent lockfiles, explicit contention/retry and possible server restart.
  Concurrent stateful operations outside that contract, saved trust-list
  races, Windows/macOS, network filesystems and power loss remain unqualified.
  Source qualification is not a production replacement or a public release.
- Stage 4 remains investigation: official Goose v2026.3 already supplies a
  grammar and LSP source; the actual CUA `lsp --probe` returned
  `goose lsp 3.17`. No Swan Goose adapter is implemented. Grammar generation,
  live semantics/execution boundaries and full semantic-map export still
  need their own acceptance checks.
- Stage 5 completed on the same candidate: 120 generated files/language,
  14 map calls; definitions/references, unchanged equality, incremental=fresh
  equality for both languages and MCP checks passed. TypeScript cold/unchanged
  median/edit/new-file times were 0.467/0.03148/0.464/0.515 s; Python was
  1.566/0.16379/0.815/0.865 s. Database load was 6–23 ms versus 388–766 ms
  reported indexer work. On 50,000 rows, 20 warmups plus 200 checked reader
  calls per binary measured median 0.085969 ms before versus 0.168354 ms after
  the concurrency change (0.082385 ms increase; new p95 0.21576 ms).
  Database/source bytes were unchanged. No additional optimization is justified;
  retain the correctness fix and existing reuse. CUA run references:
  `swan-runtime-bigun36h/summary.json` and
  `swan-reader-latency-y32vjttc/summary.json`.
- The final isolated real-Python trust regression passed deliberate diagnostics
  and interpreter markers false/true/false (`swan-verify-_azjgets`); the saved
  trust file remained absent and unchanged. This does not qualify trust-list
  concurrency. Next: finish PR #15 review/merge checks and preserve the bounded
  qualification evidence. Active installations, saved trust and agent/module
  configuration are unchanged.

## 2026-11-06 — Review completion and fresh CUA qualification

This supersedes the earlier stage-3 candidate's qualification for current
source; its results remain historical. PR #15 includes the reviewed correction
from `8223ea6` and lock-entry symlink refusal at `5d415961fbfc679207b3e12cf92bb4ef364d6ad9`.
Successful foreground jobs explicitly unlock idle build-server copies;
failure, timeout and parent death retain surviving writer ownership.
The fresh-map skill instructions also specify an isolated registry, exact map
verification and a direct-database CLI fallback (PR #13 comment 4493383118).

The exact rebuilt CUA binary has SHA-256
`05896de6f1d50cb0aaf4c50f81c24861b4198690a6f4fe24980701a3f70f480b`.
All 41 local package/native tests, 14 skill unit tests, 13 native CUA tests,
nine concurrency cases, five reader regressions, 24 fixture patterns and real
Python/TypeScript maps/live diagnostics pass. The isolated trust probe again
records interpreter execution false/true/false without changing saved trust.
Fourteen mapping calls also preserve incremental-versus-fresh semantic equality.
A benchmark launcher preflight failed for missing Bun on PATH; adding the
already installed private runtime to that process's PATH passed the retry.

Source and receipt: `docs/evidence/swan-review-completion-2026-11-06.json`.
Raw CUA evidence was copied to the host at
`/home/aya-hmw/aya/sandbox/swan-package-candidate-2026-11-06/swan-final-review-evidence-2026-11-06.tar.gz`.
PR #15 tracks source integration. The active executable, trust list and module
configuration still match their saved hashes; installing a rebuilt package
remains a separate operation requiring approval. The saved trust-list race,
Goose adapter implementation and broader platform qualification remain outside
this completed review scope.

## 2026-11-06 — Independent review follow-up: request build policy

Stage: isolated Linux candidate qualified; PR integration tracked by the
request-build-policy change. Baseline is
`019119335b44e7d8069a34851e67cd7472933da7` with unchanged library pins.
The accepted first change advertises and enforces optional boolean `build`
on every repository-selecting tool. False prevents implicit map building;
malformed supplied values fail before selection or tool effects. The skill
now checks installed schemas and retains a legacy fallback. See
`docs/request-build-policy.md` for the contract and focused reproduction.

Implementation `e0a22796ab0f1e0e190197b25940d456ad0465a0` built offline in CUA;
binary SHA-256 is
`e1411825179fec2009a0495e8fb3b270ca80f5c39f098f310a160be5f479e878`.
All nine focused policy groups pass, covering 22 advertised selection tools
and 24 malformed-policy requests. The old binary fails six policy groups;
authorized build controls pass on both. Thirteen native lock tests, five
reader cases, nine concurrency scenarios and 14 skill unit tests also pass.
The focused test's initial lock-fixture error was corrected without changing
the candidate binary; both runs and the final receipts are retained. See
`docs/evidence/swan-request-build-policy-2026-11-06.json`. No new real-language
or live-Python trust qualification is claimed for this selection-only change.

The independent review also identified source-supported follow-up defects:
cache metadata can advance before successful map publication; affected-test
substring deduplication can omit a distinct suffix-related path; skipped
Java checking can clear unchecked saved diagnostics. These need separate
runtime reproductions and focused fixes, starting with cache recovery.
Their resolution is not claimed by this selection-policy change.

After those correctness repairs: clearer executed-test/partial-live/coverage
reporting, strict bounded skill qualification, a current architecture reading
guide, then representative measurements before performance changes. Preserve
SQLite, external semantic engines, writer ownership and read snapshots.
The active installation, saved trust and production configuration remain
outside this source PR.

## 2026-11-06: Kotlin on Android (AGP 9), scip-java 0.14.1

- scip-java is pinned at v0.14.1, installed per version
  (`.tools/scip-java/v0.14.1/scip-java`, the `SCIP_JAVA` constant in
  src/pipeline.goose), so re-running fetch-tools.sh fetches a new pin
  instead of keeping the old binary; older ones beside it are left alone.
- On aya-phone (Gradle 9.7.0, AGP 9.4.1 with its built-in Kotlin, Kotlin
  2.4.21), measured in a VM: scip-java 0.13.2 and 0.14.1 both die in
  `scipPrintDependencies` (ConcurrentModificationException: its
  WriteDependencies walks the project's configurations while AGP 9 adds
  some), and `scipCompileAll` alone has no actions there and writes no
  index. Naming the Kotlin compiles works: 16/16 .kt files, with correct
  callers, implementations and references.
- So for a Gradle repo with an Android module (com.android.application,
  .library, .test or .dynamic-feature, by plugin id, `apply plugin:` or a
  version-catalog alias, in the root or a settings.gradle(.kts) `include`),
  `swan map` runs `clean compileDebugKotlin compileDebugUnitTestKotlin
  scipCompileAll`. The compiles are unqualified: Gradle runs them in every
  project that has them and fails only if none does, so a module wrongly
  taken for Android costs nothing (a qualified `:app:compileDebugKotlin`
  for a module that is not Android would fail the whole run and leave no
  Java/Kotlin map). `compileDebugUnitTestKotlin` is left out when every
  Android module found is com.android.test. Other Gradle repos keep
  `clean scipPrintDependencies scipCompileAll`. Comments in build files,
  `plugins.withId(...)` and an `apply false` on the chained lines after an
  `id(...)` do not count. `swan gradle-tasks <repo>` prints the list; `bun
  tests/lang_check.ts gradle` checks it on fixtures/gradle-android (build
  files only), negative cases included.
- Trade-off: without scipPrintDependencies, callees in external packages
  carry no package versions on Android. Limits: the debug variant is
  assumed. A module without a debug variant or without Kotlin is passed
  over by Gradle, but either task missing from every project fails the
  run: only product flavors, multiplatform Android (`...KotlinAndroid`),
  Java-only Android, or unit tests off in every module.
  Modules moved with `projectDir` are looked for at their default path, and
  a convention plugin that applies AGP for a module (build-logic, as in
  nowinandroid) is not seen: such a repo gets the plain list.
- The scip-java index's fingerprint covers .java, .kt, .kts and .gradle
  files plus the root build files and gradle/libs.versions.toml, so editing
  any of them maps again instead of reusing the index.
- Host checks with 0.14.1: tiny-java (`lang_check.ts java`) and tiny-kt
  (`kotlin_live_check.ts`) pass. The Android path has been run through
  this branch's `swan map` on aya-phone in the VM: exit 0, 25 s, about
  2.19 GB peak, 22 files including 16/16 .kt, with callers, implementations
  and references matching grep.

## 2026-11-07: exact-map clean rebuild and offline Cua qualification

- Added CLI `map --clean` and boolean MCP `update_map.clean` for one exact
  map. Clean invalidates generated reuse metadata under the existing stable
  writer lock, reruns eligible indexers, retains the old database until
  complete atomic publication, and writes replacement cache metadata only
  afterward. Existing trust, sessions, other maps and ordinary refresh
  behavior retain their owners. Source skill guidance documents selection,
  failure/retry and the private-map fallback.
- Independent testing found that the old permissive parser accepted a
  malformed symbols row, published an empty database and reported success.
  Clean-only prepublication checks now reject invalid row shapes, numbers
  and roles/flags while retaining legitimate empty output and five/six-field
  symbol compatibility. The same MCP reader retains the old map after
  rejection and recovers on valid input. The new test fails at that exact
  malformed case against the pre-fix binary `c7101a1fc78604ff2332d196dc20f9d33d8184c310759e6d53306101c3ee05f9`.
- Final host binary `0a42c9dec9a9f5bcfb0ec9037a68a28cd908d5b7f5d3463466c1d339b882a3eb`:
  6/6 clean-rebuild cases and 9/9 build-policy cases passed. The host Node 26
  Python/TypeScript doctor environment remains unqualified; synthetic host
  tests and guest success do not establish host dependency readiness.
- Cua Space independently built the corrected archive
  `fd6c42c218baa9b94a7310868450b0860dd1f453d12678dcff0150fcee7b478f`.
  On Node 24.21/Bun 1.3.14, Python/TypeScript doctor passed, followed by
  6 clean-rebuild, 9 build-policy, 9 concurrency, 5 reader and 24 pattern
  checks. Manifest-covered source bytes stayed unchanged; generated
  `bin/swan` and `build/golsp.c` were rebuilt. Earlier, the pre-row-validation
  guest source passed 41 unit and 14 skill-unit tests; those totals are not
  represented as a rerun on the final row-validation source.
- Qualification is bounded to these synthetic cases, fixture patterns and
  dependency observations. It does not prove complete semantic coverage,
  source immutability during arbitrary builds or power-loss durability.
  No installation, live map refresh or trust/configuration change is claimed
  by this source commit. See [clean-rebuild details](docs/clean-reindex.md).

## 2026-11-07: clean-rebuild test documentation follow-up

Added missing docstrings only to the maintained `tests/test_clean_reindex.py`;
all 13 class/function definitions are documented. Its AST matches `890c7e5`
after removing docstrings and source locations. All six clean scenarios
passed against unchanged binary
`0a42c9dec9a9f5bcfb0ec9037a68a28cd908d5b7f5d3463466c1d339b882a3eb`.
Native code, skills and existing tests were untouched. Earlier Cua archives,
qualification packets and manifests retain their original bytes and do not
include this later test-documentation follow-up.

## 2026-11-14: cosmetic edits rerun no indexer

`swan map` over an existing map now stamps files by content, and for
TypeScript, JavaScript and Python by their code alone (src/change.goose). A
comment or layout edit runs no indexer; Swan moves that file's rows itself.
Verified: `tests/cosmetic_check.sh` (23 checks, each map compared with a fresh
build); on a private copy of rea a comment edit's refresh went from 51.3 s to
5.7 s, and 40 cosmetic edits at once left 19,724 rows equal to a fresh map.
The rest of `scripts/test.sh` passed on the PC except `kotlin_live_check` and
3 `trust_check` checks, which fail the same way with main's binary there (the
seal cannot bind-mount from that root shell). Not done: a real TypeScript
change on rea still reruns the whole program. Details in DECISIONS.md.

## 2026-11-14: a real TypeScript edit reindexes only what it touches

A big TypeScript project with no job slot to split into (rea) now runs as
one chunk, so a code edit is indexed as a layer of the changed files and
their users. Chunks also hold only tsc's root files, in the config's order,
which fixes split mode indexing files outside the project's include.
Verified: `tests/layer_check.sh` (31 checks, fails on the old planner); on a
private copy of rea a code edit's refresh went from 52.6 s to 6.6 s, and an
edit to a file 38 others use from 53.2 s to 7.3 s; after both, the map
differs from a fresh build in 88 of 1,876,863 rows (two whole runs differ
in 22 to 59). An edit to a file imported from outside the include reruns
every chunk. Details and limits in DECISIONS.md.

## 2026-11-15: Swan's own steps use every core; the flattener is Rust

- Code stamping runs in one worker process per core; the flattener is
  `native/swan-flatten` (Rust); since 2026-11-17 it is the only flattener.
  On rea, a 16-core box: full map 88.2 s to 65.5 s, map after a code edit
  9.10 s to 2.7 s. Details and settings in docs/speed.md. (PR 31)
- `[profile.quick]` for the flattener: `SWAN_FLATTEN_PROFILE=quick` rebuilds
  in about 1.6 s instead of 8 s; the shipped build is unchanged. (PR 32)

## 2026-11-16: the seal covers every mount and hides host sockets

On an Omarchy machine (btrfs, `/home` its own mount) `eggshell/test.sh`
failed two checks: the repo under `/home` was writable inside the seal, and
`getent hosts` resolved names through systemd-resolved's unix socket. Fixed
in `eggshell/eggshell`: every mount is remounted read-only and the repo's
mount is checked, and sealed runs get an empty read-only `/run`. See
DECISIONS.md.

- `eggshell/test.sh`: 13 passed, 0 failed (7 of them fail on the old runner).
- `scripts/test.sh`: everything passes except one Rust check, "Shape::Square
  inside vec![...] counts as a use of Shape, by name", which fails the same
  way with the old runner: that check runs trusted, so it doesn't go through
  eggshell. rust-analyzer now resolves that use inside the macro, so the row
  has no `by_name` flag.
- A sealed map of a small Rust/shell repo gives the same symbols and
  references as before (39 symbols, 134 occurrences).

## 2026-11-16: every run sealed; Rust maps with no trust

Trusted runs are sealed too (trust adds network and `--rw` grants); Rust's
rust-analyzer runs sealed and offline for untrusted repos; the map's tsc and
Python probes are sealed; sealed runs get a private `/tmp`; child processes
see each environment variable once. See DECISIONS.md.

- Untrusted map of a small Rust workspace: 825 symbols, compiler-resolved
  (39, syntax only, before); direct callers match `rg`; repo untouched.
- `eggshell/test.sh`: 15 passed (two new `--rw` checks).
- `tests/trust_check.ts`: 12 passed, including three new untrusted-Rust
  checks that fail on main.
- `lang_check` 61, `diag_check` 8, `agnostic_check` 13, `split_check` 2,
  `live_check` 13, `game_live_check` 8, the checks before `rust_check` all
  pass. `rust_check` keeps its one known failure (as on main);
  `structural_check` and `kotlin_live_check` fail as on main.
- Still waiting for trust: Gradle/Maven/MSBuild indexers, `swan check`,
  live language servers.

## 2026-11-17: a batch plan says what it reaches

`edit_batch` without `apply` now has a `touches` part: for each rename and
replaced body, Spread-Wings' `touches` answer, then the files those symbols
reach (callers, importers) that the batch does not edit, the tests among
everything reached, and the repo groups involved. Spread-Wings' graph is
kept beside the map as `wings.db`, rebuilt (sealed) when the map is newer,
and takes Swan's compiler answers. Found by `$SWAN_SPREAD_WINGS` or
`spread-wings` on PATH; without it the plan is unchanged and says why.

- On tiny-py: replacing `total_area`'s body lists `main.py` (calls it) and
  `test_shapes.py` (a test) as reached but not edited; renaming it lists
  nothing, since the rename edits both. A plan with the graph built takes
  about 60 ms.
- Limit: Spread-Wings knows a definition by name and file, so for a method
  it counts every method of that name in the file (marked in the answer).

## 2026-11-17: running servers move to a new build by themselves

`swan serve` remembers the path it was started by (swan-up's
`<root>/current/bin/swan`). After each answer it checks where that path
leads; when `swan-up update` has pointed it at another version, the server
stops its language servers and execs the new build in the same process,
on the same pipes, with the selected repo handed over in the environment.
The new build sends `notifications/tools/list_changed` (initialize now
advertises `listChanged`). It does not move while stdin's buffer holds a
request it has read ahead, so requests sent together are all answered.
A binary rewritten in place is the same path and never moves anything;
`SWAN_NO_RESTART=1` turns it off.

- `tests/test_serve_restart.py` (3 tests, a swan-up layout with two
  versions): moves after an answer and answers from the same repo; three
  requests in one write all answered, then one notice; an in-place rewrite
  does not move it. Pass in a microVM fork.

## 2026-11-17: live Java answers from Eclipse JDT LS, no trust needed

The first language module taken from Serena's SolidLSP. `tools/modules.json`
gains "java" with JDT LS 1.63.0 on its own Temurin 25 JRE (JDT LS needs
Java 25 since 1.62; Swan's JDK 21 stays for scip-java and Gradle), both
pinned by sha256 in `scripts/fetch-tools.sh`.

- Trusted repo: Gradle and Maven import on (runs the build files).
- Untrusted repo: import off, the repo opened as plain folders, the server
  sealed in eggshell (`"sealed": true`, new for live servers). Source folders
  come from `{java_source_paths}`, read from each file's `package` line;
  without them JDT LS guessed the root and reported every class as in the
  wrong package.
- On tiny-java, untrusted: a String returned as double is reported at
  13:16 in 3.2 s from a cold start; the repo is untouched; the process tree
  shows java inside eggshell's user, mount, net and pid namespaces.
- JDT LS publishes diagnostics (no pull), and says `language/status
  ServiceReady` about 1 s after start; the existing `publish` settle works.
- Live find_implementations works through it too: Shape gives Circle and
  Square, Shape/area their two area() overrides (checked by hand).
- Not done: the other live servers are still unsealed; Lombok.

## 2026-11-17: what broke since my last edit

`what_broke` (MCP) and `swan broke <map-dir> <file>...` ask the language
server about the files just written and report only errors it did not
report the last time that file was asked about (same severity, code and
message; lines may move). What was seen is kept beside the map in
`broke-seen.tsv`. `scripts/hooks/what-broke-after-edit.py` is a Claude
Code PostToolUse hook: silent unless the edit introduced an error, then
it tells the agent (exit 2); it never blocks an edit.

- Checked on tiny-py: clean, one bad edit (reported once), asked again (not
  new), a second bad edit (only that one), the first fixed (nothing new).
- The CLI starts the language server each time (pyright: about a second;
  rust-analyzer and JDT LS: several). The MCP tool uses the running one.
- Limits: needs a live server for the language; warnings are counted, not
  listed; breakage in callers in other files is not looked at yet.

## 2026-11-17: live Goose errors from the compiler's own server

`tools/modules.json` gains "goose": `goose lsp`, sealed. `{goose_entry_files}`
names the repo's programs (files with `fn main(`) in the server's
initialization options; without it a module checked alone reports every
name its importer provides as unknown (src/edit.goose: 6 false errors, with
it 0). On a copy of Swan's own source a real error in src/edit.goose comes
back in about half a second. `fixtures/tiny-goose` and three `live` checks.
Not done: a Goose map (definitions, references, callers); `swan check` with
`goose check --diagnostics json`; the installed Swan ships no Goose compiler.

## 2026-11-17: pipeline.goose split by job (no behaviour change)

A review for modularity found `src/pipeline.goose` doing nine jobs in 3,200
lines. Five self-contained groups moved out, text unchanged:
`gradle.goose` (356), `seal.goose` (141), `pyplan.goose` (290),
`stamp.goose` (237), `checkers.goose` (351); pipeline.goose is 1,867.
Two comments that had drifted off their functions were put back. The full
suite passes unchanged.

Still to do, largest first: `map_main_locked` (1,176 lines, one function
with nested closures over shared locals), `syntax_index_main` (496),
`rename_symbol` (295), `check_main` (173), `edit_batch` (169).

## 2026-11-17: Swan maps Goose, and itself

- `swan lsp-index` (src/lspindex.goose): a map for a language from its
  language server, for languages with a server and no SCIP indexer. It asks
  for each file's document symbols, then each definition's references, and
  writes a SCIP index the flattener reads like any other. Declared as data:
  `"map": "lsp"` on the language's entry in tools/modules.json. Goose is
  mapped this way; its rows are what the Goose compiler resolved.
- goose-lsp gains a general `request` op (any LSP method, the server's own
  result) and stops re-sending unchanged files; `swan lsp-ask` exposes it.
  Indexing Swan's Goose went from 216 s to 15 s with that.
- The repo walk no longer enters hidden folders. Swan's own `.tools`
  (3.7 GB of fetched compilers and SDKs) made its map run past ten minutes
  without finishing; the whole repo now maps in 16.5 s.
- On Swan itself: 48 Goose files, 636 definitions (functions nested in
  functions included, as `map_main_locked/stamp`), 3,887 references.
  `callers seal_argv` and a cross-file rename on the fixture, which the
  Goose compiler then accepts, both work.
- Installs fetch the Goose compiler too (28 MB).
- Limits: uses of the standard library and of packages are not in the map
  (only what the repo defines is asked about); symbols nested more than
  four deep are left out; the server analyses each file as it is first
  opened (about 0.3 s a file on Swan), with no per-file reuse yet.

## 2026-11-17: Go through SolidLSP, behind a bridge

- `tools/solidlsp/bridge.py` speaks LSP to Swan's client and answers from
  SolidLSP (Serena's MIT language-server library), which starts, configures
  and waits for the real server. `swan lsp-index` and the live tools need
  no change: Go is one entry in tools/modules.json (`"map": "lsp"`).
- Fetched pinned by `SWAN_LANGS=go scripts/fetch-tools.sh`: only
  src/solidlsp from oraios/serena 0cef825 (sha256), its Python packages in
  a uv venv, Go 1.27.4 (sha256) and gopls v0.24.0 built by that Go. Installs
  fetch it too (about 400 MB).
- Licence: SolidLSP's ls.py imports two helpers from the GPL Serena
  application; tools/solidlsp/shim holds Swan's own versions, so no Serena
  application code is fetched or used. See NOTICE.
- `swan lsp-index` now also asks what implements each interface or class
  and their methods, and writes SCIP relationships.
- Go is left out of the by-name syntax index when it is mapped this way.
- Outside modules: Swan's own module cache (`.tools/go-mod`), filled when
  the repo is trusted (the seal then has the network), read offline
  otherwise. Without them gopls resolves nothing: cobra gave 789
  definitions and 0 references until its modules were there.
- eggshell sets XDG_CACHE_HOME to the scratch home: a desktop session's
  value pointed into the read-only real home and gopls died at start.
- Checked: fixtures/tiny-go (references across packages, Square implements
  Shape, one TotalArea not two, rename across packages); live errors
  (a string returned as float64, with gopls's code); spf13/cobra adbc881:
  36 files, 789 definitions, 5,920 references, 3 implementations in 6.9 s,
  trusted and untrusted alike once the modules are cached, repo untouched;
  `refs ExecuteC` gives the 5 real call sites, where grep also matches two
  comments and TestSubcommandExecuteC.
- Limits: a Go method is named without its receiver type (`Area`, not
  `Square/Area`); an untrusted Go repo whose modules were never fetched
  gets definitions only; only Go is wired through the bridge so far.

## 2026-11-17: Rust: every cargo project, every feature, a library it can read

- `swan map` runs rust-analyzer once for each cargo project in the repo, not
  only for the workspace at its root (src/rustproj.goose). A folder with a
  Cargo.toml is a project of its own when nothing above it has one, when it
  has a `[workspace]` table (what `cargo fuzz` writes), when the workspace
  above excludes it, or when no workspace is above it and no other crate
  depends on it by path. This is read from the Cargo.toml files; cargo is
  not run to decide it. Each project's index is reused on its own, and the
  projects link to each other by crate name: a use of the root crate's
  `Tile::new` in `fuzz/src/main.rs` is a reference to the root's definition.
  Twelve projects at most in one map; the rest are named.
- A project inside another one that fails does not fail the map: its line
  says "not mapped, the map goes on without it" with cargo's reason. Every
  map that indexed Rust ends by naming the crates it has no rows for.
- Every cargo feature is on (`cargo.features = "all"`, given to
  `rust-analyzer scip --config-path`), as RustRover has it, so code behind
  `#[cfg(feature = "...")]` is resolved rather than matched by name.
- A repo that pins an installed Rust 1.N older than rustup's default
  toolchain: cargo, build scripts and proc macros still run with the pinned
  one, and rust-analyzer reads the default one's standard library
  (`cargo.sysrootSrc`). Swan's rust-analyzer (0.3.3089) given Rust 1.88's own
  library loaded core but resolved no `macro_rules` macro of it and nothing
  from the prelude: `vec!`, `matches!`, `assert_eq!`, `Some`. The map lost
  every use inside those macros, and rust-analyzer's own diagnostics
  reported `unresolved macro vec!` on sound code. The live server gets the
  same setting (`{rust_std_source}` in tools/modules.json).
- The Rust fingerprint now covers every Cargo.toml, Cargo.lock and
  rust-toolchain file in the repo, not only the root's: a dependency added
  to a member crate used to leave the old index in place.
- `swan cargo-projects <repo>` prints the plan (projects, settings,
  toolchain) and runs nothing.
- Measured on relatedb/relate 2e47f55 (44 crates, pins Rust 1.88.0, with a
  fuzz crate cut off from the workspace), against the map made earlier the
  same day:

  | | before | after |
  |---|---|---|
  | Rust files in the map | 1,721 | 1,890 |
  | definitions | 38,821 | 43,222 |
  | references to the repo's own definitions | 204,080 | 313,716 |
  | references matched by name only | 2,345 | 406 |
  | rows in surfaces/relate-ffi/fuzz | 0 | 306 |

  With every feature on but Rust 1.88's own library, 11,169 references were
  by name. rust-analyzer took 31 s for the workspace and 16 s for the fuzz
  crate, side by side. RustRover agrees on 2,973 of 3,000 sampled
  references (26 it has no answer for, 1 it resolves into the standard
  library); before it was 2,924, with two disagreements from features and
  one wrong link of Swan's (a local `args` in feature-gated code linked to
  the function `args`), all three gone.
- Checked in the suite: a repo with four projects (root with a feature and
  a path dependency, a `[workspace]` fuzz crate, a crate that stands alone,
  one cargo cannot read), and the toolchain choice against a made-up rustup
  folder. Not in the suite: the effect of the library swap itself, since the
  test machine has one toolchain; that is the relate measurement above.
- Limits: `swan check` and the live server still work from the repo root's
  workspace only; a crate in a workspace whose `members` globs do not match
  it is taken for a member, so it is named at the end of the map rather
  than mapped; with every feature on, code under `#[cfg(not(feature =
  "..."))]` is the part left to names.

## 2026-11-17: TypeScript: one name for one object key, whichever chunk asks

- Found by comparing with WebStorm on Egonex-AI/Understand-Anything
  (b861852): `locales.en.onboarding.steps` was linked to another `steps`
  key of the same object, 224 lines up.
- Cause: scip-typescript 0.5.2 names a property of an object literal
  `steps0`, `steps1`, ... from a counter of the file it is indexing, the
  first time it meets the property. Swan runs it as several processes over
  parts of a project (chunks, and layers for changed files), and each
  numbered the other parts' keys from its own point of view.
- Fix (src/tspatch.goose): Swan patches its own copy of the indexer, as it
  does scip-python's, so that the number is the key's place among the keys
  of that name in its own file. Two sites in dist/src/FileIndexer.js, each
  required to match exactly once; `swan scip-typescript-patch <file>
  [--revert]` by hand. The indexer's size is now part of every TypeScript
  fingerprint, so existing maps index TypeScript again once.
- If the indexer cannot be patched (another version, a read-only install,
  SWAN_SCIP_TYPESCRIPT_PATCH=0) the map says so and runs TypeScript as one
  process with no layers.
- Type literals carry the same kind of number (`typeLiteral3`) and needed
  nothing: the flattener already drops it, and their owner tells them apart.
- Checked: the split suite's project gains an object with two `steps` keys
  read from eight other files. Swan before this fix, in 4 chunks, sent 6 of
  the 8 uses to the wrong key; now all 8 are right and the split and single
  maps hold the same rows. The patch applied and undone leaves the file
  byte for byte as it was.
- Not fixed by this: every file is still indexed under the root tsconfig
  (the next entry's subject).

## 2026-11-18: TypeScript: each file under the tsconfig that owns it

- Found with the fault above, on Understand-Anything: Swan indexed every
  file under the root tsconfig. The root one has no `jsx`; the dashboard
  package's own sets it. TypeScript does not follow an import that resolves
  to a .tsx file while `jsx` is unset, so a .tsx file in another chunk was
  not loaded and the import and every use of what it brought in was lost
  (621 rows, 136 of App.tsx's 450). A package's own `paths` aliases were
  ignored the same way, and a package the root config did not include had
  no rows.
- Now (src/tsproj.goose): a config is a project when it is a tsconfig.json
  somewhere in the repo, or one that such a config or the root's references
  (tsconfig.app.json beside a tsconfig.json that only points at it). Each
  file belongs to the nearest config above it that lists it, as an editor's
  language service has it; what a config lists is tsc's own answer
  (`tsc -p <config> --showConfig`, sealed). Chunks are planned inside each
  project, each chunk's config extends its project's, with that project's
  declaration files. An edit is a layer for each project it touches.
- A config tsc cannot read (it extends a package that is not installed) is
  counted in the report and its files stay with the root's config. 64
  configs at most are asked about. The answers are kept until a file comes
  or goes or any tsconfig changes.
- A repo with one tsconfig is planned exactly as before.
- Measured on Understand-Anything b861852 (six tsconfig files):

  | | one process, root config | 7 chunks, root config | now (8 chunks, 4 projects) |
  |---|---|---|---|
  | TypeScript rows | 36,031 | 35,410 | 36,526 |
  | rows in dashboard/src/App.tsx | 450 | 314 | 542 |

  The map takes 4.5 s (3.7 s before). WebStorm, 3,000 sampled references:
  2,816 the same definition, 154 it has no answer for, 12 constructors
  (Swan has the class and the constructor), 18 where it names the import
  line of the using file (aliases and default imports) and Swan the
  declaration. No site left where the two name different declarations.
  morluto/rea (one tsconfig.json) maps as before: 1,509,193 TypeScript rows,
  60 s.
- Checked in the split suite: a repo with a root config that takes in
  everything, a package with its own tsconfig, a package whose tsconfig.json
  only references a tsconfig.app.json with `jsx` and a `paths` alias, and a
  config tsc cannot read. Twelve .tsx components importing one another
  across chunks all resolve; the alias import resolves in all twelve (0 of
  12 before); one chunk for each project and several hold the same rows; an
  edit in two projects is two layers and gives the rows of a fresh map.
- Limits: `tsc --listFilesOnly` is still asked of the root config only, so
  a file a nested project imports from outside every config's list is not
  watched for changes; `swan check` runs tsc on the root config only; when
  the indexer cannot be patched (previous entry) TypeScript runs whole under
  the root config, as before.

## 2026-11-18: folders git ignores are not the repo's code

- Swan's map of its own repo held 1,919 files; 148 are Swan's. The rest
  came from folders git ignores: 482 files of old test output in `data/`
  (seven cargo projects among them, each given a rust-analyzer run), and
  about 1,300 from `.tools`, where the syntax index walked into the Lua
  server's library (29,744 symbols) and the C fixtures pulled in compiler
  headers.
- `swan map` now asks git, sealed, which folders it ignores
  (`git ls-files --others --ignored --exclude-standard --directory`) and no
  walk of the repo enters them: language detection, fingerprints, Python
  pieces, cargo and tsconfig projects, the syntax index, the server-built
  maps, `swan check`, the search for new files and structural search. The
  list is kept in the map folder (git-ignored.txt) for the map's other
  processes and for `swan serve`. The report names the folders.
- An indexer that finds its own sources (scip-java without a build tool
  compiles every .java it sees) or follows an include into such a folder
  still reads those files; the flattener leaves their documents out
  (`--ignored`), so nothing under an ignored folder is in the map.
- The syntax index skips hidden folders, as the main walk has since
  2026-11-17.
- A folder holding a file git tracks is never left out: git lists a folder
  as ignored only when nothing in it is tracked. A repo that is not a git
  repo is walked as before.
- Swan on itself: 148 files and 3,278 symbols (1,919 and 38,037), two
  cargo projects instead of seven, 21.5 s (26.3 s).
- Checked: a git repo with an ignored folder holding Python, Java and a
  cargo project. None of it is in the map and no cargo project is run; the
  same files without git are all mapped.
- Limits: only whole folders are left out, not single ignored files; code
  generated into an ignored folder is now outside the map, so uses of it
  resolve to symbols with no definition row, like a dependency's; an
  indexer still spends its time on what it finds there.

## 2026-11-18: Swan for Hermes

- `integrations/hermes/swan`: a native Hermes plugin (plugin.yaml and one
  Python file). Its `transform_tool_result` hook runs after Hermes's
  `write_file` and `patch` tools and adds the errors that edit introduced to
  the result the model reads, the same answer Swan's Claude Code hook gives.
  It reads the written files from the tool's own result (`files_modified`,
  `resolved_path`), runs the installed Swan's what-broke script, and stays
  silent for a clean edit, a file no map covers, a refused or failed call,
  or a machine without Swan. It registers the swan-code-check skill from
  the installed Swan, so the skill follows Swan's version.
- Swan's tools reach Hermes through its MCP client, like every other agent.
- `swan-up` connects Hermes with the other agents (`--agents
  claude,pi,hermes`, the default): every profile gets the plugin, enabled,
  and the MCP server, added once.
- Checked: Hermes's own `hermes plugins validate` passes it; through
  Hermes's real tool pipeline in a throwaway Hermes home, a breaking
  `write_file` (absolute and relative path) and `patch` carry the note and
  the fixing write does not; the installer on a throwaway home with two
  profiles, twice; 8 unit tests with a stand-in Swan
  (tests/test_hermes_plugin.py).
- Not checked: a live session with a model. A gateway that is already
  running does not load a newly enabled plugin until it restarts.
- Limits: only Hermes's own file tools are heard; an edit made through the
  terminal tool is not. The first answer for a language can wait on its
  server starting (60 s at most, then the result goes through untouched).

## 2026-11-18: Spread-Wings ships inside Swan

Spread-Wings was a second program to build, put on PATH and point Swan at
(`SWAN_SPREAD_WINGS`); on this machine it was installed nowhere, so a
planned `edit_batch` said "spread-wings is not installed" for every agent.

- `wings/` is the Spread-Wings repo as a submodule at 6fe7e10 (definitions
  by node kind, the type a call names, `score`). `scripts/build.sh` builds
  it as `bin/spread-wings` (3.5 s); the package requires and ships it beside
  `bin/swan`, bound to the build receipt like the flattener, with its
  license. Swan looks beside itself first, then on PATH;
  `SWAN_SPREAD_WINGS` still overrides.
- Three server tools answer from its graph (`wings.db` beside the map,
  built sealed, Swan's answers applied): `repo_overview`, `what_touches`,
  `file_neighbors`. Each answer carries `"source":"spread-wings"` and what
  that evidence is worth.
- `docs/wings-and-swan.md`: who does what between the two, as agreed with
  the owner, and the order of what comes next (survey, corrections for any
  guessed link, the watcher, more languages).
- The swan-code-check skill has a "Find your way first" section and a
  "Broad map" evidence kind.

Checked: lang suite (the plan's touches with no variable set, the three
tools, the errors for an unknown name and a missing Spread-Wings); package
tests (ships under the receipt's checksum; refused without it, with a
mismatch, or when it is no ELF file).

Limits:
- The graph is rebuilt whole and only when the map is newer than it: an
  edit made since the last `update_map` is not in it.
- The package grows by the Spread-Wings binary (34 MB), which needs
  libcurl on the machine it runs on (for its optional `decide` step).
- An installed Swan from before this change has no `bin/spread-wings`:
  `swan-up update` brings it.

## 2026-11-18: the map surveys the repo first; Go from each module's folder

Swan assumed one project at the top of a repo wherever a language's step
had not been taught otherwise. For Go that meant gopls started at the top
of relatedb/relate, whose three go.mod files are further down: 50 s for 38
files.

- `wings/` moves to 7beddf2: `spread-wings survey` (the projects a repo
  holds, read from manifest, lock and version files) and `compiler` taking
  Swan's answer for every call site.
- Every map runs the survey first, sealed (src/survey.goose), keeps it as
  `survey.json` in the map folder and says in the report what the repo
  holds and which node projects have no dependencies installed. Without
  Spread-Wings, or when the survey fails, the map goes on as before and
  says so.
- Go: with go.mod files below the top (and no go.mod or go.work at the
  top), one `swan lsp-index go --within <module>` per module, the server
  started in the module's folder; paths stay relative to the repo, so the
  rows are the ones a run over the whole repo gives. Go files outside every
  module are counted in the report as not mapped.
- `repo_projects`: the survey through the server, read fresh each time.
- Checked in the microVM: fixtures/go-modules (two modules below the top,
  a Go file outside both, a package.json) and 9 checks in the lang suite,
  one more in agnostic (a project in an ignored folder). On the Swan
  installed before this, the same map has no projects line, no
  survey.json, one `lsp-index go` run, and `repo_projects` is unknown.

| relate, Go | Before | After |
|---|---|---|
| Step | one run, 50.0 s | three runs side by side: 6.5 s, 4.6 s, 4.4 s |
| Rows | 38 files, 924 definitions, 3,027 references, 87 implementations | the same rows, byte for byte |

Limits:
- Only Go uses the survey to decide where a tool starts. Python
  environments, `run_tests`, `swan check` and live servers still work from
  the top of the repo.
- A Go file outside every module is not mapped at all in such a repo
  (before, gopls at the top answered for it, slowly).
- The survey does not read .gitignore. Swan leaves a project inside a
  folder git ignores out of its count and of where tools start, and
  `repo_projects` names such projects under `in_folders_git_ignores`;
  `survey.json` itself still lists them.

## 2026-11-18: the broad map follows the files

Spread-Wings' graph beside a map was built when the map was newer than it,
and not otherwise. A file changed after the map was made stayed out of
`repo_overview`, `what_touches`, `file_neighbors` and a planned batch's
`touches` until `swan map` ran again, and then the whole graph was built
again (6 s on relate) though one file had changed.

- `wings/` moves to 049fe53: `spread-wings update` (the graph from the
  files that changed), `watch`, and `compiler --into` (Swan's answers into
  a copy).
- Before each broad-map answer Swan has Spread-Wings bring its graph up to
  date, sealed as before (src/wings.goose `wings_graph`). Three files
  beside the map: `wings-rules.db`, the graph by the rules alone, which
  `update` keeps; `wings.db`, a copy with Swan's compiler answers, made
  again when the graph changed or the map was written since; and
  `wings.checked`, the time and size of the rules graph when Swan last saw
  the copy in line with it. A rules graph that is not as Swan left it (a
  run cut short before its copy, another program) has its copy made again.
- When files had changed, the answer says so under `files_changed`: the
  files changed, added and gone, the files that import or call into them
  (`reaches`), and the tests among those and the changed files (`tests`).
  It is said once, in the first answer after the change.
- A call in a file changed since the map was made is tied by the rules
  alone (the compiler's answer for that line may be of other code), as
  `compiler` already did.
- When no copy can be made the answers come from the rules graph. A
  spread-wings from before `update` (set by `SWAN_SPREAD_WINGS`, or on
  PATH) is named as that, with what to use instead.

| A copy of relate (2,261 mapped files) and of its map, `what_touches` | Before (fdc02e6) | After |
|---|---|---|
| First question, nothing built | 6.3 s | 6.1 s |
| The same question again | 0.05 s | 0.11 s |
| A file changed outside Swan, then the question | 0.05 s, and the new caller is not in the answer | 1.4 s, and it is |
| The map written since, then the question | 6.2 s | 1.3 s |

Checked:
- 7 new checks in the lang suite, on a copy of fixtures/tiny-py with each
  question put to a fresh `swan serve`: a caller written after the map was
  made is in the next answer, with what changed; asked again, it is still
  there and nothing is said to have changed; a planned batch reaches it and
  says which file changed; `wings.db` holds the compiler's answers and
  `wings-rules.db` none, and the changed file's call stays tied by name; a
  graph brought up to date by `spread-wings update` run by hand has its
  copy made again; a change to the file the others import names the four
  files it reaches and the test; a stand-in spread-wings with the old
  usage is named as having no `update`.
- Seen failing in the microVM: with src/wings.goose as on main (what the
  installed Swan does) all 7 fail. With three faults put in (the "not as
  Swan left it" rule off, the batch not passing on what changed, the copy
  made against a map path that is not there) the three checks for those
  fail and the other new ones pass.
- By hand, the Spread-Wings of the installed Swan (7beddf2) set through
  `SWAN_SPREAD_WINGS`: the answer names it and says to use the one that
  ships with Swan.

Limits:
- Swan's own map is not refreshed by this. Its exact tools still say
  `"stale": true` for a file changed outside Swan until `swan map` runs;
  `files_changed` tells the agent which files those are and which tests to
  run, and nothing more happens by itself.
- Every broad-map answer costs one sealed look more: 0.06 s on relate when
  nothing changed.
- After a change the copy is made whole (1.3 s on relate). Not timed on a
  larger repo through Swan: this machine holds no Swan map of rea.
- `files_changed` goes to whoever asks first. Two agents share one map
  folder, and the second is not told.
- Two Swans asking at the same moment may each make the copy.
- When something other than Swan keeps the rules graph (a watcher), Swan
  makes the copy again and cannot say what changed. `update` also writes
  its file when it found nothing, so a watcher's idle looks would have the
  copy made again each time: Spread-Wings has to say whether the graph
  changed (a number that moves only then) before Swan runs one.
- Swan does not start `spread-wings watch`.
- `repo_overview` takes 3.2 s on relate, before and after: its "most
  called" list, in Spread-Wings.

## 2026-11-18: a Python project's own virtualenv is read, not run

Swan looked for a virtualenv only at the top of a repo, and used it only
once the repo was trusted, since using it meant running its python. A repo
that is not trusted (every repo, by default) was indexed against this
machine's own Python instead: the packages the project had installed were
not found, their uses not tied to anything, and the few outside names that
did come out carried whatever versions this machine happens to hold. And
scip-python read every project as Python 3.11.

- The virtualenvs come from the survey (each Python project's `.venv` or
  `venv`, wherever the project is) and from Swan's own look at the top (a
  repo of scripts has no manifest, so the survey names no project there).
- They are read. A sealed `python3 -I` lists the packages from their
  dist-info folders (`importlib.metadata`, no package imported), as
  `python-env.json`. scip-python finds the packages through a stand-in for
  the interpreter, written to `py-standin/` in the map folder and put first
  on its PATH: its pyright asks `python3 -c` where packages are, and the
  stand-in answers in the machine's python3 with the virtualenv's
  site-packages. The virtualenv's own interpreter is never started (inside
  the seal it is usually not there: `bin/python` is a link out of the
  repo). So this needs no trust.
- Swan's second fix to its copy of scip-python (src/pypatch.goose, five
  places in dist/scip-python.js): a definition under a site-packages
  folder inside the repo is the package's, not the project's; a class a
  package hands on from one of its modules (`requests.Response`,
  `unittest.TestCase`) is named by its own file, not by the file that uses
  it; and the Python version of the virtualenv (`pyvenv.cfg`) is the one
  the code is read as, unless the project sets one for pyright itself.
- The map's report says so: `python: 86 packages read from the project's
  own virtualenv (.venv, Python 3.12); nothing in it was run`.
- A virtualenv at the top of a trusted repo is run as before, now with the
  same names and Python version as when it is read.
- Each Python piece's key holds the virtualenv read (its folders, its
  Python, its package list), so a changed virtualenv is indexed again.

| graphify with its own `.venv` (86 packages, Python 3.12), not trusted | Before (9e2ed87) | After |
|---|---|---|
| The virtualenv's packages named with the version it holds | 3 | 30 |
| Uses tied to networkx | 0 | 3,065 |
| Uses tied to pytest | 0 | 3,812 |
| Occurrences in the map | 192,080 | 199,858 |
| The map, from nothing | 33.3 s | 35.1 s |

On fixtures/tiny-py with a uv virtualenv holding requests 2.32.5: not
trusted, `requests.get` was missing and is now `requests 2.32.5`, the same
as trusted; `requests.Response` and `unittest.TestCase` were named `repo 0`
in both and are now `requests 2.32.5` and `python-stdlib 3.12`.

Checked:
- 6 new checks in the lang suite on a project below the top with a
  hand-made virtualenv of Python 3.9 (files only: no interpreter, no pip,
  no network), mapped as not trusted: the report line; a function imported
  from the virtualenv's package resolves and is named by package and
  version; the code is read as 3.9 (the other branch of a version check,
  `python-stdlib 3.9`); a class the package hands on from one of its
  modules is named by the package wherever it is used; an unchanged map
  keeps its piece and a changed virtualenv is indexed again; a virtualenv
  at the top of a repo with no manifest is read too. 1 new check in the
  pypatch suite: the second fix goes on a copy of scip-python.js once and
  comes off leaving the file as it shipped.
- Seen failing in the microVM: with src as on main, all 7. With the
  version site off, the virtualenv left out of the piece key and the top
  virtualenv dropped as before: those three checks and the pypatch one.
  With the three site-packages sites off: the naming check and the three
  that depend on names. With the class site off: the class check alone.

Limits:
- `swan check`, live answers and `run_tests` do not use what was read. In
  a repo that is not trusted pyright still reports the project's packages
  as imports it cannot resolve. The next piece of this step.
- One environment for a whole repo. With several virtualenvs, a package
  two of them hold is taken from the first (the top of the repo first),
  and the first one's Python is the version read as. One run for each
  project is not built.
- With a virtualenv at the top of a trusted repo, virtualenvs further down
  are not read (as before).
- `.pth` files are not followed, so an editable install that points
  elsewhere is not found; `include-system-site-packages` is not honoured.
  Only folders named `.venv` and `venv` are looked for, in the Linux
  layout (`lib/python*/site-packages`).
- A Python later than 3.12 is read as 3.12, the newest this scip-python
  knows.
- Names change once. Every repo's Python pieces are indexed again on its
  next map (the key now ends in `-n2`), and classes handed on by a package
  get the package's name instead of the repo's.
- The second fix fits scip-python 0.6.8. A newer one that does not match
  is left alone, and the map says so.
- Not looked into: the repo's own modules that a map holds as outside
  symbols (graphify: 171, `tools.skillgen.gen` among them). They were
  there before and are named rightly, as the repo's.

## 2026-11-19: a port to Rust is started, on a branch

The owner asked for Swan to be carried over to Rust as a complete overhaul
(Spread-Wings went the same way on 2026-11-18). Branch `rust`, from main
`fb8df2a`. The Goose program is unchanged and is what ships.

- The bar was written before any Rust: [docs/rust-port.md](docs/rust-port.md).
  The same map by table hash, the same answers by bytes, the same suite
  counts in the microVM, the same or better cost, and either program reading
  the other's map. About 13,200 lines to carry, in nine stages.
- Stage 0 is done: `rust/` builds with cargo 1.100.0, and
  `scripts/port-compare.sh --wrong-calls` finds 47 of 47 wrong calls answered
  as the installed Goose build `fb8df2a4c199` answers them. Every real
  command exits 70 and names the stage it waits for.
- The repository has a home now: `PROJECT.md`, `AGENTS.md`, `CLAUDE.md`, and
  `HANDOFF.md` for the work in progress.

Not done:

- Stages 1 to 8. No map, query or server answer comes from Rust yet.
- No suite was run; nothing the suites cover changed.
- Nothing is committed or pushed.
- `wings/` is still pinned to Spread-Wings from before its Rust port.

## 2026-11-19: the store is carried to Rust (stage 1 of the port)

The owner said to start turning Swan into Rust. Stage 1 of
[docs/rust-port.md](docs/rust-port.md) is done on branch `rust`: the Rust
program builds a map from flattened SCIP rows (`index`), updates one
(`refresh`) and answers 13 of the 14 kinds of `swan query`, each as the
installed Goose build `fb8df2a4c199` does. The Goose program is unchanged
and is what ships.

Carried: `native/swan_sys.c` (the stat call and the writer's lock), `db`,
`writer`, `scip`, `index`, `fresh`, `query`, `graph`, the walk of a repo
from the head of `pipeline` (`fresh` needs it) and the question half of
`diag`. About 3,500 lines in `rust/src/`, with 5 unit tests.

Both programs were given the same rows (`scripts/port-store.sh`):

| Rows from | Tables the same | Refusals the same | Questions answered the same |
|---|---|---|---|
| Agent-Reach (Python) | 6 of 6 | 14 of 14 | 3,681 of 3,681 |
| Understand-Anything (TypeScript, Python) | 6 of 6 | 14 of 14 | 4,216 of 4,216 |
| relate (Rust, Python, TypeScript, Go, Java, C++) | 6 of 6 | 14 of 14 | 4,508 of 4,508 |
| rea (TypeScript, Python, C++, Java) | 6 of 6 | 14 of 14 | 4,520 of 4,520 |
| the 20 fixtures and cobra | 126 of 126 | 294 of 294 | 5,330 of 5,330 |

- **Tables**, at six points for each: a new map; after a refresh with every
  7th file gone and every 5th of the rest edited; after that refresh again;
  after a refresh back to the first rows; a map from rows with no
  `relationships.tsv`; and a map of a copy of the repo (below). A point is
  the schema and all five tables, hashed in rowid order with the rowid
  (`scripts/port-tables.sh`).
- **Refusals**: no map, no rows, no folder, a file that is not a map, a map
  of another schema, a linked map, a second writer, an unknown kind, rows
  that are not rows. Output, exit code and the words of the error (12 of
  the 14; the two rows with too few fields by exit code, see Limits).
- **Questions**, every kind but `pattern`, on names, files and positions
  taken from each map, compared by bytes. Part of them are asked of a copy
  of about sixty of the repo's files, with a third edited since the SCIP
  run, the rest of the repo gone, files added (four a walk must list and
  eight it must not), four files marked as Swan's own edits, and
  diagnostics dated before the edits. On relate that copy has 2,211 stale
  files and 4 new ones, and both programs say so.

Cost, medians (7 runs on relate, 5 on rea, 15 for a question), the two
programs turn about on one machine:

| | Goose | Rust |
|---|---|---|
| `index`, relate (742 thousand occurrences) | 1,054 ms, 346 MB | 947 ms, 338 MB |
| `index`, rea (1.5 million) | 3,830 ms, 832 MB | 3,264 ms, 794 MB |
| `refresh`, relate, nothing changed | 240 ms, 151 MB | 156 ms, 146 MB |
| `query symbol`, `refs`, `callers`, `callees`, relate | 1 to 2 ms, 9 MB | 1 to 2 ms, 9 MB |
| `query uses`, relate | 1,355 ms, 9 MB | 1,349 ms, 9 MB |
| `query info`, relate | 6 ms, 9 MB | 6 ms, 9 MB |

Checked:
- The same counts on the final tree for all of the above, and
  `scripts/port-compare.sh --wrong-calls`: 47 of 47.
- Seen failing (`scripts/port-prove.py`, 9 of 9): nine copies of the Rust
  program, each broken in one place on purpose, each caught by the step
  meant to catch it. The smallest-body
  rule and the hash constant by the tables; a column off by one by 1,551
  of 1,806 questions; an edited file called fresh, hidden folders walked,
  and stale diagnostics called fresh by the copy of the repo only; a
  missing `relationships.tsv` made an error by its own map; two reworded
  messages by their refusals. The first judge written passed two of these
  (it had no stale file to ask about and did not compare the words of an
  error); it was rewritten before the counts above were taken.
- RustRover on a copy of `rust/` opened as its own project: no errors, no
  warnings, three style notes left on purpose.

Found on the way (docs/rust-port.md has each):
- `swan index` is 70% SQLite's own work; 40% is the nine indexes at the
  end. `memchr` is in (9% off relate). Threads were tried in scratch copies
  and are held for the owner: `rayon` 14% more off relate, SQLite's own
  sort threads 6% more (DECISIONS.md, 2026-11-20).
- Not the port's: `query uses` is slow in the Goose program that ships,
  1.4 s for one function on relate and 79 s for a shared name on rea;
  `query diag` 4 s on rea. The SQL reads every symbol several times.

Limits:
- No map, check, edit or server answer comes from Rust yet: stages 2 to 8.
  `swan query <db> pattern` exits 70 until stage 3.
- The suite judges the Goose program, which this change does not touch;
  the Rust program cannot run it before stage 8. It was run in full in the
  microVM on the commit that went into main, and its counts are in that
  pull request.
- A row with too few fields is refused by both with exit 1, in different
  words (Goose's is its own bounds check).
- Not compared: a file Swan edited whose mark still matches its text (only
  an edit makes that mark: stage 6); loading diagnostics (stage 6; the
  Goose program loaded made-up ones for the questions); errors inside
  SQLite for statements that never fail here.
- The fixtures' maps are small (0 to 156 occurrences; five hold none, made
  without trust), and cobra's holds 812.
- Cost is from one machine with 32 processors.
- Merged into main with stage 0, on the owner's word, as files beside the
  Goose program. `scripts/build.sh` does not build the Rust program and
  nothing installs or ships it.

## 2026-11-20T16:04Z: README says Goose still ships and Rust is the way forward

Wrong: the README opened with "built in Goose" and never said the program is
moving to Rust; the only mention was one line in the layout list. A reader
(the owner) took it as out of date.

Changed: a short paragraph under the opening says the shipped program is
still Goose, the port to Rust has been under way since 2026-11-19, stages 0
and 1 are merged (2026-11-20), stages 2 to 8 are not done, and nothing of
the Rust program is built, installed or shipped yet. A line under "What a
Goose Serena means here" says that section is today's design. Text only.

Checked: the claims read against HANDOFF.md, docs/rust-port.md and the stage
0 and 1 entries above. Fetched every branch: no Rust work newer than the
2026-11-20 merge is on GitHub.

Limits: the rest of the README still describes the Goose program, as it
should until a stage ships. Any Rust work done on the owner's own computer
and not pushed is not in this entry.

## 2026-11-20T16:21Z: stage 2 of the port begun: `cargo-projects` in Rust

What was missing: the Rust program answered `swan cargo-projects <repo>`
with exit 70, "not carried over yet (stage 2)".

Changed: `rust/src/rustproj.rs` carries src/rustproj.goose line by line,
with the five toolchain helpers it uses from src/seal.goose (which channel
a repo pins, where rustup lives, whether it has that toolchain, its
default, the version of each). `sys.rs` gains `env`, `write_stderr`,
`realpath` and `run_capture` (for `rustup show home` only). The command
prints the same projects, settings, toolchain warnings and "not mapped"
lines as the Goose program. Nothing ships: `scripts/build.sh` still builds
only the Goose program.

The judge: `scripts/port-plan.sh` runs each stage 2 command carried so far
through `port-compare.sh` on the 20 fixtures, on made-up repos that hold
the cases the fixtures do not (15 crates side by side, a workspace with a
multi-line exclude and a cut-off fuzz crate, path dependencies that leave
the repo or hide in another word, odd folder names, skipped folders, a
symlink, pinned toolchains old, new, missing and broken), on a repo that
does not exist and on any repo named, each under three rustup homes.

Checked, Goose program built from main `8d3417a` against the Rust one:
- `scripts/port-plan.sh` with relate, tokio, ripgrep, cargo, bevy and
  cobra (shallow clones, read only; the command runs nothing in a repo):
  93 of 93 the same. On cargo, 660 manifests: 366 lines from both, 12
  projects and 354 "not mapped".
- Seen failing: `scripts/port-prove-plan.py`, 11 copies of the Rust
  program each broken in one place, 11 caught. The first judge caught 4;
  the made-up repos were widened until all were (docs/rust-port.md).
- `--wrong-calls` 47 of 47. `cargo test` 5 of 5. No new linter notes.

Cost, one run each in the judge: cargo 71 ms Goose, 53 ms Rust; bevy 26
against 13; relate 18 against 12.

Limits:
- Run in a cloud container, not on the owner's machine: the four trial
  repos and their maps are not here. relate was cloned fresh (its current
  head, not the trial copy). Understand-Anything, rea and Agent-Reach were
  not run; they hold no Rust that the fixtures and clones do not cover, but
  that is a reading, not a run.
- The microVM suite was not run: it judges the Goose program, which this
  change does not touch.
- The rest of stage 2 is not done: `gradle-tasks`, `plan-python`,
  `stamp-bench`, `stamp-worker`, and `modules`, `survey` and `tsproj`.
- On the session's branch with the README entry before it, not a branch of
  its own.

## 2026-11-20T16:41Z: stage 2 of the port: `gradle-tasks` in Rust

What was missing: the Rust program answered `swan gradle-tasks <repo>` with
exit 70, "not carried over yet (stage 2)".

Changed: `rust/src/gradle.rs` carries src/gradle.goose line by line: the
Android plugin ids in quotes, the version catalog's aliases, comments taken
out (Kotlin's nest, Groovy's do not; strings, triple-quoted strings and
Groovy's slashy and dollar-slashy strings kept), reactions (`withId`,
`hasPlugin`, `withPlugin`) masked, `apply false` on chained lines, and the
modules `settings.gradle(.kts)` includes. It shares `scip::is_ident` with
the store, as the Goose program does. Nothing ships.

The judge: `scripts/port-plan.sh` runs `gradle-tasks` on every repo it
judges, on each case of fixtures/gradle-android, and on 31 made-up Gradle
repos, one rule each, which hide or show an Android plugin depending on
whether the reader gets that rule right (each case's answer was looked at:
11 Android, 20 plain).

Checked, Goose program built from main `8d3417a` against the Rust one:
- `scripts/port-plan.sh` with relate, tokio, ripgrep, cargo, bevy, cobra,
  nowinandroid, architecture-samples, okhttp and RxJava (shallow clones,
  read only): 181 of 181 the same.
- Seen failing: `scripts/port-prove-plan.py`, 36 of 36 breaks caught (11
  for `cargo-projects`, 25 for `gradle-tasks`). The first run caught 36 of
  37; the one missed (a commented catalog line read) cannot change any
  answer, so it was taken out (docs/rust-port.md, "Found while porting").
  A rerun crashed when its work folder was deleted by mistake (taken for
  the leftover of a stopped run); it was run again, whole.
- `--wrong-calls` 47 of 47. `cargo test` 5 of 5. No linter notes on the
  new files.

Cost: 2 to 4 ms in both programs on every repo.

Found, not the port's: Now in Android is read as a plain JVM build by the
program that ships. Its modules apply Android through convention plugins
of its own, which only its build-logic Kotlin names as
`com.android.application`. Swan then names `scipPrintDependencies`, which
its own comment says dies on an Android build. Not run (third-party,
sealed; no Android SDK here). Waiting on the owner: fix on main now or
after the port.

Also recorded: serena-rs as a reference for stage 5, and the owner's
direction for after the port (DECISIONS.md; docs/rust-port.md, "Held for
after the port").

Limits: as for `cargo-projects` above (cloud container; the trial repos and
the microVM suite not run). Left in stage 2: `plan-python`, `stamp-bench`,
`stamp-worker`; `modules`, `survey`, `tsproj`.

## 2026-11-20T19:40Z: Android builds through convention plugins are read as Android (Now in Android)

What was wrong: `swan gradle-tasks` (and so `swan map`'s scip-java run)
called android/nowinandroid a plain JVM build: `clean scipPrintDependencies
scipCompileAll`. Its modules apply the repo's own convention plugins
(`alias(libs.plugins.nowinandroid.android.application)`), and only the
Kotlin in its build-logic applies `com.android.application`. Swan read
build files only. On an Android build `scipPrintDependencies` dies (the
reason Swan names the Kotlin compiles instead), so such a repo would get no
Java or Kotlin map. Found while carrying `gradle-tasks` to Rust.

Changed (src/gradle.goose, then the same in rust/src/gradle.rs): the
repo's own build logic is read too, as text, nothing run: buildSrc, and
each build settings.gradle(.kts) includes with `includeBuild`. In it, a
precompiled script plugin (a .gradle.kts or .gradle file under src/main;
its id is its file name, after a Kotlin package) and a plugin registered
in a gradlePlugin block (its id written out or taken from the catalog,
its class found by file name) count as Android when their file applies an
Android plugin or another such plugin, read by the same rules as a build
file (comments and reactions like `hasPlugin` do not count). A module that
applies one, by id or by catalog alias, is Android. Folders outside the
repo (`..`) are not read.

Before and after (`swan gradle-tasks`, the Swan before this change against
this one):
- nowinandroid: `scipPrintDependencies` before, `compileDebugKotlin
  compileDebugUnitTestKotlin` after.
- The five new fixtures (fixtures/gradle-android/convention-*): four gave
  the plain list before and the Android one after (convention-class,
  -chain, -script; -test without the unit-test compile); convention-jvm,
  which only reacts to Android, is plain in both.
- Unchanged: every older case of fixtures/gradle-android, tiny-kt,
  tiny-java, architecture-samples and okhttp (Android in both), RxJava
  (plain in both).

Checked:
- The five new checks in tests/check/lang_suite.goose (lang_gradle) run
  `bin/swan gradle-tasks` on those fixtures; each command was run by hand
  on the Swan before (four wrong) and after (five right).
- The Rust port carries the same change: `scripts/port-plan.sh` against
  the fixed Goose program, with 14 more made-up repos for the new rules:
  201 of 201 the same (the fixtures, the made-up repos and the ten public
  repos).
  `scripts/port-prove-plan.py`: 56 of 56 breaks caught, 20 of them in the
  new code.

Limits:
- The suites were not run: this cloud container has no microVM and not
  the indexers the lang suite maps with. They are to run in the microVM
  before this merges.
- Gradle was not run on nowinandroid (a third-party build stays sealed;
  no Android SDK here), so "the map now works there" is not shown, only
  that the task list is the Android one. Its app module has product
  flavors; Gradle runs compileDebugKotlin where a module has it (the
  libraries), as before.
- Not read: plugins applied by type (`apply<SomeClass>()`), by
  `libs.findPlugin(...)` in code, from a published plugin jar, or a
  settings plugin.
- Its own commit on the session's branch; main needs the owner's word.

## 2026-11-20T20:19Z: stage 2 of the port done: `plan-python` in Rust; `stamp` and three more files moved

What was missing: the Rust program answered `swan plan-python <repo> [k]`
with exit 70, "not carried over yet (stage 2)".

Changed: `rust/src/pyplan.rs` carries src/pyplan.goose line by line: the
.py files of the repo, by size (at least one byte each); folders over
their share split into subfolders and files; a folder of more than k
loose files kept whole unless its scripts stand alone (at most one in ten
imports a folder or module of the repo, or imports relatively), when it is
split by filename prefix (at most 64 files and 40 pieces). Names are kept
by Goose's `hash`, as the Goose program keeps them. `sys::file_size`
added. `piece_target`, which only the map uses, waits for stage 4.

Moved out of stage 2 (docs/rust-port.md, the stage table): `stamp`
(`stamp-bench`, `stamp-worker`) stamps files by their code with
tree-sitter, so it goes to stage 3 with the pinned grammars; `tsproj` and
`survey` go to stage 4 (only the map and the server use them); `modules`
to stage 6 (only check, format, test and live errors). No command of stage
2 prints what they make, so no comparison could judge them now.

The judge: `scripts/port-plan.sh` runs `plan-python` on every repo it
judges and on 21 made-up Python repos (few files; packages of different
sizes; flat folders of scripts that stand alone, import the repo, import
relatively, import a sibling module or name the repo second on an import
line; exactly one in ten and one more; loose scripts at the root; names
sharing only a dot; a folder named as the prefix; more than 40 and exactly
40 first letters; exactly 64 scripts; splits by second and third byte with
a space and UTF-8; a group over the byte limit; empty files, alone and beside others; a folder
exactly at the limit beside one whose name starts the same; two equal
groups competing for room), each with k unset and 1, 2, 3, 4 and 8.

Checked, the Goose program built from this branch (with the convention
plugin fix) against the Rust one:
- `scripts/port-plan.sh` with relate, tokio, ripgrep, cargo, bevy, cobra,
  nowinandroid, architecture-samples, okhttp, RxJava, requests, flask,
  pytest and django: 577 of 577 the same.
- Seen failing: `scripts/port-prove-plan.py`, 76 of 76 breaks caught (20 for
  `plan-python`, 45 for `gradle-tasks`, 11 for `cargo-projects`).
- `--wrong-calls` 47 of 47. `cargo test` 5 of 5. The linter's notes on
  pyplan.rs are three loops over an index, kept as the Goose lines are.

Cost: django, 2,943 .py files and 239 pieces: 22 to 28 ms in both
programs; pytest 3 ms in both.

My mistake, found by the prover: the made-up Python repos were written in
loops over `g`, which is also the folder of the made-up Gradle repos, so
after them no Gradle repo was judged: a run said "the same: 497 of 497"
without them (and 381 without the public repos), and 37 Gradle breaks went
uncaught. The loops now use another name; the counts above are from after
the fix. Two prover runs then crashed on a judge's output that was not
UTF-8 (a diff cut inside "é"); I first took the crash for its time limit
and capped it at one judge a core, which it keeps. It now reads judges'
output with bad bytes replaced.

Limits: the cloud container, as for the commands before: not the trial
repos, not the microVM suite. Stage 2 is on the session's branch with the
rest of today's work; main needs the owner's word.
