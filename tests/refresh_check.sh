#!/usr/bin/env bash
# Edits a copy of the fixture, reruns SCIP, and checks that `swan refresh` of
# the old map gives exactly what a fresh `swan index` of the new rows gives.
set -euo pipefail
cd "$(dirname "$0")/.."
work=data/refresh-check
rm -rf "$work" && mkdir -p "$work"
cp -r fixtures/tiny-ts "$work/repo"
scripts/index-repo.sh "$work/repo" "$work/before" >/dev/null 2>&1
cp "$work/before/swan.db" "$work/refreshed.db"
# The edit: a line added at the top of store.ts (every row in it moves), a
# new caller of Store.total, format.ts deleted, and Crate no longer
# implementing Weighed.
{ echo "// edited"; cat "$work/repo/src/store.ts"; echo 'export const heaviest = (s: Store) => s.total();'; } > "$work/repo/src/store.ts.new"
mv "$work/repo/src/store.ts.new" "$work/repo/src/store.ts"
rm "$work/repo/src/format.ts"
sed -i 's/^export class Crate implements Weighed {$/export class Crate {/' "$work/repo/src/kinds.ts"
sed -i 's|^export { format as formatItem } from "./format";$|export const formatItem = (x: unknown) => String(x);|' "$work/repo/src/index.ts"
sed -i 's|^import { total } from "./format";$|const total = (xs: Item[]) => xs.length;|' "$work/repo/src/main.ts"
mkdir -p "$work/after"
(cd "$work/repo" && ../../../tools/node_modules/.bin/scip-typescript index --output ../after/index.scip >/dev/null)
bun tools/scip-flatten.ts "$work/after/index.scip" "$work/after" 2>/dev/null
bin/swan refresh "$work/after" "$work/refreshed.db"
bin/swan index "$work/after" "$work/fresh.db" "$PWD/$work/repo" >/dev/null
python3 tests/dump.py "$work/refreshed.db" | grep -v '^F' > "$work/refreshed.txt"
python3 tests/dump.py "$work/fresh.db" | grep -v '^F' > "$work/fresh.txt"
if diff -u "$work/fresh.txt" "$work/refreshed.txt" > "$work/diff.txt"; then
  echo "ok   refresh matches a fresh build ($(wc -l < "$work/fresh.txt") rows)"
else
  echo "FAIL refresh differs from a fresh build:"; head -40 "$work/diff.txt"; exit 1
fi
grep -q $'heaviest\t' "$work/refreshed.txt" && echo "ok   the new symbol is in the refreshed map" || { echo "FAIL new symbol missing"; exit 1; }
! grep -q 'format.ts' "$work/refreshed.txt" && echo "ok   the deleted file is gone" || { echo "FAIL deleted file still mapped"; exit 1; }
! grep -q $'^R\t[^\t]*Crate#\t' "$work/refreshed.txt" && grep -q $'^R\t[^\t]*Box#\t' "$work/refreshed.txt" && echo "ok   Crate's dropped implements is gone, Box's remains" || { echo "FAIL relationships not refreshed"; exit 1; }
