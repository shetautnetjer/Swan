# Draft contribution proposal: independent validation and honest build boundaries

Prepared locally on 2026-10-26. This is a review draft, not a submitted PR or
release announcement.

The reusable libraries were extracted from Swan, but their independent
contracts and compile costs were not demonstrated by standalone tests.
Swan's public docs still referred to removed native paths and described
implemented diagnostics, editing and language adapters as missing. Some
language and performance wording implied broader guarantees than the
available evidence supports.

This contribution adds independent tests to goose-sqlite, goose-treesitter
and goose-lsp, an offline Swan demo, a reproducible compiler/cache probe and
documentation corrections. It preserves the existing APIs and Goose's
repository/ref package mechanism.

## Proposed review units

1. **goose-sqlite:** a local-import API suite for bindings, reset behavior,
   transactions and errors; documented C/Goose boundary and cache limits.
2. **goose-treesitter:** local-import tests for all ten grammars, captures,
   repeated metavariables, templates, rejected patterns and worker ordering;
   document the all-grammar cold build and unused-import cost.
3. **goose-lsp:** standalone consumer and deterministic local mock server,
   verifying framing, initialization, synchronization, diagnostics,
   implementations and cleanup. Document separate runtime/ABI ownership and
   external-server requirements.
4. **Swan:** correct current architecture and language claims, provide a
   known-answer synthetic-row demo, and publish an offline build-boundary
   harness with explicit methodology and limitations.

The library changes do not require bumping Swan's dependency refs: they add
tests/docs and exclude test directories from package ownership without
changing runtime APIs. A future public release/tag update would be a
separate maintainer decision. Swan's `lsp/` gitlink is unchanged here.

## Evidence and acceptance

Each new test command must fail on an incorrect result, run without Swan
where appropriate, and leave original checkouts untouched. The local
validation record distinguishes the independent library tests, synthetic
Swan demo and real TypeScript SCIP/MCP integration checks. It does not infer
real-server qualification from the mock LSP fixture. Exact local outcomes
and unrun suites are recorded in [validation.md](validation.md).

The benchmark found a material limitation worth documenting before redesign:
an unused SQLite import avoids native compilation, while an unused
tree-sitter import still builds all 20 configured C sources and links roughly
20 MB. Its retained worker entry point explains the native reachability.
Warm native objects were reused. See [packages.md](packages.md) for exact
methodology and the small consumer results.

Review should confirm package test exclusions, clean independent imports,
negative/error assertions, source-pinned benchmark inputs, and wording that
distinguishes Goose libraries from C engines and external servers.

## Scope held for a separate decision

Grammar-specific imports or packages would require an API/registration
design. Converting the LSP client to an ordinary Goose package would change
whole-program compilation or introduce a generated-native release workflow.
The measured costs and alternatives are in [packages.md](packages.md).
Neither change is bundled here. Reimplementing language servers/compilers,
claiming precise call graphs, JetBrains parity or CUDA device validation is
outside this proposal.

No new CI workflow is included: the local commands are ready for a maintainer
to run with a pinned installed toolchain, but hosted provisioning and platform
coverage have not been tested. No push, PR, tag, maintainer contact,
deployment or runtime configuration change is part of this local preparation.
