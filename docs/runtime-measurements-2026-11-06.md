# Runtime measurements, November 6, 2026

Decision: retain the concurrency correctness fix and existing incremental
caches. This bounded experiment does not justify another SQLite optimization,
a database replacement, or a grammar-bundle redesign.

Candidate source: `ef03ba0e13e357316e318a2384b58c5ec0b222d3`.
Binary SHA-256: `597dd20e6b58919a703249e9f77c55783a2c2a04a7a8d8bd66739b7617b4a5f8`.
Environment: isolated CUA Ubuntu 24.04 x86-64, glibc 2.39, four cores/4 GB;
one indexer worker, existing installed tools, fresh Swan map directories.
The OS page cache was not flushed.

## Mapping and refresh

Each language started with 120 generated files with cross-file calls. Fourteen
map calls covered initial indexing, three unchanged reruns, an edited file,
a new file and a separate fresh map of the final source. Every stage checked
known definitions, extents and references. Unchanged semantic rows matched
exactly; final refreshed and fresh maps matched exactly for both languages.
Final MCP definition/body/reference checks also passed.

| Wall time, seconds | TypeScript | Python |
| --- | ---: | ---: |
| Initial map | 0.467 | 1.566 |
| Unchanged map, median of three | 0.0315 | 0.1638 |
| One edited file | 0.464 | 0.815 |
| One added file | 0.515 | 0.865 |
| Fresh map of final source | 0.464 | 0.815 |

Reported database loading/refresh took 6–23 ms; external indexer phases took
388–766 ms. Initial Python mapping also includes setup outside its reported
indexer phase. These numbers do not establish a useful SQLite bottleneck.
Maximum reported RSS was about 224 MiB for TypeScript and 181 MiB for Python;
GNU time reports a maximum, not summed simultaneous child memory.

## Reader correctness cost

The same immutable 50,000-symbol synthetic map was queried by the earlier
matcher-only build and the corrected build. Each persistent MCP session ran
20 warmups and 200 measured `find_symbol` requests. Every complete reply was
validated; source/database hashes and metadata remained unchanged.

| Milliseconds per request | Earlier build | Corrected build |
| --- | ---: | ---: |
| Median | 0.085969 | 0.168354 |
| p95 | 0.102850 | 0.215760 |

The observed median increase was 0.082385 ms, including IPC and JSON decoding.
Reopening the map and keeping a consistent read transaction is retained for
correctness. One baseline-first session per executable is descriptive evidence,
not a statistical-significance or production tail-latency claim. Large
monorepos, dependency-heavy projects and other platforms remain unmeasured.

## Reproduction and receipts

The harnesses create new directories, refuse missing prerequisites, retain
logs/provenance, and do not install dependencies, change saved trust or replace
an executable. Use an absolute, reviewed binary in its complete installation.

```sh
python3 scripts/bench-runtime.py --binary /absolute/staged/Swan/bin/swan --output-parent /absolute/disposable-output --mcp-helper /absolute/reviewed/Swan/scripts/demo-offline.py --files 120 --jobs 1 --timeout 240 --time-binary /absolute/gnu-time
python3 scripts/bench-reader-latency.py --binary /absolute/new/Swan/bin/swan --baseline /absolute/earlier/Swan/bin/swan --database /absolute/retained-concurrency-fixture/baseline.db --repository /absolute/retained-concurrency-fixture/repo --mcp-helper /absolute/reviewed/Swan/scripts/demo-offline.py --output-parent /absolute/disposable-output
```

`bench-runtime.py` defaults to `/usr/bin/time`. CUA lacked it, so the Ubuntu
`time` package `1.9-0.2build1` was downloaded and extracted into the disposable
lab, with no system installation. Package SHA-256:
`abe09ee9806b336cc255c013cc726b39cbf9d56ff9dc7c2acff5762ab0f07be8`.
The second harness requires the known generation-A fixture from
`tests/check_concurrency.py`; it does not accept an arbitrary map as its oracle.

[Machine-readable measurements](evidence/swan-performance-2026-11-06.json)
record the summaries and raw-summary hashes. Full samples, source/semantic
oracles, logs, tool hashes and provenance were retained in the test lab:

- `/home/cua/swan-package-m1RBGOcY/swan-runtime-bigun36h`
- `/home/cua/swan-package-m1RBGOcY/swan-reader-latency-y32vjttc`

These results supplement the [concurrency qualification](concurrency.md);
they do not substitute for its interrupted-writer and contention tests.

## Review-completion recheck

After the lock-lifetime review fix, source `5d415961` / binary `05896de6…`
passed a fresh 14-call mapping/refresh experiment with the same 120-file
fixture design. Unchanged rows and incremental-versus-fresh equality passed
for both languages, as did known MCP answers. The reader-latency experiment
above was not rerun or relabeled. See the
[review-completion receipt](evidence/swan-review-completion-2026-11-06.json)
and its separately retained `swan-runtime-51a_5c5i/summary.json` for this
later run. No additional performance optimization was introduced.
