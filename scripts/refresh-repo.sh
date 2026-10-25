#!/usr/bin/env bash
# Brings a map up to date after edits: reruns the SCIP indexers over the
# whole repo (they have no per-file mode), flattens, and rewrites only the
# files whose rows changed.
#   scripts/refresh-repo.sh <repo> <out-dir>     (out-dir from index-repo.sh)
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
[ -f "$2/swan.db" ] || { echo "no map at $2/swan.db; run scripts/index-repo.sh first" >&2; exit 1; }
"$here/scripts/scip-run.sh" "$1" "$2"
"$here/bin/swan" refresh "$2" "$2/swan.db" "$(cd "$1" && pwd)"
