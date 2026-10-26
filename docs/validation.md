# Local contribution validation — 2026-10-26

The contribution was prepared in isolated checkouts. The original Swan
`153bae0`, goose-sqlite `04d0cc1`, goose-treesitter `1a33f28`, and goose-lsp
`8116eef` tracked sources were archived and SHA-256 inventoried before edits.
All 1,174 original tracked files (initialized submodules included) still
matched those hashes at closeout; original checkouts stayed clean.

## Passed

| Check | Result |
|---|---|
| goose-sqlite `GOOSE=/path/to/goose scripts/test.sh` | 43 assertions; independent local import |
| goose-treesitter `GOOSE=/path/to/goose scripts/test.sh` | 52 assertions; ten grammar smoke checks, captures/rewrite/negatives/worker ordering |
| goose-lsp `GOOSE=/path/to/goose scripts/test.sh` | standalone native consumer, 11 response cases plus wire/cleanup assertions |
| LSP negative control | deliberately incorrect diagnostic output rejected |
| `python3 scripts/demo-offline.py` | 11 assertions, synthetic rows into real SQLite/MCP/structural paths |
| `scripts/index-repo.sh fixtures/tiny-ts data/tiny-ts` | real TypeScript SCIP map, 56 symbols / 139 occurrences |
| `bun tests/mcp_smoke.ts bin/swan data/tiny-ts/swan.db` | all existing MCP smoke assertions |
| `bash tests/refresh_check.sh` | refreshed and fresh maps equal across 202 dumped rows |
| `bun tests/edit_check.ts` | edits/rename/conflict/staleness; tsc passes; 27 symbols' shifted positions compared with fresh SCIP |
| `bun tests/split_check.ts` | split/single maps equal across 503 rows |
| Package build harness | 28 builds and 28 executable checks; cold/warm evidence in packages.md |
| Swan build | cold and three warm builds; default AOT optimization, private package cache |
| Source review | independent review; shell/Python syntax and `git diff --check` |

The first attempt at the existing Bun MCP test timed out without receiving
the initial reply. A bounded probe showed `EPERM` on Bun's child-stdin send
inside the restricted execution environment. The normal approval route then
allowed the same installed tests to run outside that restriction, and all
four TypeScript suites above passed. The initial timeout is retained in the
evidence; it was not counted as a passing test or fixed by changing Swan.

## Not run / limits

- The complete `scripts/test.sh` integration suite was not run. Its Rust,
  batch diagnostics, additional languages, structural comparison against
  ast-grep, and real-server/Kotlin integration suites remain unrun here.
- Mock LSP success does not qualify real server semantics, Gradle/Kotlin
  import, Unicode position handling, or diagnostics requests interrupted
  by server death (that path may wait its existing 120-second deadline).
- The demo's hand-authored rows do not qualify an indexer. The separate
  TypeScript tests above do use the installed SCIP toolchain.
- No network fetching, installation, hosted CI, release, push, PR,
  maintainer contact, runtime restart or deployment was performed.
- No precise call-graph, JetBrains parity, device-CUDA or cross-language
  compiler-performance claim follows from these checks.

The local delivery includes `backups/manifest.json` with source archives,
`evidence/benchmarks/`, `evidence/swan-build/`, `evidence/library-tests/`,
`evidence/lsp-tests/`, `evidence/swan-demo.log`, and
`evidence/swan-integration/`. Those private delivery paths are not required
by the public test commands. There are no remaining execution or approval
blockers for this bounded contribution.
