#!/usr/bin/env bash
# Stage 2's judge (docs/rust-port.md): the planning commands, which run
# nothing, give the same bytes from the Goose program and the Rust port.
# Each command is run through scripts/port-compare.sh on every fixture, on
# made-up repos that hold the cases the fixtures do not (written by this
# script into a temporary folder), and on each repo given.
#
#   scripts/port-plan.sh [repo...]
#
# The commands judged are those carried so far: cargo-projects and
# gradle-tasks. cargo-projects is run three times, with RUSTUP_HOME unset,
# set to a made-up rustup home (an old pinned toolchain installed, a newer
# default with its library source) and set to a folder that does not exist,
# so the toolchain lines are judged too. gradle-tasks is run once on each
# repo, on each case of fixtures/gradle-android, and on made-up Gradle repos.
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
# put <file>: standard input into the file, byte for byte (no escapes).
put() { mkdir -p "$(dirname "$1")"; cat >"$1"; }

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

# ---- gradle-tasks ----
# Each repo under gradle/ holds one case; most hide or show an Android
# plugin id depending on whether the reader gets the case right. The plain
# answer is "clean scipPrintDependencies scipCompileAll"; an Android one
# names compileDebugKotlin.
g="$cases/gradle"
# Comments: Kotlin nests /* */, Groovy does not.
printf 'include(":app")\n' | put "$g/kts-nested-comment/settings.gradle.kts"
put "$g/kts-nested-comment/app/build.gradle.kts" <<'EOF'
/* outer /* inner */ id("com.android.application") */
plugins { id("java") }
EOF
printf "include ':app'\n" | put "$g/groovy-nested-comment/settings.gradle"
put "$g/groovy-nested-comment/app/build.gradle" <<'EOF'
/* outer /* inner */ apply plugin: 'com.android.application' // */
EOF
# A string holding "//" is not a comment.
printf 'include(":app")\n' | put "$g/string-slashes/settings.gradle.kts"
put "$g/string-slashes/app/build.gradle.kts" <<'EOF'
val u = "http://example.com"; plugins { id("com.android.library") }
EOF
# A backslash in a Kotlin raw string escapes nothing; in Groovy it does.
printf 'include(":app")\n' | put "$g/kts-raw-backslash/settings.gradle.kts"
put "$g/kts-raw-backslash/app/build.gradle.kts" <<'EOF'
val p = """C:\"""
// id("com.android.application")
EOF
printf "include ':app'\n" | put "$g/groovy-triple-backslash/settings.gradle"
put "$g/groovy-triple-backslash/app/build.gradle" <<'EOF'
def p = '''C:\'''
// apply plugin: 'com.android.application'
EOF
# Groovy slashy strings: where one starts (after = and return, not after a
# value or a postfix ++), its \/ escape, and the dollar-slashy kind with its
# $/ escape.
for c in division slashy-quote slashy-escape postfix keyword dollar dollar-escape; do printf "include ':app'\n" | put "$g/groovy-$c/settings.gradle"; done
put "$g/groovy-division/app/build.gradle" <<'EOF'
def half = total / 2 // apply plugin: 'com.android.application'
EOF
put "$g/groovy-slashy-quote/app/build.gradle" <<'EOF'
def re = /it's/ // apply plugin: 'com.android.application'
EOF
put "$g/groovy-slashy-escape/app/build.gradle" <<'EOF'
def re = /it\/'s/ // apply plugin: 'com.android.application'
EOF
put "$g/groovy-postfix/app/build.gradle" <<'EOF'
def y = i++ / 2; def z = 'q' // apply plugin: 'com.android.application'
EOF
put "$g/groovy-keyword/app/build.gradle" <<'EOF'
def f() { return /x'/ } // apply plugin: 'com.android.application'
EOF
put "$g/groovy-dollar/app/build.gradle" <<'EOF'
def s = $/ // apply plugin: 'com.android.application' /$
EOF
put "$g/groovy-dollar-escape/app/build.gradle" <<'EOF'
def s = $/ a $/$ // apply plugin: 'com.android.application' /$
EOF
# Reactions: over several lines, with parentheses inside, with a space
# before the parenthesis, and a longer word that only ends in withId.
for c in react-multiline react-nested react-space react-word; do printf 'include(":app")\n' | put "$g/$c/settings.gradle.kts"; done
put "$g/react-multiline/app/build.gradle.kts" <<'EOF'
pluginManager.withPlugin(
    "com.android.library"
) {
}
plugins { id("java") }
EOF
put "$g/react-nested/app/build.gradle.kts" <<'EOF'
plugins.withId(foo(1), "com.android.application") { }
EOF
put "$g/react-space/app/build.gradle.kts" <<'EOF'
if (project.plugins.hasPlugin ("com.android.test")) { }
EOF
put "$g/react-word/app/build.gradle.kts" <<'EOF'
mywithId("com.android.application")
EOF
# apply false on chained lines that start with "version " and "apply ".
printf 'include(":app")\n' | put "$g/apply-false-chain/settings.gradle.kts"
put "$g/apply-false-chain/build.gradle.kts" <<'EOF'
plugins {
    id("com.android.application")
        version "9.0.0"
        apply false
}
EOF
printf 'plugins { id("java") }\n' | put "$g/apply-false-chain/app/build.gradle.kts"
# Includes: a Groovy list over lines, a Kotlin call over lines with a name
# without ':', a name with '/', an include inside a raw string, includeBuild,
# both settings files (the .kts one wins), a commented include, a quoted
# name later on an include line, and Groovy slashy and dollar-slashy
# strings over lines.
put "$g/inc-groovy-multi/settings.gradle" <<'EOF'
include ':core',
        ':feature:login'
EOF
printf "apply plugin: 'com.android.library'\n" | put "$g/inc-groovy-multi/feature/login/build.gradle"
put "$g/inc-kts-paren/settings.gradle.kts" <<'EOF'
include(
    ":a",
    "b"
)
EOF
printf 'plugins { id("com.android.library") }\n' | put "$g/inc-kts-paren/b/build.gradle.kts"
printf 'include("sub/app")\n' | put "$g/inc-slash/settings.gradle.kts"
printf 'plugins { id("com.android.library") }\n' | put "$g/inc-slash/sub/app/build.gradle.kts"
put "$g/inc-raw-string/settings.gradle.kts" <<'EOF'
val doc = """
include(":app")
"""
EOF
printf 'plugins { id("com.android.library") }\n' | put "$g/inc-raw-string/app/build.gradle.kts"
printf 'includeBuild("tools")\n' | put "$g/inc-build/settings.gradle.kts"
printf 'plugins { id("com.android.library") }\n' | put "$g/inc-build/tools/build.gradle.kts"
printf 'include(":a")\n' | put "$g/inc-both/settings.gradle.kts"
printf "include ':b'\n" | put "$g/inc-both/settings.gradle"
printf "apply plugin: 'com.android.library'\n" | put "$g/inc-both/b/build.gradle"
printf '// include(":app")\n' | put "$g/inc-comment/settings.gradle.kts"
printf 'plugins { id("com.android.library") }\n' | put "$g/inc-comment/app/build.gradle.kts"
printf 'include(":a"); val x = listOf("b")\n' | put "$g/inc-later-name/settings.gradle.kts"
printf 'plugins { id("com.android.library") }\n' | put "$g/inc-later-name/b/build.gradle.kts"
put "$g/inc-groovy-slashy/settings.gradle" <<'EOF'
def p = /x
include ':app'
/
EOF
printf "apply plugin: 'com.android.library'\n" | put "$g/inc-groovy-slashy/app/build.gradle"
put "$g/inc-groovy-dollar/settings.gradle" <<'EOF'
def p = $/
include ':app'
/$
EOF
printf "apply plugin: 'com.android.library'\n" | put "$g/inc-groovy-dollar/app/build.gradle"
# The version catalog: '_' and '-' in a key become '.', a commented line
# names nothing, and "id:version" is read.
for c in cat-underscore cat-commented cat-test; do
    put "$g/$c/gradle/libs.versions.toml" <<'EOF'
[versions]
agp = "9.0.0"
[plugins]
android_lib = { id = "com.android.library", version.ref = "agp" }
#android-app = { id = "com.android.application", version.ref = "agp" }
android-test = "com.android.test:9.0.0"
EOF
    printf 'include(":app")\n' | put "$g/$c/settings.gradle.kts"
done
printf 'plugins { alias(libs.plugins.android.lib) }\n' | put "$g/cat-underscore/app/build.gradle.kts"
printf 'plugins { alias(libs.plugins.android.app) }\n' | put "$g/cat-commented/app/build.gradle.kts"
printf 'plugins { alias(libs.plugins.android.test) }\n' | put "$g/cat-test/app/build.gradle.kts"
# A module's build.gradle.kts wins over its build.gradle.
printf 'include(":app")\n' | put "$g/kts-wins/settings.gradle.kts"
printf 'plugins { id("java") }\n' | put "$g/kts-wins/app/build.gradle.kts"
printf "apply plugin: 'com.android.library'\n" | put "$g/kts-wins/app/build.gradle"

# The last: a repo that does not exist, which both refuse.
repos=(fixtures/* "$cases/many" "$cases/ws" "$cases/side" "$cases/tc" "$cases/does-not-exist" "$@")

total=0; bad=0
# judge <command> <repo> [rustup homes...]: with none given, once as it is.
judge() {
    local cmd=$1 repo=$2
    shift 2
    local homes=("$@")
    [ ${#homes[@]} = 0 ] && homes=(as-is)
    for which in "${homes[@]}"; do
        local code
        case $which in
            unset) (unset RUSTUP_HOME; scripts/port-compare.sh "$cmd" "$repo") >"$cases/report" 2>&1 ;;
            made-up) RUSTUP_HOME=$rh scripts/port-compare.sh "$cmd" "$repo" >"$cases/report" 2>&1 ;;
            missing) RUSTUP_HOME=$cases/nowhere scripts/port-compare.sh "$cmd" "$repo" >"$cases/report" 2>&1 ;;
            as-is) scripts/port-compare.sh "$cmd" "$repo" >"$cases/report" 2>&1 ;;
        esac
        code=$?
        total=$((total + 1))
        if [ $code = 3 ]; then echo "port-plan: $cmd is not carried over yet"; exit 3; fi
        if [ $code != 0 ]; then
            bad=$((bad + 1))
            if [ "$which" = as-is ]; then echo "DIFFERENT ($cmd ${repo#"$cases/"})"
            else echo "DIFFERENT ($cmd ${repo#"$cases/"}, rustup $which)"; fi
            sed 's/^/    /' "$cases/report"
        fi
    done
}

for repo in "${repos[@]}"; do judge cargo-projects "$repo" unset made-up missing; done
for repo in "${repos[@]}" fixtures/gradle-android/*/ fixtures/gradle-android/bad-include/repo "$g"/*; do
    judge gradle-tasks "$repo"
done

if [ $bad = 0 ]; then echo "the same: $total of $total"; exit 0; fi
echo "DIFFERENT: $bad of $total"
exit 1
