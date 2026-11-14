#!/usr/bin/env bash
# Checks that an edit in comments or layout reruns no indexer, yet leaves a
# map equal to a fresh build of the edited repo (src/change.goose), and that
# a real change, a doc comment or a Python indent still reruns its indexer.
#   tests/cosmetic_check.sh
set -euo pipefail
cd "$(dirname "$0")/.."
export SWAN_TRUST_BUILD=1
work=data/cosmetic-check
rm -rf "$work" && mkdir -p "$work"
failures=0
ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1"; failures=$((failures + 1)); }
map()  { bin/swan map "$1" "$2" 2>&1; }

# refresh <label>: maps the edited repo over the kept map, keeps the report.
refresh() { map "$work/$repo" "$work/$repo.map" > "$work/$1.out"; }
ran()     { grep -Eq "^$1[^:]*: [0-9]+ ms" "$work/$2.out"; }
# same <label>: the kept map holds exactly what a fresh build of the repo holds.
same() {
  map "$work/$repo" "$work/$1.fresh" > /dev/null
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

# ---- TypeScript
repo=ts
cp -r fixtures/tiny-ts "$work/$repo"
map "$work/$repo" "$work/$repo.map" > "$work/ts-first.out"
s="$work/$repo/src/store.ts"
# Comments, blank lines and spacing: every row in store.ts moves.
{ echo "// a comment"; echo; echo "/* and a block"; echo "   comment */"; cat "$s"; } > "$s.new" && mv "$s.new" "$s"
sed -i 's/^export class Store {$/export   class   Store {   \/\/ trailing/; s/^  get(id: string)/  get(  id: string )/' "$s"
refresh ts-comment
no_index scip-typescript ts-comment
grep -q "rows moved to match 1 file" "$work/ts-comment.out" && ok "ts-comment: store.ts's rows were moved" || fail "ts-comment: no rows moved"
same ts-comment
# Moved rows read as fresh, and a symbol's body is cut from its new place.
q=$(bin/swan query "$work/ts.map/swan.db" symbol Store src/store.ts)
case "$q" in *'"stale":true'*) fail "ts-comment: store.ts reads as stale";; *) ok "ts-comment: store.ts reads as fresh";; esac
case "$q" in *'"body":"export   class   Store {   // trailing'*) ok "ts-comment: Store's body is cut from where it is now";;
             *) fail "ts-comment: Store's body is cut from the wrong place: ${q:0:300}";; esac
refresh ts-again
no_index scip-typescript ts-again
same ts-again
# A second cosmetic edit on top of moved rows, still without an indexer run.
sed -i 's/^  total(): number {$/\n\n  total(): number {   \/\/ sums the weights/' "$s"
refresh ts-twice
no_index scip-typescript ts-twice
same ts-twice
# A doc comment is read into the map: the indexer runs.
sed -i 's|^export function makeStore|/** Makes an empty store. */\nexport function makeStore|' "$s"
refresh ts-doc
indexed scip-typescript ts-doc
same ts-doc
# Real code.
echo 'export const heaviest = (s: Store) => s.total();' >> "$s"
refresh ts-code
indexed scip-typescript ts-code
same ts-code
# Touched, not changed.
touch "$work/$repo/src/kinds.ts"
refresh ts-touch
no_index scip-typescript ts-touch
same ts-touch

# ---- Python
repo=py
cp -r fixtures/tiny-py "$work/$repo"
map "$work/$repo" "$work/$repo.map" > "$work/py-first.out"
p="$work/$repo/shapes/__init__.py"
{ echo "# a comment"; echo; cat "$p"; } > "$p.new" && mv "$p.new" "$p"
sed -i 's/^class Square(Shape):$/class Square(Shape):   # the four-sided one/' "$p"
refresh py-comment
no_index scip-python py-comment
same py-comment
# Code: a line added to the block.
m="$work/$repo/main.py"
printf '    print("done")\n' >> "$m"
refresh py-code
indexed scip-python py-code
same py-code
# The same tokens, out of the block: indentation is code in Python.
sed -i 's/^    print("done")$/print("done")/' "$m"
refresh py-indent
indexed scip-python py-indent
same py-indent

if [ "$failures" -gt 0 ]; then echo "$failures cosmetic check(s) failed"; exit 1; fi
echo "all cosmetic checks passed"
