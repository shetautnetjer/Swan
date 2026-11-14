# A modular, open Swan: what to take from Graphify, Understand Anything and REA

Status: proposal, 2026-11-14. Nothing here is built unless it says so.
Studied: Graphify 0.9.108 (PyPI `graphifyy`), Egonex-AI/Understand-Anything at
`5cc4aad`, morluto/rea at `1ba93b4`.

## In plain words

Swan answers code questions from what a compiler worked out, so its answers
are exact and fast. The cold test on five strangers' repos showed its weak side:
when a repo didn't fit its assumptions, it gave nothing at all. The other three
tools are each good at one thing Swan needs:

- **Graphify** maps every repo, in about 30 languages, because it reads syntax
  (tree-sitter) instead of waiting for a compiler.
- **Understand Anything** has one plug-in per language and a shared list of
  node and edge kinds, including non-code things: configs, CI, Dockerfiles,
  SQL tables and endpoints.
- **REA** keeps each backend behind a declared contract, and every answer says
  what evidence it rests on and what it couldn't see.

The proposal: keep Swan's exact core, and rebuild its edges as plug-ins with
declared contracts, a syntax fallback for every language, and evidence on every
answer.

## What each one does better, and where it falls short

| | Better than Swan | Weaker than Swan |
|---|---|---|
| Graphify | Breadth: tree-sitter for ~30 languages (Go, Bash, Ruby, Elixir, Fortran, ...), so no repo gets nothing. One graph format. Cross-repo merge. It can also ingest SCIP (`scip_ingest.py`) and Postgres schemas. | Name-based guesses. In the cold test it found 26% of click's `get_current_context` call sites and 1% of ky's test-server calls (both inside callbacks), and no `Error` subclasses in TypeScript. |
| Understand Anything | A plug-in registry: each language is an `AnalyzerPlugin` plus a `LanguageConfig` (extensions, entry-point, test and config file patterns). 27 node kinds and 38 edge kinds, code and non-code. Fingerprints for staleness. Tours and plain-English summaries for people. | Summaries and domain flows come from an LLM (cost, and accuracy depends on the model). Stores one JSON file per project. |
| REA | Architecture: capability declarations are separate from provider adapters and from CLI/MCP translation; adapters are built lazily and probed for availability; every result carries provenance, coverage and unknowns; contract tests guard the boundaries. | A reverse-engineering tool, not a code map; its lesson is structure, not features. |

## Where Swan is today

- Exact and fast: compiler-made maps, answers in milliseconds, symbol edits,
  live diagnostics. After today's fixes it scored 0.85 against Graphify's 0.70
  on the cold test's 14 questions.
- Not modular at its edges: `src/pipeline.goose` (about 2,100 lines) hard-codes
  every language's detection, tool paths, environment and reuse rules. The
  Go/shell fallback added today needed edits in four places of it.
- Setup is all or nothing: `fetch-tools.sh` fetches 3.7 GB for every language.

## Proposed modules

1. **Core map** (Goose, as now): schema, queries, MCP server. Unchanged.
2. **Indexer adapters**: one declaration per language, as data, not code:
   file patterns, the tool and its pinned version and checksum, whether it runs
   the repo's code (so it needs `swan trust`), extra environment (for example
   `PYTHONPATH=src`), and the output (always SCIP). The pipeline reads the
   declarations; `fetch-tools.sh` and `swan doctor` read the same ones, which
   gives profiles ("python-typescript") for free.
3. **Flattener**: SCIP to rows. TypeScript on Bun today.
4. **Syntax layer**: the fallback for any language without a compiler indexer.
   Built today as `tools/syntax-index.ts` (Go, shell, Make, Ruby, Lua; line
   patterns). Next: tree-sitter through goose-treesitter.
5. **Evidence on every fact** (from REA): compiler (exact), syntax (`by_name`),
   or inferred (an LLM). Swan already marks `by_name`; make it a column every
   answer carries, and let callers filter on it.
6. **Non-code layer** (from Understand Anything): configs, CI workflows,
   Dockerfiles, SQL, OpenAPI, and shell entry points (`exec node door.ts`,
   `python -m pkg`) as nodes with typed edges into code. This is where
   "which script starts this program" gets answered.
7. **Storage adapter**: below.
8. **Front doors**: MCP for agents and the CLI, as now; GraphQL only if a
   dashboard needs it.

## Which parts could become Goose

1. The syntax layer, once goose-treesitter vendors the Go, Bash and Ruby
   grammars (it has 17 today; Go and Bash are not among them). This replaces
   line patterns with real parse trees.
2. The flattener (`tools/scip-flatten.ts`, about 500 lines): moving it to Goose
   removes Bun from mapping. Bun would then be needed only where a Node tool is.
3. The prerequisite check and `doctor`, so a missing `uv` or `libicu` is
   reported before any download.

Keep external: the SCIP indexers themselves (scip-typescript, scip-python,
rust-analyzer, scip-java, scip-clang). They are compilers; rewriting them is
not worth it.

## Storage: what comes in, and where it should live

| Kind of data | Shape | Fits |
|---|---|---|
| Compiler facts (symbols, occurrences, relationships) | Millions of rows, replaced file by file, point lookups and recursive walks | SQLite, per repo (today) |
| Syntax facts | The same shape, lower confidence | SQLite, the same tables, marked `by_name` |
| Diagnostics | Change on every edit | SQLite (today) |
| LLM-made meaning (summaries, domains, flows, claims) | Few rows, long text, versioned, shared | Postgres |
| Cross-repo and Brain knowledge (people, places, decisions linked to code) | Graph-shaped, shared across tools and sessions | Postgres |

**Recommendation: SQLite stays the engine for each repo's map; add an optional
export to Postgres for shared and cross-repo data. No Neo4j.**

- SQLite is what lets Swan run anywhere: no service, a few MB of memory while
  answering, one file per map. Its recursive queries already walk callers to
  depth 5 in 20 to 26 ms over 800,000 rows.
- Postgres is already running on the PC for Aya (the brainstem container), so
  it adds no new service. Recursive CTEs cover cross-repo callers. Apache AGE
  (Cypher inside Postgres) is the step up if graph queries get complex.
- Neo4j would add a JVM service using 1 to 2 GB of memory on a PC that is
  already deep in swap, and a second database to back up, without answering
  anything the two above can't.

## GraphQL

Useful later as a read-only schema over the same queries (`Symbol`,
`Reference`, `Caller`, `TypeEdge`, `Diagnostic`), for a UI or a dashboard that
wants one request instead of many. Agents keep MCP. Not needed before there is
such a UI.

## Pass criteria

- Cold test (`bench.py`: 14 questions, 5 public repos, answer key from the
  source): Swan at least 0.85 and at least Graphify's score on the same
  daily-refreshed graphs; no repo answers "no language found".
- Adding a language is one adapter declaration plus its fixture and tests, with
  no edit to the pipeline core.
- A fresh Ubuntu box reaches a working map with one command and a chosen
  profile, and a missing prerequisite is reported before anything downloads.
- The Postgres export round-trips the counts of symbols, occurrences and
  relationships exactly, and adds no always-on service.
- Every answer row carries its evidence kind: compiler, by name, or inferred.
