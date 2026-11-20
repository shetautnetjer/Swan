#!/usr/bin/env bash
# Stage 2's judge (docs/rust-port.md): the planning commands, which run
# nothing, give the same bytes from the Goose program and the Rust port.
# Each command is run through scripts/port-compare.sh on every fixture, on
# made-up repos that hold the cases the fixtures do not (written by this
# script into a temporary folder), and on each repo given.
#
#   scripts/port-plan.sh [repo...]
#
# The commands judged are those carried so far: cargo-projects,
# gradle-tasks and plan-python. cargo-projects is run three times, with RUSTUP_HOME unset,
# set to a made-up rustup home (an old pinned toolchain installed, a newer
# default with its library source) and set to a folder that does not exist,
# so the toolchain lines are judged too. gradle-tasks is run once on each
# repo, on each case of fixtures/gradle-android, and on made-up Gradle repos.
# plan-python is run on each repo and on made-up Python repos, with its
# number of pieces unset (6) and set to 1, 2, 3, 4 and 8.
#
# SWAN_OLD, SWAN_NEW: as for port-compare.sh.
# Prints one "DIFFERENT (<command> <repo>, rustup <which>)" block for each
# disagreement, then "the same: N of N" or "DIFFERENT: K of N".
# Exit 0: all the same. 1: some differ. 2: a comparison could not be made
# (a program is missing). 3: a command is not carried yet.
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

# Convention plugins: the repo's own plugins, in buildSrc or a build that
# settings includes with includeBuild, that apply Android for the modules.
cls_android() { # <file> <applied id>: a Kotlin class that applies it
    put "$1" <<EOF
class P : Plugin<Project> {
    override fun apply(target: Project) {
        with(target) { apply(plugin = "$2") }
    }
}
EOF
}
# A Groovy precompiled script plugin (its id: the file name less .gradle).
printf "include ':app'\n" | put "$g/conv-groovy-script/settings.gradle"
printf "plugins { id 'com.android.library' }\n" | put "$g/conv-groovy-script/buildSrc/src/main/groovy/demo.android-lib.gradle"
printf "plugins { id 'demo.android-lib' }\n" | put "$g/conv-groovy-script/app/build.gradle"
# A Kotlin one in a package: its id starts with the package.
printf 'include(":app")\n' | put "$g/conv-kts-package/settings.gradle.kts"
printf 'package demo.conv\n\nplugins { id("com.android.application") }\n' | put "$g/conv-kts-package/buildSrc/src/main/kotlin/demo/conv/android.gradle.kts"
printf 'plugins { id("demo.conv.android") }\n' | put "$g/conv-kts-package/app/build.gradle.kts"
# A script outside src/main is no plugin.
printf 'include(":app")\n' | put "$g/conv-not-src/settings.gradle.kts"
printf 'plugins { id("com.android.application") }\n' | put "$g/conv-not-src/buildSrc/scripts/demo.x.gradle.kts"
printf 'plugins { id("demo.x") }\n' | put "$g/conv-not-src/app/build.gradle.kts"
# Groovy: includeBuild with a space, a registration written `id '...'`,
# and the class in a .groovy file.
put "$g/conv-groovy-register/settings.gradle" <<'EOF'
includeBuild 'logic'
include ':app'
EOF
put "$g/conv-groovy-register/logic/build.gradle" <<'EOF'
gradlePlugin {
    plugins {
        androidLib {
            id 'demo.lib'
            implementationClass = 'demo.AndroidLibPlugin'
        }
    }
}
EOF
put "$g/conv-groovy-register/logic/src/main/groovy/demo/AndroidLibPlugin.groovy" <<'EOF'
class AndroidLibPlugin implements Plugin<Project> {
    void apply(Project project) { project.pluginManager.apply('com.android.library') }
}
EOF
printf "apply plugin: 'demo.lib'\n" | put "$g/conv-groovy-register/app/build.gradle"
# The class in a .java file.
printf 'includeBuild("logic")\ninclude(":app")\n' | put "$g/conv-java-class/settings.gradle.kts"
put "$g/conv-java-class/logic/build.gradle.kts" <<'EOF'
gradlePlugin {
    plugins {
        register("lib") {
            id = "demo.java"
            implementationClass = "demo.JavaLibPlugin"
        }
    }
}
EOF
put "$g/conv-java-class/logic/src/main/java/demo/JavaLibPlugin.java" <<'EOF'
public class JavaLibPlugin implements Plugin<Project> {
    public void apply(Project project) { project.getPluginManager().apply("com.android.library"); }
}
EOF
printf 'plugins { id("demo.java") }\n' | put "$g/conv-java-class/app/build.gradle.kts"
# includeBuild in a comment, in a longer word, or leaving the repo: not read.
for c in conv-comment-include conv-word-include; do
    put "$g/$c/logic/build.gradle.kts" <<'EOF'
gradlePlugin { plugins { register("a") { id = "demo.a"; implementationClass = "A" } } }
EOF
    cls_android "$g/$c/logic/src/main/kotlin/A.kt" com.android.library
    printf 'plugins { id("demo.a") }\n' | put "$g/$c/app/build.gradle.kts"
done
printf '// includeBuild("logic")\ninclude(":app")\n' | put "$g/conv-comment-include/settings.gradle.kts"
printf 'myincludeBuild("logic")\ninclude(":app")\n' | put "$g/conv-word-include/settings.gradle.kts"
printf 'includeBuild("../logic")\ninclude(":app")\n' | put "$g/conv-outside/repo/settings.gradle.kts"
put "$g/conv-outside/logic/build.gradle.kts" <<'EOF'
gradlePlugin { plugins { register("a") { id = "demo.a"; implementationClass = "A" } } }
EOF
cls_android "$g/conv-outside/logic/src/main/kotlin/A.kt" com.android.library
printf 'plugins { id("demo.a") }\n' | put "$g/conv-outside/repo/app/build.gradle.kts"
# The catalog: a plain "id:version" entry, a key that only holds "id",
# and a key with '_'.
for c in conv-catalog-plain conv-catalog-word conv-catalog-underscore; do
    printf 'includeBuild("logic")\ninclude(":app")\n' | put "$g/$c/settings.gradle.kts"
    put "$g/$c/logic/build.gradle.kts" <<'EOF'
gradlePlugin { plugins { register("a") { id = "demo.lib"; implementationClass = "A" } } }
EOF
    cls_android "$g/$c/logic/src/main/kotlin/A.kt" com.android.library
    printf 'plugins { alias(libs.plugins.demo.lib) }\n' | put "$g/$c/app/build.gradle.kts"
done
printf '[plugins]\ndemo-lib = "demo.lib:1.0"\n' | put "$g/conv-catalog-plain/gradle/libs.versions.toml"
printf '[plugins]\ndemo-lib = { grid = "x", id = "demo.lib" }\n' | put "$g/conv-catalog-word/gradle/libs.versions.toml"
printf '[plugins]\ndemo_lib = { id = "demo.lib" }\n' | put "$g/conv-catalog-underscore/gradle/libs.versions.toml"
# A chain of three, registered from the top down, so one pass finds only
# the last; and two plugins that apply each other, neither Android.
printf 'includeBuild("logic")\ninclude(":app")\n' | put "$g/conv-chain3/settings.gradle.kts"
put "$g/conv-chain3/logic/build.gradle.kts" <<'EOF'
gradlePlugin {
    plugins {
        register("a") { id = "demo.a"; implementationClass = "A" }
        register("b") { id = "demo.b"; implementationClass = "B" }
        register("c") { id = "demo.c"; implementationClass = "C" }
    }
}
EOF
cls_android "$g/conv-chain3/logic/src/main/kotlin/A.kt" demo.b
cls_android "$g/conv-chain3/logic/src/main/kotlin/B.kt" demo.c
cls_android "$g/conv-chain3/logic/src/main/kotlin/C.kt" com.android.application
printf 'plugins { id("demo.a") }\n' | put "$g/conv-chain3/app/build.gradle.kts"
printf 'includeBuild("logic")\ninclude(":app")\n' | put "$g/conv-cycle/settings.gradle.kts"
put "$g/conv-cycle/logic/build.gradle.kts" <<'EOF'
gradlePlugin {
    plugins {
        register("a") { id = "demo.a"; implementationClass = "A" }
        register("b") { id = "demo.b"; implementationClass = "B" }
    }
}
EOF
cls_android "$g/conv-cycle/logic/src/main/kotlin/A.kt" demo.b
cls_android "$g/conv-cycle/logic/src/main/kotlin/B.kt" demo.a
printf 'plugins { id("demo.a") }\n' | put "$g/conv-cycle/app/build.gradle.kts"
# How a module applies a convention plugin: only applying it counts.
for c in conv-apply-groovy conv-apply-kts conv-plugin-manager conv-id-space conv-not-applied; do
    put "$g/$c/logic/build.gradle.kts" <<'EOF'
gradlePlugin { plugins { register("a") { id = "demo.a"; implementationClass = "A" } } }
EOF
    cls_android "$g/$c/logic/src/main/kotlin/A.kt" com.android.library
done
for c in conv-apply-groovy conv-id-space; do printf "includeBuild 'logic'\ninclude ':app'\n" | put "$g/$c/settings.gradle"; done
for c in conv-apply-kts conv-plugin-manager conv-not-applied; do printf 'includeBuild("logic")\ninclude(":app")\n' | put "$g/$c/settings.gradle.kts"; done
printf "apply plugin: 'demo.a'\n" | put "$g/conv-apply-groovy/app/build.gradle"
printf "plugins { id 'demo.a' }\n" | put "$g/conv-id-space/app/build.gradle"
# Named in a string first, then applied, on one line.
printf 'val n = "demo.a"; apply(plugin = "demo.a")\n' | put "$g/conv-apply-kts/app/build.gradle.kts"
printf 'pluginManager.apply("demo.a")\n' | put "$g/conv-plugin-manager/app/build.gradle.kts"
put "$g/conv-not-applied/app/build.gradle.kts" <<'EOF'
plugins { kotlin("jvm") }
val n = "demo.a"
println("demo.a")
apply(from = "demo.a")
EOF
# Two registrations: each id is read from its own block, so the JVM one
# written first is not given the Android class written after it.
printf 'includeBuild("logic")\ninclude(":app")\n' | put "$g/conv-two-blocks/settings.gradle.kts"
put "$g/conv-two-blocks/logic/build.gradle.kts" <<'EOF'
gradlePlugin {
    plugins {
        register("jvm") {
            id = "demo.jvm"
            implementationClass = "Jvm"
        }
        register("andr") {
            implementationClass = "Andr"
            id = "demo.andr"
        }
    }
}
EOF
cls_android "$g/conv-two-blocks/logic/src/main/kotlin/Jvm.kt" org.jetbrains.kotlin.jvm
cls_android "$g/conv-two-blocks/logic/src/main/kotlin/Andr.kt" com.android.library
printf 'plugins { id("demo.jvm") }\n' | put "$g/conv-two-blocks/app/build.gradle.kts"

# ---- plan-python ----
# Each repo under py/ holds Python files whose number, size, names and
# imports decide the pieces. Run with k unset (6) and k = 1, 2, 3, 4, 8.
p="$cases/py"
pyfile() { # <file> <bytes of filler> [first line]
    mkdir -p "$(dirname "$1")"
    { [ -n "${3:-}" ] && printf '%s\n' "$3"; head -c "$2" /dev/zero | tr '\0' '#'; printf '\n'; } >"$1"
}
# Too few files for the pieces: one run.
for f in a b c; do pyfile "$p/few/$f.py" 10; done
# Packages of different sizes, files at the root, and a nested package.
for i in 1 2 3 4 5 6; do pyfile "$p/pkgs/big/m$i.py" 4000; done
for i in 1 2; do pyfile "$p/pkgs/small/s$i.py" 300; done
for i in 1 2 3; do pyfile "$p/pkgs/deep/one/d$i.py" 900; pyfile "$p/pkgs/deep/two/e$i.py" 700; done
pyfile "$p/pkgs/top.py" 50; pyfile "$p/pkgs/setup.py" 20
mkdir -p "$p/pkgs/node_modules/x" && pyfile "$p/pkgs/node_modules/x/n.py" 99999
# A flat tests/ of standalone scripts (stdlib imports only): split by prefix.
for pre in a b c; do for i in $(seq -w 1 30); do pyfile "$p/flat/tests/test_${pre}$i.py" $((10#$i * 7)) "import os, sys"; done; done
pyfile "$p/flat/pkg/core.py" 500; pyfile "$p/flat/pkg/util.py" 300
# The same, but most import the repo's own package: kept whole.
for i in $(seq -w 1 80); do pyfile "$p/flat-own/tests/t$i.py" 40 "from pkg import core"; done
pyfile "$p/flat-own/pkg/core.py" 500; pyfile "$p/flat-own/pkg/x.py" 100
# Relative imports, and imports of a sibling module by its file name.
for i in $(seq -w 1 80); do pyfile "$p/flat-rel/tests/t$i.py" 40 "from . import helper"; done
for i in $(seq -w 1 80); do pyfile "$p/flat-sib/tests/u$i.py" 40 "import u01"; done
pyfile "$p/flat-rel/pkg/a.py" 900; pyfile "$p/flat-sib/pkg/a.py" 900
# Exactly one in ten imports the repo (allowed), and one more (not).
for c in ten eleven; do
    for i in $(seq -w 1 70); do pyfile "$p/ratio-$c/tests/r$i.py" 30 "import json"; done
    for i in 01 02 03 04 05 06 07; do pyfile "$p/ratio-$c/tests/r$i.py" 30 "import pkg"; done
    pyfile "$p/ratio-$c/pkg/m.py" 800
done
pyfile "$p/ratio-eleven/tests/r08.py" 30 "import pkg"
# Loose standalone scripts at the root: pieces with no folder in front.
for pre in x y; do for i in $(seq -w 1 40); do pyfile "$p/root-loose/${pre}$i.py" 25 "import re"; done; done
# Two names that only share a dot, beside many others: the group "." is
# under the limits, and "." cannot be a piece, so the root is one run.
pyfile "$p/dot/.a1.py" 25; pyfile "$p/dot/.b1.py" 25
for i in $(seq -w 1 80); do pyfile "$p/dot/z$i.py" 25; done
# A folder named as the prefix ends a split there.
for i in $(seq -w 1 80); do pyfile "$p/ends/s/t$i.py" 25; done
pyfile "$p/ends/s/t/inner.py" 25
# Many first letters: more groups than allowed stops the split.
for l in a b c d e f g h i j k l m n o p q r s t u v w x y z A B C D E F G H I J K L M N O P Q; do
    for i in 1 2; do pyfile "$p/many/tests/${l}$i.py" 30; done
done
# A split by a second and third byte; byte order, a space and UTF-8.
for pre in aa ab ac ba bb; do for i in $(seq -w 1 20); do pyfile "$p/deep/tests/${pre}_$i.py" 60; done; done
for i in $(seq -w 1 20); do pyfile "$p/deep/tests/Zz $i.py" 60; pyfile "$p/deep/tests/é$i.py" 60; done
# Big files: a group over the byte limit, not the file count.
for i in $(seq -w 1 70); do pyfile "$p/bytes/tests/b$i.py" $((10#$i < 10 ? 20000 : 30)); done
pyfile "$p/bytes/pkg/a.py" 30
# A second name in one import line counts: `import os, pkg` needs the repo.
for i in $(seq -w 1 80); do pyfile "$p/flat-multi/tests/m$i.py" 40 "import os, pkg"; done
pyfile "$p/flat-multi/pkg/core.py" 500
# At the limits: exactly 40 first letters (the most groups a split may
# make), and exactly 64 loose scripts (not more than a piece may hold).
for l in a b c d e f g h i j k l m n o p q r s t u v w x y z A B C D E F G H I J K L M N; do
    for i in 1 2; do pyfile "$p/groups40/tests/${l}$i.py" 30; done
done
for i in $(seq -w 1 64); do pyfile "$p/files64/tests/f$i.py" 30; done
pyfile "$p/files64/pkg/a.py" 900
# A folder exactly at the size limit (k = 4: 800 bytes, 200 each), beside
# one whose name starts the same.
for i in 1 2; do pyfile "$p/limit-eq/a/x$i.py" 99; pyfile "$p/limit-eq/ab/y$i.py" 99; done
for i in 1 2 3 4; do pyfile "$p/limit-eq/c/z$i.py" 99; done
# Two groups as big as each other, each splitting 36 ways: whichever is
# split first takes the room, and the other stays whole.
for pre in a b; do for x in 0 1 2 3 4 5 6 7 8 9 a b c d e f g h i j k l m n o p q r s t u v w x y z; do
    for i in 1 2; do pyfile "$p/tie/tests/${pre}${x}_$i.py" 30; done
done; done
# Empty files count as one byte: at k = 4, three empty files beside five
# of one byte are over the limit (2) and split, not under it (1) and whole.
mkdir -p "$p/empty-mix/e" "$p/empty-mix/d"
for f in a b c; do : >"$p/empty-mix/e/$f.py"; done
for f in a b c d e; do printf x >"$p/empty-mix/d/$f.py"; done
# Empty files count as one byte.
for i in $(seq -w 1 20); do : >"$p/empty-$i.py"; done 2>/dev/null; mkdir -p "$p/empty"; for i in $(seq -w 1 20); do : >"$p/empty/e$i.py"; done; rm -f "$p"/empty-*.py

# The last: a repo that does not exist, which both refuse.
repos=(fixtures/* "$cases/many" "$cases/ws" "$cases/side" "$cases/tc" "$cases/does-not-exist" "$@")

total=0; bad=0
# judge <command> <repo> [rustup homes...]: with none given, once as it is.
# PORT_PLAN_ARG: one more argument after the repo.
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
            as-is) scripts/port-compare.sh "$cmd" "$repo" ${PORT_PLAN_ARG:+"$PORT_PLAN_ARG"} >"$cases/report" 2>&1 ;;
        esac
        code=$?
        total=$((total + 1))
        if [ $code = 3 ]; then echo "port-plan: $cmd is not carried over yet"; exit 3; fi
        # port-compare.sh could not run the two programs (one is missing): no
        # comparison was made, so nothing may be counted as a difference.
        if [ $code = 2 ]; then echo "port-plan: no comparison could be made ($cmd ${repo#"$cases/"}):"; sed 's/^/    /' "$cases/report"; exit 2; fi
        if [ $code != 0 ]; then
            bad=$((bad + 1))
            if [ "$which" = as-is ]; then echo "DIFFERENT ($cmd ${repo#"$cases/"}${PORT_PLAN_ARG:+ $PORT_PLAN_ARG})"
            else echo "DIFFERENT ($cmd ${repo#"$cases/"}, rustup $which)"; fi
            sed 's/^/    /' "$cases/report"
        fi
    done
}

for repo in "${repos[@]}"; do judge cargo-projects "$repo" unset made-up missing; done
for repo in "${repos[@]}" fixtures/gradle-android/*/ fixtures/gradle-android/bad-include/repo "$g"/* "$g/conv-outside/repo"; do
    judge gradle-tasks "$repo"
done
for repo in "${repos[@]}" "$p"/*; do
    for k in "" 1 2 3 4 8; do PORT_PLAN_ARG=$k judge plan-python "$repo"; done
done

if [ $bad = 0 ]; then echo "the same: $total of $total"; exit 0; fi
echo "DIFFERENT: $bad of $total"
exit 1
