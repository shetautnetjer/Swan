#!/usr/bin/env bash
# Runs the repo's checkers (tsc, cargo check, pyright) into its map.
#   scripts/diagnose-repo.sh <repo> <out-dir>
exec "$(cd "$(dirname "$0")/.." && pwd)/bin/swan" check "$1" "$2"
