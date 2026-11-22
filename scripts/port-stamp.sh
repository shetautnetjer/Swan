#!/usr/bin/env bash
# Stage 3's judge for the stamps (docs/rust-port.md): `swan stamp-bench
# <repo> <out-dir>` and `swan stamp-worker <repo> <list> <out.tsv>
# <texts-dir>` say the same, exit the same and leave the same files from the
# Goose program and the Rust port: the stamp lines, the texts kept beside
# them, and nothing else. It writes a made-up repo that holds each kind of
# comment that counts as code and each that does not, files that do not
# parse, links, names that are not UTF-8 and enough files to start workers,
# and runs the two commands on it with one process, with worker processes
# and with threads, on each fixture, on this repository and on each repo
# given, through scripts/port-compare.sh.
#
#   scripts/port-stamp.sh [repo...]
#
# With threads the stamp lines come back in the order the workers finish,
# in both programs, so there they are compared sorted. The two programs may
# count the threads a machine allows differently, so threads are asked for
# by number (2 and 3).
#
# SWAN_OLD, SWAN_NEW: as for port-compare.sh.
# Prints one "DIFFERENT (<case>)" block for each disagreement, then "the
# same: N of N" or "DIFFERENT: K of N".
# Exit 0: all the same. 1: some differ. 2: a comparison could not be made
# (a program is missing). 3: a command is not carried yet.
set -uo pipefail
# A repo given by a path from where this was started is found from there.
given=(); for a in "$@"; do given+=("$(realpath -- "$a" 2>/dev/null || printf '%s' "$a")"); done
set -- "${given[@]+"${given[@]}"}"
cd "$(dirname "$0")/.."
here=$PWD
export LC_ALL=C

work=$(mktemp -d)
trap 'chmod -R u+rwx "$work" 2>/dev/null; rm -rf "$work"' EXIT
r="$work/repo"

# put <file>: standard input into the file, byte for byte.
put() { mkdir -p "$(dirname "$1")"; cat >"$1"; }

# ---- comments that count as code, each in a file of its own ----
printf '/** doc */\nexport const a = 1;\n' | put "$r/src/doc.ts"
printf '/**/\nexport const b = 2;\n' | put "$r/src/empty_doc.ts"
printf '/// triple\nexport const c = 3;\n' | put "$r/src/triple.ts"
printf '//! bang\nexport const d = 4;\n' | put "$r/src/bang.ts"
printf '/*! starbang */\nexport const e = 5;\n' | put "$r/src/starbang.ts"
printf '/* @jsx h */\nexport const f = <div/>;\n' | put "$r/src/jsx.tsx"
printf '// @ts-ignore\nexport const g: number = "x";\n' | put "$r/src/tsignore.ts"
printf '// @flow\nexport const h = 8;\n' | put "$r/src/flow.js"
printf 'x = []  # type: list\n' | put "$r/py/typed.py"
printf 'y = 1  #type: int\n' | put "$r/py/typed2.py"
printf '# pyright: strict\nz = 1\n' | put "$r/py/pyright.py"
printf '# mypy: ignore-errors\nw = 1\n' | put "$r/py/mypy.py"
# ---- comments that do not ----
printf '// plain\nexport const i = 9; /* also plain */\n' | put "$r/src/plain.ts"
printf '# plain\nv = 1  # more\n' | put "$r/py/plain.py"
# ---- the same code, other comments and layout: one stamp, other bytes ----
put "$r/src/a.ts" <<'EOF'
/** Adds. */
export function add(a: number, b: number): number {
  // a plain comment
  return a + b;
}
EOF
put "$r/src/a_cosmetic.ts" <<'EOF'
/** Adds. */
export function add(a: number,
    b: number): number {
  /* another comment */
  return a + b;
}
EOF
# Another doc comment, and another name: other stamps.
put "$r/src/a_doc.ts" <<'EOF'
/** Adds two numbers. */
export function add(a: number, b: number): number {
  return a + b;
}
EOF
put "$r/src/a_name.ts" <<'EOF'
/** Adds. */
export function sum(a: number, b: number): number {
  return a + b;
}
EOF
# Python: a docstring is code, and so is where a line is indented.
printf 'def f(x):\n    """Doc."""\n    if x:\n        y = 1\n    return x\n' | put "$r/py/indent.py"
printf 'def f(x):\n    """Doc."""\n    if x:\n        y = 1\n        return x\n' | put "$r/py/indent_in.py"
printf 'def f(x):\n    """Other doc."""\n    if x:\n        y = 1\n    return x\n' | put "$r/py/docstring.py"
# ---- files that do not parse: stamped by their bytes ----
printf 'export function ( {\n' | put "$r/src/error.ts"
printf 'def f(:\n    pass\n' | put "$r/py/error.py"
printf 'const x = ;\n// a comment\n' | put "$r/src/error.js"
# ---- every ending that is stamped by its code ----
printf 'export const m = 1;\n' | put "$r/ends/a.mts"
printf 'export const n = 1;\n' | put "$r/ends/a.cts"
printf 'export const o = 1;\n' | put "$r/ends/a.mjs"
printf 'module.exports = 1;\n' | put "$r/ends/a.cjs"
printf 'export const p = <b>x</b>;\n' | put "$r/ends/a.jsx"
printf 'def q(x: int) -> int: ...\n' | put "$r/ends/a.pyi"
# ---- files in other languages are not stamped here ----
printf 'fn main() {}\n' | put "$r/other/lib.rs"
printf 'package main\n' | put "$r/other/main.go"
printf 'int main(void) { return 0; }\n' | put "$r/other/x.c"
printf '# notes\n' | put "$r/other/notes.md"
printf 'local x = 1\n' | put "$r/other/script.lua"
# ---- empty files, carriage returns, bytes that are not UTF-8 ----
: | put "$r/odd/empty.ts"; : | put "$r/odd/empty.py"
printf 'const a = 1;\r\n// c\r\n' | put "$r/odd/crlf.js"
printf '# \xff\xfe\nx = "\xff"\n' | put "$r/odd/raw.py"
printf 'x = 1\n' | put "$r/odd/$(printf 'x\xff').py"
printf 'export const s = 1;\n' | put "$r/we ird/naïve/a b.ts"
# ---- folders a walk leaves out ----
for d in node_modules/pkg .hidden target build venv __pycache__; do printf 'export const left = 1;\n' | put "$r/$d/index.ts"; done
# A folder named like a file; links to a file, to a folder and to nothing.
printf 'x = 2\n' | put "$r/dir.ts/inner.py"
ln -s src/doc.ts "$r/link.ts"
ln -s nowhere "$r/dangling.ts"
ln -s src "$r/linkdir"
# A file that cannot be read (unless this runs as root).
printf 'export const secret = 1;\n' | put "$r/perm/secret.ts"; chmod 000 "$r/perm/secret.ts"
# ---- enough files to start workers by the usual floor of 256 ----
mkdir -p "$r/many"
for i in $(seq 1 300); do printf 'def f%s(x):\n    return x + %s\n' "$i" "$i" >"$r/many/m$i.py"; done
# A repo under that floor, and one with nothing to stamp.
mkdir -p "$work/mid" "$work/none"
for i in $(seq 1 200); do printf 'x = %s\n' "$i" >"$work/mid/m$i.py"; done
printf 'fn main() {}\n' >"$work/none/main.rs"
printf 'not a folder\n' >"$work/a-file"

# ---- running both programs ----
each="$work/each"
mkdir -p "$each/old" "$each/new"
for side in old new; do
    cp -a "$r" "$each/$side/rel" 2>/dev/null
    mkdir -p "$each/$side/lists" "$each/$side/locked"
    {
        printf 'src/doc.ts\nsrc/error.ts\nsrc/a.ts\nsrc/a_cosmetic.ts\nother/lib.rs\nmissing.ts\n\nsrc\ndir.ts\n'
        printf 'we ird/naïve/a b.ts\nodd/x\xff.py\nmany/m1.py\nmany/m2.py\nlink.ts\ndangling.ts\nperm/secret.ts\nodd/empty.py\n\n'
    } >"$each/$side/lists/all.txt"
    : >"$each/$side/lists/empty.txt"
    printf 'src/doc.ts' >"$each/$side/lists/no-line-end.txt"
    chmod 555 "$each/$side/locked"
done

total=0; bad=0
# said <code> <case>: counts a case, and prints it when the two differ.
said() {
    if [ "$1" = 3 ]; then echo "port-stamp: the command is not carried over yet"; exit 3; fi
    if [ "$1" = 2 ]; then echo "port-stamp: no comparison could be made ($2):"; sed 's/^/    /' "$work/report"; exit 2; fi
    if [ "$1" != 0 ]; then bad=$((bad + 1)); echo "DIFFERENT ($2)"; sed 's/^/    /' "$work/report"; fi
}
# same_files <folder> <exact|sorted> <lines file>: the folder of each program
# holds the same names, the same lines file and the same kept texts.
same_files() {
    local o="$each/old/$1" n="$each/new/$1"
    if ! diff <(cd "$o" 2>/dev/null && ls -A) <(cd "$n" 2>/dev/null && ls -A) >"$work/names" 2>&1; then
        { echo "the two folders hold other files (Goose < > Rust):"; head -10 "$work/names"; } >"$work/report"; return 1
    fi
    if [ -e "$o/$3" ] || [ -e "$n/$3" ]; then
        if [ "$2" = sorted ]; then diff <(sort "$o/$3") <(sort "$n/$3") >"$work/lines" 2>&1; else diff "$o/$3" "$n/$3" >"$work/lines" 2>&1; fi
        if [ $? != 0 ]; then { echo "$3 differs (Goose < > Rust):"; head -10 "$work/lines" | cut -c1-300; } >"$work/report"; return 1; fi
    fi
    if [ -d "$o/texts" ] || [ -d "$n/texts" ]; then
        if ! diff -r "$o/texts" "$n/texts" >"$work/texts" 2>&1; then
            { echo "the kept texts differ (Goose < > Rust):"; head -6 "$work/texts" | cut -c1-200; } >"$work/report"; return 1
        fi
    fi
    return 0
}
# bench <case> <exact|sorted> <repo> <out> [NAME=value...]: stamp-bench with
# those settings and no others; out is a folder of each program's own.
bench() {
    local label=$1 how=$2 repo=$3 out=$4; shift 4
    [ -n "${KEEP:-}" ] || { chmod -R u+rwx "$each/old/$out" "$each/new/$out" 2>/dev/null; rm -rf "$each/old/$out" "$each/new/$out"; }
    total=$((total + 1))
    env -u SWAN_STAMP_JOBS -u SWAN_STAMP_MIN -u SWAN_STAMP_MODE "$@" PORT_EACH_IN="$each" scripts/port-compare.sh stamp-bench "$repo" "$out" >"$work/report" 2>&1
    local code=$?
    if [ $code = 0 ]; then same_files "$out" "$how" stamps.tsv || code=1; fi
    said $code "$label"
}
# worker <case> <repo> <list> <out folder>: stamp-worker, its lines written to
# <out folder>/lines.tsv beside the texts it keeps.
worker() {
    local label=$1 repo=$2 list=$3 out=$4
    rm -rf "$each/old/$out" "$each/new/$out"
    [ -n "${NO_FOLDER:-}" ] || mkdir -p "$each/old/$out/texts" "$each/new/$out/texts"
    total=$((total + 1))
    PORT_EACH_IN="$each" scripts/port-compare.sh stamp-worker "$repo" "$list" "$out/lines.tsv" "$out/texts" >"$work/report" 2>&1
    local code=$?
    if [ $code = 0 ]; then same_files "$out" exact lines.tsv || code=1; fi
    said $code "$label"
}

bench "made-up, one process" exact "$r" o SWAN_STAMP_JOBS=1
bench "made-up, 3 workers" exact "$r" o SWAN_STAMP_JOBS=3 SWAN_STAMP_MIN=1
bench "made-up, 4 workers by the usual floor" exact "$r" o SWAN_STAMP_JOBS=4
bench "made-up, 64 workers" exact "$r" o SWAN_STAMP_JOBS=64 SWAN_STAMP_MIN=1
bench "made-up, 7 asked for and a floor of 100" exact "$r" o SWAN_STAMP_JOBS=7 SWAN_STAMP_MIN=100
bench "made-up, 7 asked for and a floor of 10" exact "$r" o SWAN_STAMP_JOBS=7 SWAN_STAMP_MIN=10
bench "made-up, a floor above its files" exact "$r" o SWAN_STAMP_JOBS=2 SWAN_STAMP_MIN=100000
bench "made-up, every core" exact "$r" o SWAN_STAMP_MIN=1
bench "made-up, every core by the usual floor" exact "$r" o
for v in 0 -3 x ""; do bench "made-up, SWAN_STAMP_JOBS='$v'" exact "$r" o "SWAN_STAMP_JOBS=$v" SWAN_STAMP_MIN=1; done
for v in 0 -3 x ""; do bench "made-up, 7 asked for and SWAN_STAMP_MIN='$v'" exact "$r" o SWAN_STAMP_JOBS=7 "SWAN_STAMP_MIN=$v"; done
bench "made-up, 2 threads" sorted "$r" o SWAN_STAMP_JOBS=2 SWAN_STAMP_MIN=1 SWAN_STAMP_MODE=threads
bench "made-up, 3 threads" sorted "$r" o SWAN_STAMP_JOBS=3 SWAN_STAMP_MIN=1 SWAN_STAMP_MODE=threads
bench "made-up, threads and a floor above its files" exact "$r" o SWAN_STAMP_JOBS=3 SWAN_STAMP_MIN=100000 SWAN_STAMP_MODE=threads
bench "made-up, a mode that is not threads" exact "$r" o SWAN_STAMP_JOBS=3 SWAN_STAMP_MIN=1 SWAN_STAMP_MODE=thread
KEEP=yes bench "made-up, into a folder that holds a run already" exact "$r" o SWAN_STAMP_JOBS=1
bench "made-up, by a path from the program's folder" exact rel o SWAN_STAMP_JOBS=1
bench "made-up, slashes after the repo" exact "$r///" o SWAN_STAMP_JOBS=3 SWAN_STAMP_MIN=1
bench "one folder of the made-up repo" exact "$r/src" o SWAN_STAMP_JOBS=2 SWAN_STAMP_MIN=1
bench "200 files, under the usual floor" exact "$work/mid" o SWAN_STAMP_JOBS=4
bench "200 files, one process" exact "$work/mid" o SWAN_STAMP_JOBS=1
bench "nothing to stamp, one process" exact "$work/none" o SWAN_STAMP_JOBS=1
bench "nothing to stamp, workers" exact "$work/none" o SWAN_STAMP_JOBS=4 SWAN_STAMP_MIN=1
bench "a repo that is not there" exact "$work/not-there" o SWAN_STAMP_JOBS=1
bench "a repo that is a file" exact "$work/a-file" o SWAN_STAMP_JOBS=1
bench "an out folder two folders deep" exact "$r" deep/er/o SWAN_STAMP_JOBS=1
KEEP=yes bench "an out folder that cannot be written" exact "$r/src" locked SWAN_STAMP_JOBS=1
KEEP=yes bench "an out folder that cannot be written, workers" exact "$r/src" locked SWAN_STAMP_JOBS=2 SWAN_STAMP_MIN=1

worker "a list of the made-up repo's files" "$r" lists/all.txt w
worker "an empty list" "$r" lists/empty.txt w
worker "a list with no line end" "$r" lists/no-line-end.txt w
worker "a list that is not there" "$r" lists/none.txt w
worker "a list, of a repo that is not there" "$work/not-there" lists/all.txt w
NO_FOLDER=yes worker "a list, and no folder for the lines" "$r" lists/all.txt nowhere

for repo in "$here"/fixtures/*/ "$here" "$@"; do
    repo=$(realpath "$repo")
    bench "${repo#"$here"/}, one process" exact "$repo" o SWAN_STAMP_JOBS=1
    bench "${repo#"$here"/}, 4 workers" exact "$repo" o SWAN_STAMP_JOBS=4 SWAN_STAMP_MIN=1
done

if [ $bad = 0 ]; then echo "the same: $total of $total"; exit 0; fi
echo "DIFFERENT: $bad of $total"
exit 1
