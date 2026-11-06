# Ordered Swan improvements

Approved by the project owner on November 6, 2026: implement the proposed
order, run tests, and merge review-ready changes. Keep changes in their owning
repositories and retain exact source and runtime evidence. Source merges do
not replace the user's active installation, grant repository trust, register
an agent, or publish a binary release.

## Scope and acceptance (PRD)

| Order | Outcome | Acceptance |
| --- | --- | --- |
| 1 | Clear skill coverage and refresh guidance | Uses real schemas/reports; distinguishes syntax/index/live evidence; handles branch, worktree, dependency and config changes; batches refresh; preserves trust and mutation boundaries; valid skill and links |
| 2 | Correct empty variadic structural patterns | Owning goose-treesitter tests cover empty/nonempty captures, punctuation and negative cases; Swan canaries and integration checks agree; immutable dependency revision |
| 3 | Qualify concurrent map access | Disposable multi-process readers/writers and interruption tests; answers represent a complete old/new generation or explicit failure; no false success or damaged published map; fixes only demonstrated failures |
| 4 | Investigate Goose-language support | Locate existing upstream grammar/server/indexer work; verify interfaces and compatibility; identify feasible integration and unproven semantics before proposing a new implementation |
| 5 | Optimize measured bottlenecks | Reproducible bounded timings and correctness checks; retain existing caches/parallelism; implement a change only when evidence shows a useful improvement |

Non-goals: a database replacement, new daemon or registry, unrelated language
ports, a rewritten parser/server, automatic trust, or production configuration
changes. SQLite thread synchronization, multi-process database locking and the
saved trust-list race are distinct concerns and must not be conflated.

## Approach and alternatives (HLD)

Use the existing Swan/SQLite/tree-sitter/LSP boundaries. First make agent
instructions accurately describe coverage. Correct matcher behavior in
goose-treesitter, then exercise it through Swan. Use isolated CUA fixtures and
the existing package build to qualify concurrency; do not assume a database
option alone protects the pipeline's intermediate files. Prefer reusing an
existing upstream Goose grammar/server to creating a parser or compiler fork.

Keep the current SQLite backend and grammar bundle until measurements justify
another choice. A per-language grammar split may reduce build size/cost but
changes the package API; a database/server replacement changes ownership and
deployment. Those are alternatives to evaluate, not approved convenience
redesigns. Material architecture changes reopen the design decision.

## Progress and evidence

- **Stage 1 — merged:** [Swan PR #13](https://github.com/shetautnetjer/Swan/pull/13)
  at `b569146` includes portable skill coverage/refresh guidance; skill format,
  links and whitespace validated. Source merge does not activate an installation.
- **Stage 2 — merged:** [goose-treesitter PR #5](https://github.com/shetautnetjer/goose-treesitter/pull/5)
  at `590107` owns the matcher fix; [Swan PR #14](https://github.com/shetautnetjer/Swan/pull/14)
  at `b3bd50c` integrates it. The CUA run passed 136 native library checks,
  24/24 skill patterns (both empty-variadic canaries FIXED; JS-label TRAP),
  and real Python/TypeScript definition/reference and live clean/error/fixed
  checks. See [matcher receipt](evidence/swan-matcher-2026-11-06.json).
- **Stage 3 — qualified candidate, PR open:** [Swan PR #15](https://github.com/shetautnetjer/Swan/pull/15),
  source `ef03ba0e13e357316e318a2384b58c5ec0b222d3`, built in CUA with SHA-256
  `597dd20e6b58919a703249e9f77c55783a2c2a04a7a8d8bd66739b7617b4a5f8`.
  Passed 9/9 concurrency scenarios, five focused reader regressions, 36 local
  package/native tests (eight locks), 24 skill patterns and real Python/TypeScript
  definitions/references/live checks. Independent review added inherited child
  lock ownership and database-file symlink refusal; parent-directory aliases
  remain supported. [Contract, limits and reproduction](concurrency.md).
  This candidate is not yet merged or installed as a production replacement.
- **Stage 4 — investigation:** official Goose `v2026.3` source at
  [`8511ae34`](https://github.com/aardappel/goose/commit/8511ae34bdc9aabf77baaab80b4d659ea87835e2)
  already has a `tree-sitter/` grammar and compiler LSP in `src/lsp*.h`.
  A November 6 CUA probe of that compiler actually returned `goose lsp 3.17`
  from `lsp --probe`; this supersedes the investigation draft's earlier
  "probe not run" status. This identifies an interface, not a qualified Swan
  adapter. No Goose adapter is implemented; grammar generation/corpus,
  live error/clean cycles, untrusted execution boundaries and compiler-resolved
  semantic export remain unqualified. A grammar alone cannot supply SCIP
  definitions/references. Reuse upstream work before proposing a parser.
- **Stage 5 — measured; no additional optimization justified:** the same
  `ef03ba0`/`597dd20e…` candidate passed 14 mapping calls over generated
  fixtures with 120 files per language. Known definitions/references,
  unchanged-map equality, incremental-versus-fresh equality for both languages
  and MCP answers passed. Wall times in seconds:

  | Language | Cold map | Unchanged median | One edit | New file |
  | --- | ---: | ---: | ---: | ---: |
  | TypeScript | 0.467 | 0.03148 | 0.464 | 0.515 |
  | Python | 1.566 | 0.16379 | 0.815 | 0.865 |

  Database load was 6–23 ms; reported indexer work was 388–766 ms. On a
  50,000-row fixture, 20 warmups and 200 validated requests per binary gave
  median reader latency 0.085969 ms before the concurrency change versus
  0.168354 ms for the candidate (increase 0.082385 ms; candidate p95
  0.21576 ms). Database/source bytes remained unchanged. These bounded
  generated fixtures establish no universal speed claim. Retain the
  correctness fix and existing reuse; no additional optimization is justified.
  CUA run references: `swan-runtime-bigun36h/summary.json` and
  `swan-reader-latency-y32vjttc/summary.json`.
- **Final isolated trust regression — passed:** real Python diagnostics and
  interpreter markers false/true/false passed in `swan-verify-_azjgets`;
  the saved trust file remained absent and unchanged. This rechecks the
  tested live-Python path, not every execution path or trust-list concurrency.

Earlier package evidence remains under `docs/evidence/`. Exported binaries
keep their recorded identities; regenerate a candidate from final reviewed
source before distribution. Preserve the active executable, saved trust,
module configuration and agent settings throughout these source changes.
