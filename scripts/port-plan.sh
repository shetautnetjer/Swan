#!/usr/bin/env bash
# Stage 2's judge (docs/rust-port.md): the planning commands, which run
# nothing, give the same bytes from the Goose program and the Rust port.
# Each command is run through scripts/port-compare.sh on every fixture, on
# made-up repos that hold the cases the fixtures do not (written by this
# script into a temporary folder), and on each repo given.
#
#   scripts/port-plan.sh [repo...]
#
# The commands judged are those carried so far: cargo-projects. Each is run
# three times, with RUSTUP_HOME unset, set to a made-up rustup home (an old
# pinned toolchain installed, a newer default with its library source) and
# set to a folder that does not exist, so the toolchain lines are judged too.
#
# SWAN_OLD, SWAN_NEW: as for port-compare.sh.
# Prints one "DIFFERENT (<command> <repo>, rustup <which>)" block for each
# disagreement, then "the same: N of N" or "DIFFERENT: K of N".
# Exit 0: all the same. 1: some differ. 3: a command is not carried yet.
set -uo pipefail
cd "$(dirname "$0")/.."

cases=$(mktemp -d)
trap 'rm -rf "$cases"' EXIT

mk() { mkdir -p "$(dirname "$1")"; printf '%b' "$2" >"$1"; }

# ---- cargo-projects ----
# many: fifteen crates side by side and no root manifest: past the limit of 12.
for i in $(seq -w 1 15); do mk "$cases/many/c$i/Cargo.toml" "[package]\nname=\"c$i\"\n"; done
# ws: a workspace with members, an exclude array over lines with a comment in
# it, a crate cut off by its own [workspace], path dependencies (one word
# "mypath" that is not one), and paths leaving the repo or absolute.
mk "$cases/ws/Cargo.toml" '[workspace]\nmembers = ["crates/*"]\nexclude = [\n  "crates/skip", # not "crates/bar"\n  "tools/x"\n]\n[workspace.dependencies]\nfoo = { path = "crates/foo" }\n'
mk "$cases/ws/crates/foo/Cargo.toml" '[package]\nname="foo"\n[dependencies]\nbar={path="../bar"}\nmypath = "x"\n'
mk "$cases/ws/crates/bar/Cargo.toml" '[package]\nname="bar"\n'
mk "$cases/ws/crates/skip/Cargo.toml" '[package]\nname="skip"\n'
mk "$cases/ws/tools/x/Cargo.toml" '[package]\nname="x"\n'
mk "$cases/ws/tools/x/y/Cargo.toml" '[package]\nname="y"\n'
mk "$cases/ws/fuzz/Cargo.toml" '[package]\nname="fuzz"\n[workspace]\n[dependencies]\nfoo = { path = "../crates/foo" }\n'
mk "$cases/ws/out/Cargo.toml" '[package]\nname="out"\n[dependencies]\nz = { path = "../../../escape" }\nabs = { path = "/abs/thing" }\n'
# side: no root manifest; one crate names another by path, one names a
# crate in a word that is not "path" (mypath), one by a path that leaves the
# repo on the way; folders a walk
# leaves out (node_modules, hidden, target, a symlink); names with a space,
# with UTF-8 and with a byte that is not UTF-8.
mk "$cases/side/a/Cargo.toml" '[package]\nname="a"\nmypath = "../b/inner"\n[dependencies]\nb = { path = "../b" }\nd = { path = "../../c/deep" }\n'
mk "$cases/side/c/Cargo.toml" '[package]\nname="c"\n'
mk "$cases/side/c/deep/Cargo.toml" '[package]\nname="deep"\n'
mk "$cases/side/b/Cargo.toml" '[package]\nname="b"\n'
mk "$cases/side/b/inner/Cargo.toml" '[package]\nname="inner"\n'
mk "$cases/side/node_modules/n/Cargo.toml" '[package]\n'
mk "$cases/side/.hidden/h/Cargo.toml" '[package]\n'
mk "$cases/side/target/t/Cargo.toml" '[package]\n'
mk "$cases/side/we ird/naïve/Cargo.toml" '[package]\nname="w"\n'
mk "$cases/side/raw/$(printf 'x\xff')/Cargo.toml" '[package]\n'
ln -s ../ws "$cases/side/link"
# tc: pinned toolchains: an old installed one, one newer than the default,
# one not installed, the plain rust-toolchain file, and one whose quote is
# not closed.
mk "$cases/tc/Cargo.toml" '[package]\nname="tc"\n'
mk "$cases/tc/rust-toolchain.toml" '[toolchain]\nchannel = "1.80.0"\n'
mk "$cases/tc/sub/Cargo.toml" '[package]\nname="sub"\n[workspace]\n'
mk "$cases/tc/miss/Cargo.toml" '[package]\nname="m"\n[workspace]\n'
mk "$cases/tc/miss/rust-toolchain.toml" 'channel = "1.70.0"\n'
mk "$cases/tc/plain/Cargo.toml" '[package]\nname="p"\n[workspace]\n'
mk "$cases/tc/plain/rust-toolchain" '1.80.0\n'
mk "$cases/tc/quoted/Cargo.toml" '[package]\nname="q"\n[workspace]\n'
mk "$cases/tc/quoted/rust-toolchain" '[toolchain]\nchannel="weird\n'
mk "$cases/tc/newer/Cargo.toml" '[package]\nname="n"\n[workspace]\n'
mk "$cases/tc/newer/rust-toolchain.toml" 'channel = "1.95.0"\n'
# A made-up rustup home: 1.80.0 and 1.95.0 installed, stable (1.91) the
# default, with its library source. A quote in its path: written into JSON.
rh="$cases/rust\"up"
stable="$rh/toolchains/stable-x86_64-unknown-linux-gnu"
mkdir -p "$rh/toolchains/1.80.0-x86_64-unknown-linux-gnu" "$rh/toolchains/1.95.0-x86_64-unknown-linux-gnu" "$stable/lib/rustlib/src/rust/library/core/src"
touch "$stable/lib/rustlib/src/rust/library/core/src/lib.rs"
printf '[pkg.cargo]\nversion = "0.1"\n[pkg.rustc]\nversion = "1.91.1 (abc)"\n' >"$stable/lib/rustlib/multirust-channel-manifest.toml"
printf 'default_toolchain = "stable-x86_64-unknown-linux-gnu"\n' >"$rh/settings.toml"

# The last: a repo that does not exist, which both refuse.
repos=(fixtures/* "$cases/many" "$cases/ws" "$cases/side" "$cases/tc" "$cases/does-not-exist" "$@")

total=0; bad=0
judge() {
    local cmd=$1 repo=$2
    for which in unset made-up missing; do
        local code
        case $which in
            unset) (unset RUSTUP_HOME; scripts/port-compare.sh "$cmd" "$repo") >"$cases/report" 2>&1 ;;
            made-up) RUSTUP_HOME=$rh scripts/port-compare.sh "$cmd" "$repo" >"$cases/report" 2>&1 ;;
            missing) RUSTUP_HOME=$cases/nowhere scripts/port-compare.sh "$cmd" "$repo" >"$cases/report" 2>&1 ;;
        esac
        code=$?
        total=$((total + 1))
        if [ $code = 3 ]; then echo "port-plan: $cmd is not carried over yet"; exit 3; fi
        if [ $code != 0 ]; then
            bad=$((bad + 1))
            echo "DIFFERENT ($cmd ${repo#"$cases/"}, rustup $which)"
            sed 's/^/    /' "$cases/report"
        fi
    done
}

for repo in "${repos[@]}"; do judge cargo-projects "$repo"; done

if [ $bad = 0 ]; then echo "the same: $total of $total"; exit 0; fi
echo "DIFFERENT: $bad of $total"
exit 1
