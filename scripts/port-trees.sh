#!/usr/bin/env bash
# Stage 3's first comparison (docs/rust-port.md): the tree-sitter trees of
# the Goose program and of the Rust port, which builds the same C (rust/
# build.rs). Every file with a grammar under the fixtures and under each
# repo given is parsed by both dumpers (scripts/port-trees.goose and
# rust/src/bin/port-trees.rs) and the dumps compared by bytes.
#
#   scripts/port-trees.sh [repo...]
#
# GOOSE: the Goose compiler (as scripts/build.sh). PORT_TREES_RUST: the Rust
# dumper (default build/rust/release/port-trees).
# Prints, for each language, the files, the nodes and whether every dump
# was the same; then "the same: N of N files" or "DIFFERENT: K of N files".
# Exit 0: all the same. 1: some differ.
set -uo pipefail
cd "$(dirname "$0")/.."
GOOSE=${GOOSE:-.tools/goose/goose-v2026.3-linux-x64/goose}
export GOOSE_HOME=${GOOSE_HOME:-$PWD/.tools/goose-home}
new=${PORT_TREES_RUST:-build/rust/release/port-trees}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p build
"$GOOSE" build scripts/port-trees.goose -o build/port-trees-goose >"$work/build.log" 2>&1 ||
    { echo "port-trees: the Goose dumper does not build:"; tail -5 "$work/build.log"; exit 2; }
[ -x "$new" ] || { echo "port-trees: no Rust dumper at $new (cargo build --release --manifest-path rust/Cargo.toml)"; exit 2; }
old=build/port-trees-goose
# Files with a grammar, the walk's folders left out.
find fixtures "$@" \( -name node_modules -o -name target -o -name '.*' -o -name build -o -name __pycache__ \) -prune -o -type f \
    \( -name '*.ts' -o -name '*.mts' -o -name '*.cts' -o -name '*.tsx' -o -name '*.js' -o -name '*.jsx' -o -name '*.mjs' -o -name '*.cjs' \
    -o -name '*.py' -o -name '*.pyi' -o -name '*.rs' -o -name '*.java' -o -name '*.c' -o -name '*.h' -o -name '*.cc' -o -name '*.cpp' \
    -o -name '*.cxx' -o -name '*.hpp' -o -name '*.hh' -o -name '*.hxx' -o -name '*.cu' -o -name '*.cuh' -o -name '*.kt' -o -name '*.kts' \
    -o -name '*.lua' -o -name '*.glsl' -o -name '*.vert' -o -name '*.frag' -o -name '*.comp' -o -name '*.geom' -o -name '*.tesc' \
    -o -name '*.tese' -o -name '*.hlsl' -o -name '*.hlsli' -o -name '*.fx' -o -name '*.wgsl' -o -name '*.gd' -o -name '*.cs' -o -name '*.php' \) \
    -print0 >"$work/files"
total=0; bad=0
: >"$work/summary"
while IFS= read -r -d '' f; do
    total=$((total + 1))
    "$old" "$f" >"$work/a" 2>&1
    "$new" "$f" >"$work/b" 2>&1
    head=$(head -1 "$work/b")
    lang=$(printf '%s' "$head" | awk -F'\t' '{print $2}')
    n=$(printf '%s' "$head" | awk -F'\t' '{print $3}')
    if cmp -s "$work/a" "$work/b"; then printf '%s\t%s\tsame\n' "$lang" "${n:-0}" >>"$work/summary"
    else
        bad=$((bad + 1)); printf '%s\t%s\tdifferent\n' "$lang" "${n:-0}" >>"$work/summary"
        [ $bad -le 5 ] && { echo "DIFFERENT: $f"; diff <(head -c 2000 "$work/a") <(head -c 2000 "$work/b") | head -8; }
    fi
done <"$work/files"
awk -F'\t' '{f[$1]++; n[$1]+=$2; if ($3=="different") d[$1]++} END {for (l in f) printf "%-11s %6d files %10d nodes  %s\n", l, f[l], n[l], (d[l] ? d[l] " DIFFERENT" : "the same")}' "$work/summary" | sort
if [ $bad = 0 ]; then echo "the same: $total of $total files"; exit 0; fi
echo "DIFFERENT: $bad of $total files"
exit 1
