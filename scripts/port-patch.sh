#!/usr/bin/env bash
# Stage 4's judge for the indexer patches (docs/rust-port.md): `swan
# scip-python-patch <file> [--revert]` and `swan scip-typescript-patch <file>
# [--revert]` say the same, exit the same and leave the same file, with the
# same permissions and nothing beside it, from the Goose program and the
# Rust port. It takes the three files Swan patches from tools/node_modules
# (scip-python's pyright-internal.js and scip-python.js, scip-typescript's
# FileIndexer.js), makes each with and without its patch using the Goose
# program, and makes files a patch must refuse from them: every site twice,
# one site twice, half a file, an empty one, one that only holds the
# patch's mark. Each is patched and reverted by both programs, through
# scripts/port-compare.sh, under the name of its own file and of the others.
#
#   scripts/port-patch.sh
#
# SWAN_OLD, SWAN_NEW: as for port-compare.sh.
# Prints one "DIFFERENT (<case>)" block for each disagreement, then "the
# same: N of N" or "DIFFERENT: K of N".
# Exit 0: all the same. 1: some differ. 2: a comparison could not be made
# (a program or an indexer's file is missing). 3: a command is not carried
# yet.
set -uo pipefail
cd "$(dirname "$0")/.."
export LC_ALL=C
old=${SWAN_OLD:-bin/swan}
[ -x "$old" ] || { echo "port-patch: no Goose program at $old"; exit 2; }
old=$(realpath "$old")

work=$(mktemp -d)
trap 'chmod -R u+rwx "$work" 2>/dev/null; rm -rf "$work"' EXIT
in="$work/in"
mkdir -p "$in"

# ---- the files, with and without their patch, as the Goose program makes them ----
# make <kind> <command> <file in tools/node_modules> <name the command knows it by>
make() {
    local kind=$1 cmd=$2 src="tools/node_modules/@sourcegraph/$3" name=$4
    [ -f "$src" ] || { echo "port-patch: no $src (scripts/fetch-tools.sh)"; exit 2; }
    mkdir -p "$in/$kind"
    cp "$src" "$in/$kind/$name"
    "$old" "$cmd" "$in/$kind/$name" --revert >/dev/null 2>&1
    cp "$in/$kind/$name" "$in/$kind.plain"
    "$old" "$cmd" "$in/$kind/$name" >/dev/null 2>&1
    cp "$in/$kind/$name" "$in/$kind.patched"
    cmp -s "$in/$kind.plain" "$in/$kind.patched" && { echo "port-patch: the Goose program does not patch $src"; exit 2; }
    cat "$in/$kind.plain" "$in/$kind.plain" >"$in/$kind.twice"
    cat "$in/$kind.patched" "$in/$kind.patched" >"$in/$kind.patched-twice"
    head -c $(($(stat -c %s "$in/$kind.plain") / 2)) "$in/$kind.plain" >"$in/$kind.half"
    head -c $(($(stat -c %s "$in/$kind.patched") / 2)) "$in/$kind.patched" >"$in/$kind.patched-half"
    : >"$in/$kind.empty"
}
make reach scip-python-patch scip-python/dist/pyright-internal.js pyright-internal.js
make site scip-python-patch scip-python/dist/scip-python.js scip-python.js
make ts scip-typescript-patch scip-typescript/dist/src/FileIndexer.js FileIndexer.js
# A file that only holds a patch's mark, after the text without the patch.
{ cat "$in/reach.plain"; printf '\n// __swanReach\n'; } >"$in/reach.marked"
{ cat "$in/site.plain"; printf '\n// __swanSite\n'; } >"$in/site.marked"
{ cat "$in/ts.plain"; printf '\n// function swanOrdinal(\n'; } >"$in/ts.marked"
# One site twice, the others once: a line of the text that is one of the
# patch's sites, said again at the end.
one_twice() {   # one_twice <kind> <text only that site's line holds>
    local line
    line=$(grep -F -m1 -- "$2" "$in/$1.plain") || { echo "port-patch: $1 has no line with '$2'"; exit 2; }
    { cat "$in/$1.plain"; printf '%s\n' "$line"; } >"$in/$1.one-twice"
}
one_twice ts 'const ts_inline = __importStar(require("./TypeScriptInternal"));'
# The two bundles are one long line each: the site itself, as the patched
# file no longer holds it, is the text between two anchors.
printf '%s' 'a.defaultPythonPlatform=t.pythonPlatform,a.defaultPythonVersion=t.pythonVersion,' >"$work/one-site"
grep -qF -f "$work/one-site" "$in/site.plain" || { echo "port-patch: scip-python.js has no default Python version site"; exit 2; }
cat "$in/site.plain" "$work/one-site" >"$in/site.one-twice"
printf '%s' 'return m.set(n.id,a),a}finally{f--}}function b(e,t){' >"$work/one-site"
grep -qF -f "$work/one-site" "$in/reach.plain" || { echo "port-patch: pyright-internal.js has no isCallNoReturn site"; exit 2; }
cat "$in/reach.plain" "$work/one-site" >"$in/reach.one-twice"

# ---- running both programs ----
each="$work/each"
mkdir -p "$each/old" "$each/new"
total=0; bad=0
# same_folder: f/ of each program holds the same files, bytes and permissions.
same_folder() {
    if ! diff -r "$each/old/f" "$each/new/f" >"$work/d" 2>&1; then
        { echo "the two folders differ (Goose < > Rust):"; head -6 "$work/d" | cut -c1-200; } >"$work/report"; return 1
    fi
    if ! diff <(cd "$each/old/f" && find . | sort | xargs -d '\n' stat -c '%a %F %n') <(cd "$each/new/f" && find . | sort | xargs -d '\n' stat -c '%a %F %n') >"$work/d" 2>&1; then
        { echo "permissions or kinds differ (Goose < > Rust):"; head -6 "$work/d"; } >"$work/report"; return 1
    fi
    return 0
}
# run <case> <command> <path under f/> [--revert]: both programs, on the
# folder f/ as it is now.
run() {
    local label=$1 cmd=$2 path=$3; shift 3
    total=$((total + 1))
    PORT_EACH_IN="$each" scripts/port-compare.sh "$cmd" "f/$path" "$@" >"$work/report" 2>&1
    local code=$?
    if [ $code = 3 ]; then echo "port-patch: $cmd is not carried over yet"; exit 3; fi
    if [ $code = 2 ]; then echo "port-patch: no comparison could be made ($label):"; sed 's/^/    /' "$work/report"; exit 2; fi
    if [ $code = 0 ]; then same_folder || code=1; fi
    if [ $code != 0 ]; then bad=$((bad + 1)); echo "DIFFERENT ($label)"; sed 's/^/    /' "$work/report"; fi
}
# fresh [<input> <name>]: an empty f/ for each program, with a copy of the
# input under that name.
fresh() {
    local side
    for side in old new; do
        chmod -R u+rwx "$each/$side/f" 2>/dev/null; rm -rf "$each/$side/f"; mkdir -p "$each/$side/f"
        [ $# = 2 ] && cp "$1" "$each/$side/f/$2"
    done
    return 0
}
both() { local side; for side in old new; do (cd "$each/$side/f" && "$@"); done; }

for spec in reach:scip-python-patch:pyright-internal.js site:scip-python-patch:scip-python.js ts:scip-typescript-patch:FileIndexer.js; do
    kind=${spec%%:*}; rest=${spec#*:}; cmd=${rest%%:*}; name=${rest#*:}
    for variant in plain patched twice one-twice half empty marked patched-twice patched-half; do
        fresh "$in/$kind.$variant" "$name"; run "$name, $variant: patch" "$cmd" "$name"
        fresh "$in/$kind.$variant" "$name"; run "$name, $variant: revert" "$cmd" "$name" --revert
    done
    fresh; run "$name, not there: patch" "$cmd" "$name"
    fresh; run "$name, not there: revert" "$cmd" "$name" --revert
    fresh; both mkdir "$name"; run "$name, a folder: patch" "$cmd" "$name"
    # One folder through the four steps, each on what the one before left.
    fresh "$in/$kind.plain" "$name"
    run "$name, in turn: patch" "$cmd" "$name"
    run "$name, in turn: patch again" "$cmd" "$name"
    run "$name, in turn: revert" "$cmd" "$name" --revert
    run "$name, in turn: revert again" "$cmd" "$name" --revert
    run "$name, in turn: patch once more" "$cmd" "$name"
    # Permissions: the file's own, and a folder nothing can be made in.
    fresh "$in/$kind.plain" "$name"; both chmod 755 "$name"; run "$name, a file anyone may run: patch" "$cmd" "$name"
    fresh "$in/$kind.plain" "$name"; both chmod 444 "$name"; run "$name, a file not to be written: patch" "$cmd" "$name"
    fresh "$in/$kind.plain" "$name"; both chmod 555 .; run "$name, in a folder not to be written: patch" "$cmd" "$name"
    fresh "$in/$kind.patched" "$name"; both chmod 555 .; run "$name, in a folder not to be written: revert" "$cmd" "$name" --revert
    # By a link, and under a name with a space in a folder of its own.
    fresh "$in/$kind.plain" "real-$name"; both ln -s "real-$name" "$name"; run "$name, by a link: patch" "$cmd" "$name"
    fresh; both mkdir "a b"; both cp "$in/$kind.plain" "a b/$name"; run "$name, under a name with a space: patch" "$cmd" "a b/$name"
done
# Which patch a name asks for: scip-python-patch reads the name's end.
fresh "$in/site.plain" other.js; run "scip-python.js's text under another name: patch" scip-python-patch other.js
fresh "$in/site.patched" other.js; run "scip-python.js's text under another name: revert" scip-python-patch other.js --revert
fresh "$in/site.plain" xscip-python.js; run "scip-python.js's text, a name that ends the same: patch" scip-python-patch xscip-python.js
fresh "$in/site.patched" xscip-python.js; run "scip-python.js's text, a name that ends the same: revert" scip-python-patch xscip-python.js --revert
fresh "$in/reach.plain" scip-python.js; run "pyright-internal.js's text named scip-python.js: patch" scip-python-patch scip-python.js
fresh "$in/reach.patched" scip-python.js; run "pyright-internal.js's text named scip-python.js: revert" scip-python-patch scip-python.js --revert
fresh "$in/reach.plain" FileIndexer.js; run "pyright-internal.js's text: the TypeScript patch" scip-typescript-patch FileIndexer.js
fresh "$in/ts.plain" pyright-internal.js; run "FileIndexer.js's text: the Python patch" scip-python-patch pyright-internal.js
fresh "$in/ts.plain" scip-python.js; run "FileIndexer.js's text named scip-python.js: the Python patch" scip-python-patch scip-python.js

if [ $bad = 0 ]; then echo "the same: $total of $total"; exit 0; fi
echo "DIFFERENT: $bad of $total"
exit 1
