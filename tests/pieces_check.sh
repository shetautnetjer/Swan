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

echo
if [ "$fail" -eq 0 ]; then echo "all piece checks passed"; else echo "$fail check(s) failed"; exit 1; fi
