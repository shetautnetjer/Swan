# Reusable Goose libraries and build boundaries

Swan uses Goose's existing package mechanism: a root file declares a local
directory or a Git repository/ref. There is no new registry, lockfile format
or package manager here. Pin a commit when an immutable source identity is
required. The name "egg" can be discussed separately; it changes no API.

| Library | What is Goose | What is native or external | Independent use |
|---|---|---|---|
| goose-sqlite | API declarations and convenience functions | C shim and vendored SQLite amalgamation | `import sqlite from "../goose-sqlite";`, or the published repository/ref |
| goose-treesitter | Pattern matching, captures, templates and worker orchestration | C adapter, tree-sitter runtime, generated C parsers/scanners | `import treesitter from "../goose-treesitter";`, or the published repository/ref |
| goose-lsp | JSON/LSP requests, synchronization and response handling | POSIX process helper and C runtime bridge; an external server process | Generate standalone C with its build script, then list that C and its native helpers in the consumer sidecar |

The first two are ordinary importable packages. LSP is an independently
reusable library with a different build boundary, not yet an ordinary
`import ... from` package. None requires Swan's map schema or MCP server.
Their standalone tests run from their own repositories.

The LSP client is written in Goose; rust-analyzer, pyright,
typescript-language-server and JetBrains' Kotlin `intellij-server` are not
Goose ports. They run as separate programs and retain their own startup,
memory, project-import and analysis costs. They are not compiled into Swan.
The client supports one server per process; Swan swaps it when changing
languages. Java and CUDA currently have batch indexing/checking paths rather
than configured live LSP adapters. CUDA's fallback is host-side analysis,
not validation by nvcc or a device build.

## What compiles, including unused imports

With the installed Goose v2026.3 distribution tested here:

- An unused SQLite import does not build SQLite C. Reaching SQLite calls
  builds its two configured C sources, then later consumers can reuse them.
- An unused tree-sitter import **does build all 20 configured C sources**.
  Calling only `language_of_path` has the same native cost. The generated C
  retains `treesitter_search_worker` and its parser calls; Goose treats
  thread entry points as reachability roots. This observed behavior is
  stronger evidence than assuming unused imports are free.
- Selecting only Rust at runtime still builds the tree-sitter runtime, shim
  and all ten grammar parsers (plus their scanners). Language selection is
  not a native build-selection switch.
- LSP's standalone Goose generation and its C compilation are separate
  steps. Swan regenerates the C when `lsp/` changes. The host sidecar still
  links the LSP components even for a command that does not launch a server.
- Warm native caches avoid repeated compilation, not disk use or binary
  size. Package Goose code still participates in the consumer's Goose
  compilation. Toolchain, source or build-description changes can invalidate
  caches. These are not promises of zero compile cost.

## Reproduce the package experiment

With an existing Goose compiler, C compiler, Python 3, GNU `time`, and
initialized local package checkouts, from Swan:

```bash
python3 scripts/bench-builds.py --goose /path/to/goose \
  --sqlite ../goose-sqlite --treesitter ../goose-treesitter \
  --lsp ../goose-lsp --out data/package-benchmark-1
```

The output directory must be new. The script snapshots sources, uses a
separate empty `GOOSE_HOME` per case and `--offline`, records the compiler
hash/toolchain, commands, raw logs, object changes, sizes and exit codes in
`results.json`, and executes each result with known-answer assertions. It
does not install or fetch anything. For checked-out Git sources, only
tracked files (with current local edits) enter the snapshot; commit new
package modules before benchmarking them.

Cold means an empty Goose build cache with source already present. It
includes runtime/native compilation but excludes source copying, downloads,
server startup and indexing. Warm means the identical build repeated three
times in that cache, without a source edit. OS page caches are not flushed.
Sizes are logical bytes, excluding `.git`; executable sizes are unstripped.
RSS is the largest process measured by GNU time, not total concurrent memory.

## Local sample, 2026-10-26

Linux x86-64, AMD Ryzen 9 9950X3D, 32 logical CPUs, GCC 15.2.0, Goose runtime
`4d3da949e563`. Compiler SHA-256:
`b56c1cf28f020a89ae164ee53c086d8ffff04f285331115ce448e1d4244eca24`.
One cold run and median of three warm runs, default `-O2` AOT build:

| Consumer | Cold seconds | Warm seconds | Executable bytes | Native package objects |
|---|---:|---:|---:|---:|
| Minimal program | 0.521 | 0.034 | 69,664 | 0 |
| SQLite import only | 0.505 | 0.034 | 69,664 | 0 |
| SQLite operations | 12.222 | 0.049 | 1,221,784 | 2 |
| Tree-sitter import only | 8.018 | 0.063 | 20,183,472 | 20 |
| Tree-sitter language helper | 8.012 | 0.077 | 20,188,952 | 20 |
| Tree-sitter Rust parse | 8.007 | 0.067 | 20,183,600 | 20 |
| LSP link/stop only | 2.053 | 0.036 | 191,808 | 0 (host-side C) |

LSP Goose-to-C generation took 0.039 seconds separately. The last row
does not start a language server or test analysis performance. All 28 builds
and all 28 runtime smoke invocations passed. These are small build-boundary probes,
not cross-language benchmarks or measurements of a complete application.

The frozen package source footprints were 10,287,688 bytes (SQLite),
117,815,619 bytes (tree-sitter, initialized vendors included) and 34,553 bytes
(LSP). The raw evidence accompanies the local contribution bundle under
`evidence/benchmarks/run-1/`; repeat the command for your machine.

Swan itself, with its existing tagged SQLite/tree-sitter sources already
present in a private cache and `lsp/` at `8116eef`, built in 26.426 seconds
from an empty build cache, then 6.712, 5.043 and 5.049 seconds on three
unchanged builds (median 5.049). The unstripped binary was 21,908,992 bytes.
This used `GOOSE=/path/to/the/same/goose`, an isolated `GOOSE_HOME`, and
`bash scripts/build.sh --offline -v`; raw commands/logs are retained under
`evidence/swan-build/` in the local bundle. The cold run included LSP C
generation. These warm runs did not simulate source edits, and the result
does not include package downloads or external tool installation.

## Decisions deliberately deferred

1. **Tree-sitter grammar selection.** Keep the current single import and
   warm cache, or introduce optional grammar packages and separate worker
   entry modules. The current single-import cost is about 20 MB in these
   binaries even when unused. A split would need an explicit grammar
   registration/import API and cross-package tests; it is not a docs change.
2. **LSP package form.** Keep the standalone runtime boundary, or make the
   Goose client an ordinary module (which participates in consumer builds),
   or add an importable facade over separately generated native artifacts.
   Each changes cache, runtime ownership or release mechanics. Measure a
   prototype before choosing. Rewriting real servers in Goose is out of scope.

The contribution preserves these boundaries while making their costs and
tests reviewable.

## Platform portability proposal (2026-11-06)

**Stage: proposal; no macOS/Windows port or release qualification is claimed.**
The goal is the same Swan commands, MCP behavior and trust boundary on
supported Linux, macOS and Windows machines, with builds for each selected
OS/CPU target. Keep the Goose/SQLite/tree-sitter/LSP split and existing
schemas. Supporting another host does not require a new daemon, database,
package manager or rewriting the language servers.

Goose v2026.3 already publishes Linux x64, macOS x64/ARM64 and Windows x64
compiler distributions ([upstream release](https://github.com/aardappel/goose/releases/tag/v2026.3)).
Swan still selects the Linux archive and compiles platform-specific helpers;
compiler availability is only one prerequisite. External indexers and
language servers must also be checked per platform and language.

| Boundary | Current implementation | Work required |
|---|---|---|
| Executable discovery and filesystem facts | `native/swan_sys.c`: `/proc/self/exe`, `st_mtim`, `lstat`, `sysconf` | Platform-specific implementations preserving the existing helper contract |
| Child processes and LSP transport | Swan native helpers and goose-lsp's `native/proc.c`: POSIX fork/exec, pipes, poll, signals and process groups | Preserve streaming, deadlines, exit reporting and descendant cleanup; add the Windows implementation in its owning library |
| Paths, virtualenvs and executable lookup | Unix separators, colon-separated PATH and `.venv/bin/python` | Correct path canonicalization, PATH rules, executable suffixes and Windows virtualenv `Scripts/` handling |
| Tool bootstrap | `scripts/fetch-tools.sh` selects Linux x86-64 downloads; Bash scripts and GNU utility assumptions | Select pinned OS/CPU assets, verify checksums, and report unavailable language adapters clearly |
| Resource defaults | `/proc/meminfo` is read when available | Review the existing fallback and qualify sensible defaults elsewhere |
| Installation and tests | Relative installation tree; current evidence is from a Linux development host | Test clean machines, paths with spaces, install relocation, dependencies and trust isolation on every claimed target |

Proposed order: first qualify the existing Linux setup on a clean machine,
then port and qualify macOS, then native Windows. WSL2 may provide an interim
Linux route for Windows users, but requires its own check and must not be
advertised as native Windows support. ARM64 targets require matching tools
as well as a matching compiler; they are not implied by x64 success.

A small platform layer behind the current native helper interfaces is the
preferred approach to review. Replacing the process layer wholesale with a
new dependency is an alternative only if a bounded prototype demonstrates
that it preserves existing timeout, I/O, cleanup and trust behavior with
less maintenance. A Linux container/WSL distribution is another option for
accessibility, but does not meet a native-host support claim.

Acceptance before marking a target supported: a clean install/build; the
offline map/query/MCP checks; real Python diagnostics with untrusted and
trusted interpreter controls; process exit, timeout and cleanup checks;
path/URI tests (spaces, Unicode, symlinks or junctions and Windows drive
letters as applicable); and per-adapter availability results. The trust
controls must run on that target, not merely inherit a Linux result or skip
when a required tool is missing. Test state must not alter a user's trust
list. Record which OS/CPU and tool versions actually passed.

The implementation scope and this proposal need approval before detailed
port design or runtime changes. Documentation of the current support level
is independent of that future work.
