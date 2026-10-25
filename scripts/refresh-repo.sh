#!/usr/bin/env bash
# Brings a map up to date after edits: reruns scip-typescript over the whole
# repo (it has no per-file mode), flattens, and rewrites only the files whose
# rows changed.
#   scripts/refresh-repo.sh <repo> <out-dir>     (out-dir from index-repo.sh)
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
repo="$(cd "$1" && pwd)"
out="$(cd "$2" && pwd)"
[ -f "$out/swan.db" ] || { echo "no map at $out/swan.db; run scripts/index-repo.sh first" >&2; exit 1; }
t0=$(date +%s%N)
(cd "$repo" && "$here/tools/node_modules/.bin/scip-typescript" index --output "$out/index.scip")
t1=$(date +%s%N)
bun "$here/tools/scip-flatten.ts" "$out/index.scip" "$out"
"$here/bin/swan" refresh "$out" "$out/swan.db" "$repo"
echo "scip-typescript: $(( (t1 - t0) / 1000000 )) ms"
