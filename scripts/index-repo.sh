#!/usr/bin/env bash
# Maps a TypeScript repository: scip-typescript -> flatten -> swan index.
#   scripts/index-repo.sh <repo> <out-dir>
# Leaves <out-dir>/index.scip, the TSV rows, and <out-dir>/swan.db. The repo
# itself is only read.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
repo="$(cd "$1" && pwd)"
mkdir -p "$2"
out="$(cd "$2" && pwd)"
t0=$(date +%s%N)
(cd "$repo" && "$here/tools/node_modules/.bin/scip-typescript" index --output "$out/index.scip")
t1=$(date +%s%N)
bun "$here/tools/scip-flatten.ts" "$out/index.scip" "$out"
"$here/bin/swan" index "$out" "$out/swan.db" "$repo"
echo "scip-typescript: $(( (t1 - t0) / 1000000 )) ms"
