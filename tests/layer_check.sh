#!/usr/bin/env bash
# Checks that a real TypeScript edit reindexes only the changed files and
# the files that use them (a layer over the last full run), yet leaves a map
# equal to a fresh build of the edited repo: one-chunk mode (no free slots,
# as on a repo with Python and Java beside it) and split mode.
#   tests/layer_check.sh
set -euo pipefail
cd "$(dirname "$0")/.."
export SWAN_TRUST_BUILD=1
work=data/layer-check
rm -rf "$work" && mkdir -p "$work"
failures=0
ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1"; failures=$((failures + 1)); }
map()  { bin/swan map "$1" "$2" 2>&1; }
refresh() { map "$work/$repo" "$work/$repo.map" > "$work/$1.out"; }
ran()     { grep -Eq "^$1[^:]*: [0-9]+ ms" "$work/$2.out"; }
same() { # against a fresh build in one whole-project scip-typescript run
  SWAN_JOBS=1 SWAN_TS_LAYER_MIN=100000000 map "$work/$repo" "$work/$1.fresh" > "$work/$1.fresh.out"
  if grep -Eq "^scip-typescript [0-9]+/" "$work/$1.fresh.out"; then fail "$1: the fresh build was split"; fi
  python3 tests/dump.py "$work/$repo.map/swan.db" | grep -v '^F' > "$work/$1.kept.txt"
  python3 tests/dump.py "$work/$1.fresh/swan.db" | grep -v '^F' > "$work/$1.fresh.txt"
  if diff -u "$work/$1.fresh.txt" "$work/$1.kept.txt" > "$work/$1.diff"; then
    ok "$1: the map equals a fresh build ($(wc -l < "$work/$1.fresh.txt") rows)"
  else
    fail "$1: the map differs from a fresh build"; head -20 "$work/$1.diff"
  fi
}
no_index() { if ran "$1" "$2"; then fail "$2: $1 ran"; else ok "$2: $1 did not run"; fi; }
indexed()  { if ran "$1" "$2"; then ok "$2: $1 ran"; else fail "$2: $1 did not run"; cat "$work/$2.out"; fi; }
layer_of() { # layer_of <label> <n>: a layer of n files ran, and no full run
  if grep -Eq "^scip-typescript changed files \($2\): [0-9]+ ms" "$work/$1.out"; then ok "$1: a layer of $2 files ran"
  else fail "$1: no layer of $2 files"; grep 'scip-typescript' "$work/$1.out" || true; fi
  no_index "scip-typescript [0-9]+/" "$1"
}

# A project of 40 files, each using the one before it, plus a shared
# declaration file.
make_repo() {
  mkdir -p "$work/$repo/src"
  # In one-chunk mode the config names a type library that is not there, as
  # on a repo whose node_modules are not installed: tsc still lists the files.
  local types=""; [ "$repo" = one ] && types=',"types":["swan-not-installed"]'
  printf '{"compilerOptions":{"strict":true,"noEmit":true,"module":"esnext","moduleResolution":"bundler"%s},"include":["src/**/*"]}\n' "$types" > "$work/$repo/tsconfig.json"
  printf 'declare interface Shared { id: number }\n' > "$work/$repo/src/types.d.ts"
  # A file outside the config's include that a root imports: tsc compiles it,
  # but a whole run does not index it, so no chunk may either.
  mkdir -p "$work/$repo/scripts"
  printf 'export function helper(n: number): number { return n * 3; }\n' > "$work/$repo/scripts/helper.ts"
  for i in $(seq 0 39); do
    {
      if [ "$i" -gt 0 ]; then echo "import { f$((i - 1)) } from \"./m$((i - 1))\";"; else echo 'import { helper } from "../scripts/helper";'; fi
      echo "export interface Box$i { value: number; inner: { depth: number } }"
      echo "export function f$i(n: number): number {"
      echo "  const s: Shared = { id: n };"
      if [ "$i" -gt 0 ]; then echo "  return f$((i - 1))(n) + s.id;"; else echo "  return helper(s.id);"; fi
      echo "}"
      echo "export const box$i: Box$i = { value: f$i($i), inner: { depth: $i } };"
      # Anonymous types, which scip-typescript numbers in the order it first
      # meets them. In one-chunk mode m31 uses one of m4's: a whole run meets
      # m31 first (the config's order), tsc's listing m4 first, so a chunk
      # in the listing's order would name it otherwise. (Across split chunks,
      # or from a layer to a file outside it, such names can differ anyway;
      # the edits below stay clear of these two files.)
      echo "export const cfg$i = { inner: { depth: $i, tag: \"m$i\" } };"
      if [ "$i" = 31 ] && [ "$repo" = one ]; then echo 'import { cfg4 } from "./m4";'; echo "export const tag31 = cfg4.inner.tag;"; fi
    } > "$work/$repo/src/m$i.ts"
  done
}

for mode in one split; do
  repo=$mode
  if [ "$mode" = one ]; then export SWAN_JOBS=1 SWAN_TS_LAYER_MIN=8; else export SWAN_JOBS=4; unset SWAN_TS_LAYER_MIN; fi
  make_repo
  map "$work/$repo" "$work/$repo.map" > "$work/$mode-first.out"
  if [ "$mode" = one ]; then indexed "scip-typescript 0/1" "$mode-first"; same "$mode-first"; else indexed "scip-typescript 0/4" "$mode-first"; fi
  # A new export in m5: m5 and its one user, m6, are indexed again.
  echo 'export function g5(n: number): string { return String(f5(n)); }' >> "$work/$repo/src/m5.ts"
  refresh "$mode-add"
  layer_of "$mode-add" 2
  same "$mode-add"
  # m6 starts using it; m20 changes its body. Layers stack, newest first.
  printf 'import { g5 } from "./m5";\nexport const label6: string = g5(6);\n' >> "$work/$repo/src/m6.ts"
  sed -i 's/return f19(n) + s.id;/return f19(n) * 2 + s.id;/' "$work/$repo/src/m20.ts"
  refresh "$mode-use"
  layer_of "$mode-use" 4
  same "$mode-use"
  # A rename across files: f12 becomes h12, and its user follows.
  sed -i 's/\bf12\b/h12/g' "$work/$repo/src/m12.ts" "$work/$repo/src/m13.ts"
  refresh "$mode-rename"
  layer_of "$mode-rename" 3
  same "$mode-rename"
  refresh "$mode-again"
  no_index "scip-typescript" "$mode-again"
  same "$mode-again"
done

# Below the threshold, one-chunk mode stays a single whole-language run.
repo=small
export SWAN_JOBS=1; unset SWAN_TS_LAYER_MIN
make_repo
map "$work/$repo" "$work/$repo.map" > "$work/small-first.out"
indexed "scip-typescript" small-first
no_index "scip-typescript [0-9]+/" small-first

unset SWAN_JOBS
echo
if [ "$failures" -gt 0 ]; then echo "$failures layer check(s) failed"; exit 1; fi
echo "all layer checks passed"
