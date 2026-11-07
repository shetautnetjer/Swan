# Clean rebuild of one code map

Use clean rebuild after dependency, lockfile or indexer/configuration changes
that ordinary map fingerprints do not capture, or when generated map data is
suspect. Ordinary `map` and `update_map` retain their incremental behavior.
Clean rebuild runs the existing pipeline without reusable indexer output or
merge layers and publishes a completely new SQLite database.

```sh
/exact/swan/bin/swan map /exact/repo /exact/map-directory --clean
```

For MCP, inspect the actual `tools/list` schema for boolean `update_map.clean`.
Select with `use_repo {"path":"/exact/repo","build":false}`, verify both the
canonical `root` and expected `map`, then call:

```json
{"name":"update_map","arguments":{"repo":"/exact/repo","build":false,"clean":true}}
```

`build:false` controls implicit repository-selection builds; it does not
suppress this explicit indexing action. Clean MCP requests require an existing
map, an explicit exact repository root, and a selected database that matches
its recorded output directory. Paths merely inside an ancestor map are refused.
Malformed `clean` values are refused before selection or implicit build effects.
CLI clean supports a fresh output directory, but refuses an existing database
whose recorded repository root differs or cannot be read. For an unverifiable
map, use a new private output directory and verify its identity before querying.

There is no registry-wide wipe. The output directory, persistent writer lock,
other maps, saved trust, agent configuration and repository sources are not
deleted or moved. Existing saved trust rules still apply: skipped indexers
remain skipped. A completed clean rebuild is not proof of full language coverage
or build/test correctness; inspect its report and query known symbols afterward.

## Failure and concurrent access

The existing nonblocking writer lock covers invalidation, indexing, flattening
and database publication. Never delete `swan.db.lock`, including after an
interruption. Lock-file presence is not evidence of an active owner. A surviving
indexer or flattener inherits ownership after its parent dies; competing writers
must wait for that work to exit. See [concurrent access](concurrency.md).

Only generated reuse metadata is invalidated at the start: whole-language
manifests, cached TypeScript file listings, chunk/shared-input/file fingerprints,
delta-layer merge lists, and Python piece/file fingerprints. Each planned indexer
must create a new output, and the flattener must create new row files. Replacement
reuse metadata is written only after the new database is published. A later
ordinary map therefore rebuilds unfinished output after a failed clean attempt.

Any requested indexer failure prevents clean publication, even when another
indexer succeeds. Flattening, indexing or interruption before atomic rename
retains the previous database bytes. Generated SCIP files, row files, logs and
cache metadata are disposable and are not rolled back. The previous database
can still answer queries but may be stale relative to current source or inputs;
do not call the failed rebuild current or complete.

Missing flattened row files return an explicit tool error. Before clean
publication, every nonempty row is checked against the flattener's shapes,
numeric fields and role/relationship flags. Symbols accept both the current
six fields and the historical five fields without the optional docs tail;
empty files/lines remain valid. A malformed row returns an explicit tool
error, retains the prior database and leaves reuse metadata invalidated.
This closes a demonstrated permissive-parser case where a malformed symbols
file previously published an empty replacement and reported success.

These checks validate representation, not the semantic correctness or
completeness of syntactically valid indexer output. Deeper SQLite/indexing
errors can still abort the native process under the existing indexer
contract; those failures do not reach post-publication cache writes or a
success response. Restart an exited MCP process before retrying. Ordinary
incremental refresh keeps its existing parser behavior.

Read-only queries hold complete database snapshots, and persistent MCP readers
reopen the path for the next request after publication. A crash after publication
can leave missing cache metadata; a subsequent map may do extra indexing. A cache
write failure after publication is reported as a warning with the fresh database
already available. These are process-failure guarantees, not power-loss durability
or a promise that repository source remains unchanged during a build. Existing
limits for noncooperating tools, external stateful operations and saved-trust
updates remain unchanged.

## Qualification

Run against an explicit built binary from this source, using a disposable output
parent. No command below replaces an installation, grants trust or indexes a
live repository:

```sh
python3 tests/test_clean_reindex.py --binary /exact/swan/bin/swan --output-parent /tmp --timeout 30
python3 tests/test_request_build_policy.py --binary /exact/swan/bin/swan --output-parent /tmp --timeout 20
python3 -m unittest discover -s tests -p test_writer_lock.py -v
python3 tests/check_concurrency.py --binary /exact/swan/bin/swan --output-parent /tmp --rows 50000 --timeout 30
python3 tests/test_map_readers.py --binary /exact/swan/bin/swan --output-parent /tmp --timeout 20
```

The new test uses real native CLI/MCP, SQLite and process locks with synthetic
indexers and a synthetic flattener. It qualifies TypeScript delta-plan disposal,
all Python pieces rerunning, a fresh database dropping orphan rows, old/new
generation visibility in one persistent reader, partial and missing-output
failures, malformed symbol/extent/occurrence/relationship rows (including
invalid numbers), empty output and historical symbol-row acceptance,
same-server recovery, unchanged unrelated maps/source/trust, exact target
checks, and SIGINT while an indexer child retains the lock. The malformed-row
case fails against the pre-fix binary at the demonstrated empty-map success.
Artifacts include the executable hash,
invocation records, MCP transcripts and per-case outcomes. It does not qualify
real indexer semantics, live diagnostics or an installed deployment; those need
separate bounded checks with the chosen complete runtime layout.

### Observed on 2026-11-07

The final host binary SHA-256 is
`0a42c9dec9a9f5bcfb0ec9037a68a28cd908d5b7f5d3463466c1d339b882a3eb`.
It passed all six clean-rebuild cases and nine build-policy cases. Running
the final clean tests against pre-fix binary
`c7101a1fc78604ff2332d196dc20f9d33d8184c310759e6d53306101c3ee05f9`
fails specifically at malformed-row publication, preserving the regression
witness. The host's Node 26 Python/TypeScript doctor environment remains
unqualified.

Cua Space rebuilt source archive SHA-256
`fd6c42c218baa9b94a7310868450b0860dd1f453d12678dcff0150fcee7b478f`
and passed Python/TypeScript doctor on Node 24.21/Bun 1.3.14, six clean cases,
nine build-policy cases, nine concurrency cases, five reader cases and all
24 fixture patterns. Manifest-covered source bytes stayed unchanged except
the generated binary and LSP C output rebuilt in the guest. Earlier guest
results of 41 unit tests and 14 skill-unit tests used the pre-row-validation
source and are recorded separately, not claimed as final-source reruns.
This results note and the chronological STATUS entry were added afterward;
the exercised runtime and test source are unchanged.

Doctor establishes the selected dependency profile, not full semantic
coverage. These host/guest checks establish bounded process-failure,
publication and fixture behavior, not power-loss durability, comprehensive
language semantics, installed host adoption or a live map refresh.
