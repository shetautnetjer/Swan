#!/usr/bin/env bash
# Runs the compilers' own checks (tsc, cargo check) over a repo and loads
# what they report into its map, pinned to symbols.
#   scripts/diagnose-repo.sh <repo> <out-dir>     (out-dir from index-repo.sh)
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
[ -f "$2/swan.db" ] || { echo "no map at $2/swan.db; run scripts/index-repo.sh first" >&2; exit 1; }
bun "$here/tools/diagnostics.ts" "$1" "$2"
"$here/bin/swan" diagnostics "$2" "$2/swan.db"
