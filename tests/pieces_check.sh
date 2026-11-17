#!/usr/bin/env bash
# Checks how a Python repo is split into scip-python pieces (plan_python).
# Every piece is a whole-program scip-python run, so a folder of many loose
# files must stay one piece, never one run per file.
set -uo pipefail
cd "$(dirname "$0")/.."
SWAN=bin/swan
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
pass=0; fail=0
ok() { echo "ok   $1"; pass=$((pass+1)); }
bad() { echo "FAIL $1"; echo "     $2"; fail=$((fail+1)); }

# pkg/ holds 12 small modules; tests/ is a flat folder of 40 test files,
# bigger than one piece's share; one script sits at the root.
mkdir -p "$work/r/pkg" "$work/r/tests"
for i in $(seq 1 12); do printf 'def f%s():\n    return %s\n' "$i" "$i" > "$work/r/pkg/m$i.py"; done
for i in $(seq 1 40); do printf 'from pkg.m1 import f1\n\ndef test_%s():\n    assert f1() == 1\n' "$i" > "$work/r/tests/test_$i.py"; done
echo 'print("hi")' > "$work/r/setup.py"

plan=$("$SWAN" plan-python "$work/r" 4)
if echo "$plan" | grep -qx 'tests'; then ok "a flat folder of 40 files is one piece"; else bad "a flat folder of 40 files is one piece" "$plan"; fi
if echo "$plan" | grep -q '^tests/test_'; then bad "no piece is a single test file" "$plan"; else ok "no piece is a single test file"; fi
n=$(echo "$plan" | grep -c .)
if [ "$n" -le 8 ]; then ok "at most 8 pieces for k=4 ($n)"; else bad "at most 8 pieces for k=4" "$n: $plan"; fi

# A repo whose root itself holds many loose files is indexed in one run.
mkdir -p "$work/flat"
for i in $(seq 1 30); do printf 'x = %s\n' "$i" > "$work/flat/f$i.py"; done
plan=$("$SWAN" plan-python "$work/flat" 4)
if [ -z "$(echo "$plan" | tr -d '\n')" ]; then ok "many loose files at the root: one run for the whole repo"; else bad "many loose files at the root: one run for the whole repo" "$plan"; fi

# A small repo is not split at all.
mkdir -p "$work/small"; echo 'x = 1' > "$work/small/a.py"
plan=$("$SWAN" plan-python "$work/small" 4)
if [ -z "$(echo "$plan" | tr -d '\n')" ]; then ok "a small repo is one run"; else bad "a small repo is one run" "$plan"; fi

# A flat folder of scripts that import nothing of the repo's own is split by
# filename prefix ("dir/ab*": every path starting with dir/ab), so its files
# index on every core and an edit reindexes a few dozen files, not the lot.
# Beside it: a subfolder, and a sibling folder whose name starts the same.
mkdir -p "$work/alone/cases/sub" "$work/alone/cases_extra" "$work/alone/lib"
for p in args class dict float int list math set str tuple; do
  for i in $(seq 1 20); do printf 'import math\nimport json\n\nx = math.floor(%s.5)\nassert json.dumps(x)\n' "$i" > "$work/alone/cases/${p}__case_$i.py"; done
done
for i in 1 2 3; do printf 'y = %s\n' "$i" > "$work/alone/cases/sub/s$i.py"; printf 'z = %s\n' "$i" > "$work/alone/cases_extra/e$i.py"; done
for i in $(seq 1 30); do printf 'def lib%s():\n    return %s\n' "$i" "$i" > "$work/alone/lib/l$i.py"; done
plan=$("$SWAN" plan-python "$work/alone" 4)
n=$(echo "$plan" | grep -c '^cases/.*\*$')
if [ "$n" -ge 4 ]; then ok "200 standalone scripts in one folder are split into prefix pieces ($n)"; else bad "200 standalone scripts in one folder are split into prefix pieces" "$plan"; fi
# Every .py file is in exactly one piece, by what scip-python will be told:
# a starred piece keeps paths that start with it, another piece is a file
# or a folder.
wrong=""
while IFS= read -r f; do
  hits=0
  while IFS= read -r piece; do
    [ -n "$piece" ] || continue
    case "$piece" in
      *\*) pre=${piece%\*}; case "$f" in "$pre"*) hits=$((hits+1));; esac ;;
      *) case "$f" in "$piece"|"$piece"/*) hits=$((hits+1));; esac ;;
    esac
  done <<< "$plan"
  [ "$hits" -eq 1 ] || wrong="$wrong $f($hits)"
done < <(cd "$work/alone" && find . -name '*.py' | sed 's#^\./##' | sort)
if [ -z "$wrong" ]; then ok "every file is in exactly one piece (the subfolder and the same-prefix sibling included)"; else bad "every file is in exactly one piece" "$wrong"; fi
big=$(echo "$plan" | grep '^cases/.*\*$' | while IFS= read -r piece; do pre=${piece%\*}; (cd "$work/alone" && find . -name '*.py' | sed 's#^\./##' | grep -c "^$pre"); done | sort -n | tail -1)
if [ "$big" -le 64 ]; then ok "no prefix piece holds more than 64 files ($big)"; else bad "no prefix piece holds more than 64 files" "$big"; fi

# The same folder, but the scripts import the repo's own package: every run
# would load that package again, so the folder stays one piece.
for f in "$work"/alone/cases/*.py; do printf 'from lib.l1 import lib1\n' >> "$f"; done
plan=$("$SWAN" plan-python "$work/alone" 4)
if echo "$plan" | grep -qx 'cases' && ! echo "$plan" | grep -q '\*$'; then ok "scripts that import the repo's own package stay one piece"; else bad "scripts that import the repo's own package stay one piece" "$plan"; fi

echo
if [ "$fail" -eq 0 ]; then echo "all piece checks passed"; else echo "$fail check(s) failed"; exit 1; fi
