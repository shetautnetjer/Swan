#!/usr/bin/env bash
# Maps a repository (or refreshes its map): `swan map` runs every SCIP
# indexer it needs, flattens, and indexes. Kept for older callers.
#   scripts/index-repo.sh <repo> <out-dir>
exec "$(cd "$(dirname "$0")/.." && pwd)/bin/swan" map "$1" "$2"
