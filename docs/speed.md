# Speed of the first build, and of every build after it

as_of: 2026-10-26, on the development machine (32 cores, 59 GB).

## Where the time went

| Repo | Total | Indexer | Flatten | SQLite load |
|---|---|---|---|---|
| A 2,853-file Python research repo (with some TS/JS) | 159 s | scip-python 139 s (88%) | 2.0 s | 3.4 s |
| AEON (2,309 TS files) | 18.6 s | scip-typescript 16.7 s (90%) | 0.7 s | 1.1 s |

The indexers are the cost. Swan's own steps are a few seconds. SQLite bulk
settings were already in place (one transaction, journal and sync off,
indexes built after the inserts); a larger cache and exclusive locking
changed nothing measurable, at 3.4 s either way.

## What changed

1. **Every language at once.** `swan map` now starts the indexers through
   the C shim's `swan_spawn` / `swan_wait_any` and runs up to
   `SWAN_JOBS` (default: half the cores, at most 8) at the same time.
2. **Python in pieces.** scip-python has almost no start-up cost (about 1 s
   for a one-file folder), and `--target-only` limits a run to part of the
   repo while imports still resolve against the whole of it. `swan map`
   splits the Python into pieces of similar size, folders where they fit
   and single files where a folder is too big, and runs them side by side.
   Document paths from those runs are relative to their piece; the
   flattener re-roots them from the index's own `project_root` metadata,
   and drops the repeats when two runs write the same file. Checked against
   one whole-repo run: the same 3,887 files. The rows of 400 sampled Python
   files differ only where the split runs label standard-library symbols
   correctly (`python-stdlib`), which the single run got wrong. 10 random
   functions: every reference real, 92% of ripgrep's lines found.
3. **Reuse.** Each piece, and each whole-language index, records a
   fingerprint of its files (size and mtime). A re-map reruns only what
   changed. A piece also reruns when one of its files uses a symbol defined
   in a changed file, according to the last map, so cross-file effects are
   not missed. With no changes at all, `swan map` stops before flattening.

TypeScript, Rust, Java and C/C++ indexers have no per-file mode, so
they rerun whole when any of their files changes; scip-clang already uses
every core itself.

## Before and after

| | Before | After |
|---|---|---|
| Python research repo, first map | 159 s | 63 s |
| Its Python only (28 MB copy), first map | n/a | 47 s |
| Same copy, one file edited | 47 s | 8.8 s (one piece rerun) |
| Python research repo, nothing changed | 159 s | 0.8 s |
| AEON, first map | 18.6 s | 18.6 s (one TS project; nothing to split) |
| AEON, nothing changed | 18.6 s | 0.05 s |

## Second pass (2026-10-26): what was tried, and what was kept

Tried in a separate copy (branch `exp/modular`), measured against main on
the same three repos, and merged only where it was faster with equal
results.

| Idea | Result | Kept |
|---|---|---|
| TypeScript split into chunks: one tsconfig each, extending the project's, with the exact file list from `tsc --listFilesOnly` (so its include and exclude hold) and every `.d.ts` | AEON first map 18.6 s to 10.1 s. 98.5% of files have identical rows. The rest differ only in scip-typescript's order-dependent counters for duplicate names, and broken links fell from 287 to 199 | yes, but only into the slots other languages leave free: on the Python repo the chunks cost more total work and slowed it from 64 s to 71 s |
| Caller walk run once into a temporary table, instead of once each for the list, the summary and the test files | `get_callers` depth 3 on AEON: 29 to 12 ms and 23 to 9.5 ms, same answers | yes |
| Covering index for the caller walk | about 15%, smaller than the temp table and overlapping it | no |
| Finer Python pieces (16 instead of 6) | slower: 88 s against 64 s, since more pieces repeat the shared analysis | no |
| Starting the largest pieces first (by bytes) | slower: 71 s against 67 s, because bytes predict scip-python's time badly | no |
| More parallel jobs (`SWAN_JOBS=16`) | Python repo 70 s to 60 s, but up to 3 GB per process | no, left as the documented `SWAN_JOBS` setting |
| Per-language databases, a separate lean read path | not built: reads already take 0.03 to 3 ms in a long-lived MCP process | no |
| Resident pyright and rust-analyzer | not built yet: the next step for live errors and small refreshes, and a bigger job | later |

Two fixes found on the way. scip-typescript numbers anonymous type
literals by walk order, so those numbers are dropped. And when a repo has
no package.json, a chunk's module names carry the absolute path, which is
cut. `tests/split_check.ts` maps a generated 24-file project both ways
and requires identical rows.

| | Main before this pass | After |
|---|---|---|
| AEON, first map | 18.6 s | 10.1 s |
| Python research repo, first map | 63.8 s | 64.2 s (unchanged) |
| Rust workspace (copy), first map | 5.4 s | 5.5 s (unchanged) |
| `get_callers` depth 3, AEON | 23 to 29 ms | 9.5 to 12 ms |

## Third pass (2026-10-26): an edit reindexes only what it touches

TypeScript chunks each load the shared code, about 7 s on AEON, so rerunning
even one costs most of a full map. Now:

- The chunk plan is kept while the set of files is the same, so an edit no
  longer moves files between chunks.
- The changed files and the files that use their symbols (by the last map)
  are indexed as a small run of their own, a *layer*. Layers are flattened
  before the chunks, and the first rows for a file win, so the newest layer
  wins. Older layers are kept. Past 6 layers, or once the layers cover a
  quarter of the files, the chunks run again and the layers go.
- `tsc --listFilesOnly` is kept with a key of the file names and the config,
  and asked again only when files come or go.
- Files with `/// <reference types=...>` go into every chunk and layer, as
  the .d.ts files do: they bring ambient types such as bun:test, which a
  chunk without them missed.

AEON copy (2,361 files), each a one-line edit:

| Edit | Files reindexed | swan map | Before |
| --- | --- | --- | --- |
| a file 1 other file uses | 2 | 2.0 s | 8.4 s |
| a file 8 others use | 9 | 3.1 s | 9.3 s |
| src/backend/backend.ts (266 users) | 267 | 7.8 s | 9.9 s |
| nothing changed | 0 | 0.07 s | 1.7 s |

After that series, the map matches a fresh one on 713,233 of 713,268
occurrence rows. The 35 that differ are scip-typescript's order-dependent
counters for repeated anonymous names (`text0` against `text2`), which also
differ between two fresh chunked maps.

### Warm language servers

`SWAN_WARM=<language>` or `SWAN_WARM=auto` (the language with the most files)
starts that language's server as soon as `swan serve` has answered
`initialize`, and opens its largest file so the server starts loading the
project. goose-lsp v0.1.1 reads the server's output on a thread, so a server
busy indexing never stalls on a full pipe while nobody asks it anything. Off
by default: a resident server costs memory.

AEON copy, the first live `get_diagnostics` on src/agent-presets.ts, asked
10 s after `initialize`: 3.56 s without warming, 0.66 s with SWAN_WARM=auto.

### search_pattern and the flattener

search_pattern names each match's symbol from one query per file instead of
one per match: `await $X` over AEON (16,054 matches) went from 0.27 s to
0.14 s, output byte for byte the same. ast-grep takes 0.1 s.

A Goose flattener was weighed and not built. On AEON the Bun flattener
reads 128 MB of SCIP and writes 108 MB of rows in 1.2 s, the larger part of
a 2 s small-edit re-map. Moving it to Goose could save part of that second,
for a rewrite of its ~480 lines and every language repair in it. Writing
rows straight into the map, without the TSV step, is the bigger lever if
small-edit maps need to get faster still.
