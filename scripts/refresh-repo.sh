#!/usr/bin/env bash
# Refreshes a map after edits; `swan map` rewrites only the changed files
# when the map exists.
#   scripts/refresh-repo.sh <repo> <out-dir>
[ -f "$2/swan.db" ] || { echo "no map at $2/swan.db; run swan map first" >&2; exit 1; }
exec "$(cd "$(dirname "$0")/.." && pwd)/bin/swan" map "$1" "$2"
