#!/usr/bin/env bash
# Runs one swan command with the Goose program and with the Rust port and says
# whether they agree: standard output, standard error and the exit code.
# (docs/rust-port.md: the bar is the same bytes.)
#
#   scripts/port-compare.sh <swan arguments...>
#   scripts/port-compare.sh --wrong-calls      every call the usage text answers
#
# SWAN_OLD   the Goose program (default: the installed one, else bin/swan)
# SWAN_NEW   the Rust program  (default: build/rust/release/swan)
# PORT_EACH_IN=<dir>   run the Goose program in <dir>/old and the Rust one in
#            <dir>/new (made if missing), so a relative path given to both is
#            a file of each one's own. Other paths must then be absolute.
# PORT_ERR=any   compare only whether each wrote to standard error, for an
#            error whose wording differs by design (a row Goose's own bounds
#            check stops on).
# PORT_TIMES=<file>   add a line to <file>: the milliseconds the Goose program
#            took, the milliseconds the Rust program took, and the arguments
#            (a unit separator between them).
#
# Taken out before comparing, because it differs by design:
#   - the Goose runtime's wrapper around an error: "goose runtime error: "
#     before the message and " (src/x.goose:N)" after it. The message itself
#     is compared.
#   - the time a command says it took: " in N ms" at the end of a line
#   - with PORT_EACH_IN, the name of each program's own folder
#
# Exit 0: the same. 1: different (a diff is printed). 3: the Rust program says
# the command's stage is not carried over yet (its exit code 70).
set -uo pipefail
cd "$(dirname "$0")/.."

old=${SWAN_OLD:-}
if [ -z "$old" ]; then
    if [ -x "$HOME/.local/share/swan/current/bin/swan" ]; then old="$HOME/.local/share/swan/current/bin/swan"; else old=bin/swan; fi
fi
new=${SWAN_NEW:-build/rust/release/swan}
[ -x "$old" ] || { echo "port-compare: no Goose program at $old" >&2; exit 2; }
[ -x "$new" ] || { echo "port-compare: no Rust program at $new (cargo build --release --manifest-path rust/Cargo.toml)" >&2; exit 2; }
old=$(realpath "$old")
new=$(realpath "$new")

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

old_dir=.
new_dir=.
if [ -n "${PORT_EACH_IN:-}" ]; then
    mkdir -p "$PORT_EACH_IN/old" "$PORT_EACH_IN/new"
    old_dir=$(realpath "$PORT_EACH_IN/old")
    new_dir=$(realpath "$PORT_EACH_IN/new")
fi

# tidy <file> <the program's own folder, or nothing>: the file with what
# differs by design taken out.
tidy() {
    if [ -n "$2" ]; then
        local folder
        folder=$(printf '%s' "$2" | sed 's/[][\.*^$|+?(){}]/\\&/g')
        sed -E -e 's/ in [0-9]+ ms$//' -e "s|$folder|<its folder>|g" "$1"
    else
        sed -E -e 's/ in [0-9]+ ms$//' "$1"
    fi
}

compare() {
    local began=${EPOCHREALTIME/./}
    (cd "$old_dir" && "$old" "$@" >"$work/old.out" 2>"$work/old.err.raw" </dev/null); local old_code=$?
    local between=${EPOCHREALTIME/./}
    (cd "$new_dir" && "$new" "$@" >"$work/new.out" 2>"$work/new.err" </dev/null); local new_code=$?
    local ended=${EPOCHREALTIME/./}
    if [ -n "${PORT_TIMES:-}" ]; then
        printf '%s\t%s\t%s\n' $(((between - began) / 1000)) $(((ended - between) / 1000)) "$(IFS=$'\x1f'; printf '%s' "$*")" >>"$PORT_TIMES"
    fi
    if [ "$new_code" = 70 ] && [ "$old_code" != 70 ]; then return 3; fi
    # The Goose runtime's wrapper comes off its error only.
    sed -E -e '1s/^goose runtime error: //' -e '$s/ \([^()]*\.goose:[0-9]+\)$//' "$work/old.err.raw" >"$work/old.err"
    local each=""
    [ -n "${PORT_EACH_IN:-}" ] && each=yes
    local f same=0
    for f in out err; do
        local name="standard output"
        [ $f = err ] && name="standard error"
        if [ $f = err ] && [ "${PORT_ERR:-}" = any ]; then
            if [ -s "$work/old.err" ] && [ -s "$work/new.err" ]; then continue; fi
            if [ ! -s "$work/old.err" ] && [ ! -s "$work/new.err" ]; then continue; fi
            same=1; echo "$name: only one program wrote to it"; head -3 "$work/old.err" "$work/new.err"
            continue
        fi
        tidy "$work/old.$f" "${each:+$old_dir}" >"$work/old.$f.tidy"
        tidy "$work/new.$f" "${each:+$new_dir}" >"$work/new.$f.tidy"
        cmp -s "$work/old.$f.tidy" "$work/new.$f.tidy" || { same=1; echo "$name differs (Goose < > Rust):"; diff <(head -c 4000 "$work/old.$f.tidy") <(head -c 4000 "$work/new.$f.tidy") | head -40; }
    done
    [ "$old_code" = "$new_code" ] || { same=1; echo "exit code differs: Goose $old_code, Rust $new_code"; }
    return $same
}

if [ "${1:-}" = "--wrong-calls" ]; then
    # Calls with the wrong number of arguments, or no such command: both
    # programs print the usage text and exit 2.
    total=0; bad=0
    while IFS= read -r line; do
        total=$((total + 1))
        # shellcheck disable=SC2086
        if ! compare $line >"$work/report" 2>&1; then bad=$((bad + 1)); echo "swan $line"; sed 's/^/    /' "$work/report"; fi
    done <<'CALLS'

bogus
map
map a
map a b c
map a b --clean c
index
index a
refresh a
query
query a b
syntax-index a
syntax-index a b c
syntax-index a b --skip
plan-python
plan-python a 0
plan-python a x
plan-python a 1 2
scip-python-patch
scip-python-patch a b
scip-typescript-patch
scip-typescript-patch a --undo
stamp-bench a
stamp-worker a b c
trust
trust a b
gradle-tasks
gradle-tasks a b
cargo-projects
cargo-projects a b
check a
check a b c
broke
broke a
lsp-index a b c
lsp-index a b c d e
lsp-index a b c d --in e
lsp-ask a b c
format a b
test a b
diagnostics a
diagnostics a b c
serve a b
serve --maps a b
doctor --home
doctor --home=/x
doctor --json --home
CALLS
    echo "$((total - bad)) of $total wrong calls answered the same"
    [ "$bad" = 0 ]; exit $?
fi

compare "$@"; code=$?
case $code in
    0) echo "the same" ;;
    3) echo "not carried over yet" ;;
esac
exit $code
