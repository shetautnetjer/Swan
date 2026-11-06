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

- Stage 1: skill guidance implemented; format, links and whitespace validated.
- Stage 2: preparing matcher regression cases in its owning repository.
- Stages 3–5: source inspection/preparation only; execution follows the order.
- Existing Linux package/self-test evidence remains under `docs/evidence/`.
  Previously exported binaries keep their recorded identities; regenerate a
  candidate from the final reviewed source before distribution.
