#!/usr/bin/env bash
# Runs every SCIP indexer a repository needs and flattens them into one set
# of rows. Used by index-repo.sh and refresh-repo.sh.
#   scripts/scip-run.sh <repo> <out-dir>
# Languages are detected from the repo root: TypeScript/JavaScript
# (tsconfig.json or package.json), Python (any .py file), Rust (Cargo.toml).
# The repo is only read: Rust build output goes to <out-dir>/cargo-target.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
repo="$(cd "$1" && pwd)"
mkdir -p "$2"
out="$(cd "$2" && pwd)"
# Edits after this moment make answers stale (see src/fresh.goose).
touch "$out/scip-started"
rm -f "$out"/index-*.scip
ms() { echo $(( ($(date +%s%N) - $1) / 1000000 )); }

if [ -f "$repo/tsconfig.json" ] || [ -f "$repo/package.json" ]; then
  t=$(date +%s%N)
  (cd "$repo" && "$here/tools/node_modules/.bin/scip-typescript" index --output "$out/index-typescript.scip")
  echo "scip-typescript: $(ms "$t") ms" >&2
fi

if [ -n "$(find "$repo" -name '*.py' -not -path '*/node_modules/*' -not -path '*/.venv/*' -print -quit)" ]; then
  t=$(date +%s%N)
  env_args=()
  # scip-python asks pip for installed packages; without pip, index with none.
  command -v pip >/dev/null || env_args=(--environment "$here/tools/empty-python-env.json")
  (cd "$repo" && NODE_OPTIONS="--max-old-space-size=${SWAN_NODE_HEAP_MB:-16000}" \
    "$here/tools/node_modules/.bin/scip-python" index . --quiet \
      --project-name "$(basename "$repo")" --project-version 0 "${env_args[@]}" \
      --output "$out/index-python.scip")
  echo "scip-python: $(ms "$t") ms" >&2
fi

if [ -f "$repo/Cargo.toml" ]; then
  t=$(date +%s%N)
  ra="${RUST_ANALYZER:-$here/.tools/rust-analyzer/rust-analyzer}"
  (cd "$repo" && CARGO_TARGET_DIR="$out/cargo-target" "$ra" scip . --output "$out/index-rust.scip" 2>"$out/rust-analyzer.log")
  echo "rust-analyzer scip: $(ms "$t") ms ($(grep -c 'Bug: definition' "$out/rust-analyzer.log" || true) definitions it could not place)" >&2
fi

shopt -s nullglob
scips=("$out"/index-*.scip)
[ ${#scips[@]} -gt 0 ] || { echo "no language found to index in $repo" >&2; exit 1; }
bun "$here/tools/scip-flatten.ts" "${scips[0]}" "$out" "${scips[@]:1}"
