# Concurrent map access

As of November 6, 2026, [PR #15](https://github.com/shetautnetjer/Swan/pull/15)
is a **qualified candidate, not yet merged**. The qualification below applies
to its exact Linux binary and disposable local-filesystem tests. It does not
replace an active installation or establish production readiness.

## Contract and boundaries

- `swan map`, direct `swan index`, and direct `swan refresh` share a
  nonblocking, per-database writer lock. The map pipeline holds it across
  indexer output, flattening and publication, not just the SQLite transaction.
  A competing writer fails explicitly with "another writer is in progress";
  retry after the current job finishes. Independent maps have independent locks.
- Writer identity is the canonical parent directory plus database filename.
  Symlinked parent directories resolve to the same identity, including before
  the database exists. A database-file symlink is refused for writing; use
  the real database path. Do not use alternate hard-link identities.
- The adjacent `swan.db.lock` file persists after release. **Its presence is
  not ownership, and it must not be deleted as a recovery step.** The OS lock
  on its open descriptor establishes ownership. Deleting the file can let
  competing writers lock different inodes under the same name.
<!-- coderabbit-ai-generated:v1 -->

<!-- coderabbit-ai-generated-section:v1:fa06c16c489d439cc55e05dc2ae3e93da769e4ae12d2d2413181c160bb1933df -->

- Indexers and flatteners inherit the writer descriptor to protect shared
  output if Swan dies. Failure, timeout and parent death retain ownership
  until surviving children exit. Successful foreground jobs and map publication
  explicitly unlock before closing, allowing idle build servers to keep their
  descriptors without blocking a subsequent writer. This success boundary
  assumes indexers finish output before reporting success; arbitrary background
  writes after successful completion are outside this qualification.

<!-- /coderabbit-ai-generated:v1 -->
- A full index builds a separate database and publishes it by rename; refresh
  updates the existing database in a transaction. CLI queries and the MCP
  read-only tool whitelist hold a SQLite read transaction while constructing
  an answer. Persistent MCP processes reopen the selected path for subsequent
  requests, so completed replacements and refreshed freshness metadata become
  visible without retaining a disconnected old database inode.
- These are **database-row snapshots**, not snapshots of source files on disk.
  Source reads, structural patterns and live diagnostics can see separately
  changing files; keep the existing freshness and coverage checks. The
  whitelist covers symbol/graph queries, saved diagnostics, structural search,
  `use_repo` and `index_info`; live requests and stateful tools are excluded.

Contention can return a busy/locked error rather than an answer. Selection-time
errors were tested to recover in the same MCP process once the blocker was
released. An error during query execution can terminate the process; restart
that server if needed, then retry within the task's authorization. A failed,
truncated or absent answer is not a clean result. There is no automatic retry
or guarantee that every concurrent request completes successfully.

Concurrent stateful operations outside the protected map/index/refresh writers
and read whitelist are not qualified: edits, rename/rewrite apply, formatting,
check/diagnostic ingestion, live adapters and test commands need their own
coordination. The saved `data/trusted-repos` rewrite remains a separate unlocked
race; serialize trust changes. Windows/macOS, network filesystems, arbitrary
hard-link aliases, threaded SQLite use and power-loss durability are also
outside this qualification.

## Qualification: November 6, 2026

Source: `ef03ba0e13e357316e318a2384b58c5ec0b222d3`.
Built and exercised in the isolated Ubuntu 24.04 x86-64 CUA environment.
Candidate SHA-256:
`597dd20e6b58919a703249e9f77c55783a2c2a04a7a8d8bd66739b7617b4a5f8`.

| Check | Observed result and scope |
| --- | --- |
| `tests/check_concurrency.py` | 9/9 scenarios pass: held reader, held writer, refresh snapshots, blocked query, simultaneous refresh, interrupted refresh, temporary-file collision, persistent replacement and writer-entry locks. Successful reads match a complete old/new synthetic generation; explicit contention failure is permitted. |
| `tests/test_map_readers.py` | Five focused reader regressions pass: refreshed freshness, Swan edit metadata, busy errors/recovery, missing-map refusal/recovery and schema refusal/recovery. |
| Local package/native tests | 36 pass, including eight native lock tests. These include parent-directory aliases, database-file symlink refusal, map deletion/recreation and child-held ownership after parent death through both native spawn/run paths. |
| Existing skill fixture | 24/24 patterns pass; this qualifies those patterns, not all languages or all concurrency paths. |
| Real Python/TypeScript smoke | Known definitions/references and live diagnostics pass. This is separate from the concurrency harness's synthetic flattened rows. |

The concurrency harness uses Linux event barriers and separate processes;
Python SQLite is an independent lock/snapshot oracle, while Swan uses its
pinned embedded SQLite. Native lock tests exercise the production C helper
with only the Goose builder ABI stubbed. Passing interruption cases does not
establish durability against power failure or every possible interruption.

## Reproduce with a staged binary

Use the source revision matching the staged binary. Set these placeholders to
an isolated installation and a disposable writable directory; do not point at
production maps. Python 3 and Linux are required, and the native unit tests
also need a C compiler. The runtime tests retain artifacts under newly created
subdirectories; they do not build/install Swan, run indexers or grant trust.

```sh
cd /path/to/reviewed/Swan
mkdir -p /path/to/disposable-output
python3 -m unittest discover -s tests -p 'test_writer_lock.py' -v
python3 tests/check_concurrency.py --binary /path/to/staged-swan/bin/swan --output-parent /path/to/disposable-output --rows 50000 --timeout 30
python3 tests/test_map_readers.py --binary /path/to/staged-swan/bin/swan --output-parent /path/to/disposable-output --timeout 15
```

Inspect `results.json` and `reader-results.json` in the printed artifact
directories. Exit 0 is pass; the concurrency harness returns 2 for an
inconclusive barrier/timing outcome, which requires investigation rather than
a success claim. An old binary is expected to expose regressions, so record
the binary hash with every run. These commands do not qualify every external
indexer, language server or source-mutating tool.
