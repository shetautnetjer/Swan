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

## 2026-11-20T19:40Z: Android builds through convention plugins are read as Android (Now in Android)

What was wrong: `swan gradle-tasks` (and so `swan map`'s scip-java run)
called android/nowinandroid a plain JVM build: `clean scipPrintDependencies
scipCompileAll`. Its modules apply the repo's own convention plugins
(`alias(libs.plugins.nowinandroid.android.application)`), and only the
Kotlin in its build-logic applies `com.android.application`. Swan read
build files only. On an Android build `scipPrintDependencies` dies (the
reason Swan names the Kotlin compiles instead), so such a repo would get no
Java or Kotlin map. Found while carrying `gradle-tasks` to Rust (the
port's stage 2).

Changed (src/gradle.goose): the repo's own build logic is read too, as
text, nothing run: buildSrc, and
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
- Carried into the Rust port (`rust/src/gradle.rs`) in the port's stage 2
  pull request, which is judged against this fixed program.

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
- Its own pull request; merging needs the owner's word.

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

## 2026-11-20T19:40Z: the convention-plugin fix carried into the port

What: the fix of its own pull request (`fix/gradle-convention-plugins`:
Android through convention plugins, Now in Android) made the same in
`rust/src/gradle.rs`, so the port matches the fixed Goose program, which it
is judged against from then on.

Checked: `scripts/port-plan.sh` against the fixed Goose program, with 14
more made-up repos for the new rules: 201 of 201 the same (the fixtures,
the made-up repos and the ten public repos). `scripts/port-prove-plan.py`:
56 of 56 breaks caught, 20 of them in the new code; two breaks of before
were anchored again, their text now being in two places.

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

## 2026-11-20T21:10Z: stage 3 of the port begun: tree-sitter in Rust, the same trees

What was missing: the Rust program could not parse a file. Stage 3
(syntax-index, query pattern, stamps) reads tree-sitter trees, and they
must be the Goose program's to the byte.

Changed: `rust/build.rs` builds goose-treesitter's own C, its `ts_shim.c`,
tree-sitter 0.25.10 and the 17 grammars, from the copy the Goose build
fetches, at the commit `src/swan.goose` imports and with the file and
include lists of that package's `treesitter.build`. `rust/src/treesitter.rs`
calls the shim (`parse`) and carries `language_of_path`. Two dumpers print
a file's tree as its eight numbers a node: `scripts/port-trees.goose`
(the Goose program's) and `rust/src/bin/port-trees.rs` (the Rust
program's). `scripts/port-trees.sh` compares them. `cc` 1.11.2 (already
in the lock file) is the one new build dependency. Nothing ships.

Checked:
- `scripts/port-trees.sh` on the fixtures, Swan's own wings/, native/ and
  lsp/, and 25 public repos (shallow clones, read only; among them wgpu,
  godot-demo-projects, laravel, cuda-samples, redis, shadcn-ui, django,
  nowinandroid): 25,300 of 25,300 files the same tree, about 46 million
  nodes; every grammar, from 86 Lua files to 7,142 Rust files.
- Seen failing: two broken copies of the Rust dumper: `.h` files taken
  for C++ (caught on the first header), and a changed shim that puts every
  column one too far (caught on the first file).
- `cargo test` 5 of 5, `--wrong-calls` 47 of 47.

Cost: the build compiles the grammars once (about 20 s here); the dumper
is 32 MB with every grammar in it.

Limits:
- The Rust build now needs the goose-treesitter copy the Goose build
  fetches; how it gets these sources once Goose is gone is stage 8's
  question (docs/rust-port.md, "Found while porting").
- Only the trees: `query pattern`, `syntax-index` and the stamps are not
  carried yet. The matcher, goose-treesitter's `treesitter.goose`, is Goose
  to carry too.
- Run in a cloud session; not the trial repos, not the microVM suite.

## 2026-11-20T21:13Z: a convention plugin's id counts only where a plugin is applied

What was wrong (review of the change above, Macroscope): a convention
plugin's id was read wherever it stood in quotes, so a plain JVM module that
only names one in a string (`val conventionName = "demo.android.library"`)
was taken for Android, and a repo of such modules would lose scip-java's
`scipPrintDependencies` for compiles it may not have.

Changed (src/gradle.goose): a convention plugin's id counts only as a plugin
being applied: `id("x")`, `id 'x'`, `apply(plugin = "x")`, `apply plugin:
'x'` or `pluginManager.apply("x")`. An Android plugin's own id is read as
before. New fixture and check: convention-string.

Checked: convention-string is Android on the Swan before this (seen
failing) and plain after. The 17 fixture checks of lang_gradle by hand: 17
of 17. Unchanged: every other case of fixtures/gradle-android,
nowinandroid, architecture-samples, okhttp (Android) and RxJava (plain).

Limits: as the change above (the microVM suite not run here).

## 2026-11-20T21:39Z: review of the port's stage 2 (#75): a deadline that holds, a prover that checks itself, #74's fix carried

What was wrong, found by review (Macroscope, Graphify) and checked:
- `sys::run_capture` (only `rustup show home`, for `cargo-projects`) kept
  its deadline only until the program exited: a child of it holding the
  output open made it wait for that child. A unit test with `sh -c 'sleep
  30 & echo hi'` and 500 ms took 30 s.
- `scripts/port-prove-plan.py` never ran the judge on the unbroken program,
  so a judge broken for some other reason (no Goose program, say) would
  "catch" every break and report success.
- #74 changed under review (a convention plugin's id counts only where a
  plugin is applied); stage 2 carries the same.

Changed:
- `run_capture` runs the program in a process group of its own, as
  `swan_run` does (native/swan_sys.c): one deadline holds for its output
  and its exit, the whole group is killed at it, and a failed wait kills
  it too. Two unit tests (`sys.rs`).
- The prover builds and judges the unbroken program first and stops (exit
  2) when the judge does not pass it.
- `rust/src/gradle.rs`: `gradle_applies_at` and `convention_plugin_in`
  as #74's `src/gradle.goose`. Five more made-up Gradle repos (`apply
  plugin:`, `apply(plugin = ...)` after the id in a string on one line,
  `pluginManager.apply`, Groovy's `id '...'`, and a module that only names
  the id in a string, a `println` and `apply(from = ...)`), and five breaks.

Checked:
- The deadline test failed before (30 s) and passes after (0.5 s, no
  `sleep` left running); `cargo test` 7 of 7.
- The prover with no Goose program: before, it would have built and
  "caught" every break; now it stops after the unbroken program with exit
  2 (seen).
- `scripts/port-plan.sh` against the Goose program of #74's head (`b23c1bc`):
  583 of 583 the same with the 14 public repos (443 of 443 without them).
- `scripts/port-prove-plan.py`: the unbroken program passes (443 of 443),
  then 81 of 81 breaks caught.

Not changed, and why: an enormous piece count (`swan plan-python <repo>
4611686018427387904` on a repo with no .py file) overflows `2 * k` (Graphify).
The program that ships has the same fault: it stops with "slice bounds
out of range" (exit 1), the Rust program panics (exit 101). The port
carries Goose as it is; the fix (`sizes.len / 2 < k`, the same answer for
every k that does not overflow) is a change to both programs, waiting for
the owner.

## 2026-11-20T23:53Z: stage 3 of the port: structural search (`swan query <db> pattern`) in Rust, the same bytes

What changed (branch `rust-stage-3`):
- `rust/src/treesitter.rs` carries goose-treesitter's matcher
  (`treesitter.goose` at `59313e9da0b9`, the commit `src/swan.goose`
  imports). That covers renaming `$X` and `$$$X`, and leaving alone strings,
  comments, raw and verbatim strings, triple quotes, Lua long brackets and
  PHP heredocs. It covers the ten contexts a pattern is tried in and the
  matching rules: repeated names, `_`, punctuation the pattern leaves out,
  the comma beside an empty `$$$`. The search runs on up to 16 threads.
- `rust/src/structural.rs` carries `search_pattern` from
  `src/structural.goose`: the 17 languages, `in_symbol`, `stale`,
  `truncated`, and why a language was skipped.
- `scripts/port-pattern.sh` is the judge. It writes a made-up repo with
  code in all 17 languages, maps it with the Goose program, edits one file
  after so its matches are stale, and asks 35 patterns under 5 paths, 6
  multi-line patterns and `$X`.
- `scripts/port-prove-pattern.py` is its prover: 33 breaks.

Checked:
- The made-up repo: 182 of 182 the same.
- With eight maps (swan-rust, django, laravel, godot-demo-projects, wgpu,
  ripgrep, shadcn-ui, and flask mapped by scip-python): 1630 of 1630 the same, in 171 s.
- The prover: the unbroken program passes (182 of 182), then 33 of 33
  breaks caught. The first judge caught 23 of 34. Its strings held `$`
  only where the plain string rule already kept it, so five string and
  comment rules, the GDScript indent, the Rust and C function context and
  three punctuation rules changed nothing it asked. Ten new cases close
  ten of the eleven holes (docs/rust-port.md, "Found while porting").
- Time, best of three on 4 cores, Goose then Rust: `$F($$$)` on django
  (203,612 matches) 1,483 and 1,334 ms; `$X.unwrap()` on wgpu (2,108)
  544 and 567 ms.
- The eleventh cannot be seen. A GDScript pattern's further lines are
  indented into a function, but the grammar reads the same statements at
  the top of a file, so the rule is never reached. 22 texts parsed both
  ways and 10 patterns on godot-demo-projects gave the same bytes without
  it. It is carried as it is, with no break.

Limits: `fill_template`, the rewrite half of the matcher, is not carried.
It goes with `rewrite_pattern` in the server's stage. Six of the eight
maps were built with empty symbol rows, so `in_symbol` is judged only on
the made-up repo, swan-rust and flask.

## 2026-11-22T05:38Z: the README said stage 2 of the port was on a branch

What was wrong: the note at the top of `README.md` still read "Done on a
branch, not yet on main: stage 2", and counted stages 3 to 8 as not done.
Stage 2 has been on main since #76 (2026-11-20), and stage 3 is under way
on a branch.

Changed: that note now names stages 0, 1 and 2 as merged (three of the
nine), and says stages 3 to 8 are not on main, with stage 3 under way. It
also gives the owner's reason for the port, which no record held: Rust has
a more developed ecosystem (DECISIONS.md has his words and what was seen
that day). Nothing else on the page changed.

Checked: read against `git log origin/main` (#73, #76) and the stage table
in `docs/rust-port.md`. Words only: no code, no build and no suite run.

Limits: the note will be stale again when stage 3 merges; that pull
request has to update it. The page below the note still describes the
Goose program, as the note says.

## 2026-11-22T06:15Z: stage 3 of the port done: `syntax-index` and the stamps in Rust, the same bytes

What was missing: the Rust program answered `swan syntax-index`,
`stamp-bench` and `stamp-worker` with exit 70, "not carried over yet".

Changed:
- `rust/src/syntax.rs` carries src/syntax.goose: the walk, the line
  patterns of Go, shell, Make, Ruby and Lua, where a body ends, uses found
  by name (same file, then folder, then repo, at most three), and the SCIP
  file. `swan syntax-index <repo> <out.scip> [--skip go]`.
- `rust/src/change.rs` carries the code stamp of src/change.goose
  (`cosmetic_lang`, `code_hash`, the comments that count) and
  `line_of_path`; the rest of that file is stage 6.
- `rust/src/stamp.rs` carries src/stamp.goose: a stamp line, the workers as
  processes and as threads, `stamp-bench` and `stamp-worker`.
- `sys.rs`: writing a file, making a folder, the processor count, starting
  a worker with its output in a log, and waiting for it. `util.rs`:
  Goose's hash of a whole number.
- Judges: `scripts/port-syntax.sh` and `scripts/port-stamp.sh`, each with
  its prover (`port-prove-syntax.py`, `port-prove-stamp.py`).
  `scripts/port-compare.sh` takes the time off `stamp-bench`'s last line.

Checked, Goose program built from this commit against the Rust program:

| Judge | Result |
|---|---|
| `port-syntax.sh` | 57 of 57 the same: a made-up repo (62 files, asked 15 ways), 20 fixtures and this repository, each with and without `--skip go` |
| `port-syntax.sh` with 8 repos | 73 of 73. The largest: 1,572 files, 3,592 definitions, 91,170 occurrences, an index of 8,402,085 bytes, the same bytes |
| `port-prove-syntax.py` | 107 of 107 breaks caught. The first run caught 105 of 107 |
| `port-stamp.sh` | 82 of 82 the same: a made-up repo (340 files to stamp) with one process, 3 to 64 worker processes, 2 and 3 threads, and each way the two commands fail; 20 fixtures and this repository |
| `port-stamp.sh` with 6 repos | 94 of 94. rea, 7,784 files: the same bytes from one process and from 32 workers; the same lines, in another order, from 4 threads |
| `port-prove-stamp.py` | 59 of 59 breaks caught |
| Earlier judges | wrong calls 47 of 47; `port-pattern.sh` 182 of 182; `cargo test` 7 passed; no warnings |

The two breaks the first judge missed: a file one byte over the largest
size read where one of exactly that size was meant, and a carriage return
that changed nothing the made-up lines showed. Both have a case now.

Cost, the median of 7 or 9 runs on 32 cores:

| | Goose | Rust |
|---|---|---|
| `syntax-index`, 1,572 shell and Lua files | 54.0 ms | 52.6 ms |
| `stamp-bench`, rea, one process | 6,282 ms | 6,241 ms |
| `stamp-bench`, rea, 32 worker processes | 459 ms | 468 ms |
| `stamp-bench`, rea, 4 threads | 1,674 ms | 1,668 ms |

The first Rust `syntax-index` took 63 ms: each word was looked up through
Rust's standard hash with a key made for the lookup. It now uses the hash
the rest of the port uses.

Limits:
- The check suites judge the Goose program, whose sources this branch does
  not change; the Rust program cannot run them before stage 8.
- `stamp_known` and `line_of_path` are carried but nothing here reaches
  them: `stamp-bench` starts from no stamps. They are judged with the map,
  at stage 4.
- On threads the two programs can report another thread count when more
  are asked for than one runtime allows; the judge asks for 2 and 3.
- A file that cannot be read is left out by both, which only shows when
  the judge does not run as root.
- Four rules of `syntax-index` and three of the stamps cannot be shown by
  either command and have no break; the provers list them.
- The pull request for stage 3 is not opened, and the note at the top of
  README.md is changed here and in #77: whichever merges second keeps this
  branch's note with #77's sentence on the owner's reason.

## 2026-11-22T06:22Z: the full suite in the microVM on stage 3's commit

`scripts/space-test.sh` on `2a75e1c` (branch `rust-stage-3`), in a fork of
the checkpoint `swan-test-v4`, about five minutes: 58 checks passed, 0
failed (mcp and maps); the cosmetic, layer and piece checks passed; 56
Python tests OK; 322 checks passed, 0 failed (rust, split, agnostic, diag,
kotlin, game, live, trust, edit, lang, structural, pypatch). Exit 0, and
the fork was deleted.

What it judges: the Goose program. Outside `rust/`, the `scripts/port-*`
judges and the records, this commit is main's (`049fd7c`), so this is also
the first full run on those sources since #74 and #76 went in.

Seen and not explained: after the count the run's last line was
`typescript test: exit 127 after 0 ms`. It is not among the checks, and I
did not find what prints it.

Limit: this entry is one commit after the tree that was tested; that
commit changes STATUS.md and HANDOFF.md only.

## 2026-11-22T06:38Z: #77 merged, main merged in, the suite again, and the pull request for stage 3 (#78)

On the owner's word ("merge, open pr and continue"): #77 was merged into
main (`15e2687`), main was merged into `rust-stage-3` (`4b22745`), and the
pull request for stage 3 was opened, #78. It is not merged: his word
covered #77.

The merge: README.md's note keeps this branch's stages with #77's sentence
on the owner's reason; STATUS.md and DECISIONS.md keep both sets of
entries, in time order. No other file differed.

Checked on `4b22745`:
- `scripts/space-test.sh` in the microVM: 58 checks passed, 0 failed; the
  cosmetic, layer and piece checks passed; 56 Python tests OK; 322 checks
  passed, 0 failed. Exit 0.
- `port-syntax.sh` 57 of 57, `port-stamp.sh` 82 of 82, wrong calls 47 of
  47.
- Not run again: the three provers. The Rust sources are those of
  `2a75e1c`, where they caught 33 of 33, 107 of 107 and 59 of 59.

Limit: this entry is one commit after the tree that was tested; that
commit changes STATUS.md and HANDOFF.md only.

## 2026-11-22T06:39Z: stage 4 of the port begun: the two indexer patches in Rust, the same bytes

What was missing: the Rust program answered `swan scip-python-patch` and
`swan scip-typescript-patch` with exit 70, "not carried over yet".

Changed (branch `rust-stage-4`, on `rust-stage-3`):
- `rust/src/pypatch.rs` carries the sites of src/pypatch.goose (the
  reachability memo for pyright-internal.js, the package and Python-version
  fix for scip-python.js) and how a file is patched: every site exactly
  once or nothing, the whole file replaced by rename.
- `rust/src/tspatch.rs` carries the sites of src/tspatch.goose (stable
  names in FileIndexer.js).
- The sites, 26 strings, were copied from the Goose sources by a script,
  not by hand.
- `sys.rs`: `write_file_atomic`, Goose's: a new file beside the old,
  flushed, renamed over it.
- Not carried yet: the three functions that make sure of a patch before a
  map runs an indexer. They come with the map.

Checked, Goose program built from this branch against the Rust program:

| Judge | Result |
|---|---|
| `port-patch.sh` | 105 of 105 the same: each of the three files with and without its patch, patched and reverted; every site twice, one site twice, half a file, an empty one, one that holds only the mark; a file that is not there, a folder, a link, a name with a space, a folder that cannot be written; each text under the others' names |
| What is compared | what is printed, the exit code, the file's bytes, its permissions, and that nothing is left beside it |
| `port-prove-patch.py` | 29 of 29 breaks caught, on the first run |
| Permissions | the replaced file takes the same permissions in both under four umasks (000, 002, 027, 077), whatever the old file had |

Also found: the line the suite ends on, `typescript test: exit 127 after 0
ms`, is the account `run_step` (src/run.goose) writes for a step that
could not be started: a step labelled `typescript test` whose program was
not found. Which check starts it was not looked into.

Limits:
- Three things have no break because neither command can show them; the
  prover lists them. A folder that cannot be written only shows when the
  judge does not run as root.
- The judge needs the indexers' files in tools/node_modules
  (`scripts/fetch-tools.sh`); without them it stops with exit 2.
- The suite was not run for this piece: no Goose source changed.

## 2026-11-22T06:49Z: stage 4: running a step, `swan trust` and `swan doctor` in Rust

What was missing: the Rust program answered `swan trust` and `swan doctor`
with exit 70, and could start a program only to read its output
(`rustup show home`).

Changed (branch `rust-stage-4`):
- `sys::run`, native/swan_sys.c's `swan_run`: a step's own variables set
  over the caller's, its program looked up on the PATH it will have, each
  folder tried in order, nothing to read, a group of its own, what it
  prints and what it complains of kept apart, one deadline for its output
  and its exit, the whole group ended at the deadline.
- `rust/src/run.rs` carries src/run.goose: Swan's home (the folder above
  `bin/`) and `run_step`, which writes a step's account.
- `rust/src/pipeline.rs`, begun: `swan trust` (the list in
  `data/trusted-repos`). `swan doctor` is in `main.rs`, as in
  src/swan.goose.
- `scripts/port-compare.sh` takes the time off every step's account.

Checked, Goose program built from this branch against the Rust program:

| Judge | Result |
|---|---|
| `port-run.sh` | 53 of 53 the same |
| `trust` | 15 cases: a first repo, the same again, a second, a longer name, a link, slashes, a space, a file, a repo that is not there; a list with no line end, with a longer name, with empty lines; `data` a file, not to be written, the list a folder |
| How a step is run, through a made-up `mkdir` | what it is given (two arguments, the folder, PATH, a variable, nothing to read); exit 3 with a long account; 599, 600 and 601 bytes of error text; text that is not UTF-8; three megabytes on each stream; signals 9 and 15; no such program, one that may not be run, a folder of that name, one with no `#!` line (alone, and before one that runs), the first folder of PATH that has it |
| The deadline | three cases wait for it in each program: a step that never ends, one that closes its output and goes on, one that ends and leaves a child holding its output. Each program must take 9 to 15 seconds, and nothing the step started may be left running |
| `doctor` | 10 ways of asking the real one; a made-up one for what it is given (its arguments, its folder, PATH once, `-I`), exit 5, two megabytes on each stream, signal 9; python3 from the step's own PATH, not the caller's |
| `port-prove-run.py` | 39 of 39 breaks caught |
| Earlier judges | `port-patch.sh` 105 of 105, `port-syntax.sh` 57 of 57, `port-stamp.sh` 82 of 82, wrong calls 47 of 47 |

One difference, kept: with an empty PATH `swan_run` looks nowhere and
names an error left over from before ("Invalid argument"); the Rust
program says "No such file or directory". Exit 127 in both
(docs/rust-port.md, "What differs").

Limits:
- Four things `trust` and `doctor` cannot show have no break; the prover
  lists them. Among them `doctor`'s own deadline of a minute.
- The judge takes about a minute, for the three deadline cases;
  `PORT_RUN_QUICK=1` leaves them out.
- Cases that need a folder or a file that cannot be written only show
  when the judge does not run as root.
- The suite was not run for this piece: no Goose source changed.

## 2026-11-22T07:26Z: stage 4: reading JSON, and the opening of `swan map`, in Rust

What was missing: the Rust program answered `swan map` with exit 70 before
doing anything, and could not read JSON.

Changed (branch `rust-stage-4`):
- `rust/src/json.rs`: Goose's own JSON reader, the part Swan uses. It takes
  and refuses the same texts, and reads strings, booleans and integers.
- `rust/src/seal.rs` (a step run through `bin/eggshell`), `wings.rs`
  (where spread-wings is), `survey.rs` (the survey, kept as survey.json,
  and the report's "projects:" lines).
- `walk.rs`: asking git, sealed, which folders it ignores; kept as
  git-ignored.txt and git-ignored-all.txt.
- `pipeline.rs`: the opening of a map. The map folder and its lock, trust,
  the languages a repo holds, a virtualenv, the survey, a clean map
  refused for another repo, an older map rebuilt, the mark of when the
  map began. Then the Rust map prints what it has said so far and stops
  with exit 70: the jobs, the indexers and the rows are not carried.

Checked, Goose program built from this branch against the Rust program:

| Judge | Result |
|---|---|
| `port-json.sh` | 159 of 159 texts read the same: 150 made up (67 of them JSON), 9 files of the repo |
| `port-prove-json.py` | 23 of 23 breaks caught (the first run: 22, and one not judged; below) |
| `port-map.sh` | 72 of 72 the same in the part of a map that is carried: 15 kinds of repo for the languages, 7 for a virtualenv and trust, 7 for what git ignores, 21 for the survey (18 with a made-up spread-wings), 14 for an older or a clean map, 8 fixtures |
| What is compared | the lines of the report the carried part writes, all of them and no others; the start of standard error; the four files written by then, and three a clean or an older map removes; when both end the same way (a refusal), all that is said, the exit code and the whole map folder |
| `port-prove-map.py` | 74 of 74 breaks caught (the first run: 69 of 74; below) |
| Earlier judges | `port-run.sh` 53 of 53, `port-patch.sh` 105 of 105, `port-syntax.sh` 57 of 57, `port-stamp.sh` 82 of 82, `port-pattern.sh` 182 of 182, wrong calls 47 of 47, `cargo test` 9 passed |

Where a judge was wrong first:
- The JSON prover's comparisons each built the Goose dumper again, at
  once, over each other; one could not compare. Built once and kept now.
- The map judge's first run had 53 of 61. All 8 were its own rules (a file
  a Python map writes later was watched; Goose's error wrapper was taken
  off the first line only).
- The map prover's first run caught 69 of 74. The judge took the Rust
  program's report for right when it was the start of the Goose program's,
  so a last line left out went unseen (two breaks); now the lines the
  carried part writes are named, and must be there, all and no others.
  Three more breaks had no case of their own: an older map with cached
  lists beside it, and a project whose folder is itself an ignored one.

Limits:
- A map is not made by the Rust program yet. The judge compares the part
  that is carried, and says so in its head.
- What trust adds to the seal is not shown by the carried part: the survey
  is never run trusted. Two other things have no break; the prover lists
  them.
- The judge keeps the Goose program's side in `build/port-map/` (about
  400 MB, mostly links to the checkout's indexers) and runs the made-up
  repos with `SWAN_TRUST_BUILD=1` in four cases, which loosens the seal
  for those repos alone. Nothing else is trusted.
- The suite was not run for this piece: no Goose source changed.

## 2026-11-22T07:49Z: stage 3 on main (#78); stage 4: the content stamps of `swan map` in Rust

On the owner's word ("merge continue"): #78, stage 3, was merged into main
(`245fb7e`), and main was merged into `rust-stage-4` (`7e0647a`). main's
tree was the commit this branch stood on, so the branch's tree is as it
was. A note of the review on #78 was taken up: the judges looked for a
repo given by a relative path from the repository, not from where they
were started.

What was missing: the Rust map stopped at the mark of when it began.

Changed: `rust/src/pipeline.rs` carries the map as far as line 1163 of
src/pipeline.goose. The folder of kept texts; each file's stamp, from
content-stamps.tsv when its size and time are as noted there, else from
the workers' lines, else by reading it; which files changed only in
comments or layout since they were indexed, and which must be indexed
again because the text their rows came from is unknown or lost.
`index_lines` is in `change.rs`. Then the Rust map stops, as before, with
exit 70.

Checked, Goose program built from this branch against the Rust program:

| Judge | Result |
|---|---|
| `port-map.sh` | 98 of 98 the same in the part of a map that is carried |
| The stamps' cases | 26: 300 files (4 workers by the usual floor; 3 asked for; one job; a second map of them, where none is stamped again), workers and threads on two files, a map again, a clean one, a comment changed, code changed, a file added, a comment changed with the time kept and with the size kept, the kept texts gone, the indexed text unknown, a record cut short, no record, a stamp that is no number, and four where Swan had moved the rows itself |
| `port-prove-map.py` | 99 of 99 breaks caught, the first time it was run |
| Earlier judges | `port-json.sh` 159 of 159, `port-run.sh` 53 of 53, `port-patch.sh` 105 of 105, `port-syntax.sh` 57 of 57, `port-stamp.sh` 82 of 82, `port-pattern.sh` 182 of 182, `port-plan.sh` 443 of 443, `port-trees.sh` 95 of 95 files, `cargo test` 9 and 2 passed. `port-store.sh` and `port-tables.sh` (stages 0 and 1, which take a flattened folder or a map) were not run again |

Jev's judgement of the port's state, asked for by the owner (one call,
1,927 tokens in, 234 out; docs/rust-port.md, "Found while porting", has
every answer): the evidence that the carried commands behave the same,
3.67 of 4; a byte comparison should not be replaced by a model, 0.11 that
it should; go on with the map in order, 98%. Evidence, not decisions: it
judged a summary the working agent wrote.

Limits:
- A map is still not made by the Rust program.
- The lines for content-stamps.tsv are gathered and not yet written: that
  file is written at the end of a map. The prover lists this and two more
  things the carried part cannot show.
- Two of the first 16 "differences" of this part were the judge's own
  (its pattern, and a Python list it watched on repos that have Python).
- The suite was not run for this piece: no Goose source changed.

## 2026-11-22T09:21Z: stage 4: TypeScript's config, tsc's list and the projects of a repo in the Rust map

What was missing: the Rust map stopped after the content stamps.

Changed: `rust/src/pipeline.rs` carries the map to line 1449 of
src/pipeline.goose. It asks tsc whether the repo's tsconfig can be read,
and says so and writes Swan's own config when it cannot; makes sure of the
indexer's patch (`ensure_scip_typescript_patch`, now in `tspatch.rs`);
works out how many places TypeScript may split into; asks tsc for its
files and their roots, or uses the list it kept, under a key of the files'
names and the configs' contents; and gives each file to the config that
owns it (`rust/src/tsproj.rs`, new, from src/tsproj.goose). With it came
what a child is given to run with (`child_env`), `jobs_limit`,
`ts_root_listing` and `lang_fingerprint`. Then the Rust map stops, as
before, with exit 70.

The judge was reworked to stay quick with tsc in it: cases run side by
side, each from a made-up home of its own; the Goose program's answers are
kept case by case, so a change to how the judge compares maps nothing
again; tsc can be a made-up program that says what a case needs.

What the prover found. Its first run on this part caught 203 of 214. Eight
of the eleven were one hole: a Rust program that did not ask tsc where the
Goose program does passed, because the judge accepted standard error that
was only the start of the Goose program's. The steps a part accounts for
are compared whole now. Two were cases that did not single their rule out,
and one was no break at all (docs/rust-port.md, "Found while porting").

Seen in Swan itself, and carried as it is (for the owner, after the port):
a repo with no tsconfig of its own never has its TypeScript split or
layered. tsc does not name the files of Swan's own config, whose `include`
is an absolute path, so the list is asked for on every map and never used.

Checked, Goose program built from this branch against the Rust program:

| Judge | Result |
|---|---|
| `port-map.sh` | 229 of 229 the same in the part of a map that is carried; twelve seconds with the Goose program's answers kept, three minutes without |
| The new cases | 131: real configs (read, not read, empty, a missing type library, another name); when tsc is asked at all (jobs, the floor of files, the places Python, cargo, Java, C and CUDA take); the indexer's patch in a home (missing, marked, stale mark, no indexer, half an indexer, turned off); the kept lists (again, clean, an older Swan's, another key, and seven repos changed after a first map); the projects of a repo (named folders, a chain of configs, ones tsc cannot read, a file two configs list, two configs in one folder, Swan's own config at the root, the limit of 64); 29 sets of answers from a made-up tsc; 15 of what a child is given |
| `port-prove-map.py` | 256 of 256 breaks caught: 254 in a run of them all, and the two it missed by the case added for them (the other 254 were not run again after that case went in) |
| Earlier judges | `port-json.sh` 159 of 159, `port-run.sh` 53 of 53, `port-patch.sh` 105 of 105, `port-syntax.sh` 57 of 57, `port-stamp.sh` 82 of 82, `port-pattern.sh` 182 of 182, `port-plan.sh` 443 of 443, `port-trees.sh` 95 of 95 files, `cargo test` 9 and 2 passed |

Limits:
- A map is still not made by the Rust program.
- What this part works out for the parts to come is not judged yet: the
  fingerprint of TypeScript's files, the words scip-typescript is started
  with, how many chunks beyond "none, one or more", which files are left
  to the root. The prover lists these.
- This machine has no clang++ on /usr/local/bin:/usr/bin:/bin and has
  Swan's JDK; on one that differs, the cases of the stand-in clang++ and of
  the JDK say something else (both programs alike) and their breaks may
  not be caught.
- Cases that leave the number of jobs to the machine need 6 GB of memory
  free to ask tsc at all.
- The suite was not run for this piece: no Goose source changed.

## 2026-11-22T16:48Z: stage 4: TypeScript's chunks and layers in the Rust map, and Goose's sort (the map's prover not yet run)

What was missing: the Rust map stopped once each TypeScript file had its
config.

Changed: `rust/src/pipeline.rs` carries the map to line 1739 of
src/pipeline.goose, the end of TypeScript. A project is cut into chunks by
size (`plan_ts`), each project of several by itself with its part of the
room; the last map's plan is kept while it holds the same files; what the
chunks share (the configs, package.json, the indexer, the declaration
files, the files tsc compiles that are no roots) is fingerprinted, and
each chunk by its files; an index is kept while the last map's record
names it with that fingerprint, and the report says "reused (no changes)";
the files changed since the last map, with the files that use what they
define (read from the last map's rows), are indexed as a layer over the
chunks while the layers cover no more than a quarter of the files and are
no more than six. The jobs are listed and the config of each chunk and
layer written. Nothing runs them yet: the Rust map stops there, as before,
with exit 70.

Goose's sort came with it (`rust/src/gsort.rs`, new, from Goose's own
`stdlib/std.goose`). It is unstable, and the plan holds the order it leaves
files of one size in: twelve keys `3 1 2 1 3 1 2 1 3 1 2 1` come out of it
as places `1 9 3 5 7 11 10 2 6 0 8 4`, and out of a stable sort as `1 3 5 7
9 11 2 6 10 0 4 8`. It has a judge of its own, `scripts/port-sort.sh`
(with `scripts/port-sort.goose` and `rust/src/bin/port-sort.rs`), and a
prover, `scripts/port-prove-sort.py`.

Not done: the map's prover has not run on this tree. It has 371 breaks,
115 of them new for this part, and every one fits the source; a run of the
new ones was stopped part-way when the session was ended on the owner's
word. Until it has run, the 88 new cases are not shown to catch what they
were made for. HANDOFF.md has it as the first thing to do.

What the sort's prover found. Its first run caught 29 of 31. One miss was
no break (a list of ten sorted the long way round comes out the same). The
other showed that the lists made to reach the heapsort never did: lists
that defeat a plain quicksort look already in order to Goose's sort, which
checks that first. The lists were remade, and 333 now reach it.

Seen on the way, in what is on main, and not mended here: a statement
written over several lines that SQLite cannot prepare is said by the Rust
program with one empty line more than by the Goose program, because the
Rust copies of those texts (stages 1 to 3) end with a line end and Goose's
texts do not. Seen with `query <db> impls a` and `callers a` on a map whose
`relationships` table was dropped. It is its own change on its own branch
(docs/rust-port.md, "Next").

The judge learned three things. A copy of a map says where its own indexes
are, so its second maps never kept an index before: the copy's record is
now moved with it, and "reused (no changes)" is compared. The config of
every chunk and layer is compared, wherever either program writes one. And
where both programs refuse a map, the record of indexes is compared with
each program's own folder taken out of it.

Checked, Goose program built from this branch against the Rust program:

| Judge | Result |
|---|---|
| `port-sort.sh` | 7,718 of 7,718 lists in the same order (7,268 with equal keys, 333 that reach the heapsort); under a second |
| `port-prove-sort.py` | 30 of 30 breaks caught |
| `port-map.sh` | 317 of 317 the same in the part of a map that is carried; four and a half minutes when the Goose program maps every case, seconds after |
| The new cases | 88: a project cut for two, three and four indexers at once, and as one chunk; files of one size; empty files; eight sources and seven; a reference at the edge of a source's first 4096 bytes; what tsc lists that is no source of the repo (a made-up tsc); several projects with one, two, four and eight places; and second maps of 16 repos changed after a first map (code, a comment, a file more, a file gone, package.json, a declaration file, a helper outside the config, four files and five, two changes in a row, two projects), with the record of indexes, the kept plan, the layers and the stamps each altered in the ways a rule turns on |
| `port-prove-map.py` | Not run. 371 of 371 breaks fit the source (`--fit`); the 256 of before were last all caught at `8dd4821` |
| Earlier judges | `port-json.sh` 159 of 159, `port-run.sh` 53 of 53, `port-patch.sh` 105 of 105, `port-syntax.sh` 57 of 57, `port-stamp.sh` 82 of 82, `port-pattern.sh` 182 of 182, `port-plan.sh` 443 of 443, `port-trees.sh` 95 of 95 files, `cargo test` 9 and 2 passed |

Limits:
- A map is still not made by the Rust program.
- The map's prover has not run on this part (above).
- What each job is to run and the record of the indexes are worked out and
  not judged yet: the jobs are first run, and the record first written, in
  parts still to be carried. That an index is kept is judged, by the line
  that says so.
- With Swan's own config at the root (a repo with none it can read), the
  fingerprint of what the chunks share takes in the path of the map
  folder, which each program has its own of: there the judge asks only
  that both programs keep one.
- The order in which files gone since the last map are taken is the order
  of a Goose dictionary. One case shows it, with a last map's rows altered
  by hand; no change to a repo that the judge makes reaches it.
- The machine's limits are as before (no clang++ on the plain PATH, Swan's
  JDK, 6 GB free for the cases that leave the number of jobs to it).
- The suite was not run for this piece: no Goose source changed.

## 2026-11-22T18:10Z: stage 4: the map's prover run on TypeScript's chunks and layers

The entry before this one said the map's prover had not run. It has now, on
the tree of `7fc1276`: `scripts/port-prove-map.py`, all 371 breaks, six
parts side by side.

| | |
|---|---|
| The unbroken program, in each of the six parts | the same: 317 of 317 |
| Breaks caught on the first run | 370 of 371 |
| The one let through | break 306, "an empty name in an earlier layer counts as a file" |
| Time | 66 minutes on 32 cores (3 to build the copies, 63 to judge them) |

The one let through is no break. Where the files of earlier layers are
counted, two checks stand side by side: the name is not empty, and the name
is not counted already. The second passes over an empty name by itself,
because every list of names ends in a line end and what follows the last
line end is an empty line. So the program without the first check does the
same in every case there can be. The break is taken out and named in the
prover's docstring under "Not among the breaks": 370 of 370.

So the 88 cases added for the chunks and layers are shown to catch what
they were made for. Nothing of the Rust program changed, and nothing of the
judge.

Limits:
- A map is still not made by the Rust program.
- A full run of the prover is an hour now, not the 40 minutes the handoff
  said: a judge is 317 cases, and twelve judges at once hold the load at
  twice the cores. No step ran past its deadline: the unbroken program
  passed in all six parts under that load.
- The suite was not run for this piece: no Goose source changed.

## 2026-11-22T18:18Z: stage 4: Python's pieces in the Rust map (no breaks written for them yet)

The Rust map is carried to the end of Python (src/pipeline.goose line
1920), planned and not run. It then stops with exit 70 as before.

What the part does, now the same in both programs: scip-python's two fixes
are made sure of in Swan's own copy, each with its mark and its line in the
report; a virtualenv of a repo that is not trusted is read and not run (the
one at the top, then the ones the survey names), its packages listed from
its site-packages folders through a stand-in interpreter written into the
map folder; a trusted repo's virtualenv is run as before, pip asked for, and
Python's own list taken when there is no pip; a src layout goes on the
search path; the pieces are planned, and each keeps its index while its
files, the search path, the packages and the Python are what they were and
no file in it uses what a changed file defines; indexes of pieces no longer
planned are removed.

| Judge | Result |
|---|---|
| `port-map.sh` | 395 of 395 the same in the carried part: the 317 of before, and 78 new |
| The new cases, first run | 59 of 78 the same. The 19 that differed were three faults of the judge (below), none of the Rust program |
| `port-prove-map.py` | No breaks for this part yet. 370 of 370 of the earlier ones fit the source (`--fit`), two of them anchored again because their text is now in two places or changed |
| Others | `cargo test` 9 and 2 passed, `port-patch.sh` 105 of 105, `port-plan.sh` 443 of 443 |

The 78 new cases: scip-python's files in the home plain, patched, marked
with another size, marked with line ends around the size, gone, empty and
holding something else, with the switch off, on and set to other words (17);
a virtualenv read, under each name, with two Pythons under lib, with no
Python named, run once trusted with a made-up python that has pip, has none
or answers nothing (14); the survey's virtualenvs from a made-up
spread-wings, one named twice, one in a folder git ignores, one whose name
ends another's, one that is not there (9); a src layout four ways (4); and
the pieces (34): a repo of five folder pieces and two file pieces mapped
again unchanged, clean, with one job, with an index gone, a record altered
seven ways, a stamp altered for a file nobody uses, for one another piece
uses and for a file that is a piece itself, a file whose indexed text is
unknown, stale index files, a file changed that another piece uses (5 of 7
kept: its piece and its user's), a file gone, a folder more, a package more
in the virtualenv, another Python named there.

What the judge learned:
- A copy of a map now moves its record of Python's pieces with it
  (`python-pieces.tsv` holds whole paths, as `index-manifest.tsv` does).
  Before, a second map kept pieces by finding the first map's files where
  they were made.
- A made-up home now has scip-python's two patched files and their marks as
  its own, and how they are left is compared after every case.
- Two things a later part of the Goose program does to what this part
  writes: where the indexers' runs are read, a piece whose run failed is
  taken out of the record (three cases name the record as a later part's,
  `LATER`); and at the end every `index-*.scip` no job names is removed (so
  the file watched to show that only `index-python-` names go is not a
  `.scip`).
- The three faults: a pattern for the report's line that took "projects'"
  and not "project's" (14 cases), and the two above (5 cases).

Limits:
- A map is still not made by the Rust program.
- The prover has no breaks for this part, so its 78 cases are not yet shown
  to catch what they were made for (AGENTS.md rule 4). The owner asked on
  2026-11-22 why the prover is used at all; he was told what it is for and
  what it costs (an hour a run now), and asked whether it should run after
  every part or once at the end of the stage. No answer yet.
- What each Python job is to run and with what is worked out and not
  judged: the jobs are first run in a part still to be carried.
- This machine's python3 has no pip, so the branch where pip answers is
  shown only by a made-up python in a trusted made-up repo.
- `python-env.json` from Python's own list holds the machine's packages.
  The Goose program's kept answers go stale when those change: remove
  `build/port-map/` then.
- The suite was not run for this piece: no Goose source changed.

## 2026-11-22T18:45Z: stage 4: every job of a map planned in Rust, and a repo with nothing to run mapped to its end

The Rust map is carried to where its jobs are run (src/pipeline.goose line
2187). After Python's pieces: the cargo projects (one rust-analyzer run
each, twelve at most, with the toolchain a folder pins), Java (scip-java,
with its own config when there is no build tool), C# (scip-dotnet), C and
CUDA (scip-clang, with a list of compile commands written when the repo has
none), what waits for `swan trust` and its line in the report, the
languages a server maps (`lsp-index`, a run for each Go module below the
top), and the syntax index. A repo with nothing to run is now mapped to its
end by the Rust program: an empty map, or "no language found to index".

| Judge | Result |
|---|---|
| `port-map.sh` | 440 of 440 the same: the 395 of before, and 45 new |
| Of the 440 | 32 end as the Goose program ends (a map made, or a map refused) and are compared whole; 408 stop with exit 70 where the jobs would run |
| The new cases, first runs | Rust's 10: 9 the same, the tenth a fault of the made-up repo (below). Java, C#, C and CUDA's 26: all the same. The servers' languages and the endings' 9: all the same |
| `port-prove-map.py` | No breaks for these parts. 370 of 370 of the earlier ones fit the source (`--fit`) |
| Others | `cargo test` 9 and 2 passed, `port-plan.sh` 443 of 443 |

The 45 new cases: a cargo project at the top, trusted, not sealed, both;
one with a second project inside it, mapped again and with a source
changed; fourteen projects side by side; a pinned toolchain that is not
installed and one that is, older than the default (10). Java alone, mapped
again, and with each file that names a build tool; Kotlin with Gradle and
with Maven; C# with each kind of project file and with none at the top; C,
C++ and CUDA, mapped again, with `$CUDA_PATH` set, and with the repo's own
compile commands in each place; everything that waits for trust in one
repo, sealed and not (26). Go modules below the top with a file outside
them, with a go.work, with the top among the modules, with one module, with
no survey; a repo of Kotlin alone mapped clean, again, and again clean; a
repo of nothing mapped clean (9).

What the judge learned:
- Where both programs end the same way, the map itself is compared by its
  rows: every table as text, each program's own folder and the two times a
  map notes of itself apart. (Before, such an ending never left a map.)
- rust-analyzer's settings file is compared wherever either program writes
  one, and scip-java's config and the list of compile commands always.
- A trusted map may write in the repo: cargo wrote a `Cargo.lock` into a
  made-up repo during the Goose program's run, and the Rust program then
  surveyed a repo that had changed. The made-up cargo projects now carry
  the lock file cargo would write.
- A made-up Cargo.toml held a line end as two characters, so the project
  inside another never loaded and "rust project fuzz: reused" was never
  said. Found by reading what the Goose program had said of the case.

What differs, and is meant to: the index `lsp-index` writes and the syntax
index are kept while a fingerprint holds that takes in the program that
made them (its path and size). The Rust program therefore never keeps one
the Goose program made, and the two lines that say such an index is kept
are left out of what the judge compares.

Limits:
- A map with anything to run is still not made by the Rust program.
- The prover has no breaks for Python's pieces or for these parts: 123
  cases are not yet shown to catch what they were made for (AGENTS.md rule
  4). The owner has been asked how the prover should be used from here.
- Trusted Java and C# are not judged: the Goose program would run Maven,
  Gradle or `dotnet restore` from the network on the made-up repos. So the
  Gradle tasks and what a Gradle run is given to run with are carried and
  not compared.
- scip-java's index is never shown kept: its fingerprint takes in the map
  folder's path, and the judge's second maps start from a copy made
  elsewhere. That it is *not* kept there is compared.
- What each job is to run is worked out and not judged until the jobs run.
- The Goose program keeps what waits for trust for `swan serve` to say
  (`map_held`); that comes with the server.
- The suite was not run for this piece: no Goose source changed.

## 2026-11-23T14:15Z: stage 4: `swan map` whole in Rust; a new map the Rust index left locked, mended; the Goose program is no longer matched

On the owner's word the port changed its method twice today (DECISIONS.md,
13:36Z and 14:15Z): what is left is not copied line by line, the provers
are not run, and the Goose program is no longer the thing to match. What
follows was done between the two.

What is now true: the Rust program makes a whole map. It starts the
indexers a map needs (as many at once as the Goose program, each sealed),
waits for them, says what each took or how it failed, flattens, stores,
moves the rows of files edited only in comments or layout, and ends its
report (src/pipeline.goose to its end).

| | before | now |
|---|---|---|
| Of the 440 made-up cases, maps the Rust program takes to their end | 32 | 440 |
| Of those, the same as the Goose program's (report, files, rows) | 32 | 440 |
| Agent-Reach (Python, 89 files), mapped sealed by both | not made by Rust | 3,768 symbols, 19,593 uses, 67 relationships in both; every table's hash the same but `meta` (its folder and times); 8 s each |
| relate (Rust, 2,211 files), mapped sealed by the Rust program | not made by Rust | 58,564 symbols, 737,824 uses, 38 s; its one Go folder not mapped (Limits) |

Found by running a map to its end, and mended: after writing a *new* map
the Rust `index` left its connection open, and a new map is written under
an exclusive lock, so nothing later in the same run could read it
("database is locked"). The Rust took `syms` out of a struct and left the
struct's two statements alive to the end of the function; a connection
closed with a statement still open stays open. No comparison of stages 1
to 4 saw it, since `swan index` ends right after. It showed as a line the
Goose program does not say ("rust: no rows for these crates: ."), 12 cases
of 440. `rust/src/index.rs` lets the two statements go, and
`rust/src/db.rs` now stops the run when a close does not close. The fault
is in the Rust on main since stage 1; that Rust is not built or shipped.

In Rust for the map's end: `spawn_job` and `wait_any` in `sys.rs`; the
rest of `change.rs` (`shift_cosmetic`); `edit.rs`, begun (`offset_of`,
`col_of`, `mark_edited`); `rust_unmapped` in `rustproj.rs`; the end of
`pipeline.rs`. Until the language-server client is in Rust,
`SWAN_PORT_GOOSE=<a Goose build of swan>` makes the Rust map start that
program for its `lsp-index` child.

`scripts/port-map.sh` compares whole maps now: the report, the files of
the map folder and every row of the map, each program's own folder taken
out. What it takes out besides, each seen and explained
(docs/rust-port.md, "Found while porting"): the time a map was refreshed;
"up to N indexers at once", which follows the free memory; what a failed
job said; three fingerprints that take in a path of each program's own and
one that takes in the time; Go's build folder and the servers' logs; the
rows scip-clang gives, which differ between two runs of the Goose program
itself; and the order scip-java gives its files back in, for one fixture.

Checked on this tree: `port-map.sh` 440 of 440; `cargo test` 9 and 2;
`port-store.sh` on Agent-Reach, 1,806 questions answered the same;
`port-compare.sh --wrong-calls` 47 of 47; `port-patch.sh` 105 of 105;
`port-run.sh` (quick) 50 of 50.

Limits:
- A repo with Go or Goose files: the Rust program has no `lsp-index` yet,
  so that job fails, is said, and the rest of the map is made (relate: 38
  files fewer than the 2,249 of the Goose program's stored map).
- C and CUDA rows are not compared, and one Java fixture is compared in
  any order (above).
- No prover was run and none will be, on the owner's word. The cases added
  since 2026-11-22T18:10Z have never been seen to fail.
- Trusted Java and C# are still run by neither program in the judge.
- `map_held` (what waits for trust, kept for `swan serve`) is not in Rust.
- The suite in the microVM was not run: no Goose source changed, and the
  Rust program cannot stand in `bin/` before its server is built.
- No pull request, nothing merged, nothing installed.

## 2026-11-23T15:00Z: `swan lsp-index` in Rust, on a language-server client built on Rust libraries; the Rust program maps Go and Goose files itself

Asked by the owner the same morning: open RustRover and use its MCP to help
build the Rust; look at serena-rs and at what exists on the net; SolidLSP as
the stable way to run a language server.

What is now true: the Rust program maps a repo's Go files (through SolidLSP
behind `tools/solidlsp/bridge.py`) and Goose files (through `goose lsp`)
with no help from the Goose program. `SWAN_PORT_GOOSE`, added three hours
earlier, is gone.

| | Goose program | Rust program |
|---|---|---|
| cobra (Go, 37 files), sealed, not trusted | 798 symbols, 6,732 uses, 3 relationships; 7.1 s | the same rows (every table's hash but `meta`); 4.7 s |
| relate (Rust with three Go folders, 2,249 files) | 59,489 symbols, 741,781 uses, 33.6 s; a second run 59,488 and 741,775 | 59,488 symbols, 741,782 uses, 33 s; before today its Go folders were not mapped by it |
| The 440 made-up cases of `scripts/port-map.sh` | | 440 of 440 the same, the Go and Goose ones now through the Rust `lsp-index` |

relate's one-symbol gap is scip-clang's: two runs of the Goose program
differ from each other by the same kind of row (`cxx . . $ size_t#`), as
seen on the C fixtures earlier today.

What was built:
- `rust/src/lsp.rs` (new): a synchronous client. A server is started in a
  process group of its own, sealed when its entry says so and this process
  is not inside the seal already (the condition and the call are those of
  `src/live.goose`); every question has a time limit; the server's own
  requests are answered while waiting; the whole group is killed when the
  client goes. Failures are one of four kinds: could not start, timed out,
  the server said no, the server went away.
- `rust/src/lspindex.rs` (new): the files of the language, each one's
  symbols, each definition's references, what implements each interface;
  written as SCIP with the `scip` crate, named as before so maps made
  earlier still line up.
- `rust/src/modules.rs`: a language's server read from
  `tools/modules.json`: which entry applies, its placeholders, and that an
  entry which runs the repo's code is used for a trusted repo only.
- New libraries, all permissive: `lsp-server` 0.10 and `lsp-types` 0.97
  (the messages), `serde` and `serde_json`, `scip` 0.10.
- Why it is faster: the old client waits 2 s after its first question for
  news of indexing that neither server sends (the worker's reading of
  `lsp/golsp.goose`; the other 0.4 s on cobra is not accounted for).

How it was built: a research agent surveyed the crates and serena-rs
(docs/rust-port.md, "What exists in Rust to build on"); a worker agent wrote
the client with RustRover open on `rust/` and asked through its MCP server
(`get_file_problems`, `lint_files`, `get_symbol_info`); the sealing was
then read against the Goose source and every number here rerun by the lead.
RustRover's inspections also found code written twice in `sys.rs` and two
needless casts from earlier in the day; both mended.

Checked on this tree: build with no warnings; `cargo test` 16 and 2 (7
new: a server that never answers, one that answers once and stops, one
that exits, each ending inside its limit with no process left; three were
broken on purpose and seen to fail); RustRover finds no errors in the
seven changed files; `port-map.sh` 440 of 440; cobra and relate above; no
gopls or bridge process left after any run.

Limits:
- A silent server is given 120 s before the job fails. That is the old
  client's limit, kept; a map with such a server waits that long once.
- Not judged against GoLand yet: GoLand has no trusted folder for the
  trial repos, and adding one is the owner's to do.
- `swan lsp-ask` and the live answers are not in Rust. `{java_source_paths}`
  is not filled in for a server's settings (no language mapped this way
  needs it).
- The index file `lsp-index` writes has other bytes than the Goose
  program's (another writer); its rows once flattened are the same.
- The Rust program now carries Apache-2.0 libraries; what a shipped binary
  must say of them (NOTICE) is for when it ships.
- The suite in the microVM was not run: no Goose source changed.

## 2026-11-25T09:04Z: Lua and PHP mapped through their language servers by the Rust program; shell and Ruby measured and left by name

What was wrong: four languages had no compiler-grade map. Lua, shell and
Ruby were matched by name (the syntax index) and PHP was only searched. On
Penlight (117 Lua files) every one of 11,895 references was a name match;
on Slim (125 PHP files) the map held no row at all.

The owner, 2026-11-25: "ok keep going with the next languages".

What changed (branch `rust-lsp-languages`, from `rust-stage-4`; the Rust
program only, nothing that ships behaves differently):
- `tools/modules.json`: a language entry may hold `"map_lsp"`, the servers
  `swan lsp-index` starts for the map. Only the Rust program reads it; the
  Goose program knows `"map"` and `"lsp"` and is unchanged (below). A
  candidate's `"needs"` names the real server behind the bridge, so a
  server not fetched is seen before a job is planned. Lua has one
  (lua-language-server 3.19.2, already fetched) and PHP is a new entry
  (PHPantom 1.1.0, MIT, a pinned fetch in `scripts/fetch-tools.sh`, group
  `php`).
- `rust/src/modules.rs`, `pipeline.rs`, `lspindex.rs`: which languages are
  mapped this way and which files are theirs come from the entries (the
  hard-coded list is gone). What a function declares inside it is not
  mapped. When a language's server fails, or is not fetched, its files are
  mapped by name in the same map and the report says so. A job's
  fingerprint takes in its servers as written and the size of each file
  they need. An implementation answer may name where a symbol starts
  (PHPantom gives a class from its `class` keyword).
- `tools/solidlsp/bridge.py`: SolidLSP's per-language settings from
  `SWAN_SOLIDLSP_SETTINGS` (a server fetched ahead is named, nothing is
  downloaded at map time); `SWAN_SOLIDLSP_HOLD_OPEN=1` keeps a file open
  across questions (a map only); `SWAN_SOLIDLSP_UNOPENED=1` sends each
  question as asked and opens no file. Without either it does what it did.
- `rust/tests/lsp_languages.rs`, `fixtures/lsp-lua`, `fixtures/lsp-php`.
- docs/languages-through-servers.md: each language's verdict, numbers,
  traps, and the recipes that were not kept.

| | Before | After |
|---|---|---|
| Penlight, Lua, 117 files | 0.2 s; 941 definitions, 11,895 references, all by name | 18.7 s; 6,026 definitions, 17,796 references, all from the server |
| Slim, PHP, 125 files | 0.1 s; no rows | 1.2 s; 1,119 definitions, 4,387 references, 194 implements |
| cobra, Go, 36 files | 4.8 s; 789 definitions, 5,920 references | the same, every table's hash but meta equal |

- Lua, 20 sites read where the two maps disagree: the server right at 17,
  the match by name at 3 (calls through a file-level alias, which the
  server links to the alias). Mapping every symbol the server lists took
  224 s; leaving out what functions declare inside them 84 s; holding files
  open 18.7 s.
- PHP, 28 references read in the source: 28 right. SolidLSP's launcher
  sleeps 1 s before each references question (1,123 s on Slim); going
  around it loses nothing: 1,116 of 1,119 definitions answer as in the slept
  run, and the difference is five more references, each right.
- Shell (bash-language-server, bats-core, 54 files): 8.2 s against 0.78 s,
  and of 10 disagreements read the server was right at 5; every reference
  only it had sat on another definition of the same name. Not kept: its
  answers are name matches that would be stored as resolved.
- Ruby (ruby-lsp, rack, 104 files): methods matched by name (of 81 method
  names defined more than once, 74 got the same references for every
  definition), 70 ms a question, no implementations. Not kept. Getting it
  to run without the repo's code took four stops (the repo's Gemfile, the
  repo's `ruby_lsp` add-ons, SolidLSP choosing `mise exec` or `bundle exec`
  from the repo's files, RuboCop's `require`); each is in the doc with the
  launcher that was measured. Solargraph answers by type and evaluates the
  repo's gemspecs and Gemfile: not for a repo that is not trusted.

How it was built: two worker agents at once, one building Lua and shell in
the Rust program and one finding the PHP and Ruby recipes in a scratch
folder; a third took shell back out, cut Lua's time and added PHP. The lead
read every change, reran the numbers above, and changed one thing: the
worker's bridge held files open for every caller, which would have had the
Goose program's live Go answers come from a copy opened before an edit; it
is now a setting only Lua's map entry gives. A second opinion on the
`"map_lsp"` key came from the architect profile (it agreed, and named the
test below).

Checked on this tree: build with no warnings; `cargo test` 24 (2, 17 and
5; 6 new; each new behaviour broken on purpose and seen to fail: `map_lsp`
ignored, locals mapped, no fallback, the class-start match, the PHP sleep
back, the fingerprint, a server not here); RustRover finds no errors in the
changed Rust files. The Goose program with the old and the new
`tools/modules.json` and bridge gives the same rows, by the hash of every
table but meta, on fixtures tiny-lua, tiny-game, tiny-syntax, tiny-go and
go-modules. Go and Goose rows from the Rust program are as before on
tiny-go, tiny-goose and cobra. No server process is left after a map, on
success or on failure, and a map writes nothing into the repo it maps.
`scripts/port-map.sh`: 14 of 440 now differ, each in the report's text (an
lsp-index line carries its counts; Lua and PHP are mapped), as meant.

Limits:
- Not judged against an IDE: PhpStorm (PHP) and GoLand (Go) each need the
  trial repos' folder among their trusted locations, the owner's to add.
  There is no JetBrains IDE for Lua here.
- A Lua map costs about 2 ms a definition; one changed Lua file redoes the
  language's whole job.
- PHP calls through a type from a package resolve to nothing in a repo as
  cloned (`vendor/` is filled by composer, the repo's package manager).
  PHPantom answered one call on Slim differently from run to run.
- Two things the Rust program now does differently from before for Go: a
  Go file outside every module is mapped by name (it was not mapped), and a
  Go server that fails leaves by-name rows and a line in the report, not a
  failed map.
- Found on the way, not mended here: `swan map` gives its sealed children
  its whole environment. Inside the seal there is no network, but a child
  can write what it reads into the map folder. HANDOFF.md has it.
- The report's first line still says "(syntax only)" of Go and Lua.
- The suite in the microVM: on this tree as it was before these records
  and one later change to `scripts/fetch-tools.sh` that no check runs
  (PHPantom is fetched in a dev checkout only): 58 + 322 checks, 0 failed,
  56 Python tests OK. None is new; the new checks are the Rust tests above.

## 2026-11-25T12:15Z: `swan lsp-ask` and `swan broke` in the Rust program; a Rust check that did not run is no longer a clean answer

What was wrong: the Rust program had no live answers. `swan lsp-ask` (one
question to a file's language server) and `swan broke` (the errors new in
a file since last asked, which the post-edit hook runs) each ended with
exit 70. And, found on the way, in the program that ships: when the Rust
compiler check cannot run, `swan broke` says "nothing new". On a copy of
this repo's `rust/` folder whose build script fails, a planted type error
was answered asked, nothing new, exit 0.

The owner, 2026-11-25: "continue" (after "ok keep going with the next
languages"). The two IDE judges still wait on him, so this is the next
piece in the handoff's order.

What changed (branch `rust-live-answers`, from `rust-lsp-languages`; the
Rust program only: no file outside `rust/` and README.md, so nothing that
ships behaves differently):
- `rust/src/lsp.rs`: the client keeps what a server says unasked
  (published diagnostics, work in progress, its status) in one state that
  every wait feeds. A watcher in the server's process group kills the group
  when swan itself is killed: the hook kills `swan broke` with SIGKILL at
  its timeout, and no cleanup runs then.
- `rust/src/modules.rs`: a server's `settle` as a type (publish, with or
  without a quiet spell; pull; check), and the live server chosen from a
  language's `"lsp"` entries by the same rule as the map's (trust, needs,
  conditions). tools/modules.json is as it was.
- `rust/src/live.rs` (new): one running server for one language of one
  repo. The file on disk is the truth: read, sent once, asked. One time
  budget per command (100 s, `SWAN_LIVE_BUDGET_MS`), under the hook's 120 s.
  A path that leaves the repo, a missing file and a file that is not UTF-8
  are refused before a server starts. A settle that does not happen is "not
  settled", never an empty answer.
- `rust/src/broke.rs` (new): the shipped command's JSON keys and its
  `broke-seen.tsv`, so the hook and a map folder work with either program.
  On purpose it differs in four things: one server per language in turn; a
  file that could not be asked says why and keeps its remembered lines; the
  seen file is written under a lock; exit 3 when nothing new was found but
  a file could not be asked (the shipped program exits 0 there).
- Rust files: with rust-analyzer saying its health is not ok, the errors it
  reports are passed on and "no errors" is not given as an answer.
- `rust/tests/live.rs` with a scripted server (`rust/tests/fake_lsp.py`),
  and `rust/tests/live_servers.rs` with the real ones.

Seconds for one ask through the real hook, on a scratch copy, each program
with its own sealed map: the clean file first, then after one planted
error. The hook's words were the same from both programs in all ten cases.

| | The program that ships | The Rust program |
|---|---|---|
| cobra, Go (sealed, through SolidLSP) | 5.8, then 3.3 | 3.4, then 0.9 |
| Penlight, Lua | 2.0, then 1.9 | 1.9, then 1.8 |
| Agent-Reach, Python | 0.7, then 0.7 | 0.7, then 0.7 |
| Understand-Anything, TypeScript | 0.8, then 0.8 | 0.8, then 0.8 |
| rea, TypeScript, 154 MB | 6.0, then 6.0 | 6.1, then 6.0 |
| this repo's Rust, trusted, building | 22.7 cold, then 2.5 | 22.7 cold, then 2.5 |
| this repo's Rust, its build script failing | asked, nothing new, exit 0: wrong | not asked, exit 3, with rust-analyzer's own words |

- Go is faster because the shipped client waits 3 s after start before it
  asks any server that is pulled (a rule made for the Kotlin server).
- relate (Rust, not trusted): both programs refuse with the same note and
  start nothing.
- swan killed with SIGKILL in the middle of a question: Go's six processes
  (sealed), TypeScript's five, Lua's two and Python's two were gone a second
  later. Before the watcher a cold Rust check left cargo and a build script
  running, and Go's bridge left four processes.
- The map is as it was: Penlight 17.6 s before and 17.5 s after with the
  same counts, Slim 1.1 s with the same counts.
- On fixture copies by hand, the same three checks (a clean file, a planted
  error, a definition in another file): clangd 0.4 s, the three shader
  languages 3.6 s each, Goose 0.6 s.

What the real servers showed that the shipped client's rules did not
expect: the TypeScript server starts loading its project 9 ms after a file
is opened and answers a question asked before that from no project (the
shipped program is right only because it waits 2 s anyway); rust-analyzer
runs its check once its workspace is loaded, saved or not; gopls puts its
children in a session of their own, which only the seal's own process
namespace reaches.

How it was built: one worker agent built it from a shape the lead named;
the architect profile was asked first and cut three things (PHP's live
entry, telling a server of a changed file, and waits that cannot be run
here). The lead read every line, reran every number above with a probe of
its own (`swan-broke-probe` in the owner's tools folder), and that probe is
what found the false "nothing new" for Rust. The worker then found the
cold case behind it.

Checked on this tree: build with no warnings; `cargo test` 46 (2, 18, 15,
6 and 5), 22 of them new, each new behaviour broken on purpose and seen to
fail; RustRover reports no errors in the eight changed files and resolves a
call from broke.rs into live.rs. The suite in the microVM was not run: it
judges the Goose program, and this change touches nothing that program
reads or runs.

Limits:
- The program that ships still gives the false "nothing new" for a Rust
  check that did not run. It is not changed here.
- The hook prints only new errors, so "could not ask" reaches an agent as
  silence, the same as "nothing new".
- No server is kept running, and a server is never told that a file
  changed: each command is one process. A second question about a file that
  changed on disk is refused. This comes with the MCP server.
- Java, Kotlin and C# were not run. Java's entry has a placeholder nobody
  fills in, so its live server is refused; the Kotlin server's wait for its
  import is not carried.
- PHP has no live server: the bridge's diagnostics path opens the file,
  which PHPantom's setting exists to avoid. Its own branch.
- Line and column go to the server as given, in its own units (UTF-16).
- One budget for a command: a silent server uses up the time of the
  languages after it.
- That a pulled server is asked only once it is ready was shown on the
  scripted server alone: Go's bridge reports no progress.
- With rust-analyzer not healthy for a reason that does no harm, a clean
  Rust file is answered "not settled" every time.
- A live server runs sealed only when its entry says so, as in the program
  that ships: the Python, TypeScript, C, Lua and shader servers do not.

## 2026-11-26T07:04Z: a Rust check that did not run is no longer a clean answer

What was wrong: live diagnostics for Rust settle on rust-analyzer's check.
When the check does not run, the server ends its progress and publishes
nothing, and the answer was "no errors". On a copy of fixtures/tiny-rs with
a build.rs that exits 1 and a type error added to src/lib.rs (trusted: our
own fixture), `swan broke` said `"asked":true` with nothing new, before
and after the error was added. The post-edit hook passed that on as
silence.

What changed: the client library (`lsp/`, goose-lsp branch
`check-health`, `2daeb2c`) keeps the health and message of
`experimental/serverStatus`. Once a check has settled, a status that says
the check did not run, with no error in the file's set, answers
`not settled:` in the server's words; errors that were found are still
returned. "Did not run" is rust-analyzer's own two sentences for it: "cargo
check failed to start" and "Failed to run build scripts". Nothing in
`src/` changed: a refused answer already read `"asked":false`.

| `swan broke` on the crate | before | after |
|---|---|---|
| build.rs exits 1, type error added | asked, nothing new | not asked: "not settled: Failed to run build scripts of some packages. …cargo check failed to start…" |
| healthy | asked, nothing new | the same |
| healthy, type error added | the error on line 61, new, exit 1 | the same |

What the microVM found: the rule first built was "any health other than
ok". In the VM rust-analyzer warns that the standard library's sources are
not installed ("has sysroot errors"), cargo check runs all the same, and
the two live checks that expect a clean file failed (322 passed, 2
failed). The rule became the two sentences; that warning does not refuse.

Checked:
- goose-lsp's own test: 27 answers, 4 of them new. On the client from
  before, the first new case fails (`{'ok': True, 'diagnostics': []}`);
  with any warning refusing, the second does.
- A new check in the live suite maps the crate with the failing build.rs
  and expects the refusal, and one more that the server is stopped.
- `scripts/space-test.sh` in the microVM on `fc7c210`: 58 checks
  passed, 0 failed; the cosmetic, layer and piece checks passed; 56 Python
  tests OK; 324 checks passed, 0 failed (322 before). Exit 0.

How it was made: an Antigravity swarm (`agy-task --swarm`) wrote the
change in a copy, from a brief. The rule was corrected by hand after the
microVM run, and every number above was measured again outside the swarm.

Limits:
- The two sentences are rust-analyzer's wording (0.3.3089, the pinned
  one). If a later version words them otherwise the live suite's new check
  fails; nothing else would say so.
- For a refusal of this kind `why` in `swan broke` is still the
  library's whole JSON answer as text, and the exit is still 0; the hook's
  own pull request changes both.
- The pin is a commit on goose-lsp's branch. It stays reachable from that
  repo's main when the pull request there is merged with a merge commit,
  as its earlier ones were; a squash would need the pin moved.
- This entry is one commit after the tree that was tested; that commit
  changes STATUS.md and DECISIONS.md only.

## 2026-11-26T07:04Z: the post-edit hook says when a file could not be checked

What was wrong: after an edit the hook
(scripts/hooks/what-broke-after-edit.py; the Hermes plugin runs the same
script) said nothing when the file could not be checked at all, and
silence read as "clean". On an untrusted copy of fixtures/tiny-rs,
`swan broke` answered `"asked":false` and left with exit 0, and the
hook printed nothing. Beside it, an answer the server had not settled in
time was taken for a full answer.

What changed:
- `swan broke` and the `what_broke` tool: a file not asked has a
  `reason` (`no_server`, `untrusted`, `unsettled`, `failed`)
  and, when a live server exists for it, `first_time`: true the first
  time it is not asked for that reason. One line for it is kept in
  broke-seen.tsv (`file<TAB>not-asked|reason|`) until the file is asked.
  An answer with `"settled":false` is not asked. `why` holds the
  client library's own words for a refusal, not its JSON. Exit 3 when
  nothing is new and a file was not asked (the Rust rebuild's numbers).
- The hook: a note, once per file and reason, as PostToolUse context when
  there are no new errors (exit 0), and after the error lines when there
  are (exit 2). Nothing for a file with no live server. It never prints
  `why` and never names a way to trust a repo.
- The Hermes plugin reads the note the same way.

| untrusted tiny-rs | before | after |
|---|---|---|
| `swan broke`, first ask | asked false, exit 0 | asked false, reason untrusted, first_time true, exit 3 |
| `swan broke`, second ask | the same | first_time false, exit 3 |
| the hook, first edit | nothing | "Swan did not check src/lib.rs: checks that run this repo's build are off for it by its owner's choice. Errors from this edit will not be reported here; verify another way." |
| the hook, second edit | nothing | nothing |
| a Markdown file | nothing, exit 0 | nothing; reason no_server, exit 3 |
| tiny-py, an error added | the error, hook exit 2 | the same |

Checked:
- Four new checks in the lang suite (a Markdown file, an untrusted Rust
  file asked twice, a file the server cannot read) and 8 new Python tests:
  7 drive the real hook with a stand-in swan, 1 the plugin.
- `scripts/space-test.sh` in the microVM on `d605b01`: 58 checks
  passed, 0 failed; the cosmetic, layer and piece checks passed; 64 Python
  tests OK (56 before); 326 checks passed, 0 failed (322 before). Exit 0.
- By hand, this build and the build from before on the same copies: the
  table. The Swan from before reads a seen file that holds the new line
  and answers as it did.

How it was made: an Antigravity swarm (`agy-task --swarm`) wrote the
change in a copy, from a brief; the words in `why` and the check for
them were added by hand, and the table was measured outside the swarm.

Limits:
- "unsettled" was not seen with a real server (it takes one that says
  nothing for two minutes): that path was read, and the hook's side of it
  is tested with the stand-in.
- The Rust rebuild's `swan broke` gives no `reason` or `first_time`
  yet. The hook treats such an answer as before, with silence; the rebuild
  has to follow before it replaces this program.
- The note is said once per file. A long session may have forgotten it by
  the time it matters.
- The seen file is written without a lock in this program, as before.
- This entry is one commit after the tree that was tested; that commit
  changes STATUS.md and DECISIONS.md only.

## 2026-11-26T07:05Z: `get_callers` also names the callers the compiler index could not resolve

What was wrong: `get_callers` answered from the compiler index alone, and
a call the indexer could not resolve was missing with nothing to say so.
On a two-file Python fixture, `paths.ensure()` inside
`def untyped(paths, args)` (no type on the parameter) is not in the map,
beside the same call in `def typed(paths: Paths, args)`, which is:
`get_callers` of `Paths/ensure` listed one caller of two. It was found
by asking Swan, Spread-Wings and a hosted code graph who calls thirty
functions of a private repo: the other two named a caller Swan lacked.

What changed: the answer gains a separate list, `possible_callers`, for
distance 1. It holds the call sites Spread-Wings ties to the definition by
syntax that the exact answer does not have and that the index does not
resolve to another symbol, each with `how` it was tied (Spread-Wings'
own resolution; `by_name` means any definition of that name could be the
one called), at most 50 with the full count in `total`. It is never
merged into `callers` or counted in `summary`. The key is left out
when there is nothing; when Spread-Wings cannot be asked it reads
`{"checked": false, "why": ...}`. The read snapshot is released before
Spread-Wings runs. The tool's description, the README's row and the
swan-code-check skill say the same.

| | before | after |
|---|---|---|
| the fixture, callers of `Paths/ensure` | `typed` | `typed`; possible_callers: pkg/cli.py line 5, in `untyped`, how `imported_file` |
| a private repo, 903 functions asked | no such list | 21 functions gained one, 33 sites in all |
| one answer on that repo, median | under 1 ms | 67 ms (95 in 100 under 75 ms; the first one 486 ms, while the graph is made) |

The 33 sites, read in the source: 30 are calls of that function (calls
from test files that are outside the TypeScript project, through a
dynamic import, through a table of functions, on an untyped parameter,
and the one this started with); 3 are `tree.validate(...)` matched by
name alone, which the list says of them.

Checked:
- Five new checks in the lang suite: the fixture's two targets, a symbol
  with nothing by syntax (no key), and Spread-Wings missing.
- `scripts/space-test.sh` in the microVM on `8ddfe79`: 58 checks
  passed, 0 failed; the cosmetic, layer and piece checks passed; 56 Python
  tests OK; 327 checks passed, 0 failed (322 before). Exit 0.
- By hand with this build and the build from before: the table.
  `swan query <db> callers` on the command line answers as before,
  without the list.

How it was made: an Antigravity swarm (`agy-task --swarm`) wrote the
change in a copy, from a brief; the measure on the private repo and the
reading of its 33 sites were done outside the swarm.

Limits:
- Every `get_callers` now starts Spread-Wings, sealed, to bring its
  graph up to date: about 60 ms more an answer on these repos. By the
  swarm's own timing on the fixture most of it is starting the seal (36
  ms) and a 20 ms sleep while waiting for the child; that was not measured
  again, and nothing was done about it.
- Distance 1 only. A test file that appears only in `possible_callers`
  is not among `summary.test_files`.
- A call written over several lines could be listed though the index has
  it on another line: sites are compared by file and line. None was seen
  among the 33.
- Measured on Python and TypeScript. Not judged by an IDE.
- This entry is one commit after the tree that was tested; that commit
  changes STATUS.md and DECISIONS.md only.

## 2026-11-26T07:08Z: the check rule corrected in the Rust program; three fixes to the program that ships are in pull requests

What was wrong here: since 2026-11-25T12:15Z the Rust program refused a
clean answer for a Rust file whenever rust-analyzer's health was not "ok".
When the same rule went into the program that ships (#79), the microVM
showed what it costs: rust-analyzer warns there that the standard
library's sources are not installed ("has sysroot errors"), cargo check
runs all the same, and every clean file was refused. Two live checks that
expect a clean file failed (322 passed, 2 failed).

What changed here (rust/src/live.rs): `check_not_run`. A set with no
error is refused only when the status holds rust-analyzer's own sentence
for a check that did not judge the code, "cargo check failed to start" or
"Failed to run build scripts"; the reason given starts at that sentence.
The scripted server has a mode with the sysroot warning, and there is one
new test.

Checked here: `cargo test`, 47 pass (46 before; 2, 18, 16, 6 and 5), no
warnings. The new test fails on the rule from before (asked false where
true is expected). The test with the real rust-analyzer, cold and warm,
passes as it did.

The program that ships, on the owner's word of this day ("i follow your
recommendations, using antigravity swarm abilities to attack and fix
places you need"). Each change was written by an Antigravity swarm
(`agy-task --swarm`) from a brief, in a copy, then read, built and
measured outside it, each on its own branch from main:

| pull request | what it makes true | the suite in the microVM |
|---|---|---|
| #79, with goose-lsp#7 | a Rust check that did not run is "not settled", not "nothing new" | 58 + 324 checks, 0 failed; 56 Python tests (`fc7c210`) |
| #80 | the post-edit hook says, once per file and reason, that a file could not be checked; `swan broke` gives the reason and exits 3 | 58 + 326 checks, 0 failed; 64 Python tests (`d605b01`) |
| #81 | `get_callers` adds `possible_callers`: the call sites the compiler index could not resolve, from Spread-Wings, marked | 58 + 327 checks, 0 failed; 56 Python tests (`8ddfe79`) |

Main at `245fb7e` gives 58 + 322 and 56. None is merged. Each pull
request's own STATUS.md entry has its table and limits.

What the swarm was like, for the next time: three runs at once, 15, 21 and
26 minutes, 196, 215 and 143 thousand tokens by its own count. Each split
its brief among named workers with one that only checked. The code of all
three built and did what the brief said. The fault the microVM found was
in the brief's rule, not in the swarm's code; and a "simpler" rewrite of
four of its lines, by hand, did not compile (Goose will not clear a buffer
while a slice of a parsed message is alive), where its own did. The copy
it works in needs the Goose compiler and its package cache put inside it
(a git archive holds neither, nor the submodules), every `.git` taken
out, and the node tools linked in, or it can build nothing and map no
Python or TypeScript.

Limits:
- The Rust `swan broke` does not give #80's `reason` and
  `first_time`; the hook stays silent for it. HANDOFF.md has it.
- The microVM suite was not run for this branch: it judges the Goose
  program, and nothing it reads or runs changed here.
- The swarm's runs are not kept in the repository; their briefs, reports
  and patches are in the session's scratch folder and the tool's cache.

## 2026-11-26T07:15Z: three points of the automated review taken into the hook

The Graphify review of this pull request listed nine possible faults it
could not confirm, five of them with their text. Read in the code, three
were right:
- Beside errors that are reported, the closing line said "Errors from this
  edit will not be reported here". It now speaks of the file that was not
  checked. (One file is asked per edit today, so the two did not meet; the
  code allowed it.)
- A reason the hook does not know was said as "its language server did not
  answer". It is now named as given.
- An exit code other than 0, 1 or 3 dropped an answer that was there. The
  hook reads the answer whatever the code, as it did before this branch.

Not taken: output that is not the one JSON object is not a note (the hook
prints nothing else); and the plugin does not track repeats itself, since
`swan broke` gives the note once. Its docstring now says so.

Checked: two new Python tests and one changed. `scripts/space-test.sh`
in the microVM on `2dec374`: 58 checks passed, 0 failed; the cosmetic,
layer and piece checks passed; 66 Python tests OK; 326 checks passed, 0
failed. Exit 0.

Limit: the four findings the review did not show in its comment were not
read. This entry is one commit after the tree that was tested; that commit
changes STATUS.md only.

## 2026-11-26T07:35Z: the three fixes merged into main and installed

On the owner's word ("merge install"), in the order given to him:
goose-lsp#7 with a merge commit (`af6b63d`; the pinned `2daeb2c` is on
that repo's main), then #79 (`833ae3a`), #80 (`0c382a1`) and #81
(`419b3be`), each squashed as main's others are.

Before #80 and before #81 went in, main was merged into the branch
(STATUS.md and DECISIONS.md keep every entry, in time order; nothing else
conflicted) and the whole suite ran in the microVM on that merge:
- #80 with #79 in it, `d6c3057`: 58 checks passed, 0 failed; cosmetic,
  layer and piece checks passed; 66 Python tests OK; 328 checks passed, 0
  failed.
- #81 with both in it, `6e7cc5c`: 58 + 333 checks, 0 failed; 66 Python
  tests OK. Main's tree at `419b3be` is that commit's tree
  (`2a11178ca1e3`), so this run is of main's own files.
Main before the three: 58 + 322 checks, 56 Python tests.

Installed: `scripts/swan-up update --keep 99` built `419b3bed04af`
from origin/main and switched to it; the five versions from before were
kept. With the installed program, on fresh copies of fixtures:
- a Python method called on an untyped parameter: `callers` holds the
  typed caller, `possible_callers` the untyped one;
- an untrusted Rust crate through the installed hook: the note the first
  time, nothing the second, nothing for a Markdown file;
- a crate whose build.rs fails, a type error added: not asked, reason
  `unsettled`, "not settled: Failed to run build scripts of some
  packages. …", exit 3; the healthy crate with the same error: the error,
  new.
And through an agent's own connection to Swan, on a private repo: the
first answer came from the server of before, which then moved itself to
the new version; the second named the caller that started all this.

Limits:
- #80 and #81 were merged while GitHub's own checks on their last commit
  (the merge of main) were still running; they had passed on the commit
  before, and the microVM run above is of the merged files.
- Other agents' Swan servers move to the new version after their next
  answer. One Hermes profile starts an older copy of Swan from another
  folder, which this does not reach.
- The remote and local branches of the three pull requests were left.

## 2026-11-26T08:40Z: the Rust `swan broke` says why a file was not checked, once

What was wrong: since #80 the program that ships gives a file it could not
ask a `reason` and a `first_time`, and the post-edit hook says so once.
The Rust `swan broke` gave only `why`, so with it the hook said nothing:
on the trial clone of relate (Rust, sealed, not trusted) main's hook was
silent on both of its runs.

What changed (rust/src/modules.rs, live.rs, broke.rs): a refusal is typed
where it is made. `modules.rs` says which kind of "no server" it is
(`Refused`), `live.rs` gives a `Refusal` with one of four reasons
(`no_server`, `untrusted`, `unsettled`, `failed`), and `broke.rs`
reports the reason, `first_time`, and keeps one
`file<TAB>not-asked|reason|` line in broke-seen.tsv under its lock, by
the rules of `src/broke.goose`. `swan lsp-ask` answers word for word as
before. Nothing outside `rust/` changed.

| main's hook on relate, one .rs file | the build before | this build |
|---|---|---|
| first run | nothing | "Swan did not check extensions/relate-dungeon/src/lib.rs: checks that run this repo's build are off for it by its owner's choice. …" |
| second run, an error added | nothing | nothing |
| `swan broke` | not asked, exit 3 | not asked, exit 3 |
| left running; the clone | nothing; unchanged | nothing; unchanged |

Checked:
- `cargo test`: 55 pass (47 before: 2, 18, 23, 7 and 5), no warnings,
  with the real language servers (none skipped).
- New, against the scripted server: 7 tests, and 4 changed. On the code
  from before, 10 of those 23 fail. The two that pin what must not be
  remembered were seen to fail by the swarm with that rule broken.
- New, with the real rust-analyzer: a crate that is not trusted is
  `untrusted`, said once; a check that did not run is `unsettled`, said
  on the cold ask and not on the warm one. Both fail on the code from
  before.
- The microVM suite was not run: it judges the Goose program, and nothing
  it reads or runs changed.

How it was made: from a written plan
(docs/superpowers/plans/2026-11-26-rust-broke-reasons.md), by one
Antigravity swarm (`agy-task --swarm`, 21 minutes, 171 thousand tokens by
its count) in a copy holding the plan, the spec's files of main and the
tree-sitter sources the build needs. Its code went in as it wrote it. The
last test of the plan was rewritten by hand after the swarm named three
faults in it (it left its folder behind, looked for leftovers in the wrong
places, and did not check the seen file). The real-server tests and the
measure were run outside the swarm, whose copy has no servers.

Limits:
- Not remembered, so not said by the hook: a file outside the repo, a file
  that is not UTF-8 text, a name holding a tab. The Goose program
  remembers any name given from the repo's top.
- A language whose candidates include one that runs the repo's code reads
  `untrusted` in a repo that is not trusted, also when that candidate
  would not have applied for another reason. The words were already so.
- No test runs the hook with the Rust program; HANDOFF.md says why.
- `lsp::tests::a_silent_server_times_out_and_is_killed` did not pass in
  the swarm's sandbox (a child not reaped there); it passes here.

## 2026-11-26T10:55Z: the Rust stack brought up to main

The four Rust branches were three commits behind main (#79, #80, #81).
Main was merged into `rust-stage-4`, and each branch into the one above it,
up to `rust-broke-reasons`. Merges, not rebases: nothing was force-pushed.

- Only STATUS.md and DECISIONS.md conflicted, as a dry run had shown. Both
  sides had only added dated entries at the end; every entry was kept, in
  the order of its heading's UTC stamp.
- The `lsp` and `wings` pins are main's (`2daeb2c`, `049fe53`).

| Branch | Merge |
|---|---|
| `rust-stage-4` | `5f7ae14` |
| `rust-lsp-languages` | `8214cda` |
| `rust-live-answers` | `eb66fac` |
| `rust-broke-reasons` | `b0d9f47` (no conflict left) |

Checked on `rust-broke-reasons` at `b0d9f47`:
- `cargo test --release`: 55 passed, no warnings (as before the merge).
- The whole suite in the microVM: 58 + 333 checks and 66 Python tests,
  0 failed. Main's own counts.

Not done: a test that runs main's hook against the Rust `swan broke`. The
suite runs the Goose `bin/swan` in the microVM, so it waits for the Rust
binary to be there (step 3's first task). The plan for step 3 is
docs/superpowers/plans/2026-11-26-rust-serve-read-tools.md, for the owner
to read before any swarm starts.

## 2026-11-27T11:55Z: `swan serve` in Rust answers the 12 tools `swan query` already knew (step 3, first part)

The Rust program now has `swan serve <map>`: an MCP server on stdin and stdout, on the `rmcp` crate, with
find_symbol, find_referencing_symbols, get_symbol_at, get_symbols_overview, get_callers, get_callees,
find_implementations, get_type_hierarchy, find_unused_symbols, get_diagnostics, search_pattern and
index_info. Each tool reads its arguments as `call_tool` in src/serve.goose does and answers through the
functions `swan query` uses. Any other tool answers "not yet in the Rust server: <name>". The checks' harness
now starts the program named by `SWAN_SERVE_BIN` when it is set, so the same checks judge both servers.

| Judge | Goose server | Rust server |
|---|---|---|
| `mcp` suite in the microVM (tiny-ts) | 31 of 31 | 31 of 31 |
| the same with `SWAN_SERVE_BIN` naming a missing program | | 0 of 1 (so the switch is real) |
| `cargo test --release` | | 78 passed, no warnings (55 before) |

How it was made: written by one Antigravity swarm from the plan
(docs/superpowers/plans/2026-11-26-rust-serve-read-tools.md, tasks 1 and 3) in 19 minutes, with a map of
tiny-ts made by the Goose program to test against (now rust/tests/data/). Its tests were seen failing before
its code. The lead moved the map into the tree, ran the tests again and ran the suite.

Limits:
- `get_callers` gives no `possible_callers`, though its description (copied from the Goose server) promises
  them: that part runs Spread-Wings and comes with the Spread-Wings tools (plan task 4).
- `live: true` on find_implementations and get_diagnostics answers "live mode is not yet in the Rust server".
- A line that is not JSON is dropped by `rmcp`; the Goose server answers it with -32700.
- `inputSchema` keys come out in sorted order (rmcp stores them in a sorted map): the same JSON, another order.
- One map per server (`swan serve <map>`); `--maps`, `use_repo` and the `repo` argument are plan task 2. The
  `maps` suite does not pass yet.
- Each call reopens the map; how long that takes is measured in plan task 5.

## 2026-11-27T12:50Z: the Rust `swan serve` chooses its repo (`--maps`, `use_repo`, `repo`) (step 3, task 2)

`swan serve --maps <dir>` and bare `swan serve` now start with no repo selected; `use_repo` (listed first, as
in `TOOLS`) and any read tool's `repo` argument select one, finding its map under the data root or building
it with the Rust `swan map` (`pipeline::map_main`, its trust rules unchanged). What the map held back for
`swan trust` is passed to use_repo's `skipped`, as the Goose `map_held` does. New: rust/src/serve_repo.rs.

| Judge (microVM, real indexers) | Goose server | Rust server |
|---|---|---|
| `maps` suite | 27 of 27 | 26 of 27 |
| `mcp` suite | 31 of 31 | 31 of 31 |
| `cargo test` (the copy, no indexers there) | | 28 passed, 5 ignored |

The one `maps` check that fails, "swan serve <db> still answers about its map", sends `tools/call` without
`initialize` first. The Goose server answers; the Rust server (rmcp) answers with MCP's -32602 error, as the
protocol requires a client to initialize. Every agent that starts Swan (Claude Code, omp, Hermes)
initializes first. The check was left as it is; whether the Rust server should be as lenient is the owner's.

How it was made: a second Antigravity swarm (20 minutes) from the plan's task 2. Its 5 ignored tests need
scip-typescript and rust-analyzer, which its copy lacks; the microVM suite above runs them for real.

Limits:
- The Rust binary must sit beside Swan's tools (`bin/spread-wings`, `bin/swan-flatten`): in the microVM it was
  copied to `bin/swan-rs`. Where it lives when installed is step 6.
- Still not here: what_broke, the four Spread-Wings tools and `possible_callers`, and the forward of the edit
  tools to the Goose server (plan task 4).

## 2026-11-27T14:10Z: the Rust `swan serve` has every tool (step 3, plan task 4)

A third Antigravity swarm added what_broke, the four Spread-Wings tools, `possible_callers` in get_callers, and the
forward (rust/src/serve_forward.rs): the ten edit tools go unchanged to a Goose `swan serve` child named by
`SWAN_GOOSE_SERVE`, started on first use with the same target and selected repo. The lead added: `live: true` on
find_implementations and get_diagnostics is forwarded too until the Rust server keeps language servers (step 4).

Judged in the microVM with every suite that starts a server, the Goose server against the Rust one (a copy of the
Rust binary in `bin/`, beside Swan's tools; `SWAN_GOOSE_SERVE=bin/swan`):

| Suite | Goose | Rust |
|---|---|---|
| mcp | 31 of 31 | 31 of 31 |
| maps | 27 of 27 | 27 of 27 |
| edit | 16 of 16 | 16 of 16 |
| lang | 131 of 131 | 131 of 131 |
| structural | 31 of 31 | 31 of 31 |
| trust | 20 of 20 | 20 of 20 |
| diag | 6 of 7 | 6 of 7 |
| live | 22 of 28 | 22 of 28 |
| game | 28 of 36 | 28 of 36 |
| kotlin | 1 of 6 | 1 of 6 |

The failures are the same checks on both: these suites ran outside `scripts/test.sh` (language servers and trust
that the test run sets up). `cargo test`: all pass, 6 ignored (need indexers or spread-wings the copy lacks).

Harness: under `SWAN_SERVE_BIN`, `mcp_open` now does MCP's opening handshake. All suites but mcp called tools
without `initialize`; the Goose server answers anyway, the Rust server (rmcp) answers with -32602 as the protocol
says. No check was changed. Whether the Rust server should accept calls before the handshake is the owner's.

Limits: the Rust binary must sit beside Swan's tools; live mode is the Goose server's until step 4.

## 2026-11-27T12:20Z: a Rust symbol's signature is rust-analyzer's, not its doc comment's first line

Found by Aya while reading the Rust `swan serve` through Swan's own tools: every Rust function on the
branch came back with an empty `signature`. In SCIP a symbol's signature is `signature_documentation`
(field 7), and its doc comment is `documentation` (field 3). swan-flatten read only field 3 and took its
first line, which works for scip-typescript (it puts the signature there) but not for rust-analyzer: a
Rust symbol's signature was its doc comment's first line, or empty when it had none.

| Repo | Rust functions and methods with a signature, before | after |
|---|---|---|
| fixtures/tiny-rs | 0 of 7 (all 11 symbols empty) | 11 of 11, e.g. `pub fn new(side: u32) -> Tile` |
| relate (trial clone, sealed) | 14,724 of 24,930, most of them doc lines | 24,938 of 24,938 |
| fixtures/tiny-ts | the same rows, byte for byte (sha256 of every symbol's scip, signature, doc) | |

- swan-flatten reads field 7 when it is there, and keeps documentation's first line otherwise.
- A map made by another swan-flatten is flattened again even when no indexer ran, so the fix reaches
  maps that already exist: `flattener.txt` in the map folder names the flattener (its size), and both
  early stops ("nothing changed", "only failed indexers ran") need it to match. An old map remapped by
  this build got its signatures; the next map said "nothing changed".
- New check (rust suite): Tile/new's signature is `pub fn new(side: u32) -> Tile`. On main's
  flattener it fails with `"signature": ""`.

- The whole suite in the microVM: 58 + 334 checks and 66 Python tests, 0 failed (main: 333 checks; +1 new).

Limits: the flattener is named by its file size, as the TypeScript patch is; two builds of one size
would look the same. A map's first run with this build reflattens every map once.

## 2026-11-27T16:40Z: the Rust `swan serve` judged by an IDE and timed (step 3, plan task 5)

The branch with main merged in (59755ce, the signature fix): the whole suite in the microVM, 58 + 334 checks and 66
Python tests, 0 failed; every suite that starts a server gives the Goose server's result (the table at 14:10Z, run
again on this tree, the same). `cargo test` in the microVM: all pass but one, `a_server_does_not_outlive_a_killed_swan`
(tests/live.rs): it fails there 3 of 3 here and 2 of 2 on `rust-broke-reasons` (249f7cb) too, and passes on the host;
it came with that branch and is not this one's.

### RustRover against the Rust server, relate

`scripts/ide-judge.py` (new): 20 functions and methods of relate's Rust, picked by a fixed order from the map, whose
name appears as a word in at most 150 places. The IDE's answer to a question is every one of those places its
`get_symbol_info` resolves to the same symbol as the definition. A fresh copy of the trial clone at 2e47f55, mapped
by the Swan installed from main; RustRover read it, nothing was edited.

| Tool | Agrees with the IDE |
|---|---|
| find_referencing_symbols, references in code (file and line) | 71 of 71; none the IDE does not have |
| get_callers, call sites at distance 1 | 62 of 62 are places the IDE confirms |
| get_symbol_at, at each place the IDE confirms | 71 of 71 |
| references in doc comments (`[name]` links) | the IDE counts 3, the map none: rust-analyzer's index does not |

RustRover's `analyze_calls` found no Rust function by any name form tried (`crate::module::f`, `module::f`, `f`,
`Type::method`), so the call hierarchy was not used: get_callers is judged by its call sites.

Not judged: cobra (Go). Mapped as an untrusted repo, gopls has no package metadata (its dependencies are fetched only
into a trusted repo's module cache), so the map has 0 references and there is nothing to compare. Trusting a trial
folder, or filling the module cache by hand, is the owner's call.

### Time, the Goose server against the Rust one, relate

The same 20 questions, each 5 times, one server per tool and run (ms per call, as the client sees it):

| Tool | Goose median | Goose p90 | Rust median | Rust p90 |
|---|---|---|---|---|
| find_symbol | 0.2 | 8.6 | 0.2 | 8.8 |
| find_referencing_symbols | 0.5 | 7.3 | 0.4 | 6.9 |
| get_symbol_at | 0.1 | 0.1 | 0.1 | 0.1 |
| get_callers (with `possible_callers`, Spread-Wings) | 107.1 | 113.7 | 108.0 | 113.5 |
| start, initialize and the first find_symbol | 1 | | 1 | |
| start, initialize and the first get_callers | 108 | | 108 | |

The first get_callers on a map builds Spread-Wings' graph once (6.6 s on relate, cached after). The two are as fast
as each other: the switch is not held up by speed.

### What is not done

- The 10 edit tools and `live: true` are the Goose server's (decision A), until steps 4 and 5.
- The Rust binary must sit beside Swan's tools (bin/spread-wings, bin/swan-flatten); packaging is step 6.
- No agent's `swan serve` entry points at the Rust binary yet: that waits for the owner's word.
