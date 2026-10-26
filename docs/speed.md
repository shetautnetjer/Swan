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
