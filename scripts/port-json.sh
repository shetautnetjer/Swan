#!/usr/bin/env bash
# Stage 4's comparison for reading JSON (docs/rust-port.md): Goose's
# json::parse and the Rust program's reader (rust/src/json.rs) take and
# refuse the same texts and read the same values from them. Each text
# below, every .json file of the fixtures and of tools/ (node_modules left
# out), and every .json file under each folder given, is read by both
# dumpers (scripts/port-json.goose and rust/src/bin/port-json.rs) and the
# dumps compared by bytes.
#
#   scripts/port-json.sh [folder...]
#
# GOOSE: the Goose compiler (as scripts/build.sh). PORT_JSON_RUST: the Rust
# dumper (default build/rust/release/port-json).
# Prints "the same: N of N texts" or each text that differs and "DIFFERENT:
# K of N texts". Exit 0: all the same. 1: some differ. 2: a dumper is
# missing or does not build.
set -uo pipefail
# A repo given by a path from where this was started is found from there.
given=(); for a in "$@"; do given+=("$(realpath -- "$a" 2>/dev/null || printf '%s' "$a")"); done
set -- "${given[@]+"${given[@]}"}"
cd "$(dirname "$0")/.."
GOOSE=${GOOSE:-.tools/goose/goose-v2026.3-linux-x64/goose}
export GOOSE_HOME=${GOOSE_HOME:-$PWD/.tools/goose-home}
new=${PORT_JSON_RUST:-build/rust/release/port-json}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p build
# Built once and kept: several comparisons at once (the prover's) must not
# build it over each other.
if [ ! -x build/port-json-goose ] || [ scripts/port-json.goose -nt build/port-json-goose ]; then
    "$GOOSE" build scripts/port-json.goose -o build/port-json-goose >"$work/build.log" 2>&1 ||
        { echo "port-json: the Goose dumper does not build:"; tail -5 "$work/build.log"; exit 2; }
fi
[ -x "$new" ] || { echo "port-json: no Rust dumper at $new (cargo build --release --manifest-path rust/Cargo.toml)"; exit 2; }
old=build/port-json-goose

# ---- made-up texts, one a file: t<number> ----
n=0
t() { n=$((n + 1)); printf '%b' "$1" >"$work/t$(printf '%03d' $n)"; }
# Values of each kind, and white space around them.
t '{}'; t '[]'; t ' 1 '; t '\t\n\r 0 \t\n\r'; t '-0'; t '0'; t '7'; t '-12'; t 'true'; t 'false'; t 'null'; t '""'; t '"a"'
t '[1,2,[3,{"a":null}]]'; t '{"a":{"b":[]}}\n'; t '[[[[[[]]]]]]'; t '{"a":1,"b":[true,false,null],"c":{"d":"e"}}'
t '[ 1 , 2 ]'; t '{ "a" : 1 , "b" : 2 }'; t '[\n  1,\n  2\n]\n'
# The same key twice: the first is the one found.
t '{"a":1,"a":2}'; t '{"a":"first","b":0,"a":"second"}'; t '{"b":1}'; t '["a"]'; t '{"a":[1]}'; t '{"":0,"a":{}}'
# Numbers: which are integers, which numbers, which nothing.
t '1.5'; t '1e5'; t '1E+5'; t '1.5e-3'; t '0.0'; t '-0.0'; t '0e0'; t '10'; t '1.0'; t '100e-2'
t '9223372036854775807'; t '9223372036854775808'; t '-9223372036854775808'; t '-9223372036854775809'
t '9999999999999999999'; t '10000000000000000000'; t '12345678901234567890123'; t '1e400'; t '0.1e-400'
t '01'; t '00'; t '-01'; t '1.'; t '.5'; t '-'; t '+1'; t '1e'; t '1e+'; t '1e-'; t '1.e3'; t '-.5'; t '0x10'; t '1_000'; t 'NaN'; t 'Infinity'
t '[1.]'; t '[01]'; t '[-]'; t '{"a":1e}'; t '1 2'; t '1,'
# Strings: escapes, and what is not one.
t '"\\"\\\\\\/\\b\\f\\n\\r\\t"'; t '"\\u00e9"'; t '"\\u00E9\\u0041"'; t '"\\ud83d\\ude00"'; t '"\\ud800"'; t '"\\udc00"'; t '"\\ud83d\\u0041"'; t '"\\ud83dx"'
t '"\\u0000"'; t '"\\uFFFF"'; t '"\\ud83d\\ud83d\\ude00"'; t '"\\x"'; t '"\\u12"'; t '"\\u12g4"'; t '"\\"'; t '"a'; t '"a\\'; t '"\\u"'; t '"\\ud83d\\u12"'
t '"a\nb"'; t '"a\tb"'; t '"a\001b"'; t '"\037"'; t '" "'; t '"\177"'; t '"\303\251"'; t '"\377\376"'; t '{"\\u0061":1}'; t '{"a\\nb":1,"a":2}'
t "'a'"; t '"a" "b"'; t '{"a":"\\q"}'
# Words.
t 'tru'; t 'truee'; t 'True'; t 'nul'; t 'nulll'; t 'fals'; t '[true,]'; t '[nul]'; t 'undefined'
t 'trux'; t 'nulx'; t 'falsx'; t '[trux]'; t '{"ab":1,"a":2}'; t '{"ab":1}'
# Brackets and commas.
t ''; t ' '; t '{'; t '['; t '}'; t ']'; t '[1,]'; t '[,1]'; t '[1,,2]'; t '{"a"}'; t '{"a":}'; t '{a:1}'; t '{"a":1,}'; t '{,}'; t '{"a" 1}'
t '[1 2]'; t '[1]]'; t '{"a":1}}'; t '[1}'; t '{"a":1]'; t '[{]}'; t '{"a":[}'; t '[1'; t '{"a":1'; t '{"a":[1,2'; t '[[]'; t '{"a":{}'
t '// a comment\n{}'; t '{} // after'; t '/* */ []'; t '[1] x'; t '{"a":1}\n\n'; t '\357\273\277{}'
# A long one, and a deep one.
{ printf '['; for i in $(seq 1 2000); do printf '{"id":%s,"name":"item %s","on":%s},' "$i" "$i" "$([ $((i % 2)) = 0 ] && echo true || echo false)"; done; printf 'null]'; } >"$work/t900"
{ for i in $(seq 1 300); do printf '['; done; printf '"deep"'; for i in $(seq 1 300); do printf ']'; done; } >"$work/t901"
{ for i in $(seq 1 300); do printf '{"a":'; done; printf '1'; for i in $(seq 1 299); do printf '}'; done; } >"$work/t902"

# ---- real files ----
find fixtures tools "$@" \( -name node_modules -o -name target -o -name '.git' -o -name build \) -prune -o -type f -name '*.json' -print0 >"$work/files"

total=0; bad=0
check() {
    total=$((total + 1))
    "$old" "$1" >"$work/a" 2>&1
    "$new" "$1" >"$work/b" 2>&1
    if ! cmp -s "$work/a" "$work/b"; then
        bad=$((bad + 1))
        if [ $bad -le 8 ]; then
            echo "DIFFERENT: ${1#"$work/"}: $(head -c 80 "$1" | tr '\n' ' ')"
            diff <(head -c 600 "$work/a" | sed "s|$work/||") <(head -c 600 "$work/b" | sed "s|$work/||") | head -6
        fi
    fi
}
for f in "$work"/t*; do check "$f"; done
made=$total
while IFS= read -r -d '' f; do check "$f"; done <"$work/files"
taken=$(for f in "$work"/t*; do "$new" "$f"; done | grep -vc 'refused$')
echo "made-up texts: $made, of which $taken are JSON; files: $((total - made))"
if [ $bad = 0 ]; then echo "the same: $total of $total texts"; exit 0; fi
echo "DIFFERENT: $bad of $total texts"
exit 1
