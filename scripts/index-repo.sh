#!/usr/bin/env bash
# Maps a repository: every SCIP indexer it needs -> flatten -> swan index.
#   scripts/index-repo.sh <repo> <out-dir>
# Leaves <out-dir>/index-<language>.scip, the TSV rows, and <out-dir>/swan.db.
# The repo itself is only read.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
"$here/scripts/scip-run.sh" "$1" "$2"
"$here/bin/swan" index "$2" "$2/swan.db" "$(cd "$1" && pwd)"
