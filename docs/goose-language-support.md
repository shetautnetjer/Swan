# Goose-language support: investigation, 2026-11-06

Status: **research only; no adapter implemented or qualified**.

## Existing upstream work

The official [aardappel/goose](https://github.com/aardappel/goose) repository already contains both a Goose language server and a tree-sitter grammar. Reuse them before considering a new parser.

Verified compiler references:

- `v2026.3`: [`8511ae34bdc9aabf77baaab80b4d659ea87835e2`](https://github.com/aardappel/goose/commit/8511ae34bdc9aabf77baaab80b4d659ea87835e2), 2026-10-20.
- Observed master: [`7b90f91d91845f4ef1712e16ed053f395e4e6e1c`](https://github.com/aardappel/goose/commit/7b90f91d91845f4ef1712e16ed053f395e4e6e1c), 2026-11-06. This is a dated source observation, not an installation claim.

| Facility | Exact primary paths | Boundary |
|---|---|---|
| Compiler language server | [`src/lsp.h`](https://github.com/aardappel/goose/blob/8511ae34bdc9aabf77baaab80b4d659ea87835e2/src/lsp.h), [`src/lsp_workspace.h`](https://github.com/aardappel/goose/blob/8511ae34bdc9aabf77baaab80b4d659ea87835e2/src/lsp_workspace.h), `src/lsp_analysis.h`, `src/lsp_features.h`, `src/lsp_rpc.h` | `goose lsp --probe` prints `goose lsp 3.17`; `goose lsp --stdio` runs compiler analysis and sets `package_nofetch=true`. It publishes diagnostics, including empty sets. |
| Compiler server tests | [`test/lsp_protocol.py`](https://github.com/aardappel/goose/blob/8511ae34bdc9aabf77baaab80b4d659ea87835e2/test/lsp_protocol.py), `test/lsp/` | Source-level protocol fixtures cover queries and changes. They have not been run in this investigation. |
| Goose tree-sitter grammar | [`tree-sitter/README.md`](https://github.com/aardappel/goose/blob/8511ae34bdc9aabf77baaab80b4d659ea87835e2/tree-sitter/README.md), `grammar.js`, `src/scanner.c`, `test/corpus/`, `build.py`, `package.json` | Official grammar and nesting-comment scanner exist. Generated `src/parser.c` is intentionally not committed. Generator pins tree-sitter-cli 0.25.8 and uses npm on first use. Preserve Apache-2.0 provenance if vendoring generated sources. |
| Generic Goose-written LSP client | [`shetautnetjer/goose-lsp/README.md`](https://github.com/shetautnetjer/goose-lsp/blob/main/README.md), `golsp.goose`, `native/proc.c` | External-server client, not a Goose language server. Current exposed operations are diagnostics, open, implementations. One process-global server; POSIX process backend. |

User-owned GitHub repository searches found `goose-lsp`, `goose-treesitter`, and `goose-sqlite`, but no separate Goose grammar/server repository. This does not exclude unindexed or local work. No SCIP export was found in the inspected official compiler CLI and source tree; a complete semantic export has not been established.

## Integration layers and acceptance

1. **Structural syntax support.** Vendor a reproducibly generated parser/scanner from a pinned official grammar in the existing goose-treesitter package. Hook `treesitter.goose` language detection/metavariable lexing/pattern context, `ts_shim.c` dispatch, `treesitter.build`, and parser/scanner wrappers/provenance. Verify the upstream corpus, valid/malformed Goose files, expressions and statements in function context, repeated metavariables, raw triple-quoted strings, nested block comments, source-preserving rewrites, and equal serial/parallel results. No new package or parser is needed for this investigation.
2. **Live diagnostics.** Route `.goose` and add a module candidate using an explicitly selected compiler executable, `lsp --stdio`, language ID `goose`, and publish settling. Never choose the compiler from repository-controlled PATH. Source indicates analysis without package fetching/code generation; runtime acceptance must still cover error → clean → error, repeated unchanged requests, imported-file changes, missing-package diagnostics/no fetch, and planted native build/interpreter markers before allowing untrusted use. Configure entry files and standard-library location only through reviewed settings.
3. **Semantic maps.** A grammar supplies syntax, not compiler-resolved definitions/references/callers. The official server supports hover/definition/references/call hierarchy, but Swan's current client exposes only diagnostics/open/implementations. The compiler does not advertise `implementationProvider`. Full Swan semantic mapping therefore needs a separately reviewed compiler-export/SCIP adapter or a deliberately bounded query adapter; no such adapter is presently approved or qualified. Do not advertise full Goose support after completing only layers 1–2.

Candidate acceptance commands for a disposable upstream checkout are `goose lsp --probe` and `python3 tree-sitter/build.py --check`. The second may download the pinned generator and must be staged with the same dependency review as other build tooling. The compiler probe was run in isolated CUA on 2026-11-06 and returned `goose lsp 3.17`. The grammar generation/corpus command was not run.

## Changes after the current compiler tag

- [18196a7, 2026-11-01](https://github.com/aardappel/goose/commit/18196a70139355d7c819a58f69bca30039558794): fix stale call hierarchy after document edits.
- [c47437b, 2026-10-29](https://github.com/aardappel/goose/commit/c47437bb482bf728d4bb12c04cbe0b44b93bf0a7): apply incremental didChange edits at their range. Swan's current client sends full-text changes, so this is not a prerequisite for its current diagnostics path.
- [e1d95ed, 2026-10-26](https://github.com/aardappel/goose/commit/e1d95ed09c0c99dad39b9c9726e00f0e6e67c64b): `defer` language/grammar support.
- [127beed, 2026-11-05](https://github.com/aardappel/goose/commit/127beedc49ccc8e44253c7f3f38851d645f65286): root struct/component storage grammar names. Other Nov 5 changes added const-if, UFCS type arguments and generic enum variants.

Pin a coherent compiler/grammar language version and record that pair in qualification. An unqualified compiler upgrade is not necessary merely to investigate existing server/grammar support.

## Performance decision

Swan's existing `docs/speed.md` and `docs/packages.md` contain historical measurements, not fresh qualification. They report external indexers consuming roughly 88–90% of initial mapping time, semantic query reads around 0.03–3 ms, no measured benefit from extra SQLite cache/locking changes, and native-cache improvements already present. Concurrent indexers, changed-file reuse, no-change early returns, TypeScript layers, batched SQLite loads, and per-file structural symbol lookups are already implemented.

The qualified candidate was measured on generated TypeScript/Python fixtures; see [runtime measurements](runtime-measurements-2026-11-06.md). Preserve known semantics and exact incremental/fresh equality before comparing timings. Separate build/cache cost, indexing, flattening, database loading, structural matching and live startup. If a phase is already cheap, leave it alone. No SQLite rewrite, grammar package split, new daemon, or memory store is justified by the evidence collected here.
