#!/usr/bin/env bash
# Stage 4's judge for `swan map` (docs/rust-port.md), for as much of the map
# as is carried. Each program maps the same repo from a made-up home of its
# own, and the two are compared:
#   - what the Rust program says is what the Goose program says in the part
#     of the map that is carried (it stops with exit 70 where the carrying
#     has got to): the lines of the report that part writes (OPENING below),
#     all of them and no others, and the start of standard error; when it
#     ends another way, all that is said and the exit code;
#   - the files of the map folder that the carried part writes or removes
#     (WRITTEN below) are there or not in both, with the same bytes; when
#     the Rust program ends as the Goose program does, the whole folder.
# The repos are made up here to hold the corners of what is carried: what
# git ignores, which languages a repo holds, a virtualenv, the survey (with
# a made-up spread-wings that says what each case needs), an older map and
# a clean one. Some fixtures are mapped too.
#
#   scripts/port-map.sh
#
# The Goose program runs every indexer for each repo, which takes a minute
# or two in all, so what it said and wrote is kept in build/port-map/ and
# used again while the Goose program and this script are the same. Nothing
# is written outside build/port-map/, and the seal is never loosened but
# for the made-up repos this script trusts by name.
#
# SWAN_OLD (default bin/swan), SWAN_NEW (default build/rust/release/swan).
# Prints one "DIFFERENT (<case>)" block for each disagreement, then "the
# same: N of N" or "DIFFERENT: K of N".
# Exit 0: all the same. 1: some differ. 2: a comparison could not be made.
set -uo pipefail
cd "$(dirname "$0")/.."
here=$PWD
export LC_ALL=C
old=${SWAN_OLD:-bin/swan}
new=${SWAN_NEW:-build/rust/release/swan}
[ -x "$old" ] || { echo "port-map: no Goose program at $old"; exit 2; }
[ -x "$new" ] || { echo "port-map: no Rust program at $new"; exit 2; }
for f in bin/eggshell bin/spread-wings bin/swan-flatten; do [ -x "$f" ] || { echo "port-map: no $f (scripts/build.sh)"; exit 2; }; done
command -v sqlite3 >/dev/null || { echo "port-map: sqlite3 is needed"; exit 2; }

# Everything of one Goose program and one state of this script lives in one
# folder, at the same path every run: the made-up repos, the Goose program's
# home and what it said of each case.
key=$( { sha256sum <"$old"; sha256sum <"$0"; } | sha256sum | cut -c1-16)
base="$here/build/port-map/$key"
mkdir -p "$base"
# What an earlier Goose program or state of this script left is of no use.
find "$here/build/port-map" -mindepth 1 -maxdepth 1 -type d ! -name "$key" ! -name 'run.*' -mmin +30 -exec rm -rf {} + 2>/dev/null
work=$(mktemp -d "$here/build/port-map/run.XXXXXX")
trap 'chmod -R u+rwx "${work:?}" 2>/dev/null; rm -rf "${work:?}"' EXIT
r="$base/repos"

put() { mkdir -p "$(dirname "$1")"; cat >"$1"; }

# ---- the two homes ----
# The Goose program maps for real, so its home holds the indexers: links to
# this checkout's, except the files a map may patch, which are copies.
if [ ! -e "$base/old/home/ready" ]; then
    rm -rf "${base:?}/old"
    mkdir -p "$base/old/home/bin"
    cp bin/eggshell bin/spread-wings bin/swan-flatten "$base/old/home/bin/"
    cp "$old" "$base/old/home/bin/swan"
    ln -s "$here/.tools" "$base/old/home/.tools"
    cp -al "$here/tools" "$base/old/home/tools"
    for f in scip-python/dist/pyright-internal.js scip-python/dist/scip-python.js scip-python/dist/.swan-reach-patch \
             scip-python/dist/.swan-site-patch scip-typescript/dist/src/FileIndexer.js scip-typescript/dist/src/.swan-stable-names; do
        [ -e "tools/node_modules/@sourcegraph/$f" ] && cp --remove-destination "tools/node_modules/@sourcegraph/$f" "$base/old/home/tools/node_modules/@sourcegraph/$f"
    done
    : >"$base/old/home/ready"
fi
# The Rust program needs, so far, only what its home's bin/ holds.
mkdir -p "$work/new/home/bin"
cp bin/eggshell bin/spread-wings bin/swan-flatten "$work/new/home/bin/"
cp "$new" "$work/new/home/bin/swan"
ln -s "$here/.tools" "$work/new/home/.tools"
ln -s "$here/tools" "$work/new/home/tools"

# ---- made-up repos, made once ----
if [ ! -e "$r/ready" ]; then
    rm -rf "${r:?}"
    # A file of each kind a map tells apart.
    for f in a.ts b.js c.py d.rs E.java f.kt g.cu h.c i.h j.go k.goose l.lua m.glsl n.gd O.cs p.php q.wgsl r.hlsl s.sh t.pyi u.hxx; do printf '\n' | put "$r/langs/$f"; done
    printf 'all:\n' | put "$r/langs/Makefile"
    printf '[package]\nname = "langs"\nversion = "0.1.0"\nedition = "2021"\n[[bin]]\nname = "langs"\npath = "d.rs"\n' | put "$r/langs/Cargo.toml"
    printf 'fn main() {}\n' >"$r/langs/d.rs"
    printf 'export const a = 1;\n' | put "$r/plain/a.ts"
    # The order other languages are named in: the order a walk meets them.
    printf '\n' | put "$r/order/z.lua"; printf '\n' | put "$r/order/sub/a.gd"; printf '\n' | put "$r/order/sub/deeper/b.php"; printf '\n' | put "$r/order/a/c.wgsl"; printf '\n' | put "$r/order/sub/y.lua"
    printf '\n' | put "$r/go-first/a.go"; printf '\n' | put "$r/go-first/b.goose"
    printf '\n' | put "$r/goose-first/a.goose"; printf '\n' | put "$r/goose-first/b.go"
    printf '\n' | put "$r/goose-only/a.goose"; printf '\n' | put "$r/goose-only/c.goose"
    printf 'fn f() {}\n' | put "$r/rs-only/a.rs"
    printf 'x\n' | put "$r/scripts-dot/scripts/notes.txt"
    # Scripts with no ending count where they sit in bin/ or scripts/.
    printf 'x\n' | put "$r/scripts-only/scripts/run"; printf 'x\n' | put "$r/scripts-only/notes"
    printf 'x\n' | put "$r/no-scripts/tools/run"
    # A manifest with no source beside it, and nothing a map knows at all.
    printf '[package]\nname = "c"\nversion = "0.1.0"\n' | put "$r/cargo-only/Cargo.toml"
    printf 'words\n' | put "$r/nothing/README"
    # A virtualenv inside the repo, under each name.
    printf 'x = 1\n' | put "$r/venv-dot/a.py"; printf 'home = /usr/bin\nversion = 3.12.0\n' | put "$r/venv-dot/.venv/pyvenv.cfg"
    printf 'x = 1\n' | put "$r/venv-plain/a.py"; printf 'home = /usr/bin\n' | put "$r/venv-plain/venv/pyvenv.cfg"
    printf 'x = 1\n' | put "$r/venv-both/a.py"; printf 'home = /usr/bin\n' | put "$r/venv-both/venv/pyvenv.cfg"; printf 'home = /usr/bin\n' | put "$r/venv-both/.venv/pyvenv.cfg"
    # What git ignores: folders a walk would reach, folders it would not,
    # files, and names with a space.
    printf 'echo hi\n' | put "$r/ign/keep.sh"
    for d in out a/gen .cache node_modules/x "with space" deep/x/y; do printf 'echo ignored\n' | put "$r/ign/$d/f.sh"; done
    printf 'log\n' | put "$r/ign/build.log"; printf 'x = 1\n' | put "$r/ign/out/gen.py"
    printf 'out/\na/gen/\n.cache/\nnode_modules/\n*.log\nwith space/\ndeep/x/y/\n' >"$r/ign/.gitignore"
    git -C "$r/ign" init -q
    printf 'echo hi\n' | put "$r/ign-one/keep.sh"; printf 'echo ignored\n' | put "$r/ign-one/out/f.sh"; printf 'out/\n' >"$r/ign-one/.gitignore"
    git -C "$r/ign-one" init -q
    printf 'echo hi\n' | put "$r/ign-many/keep.sh"
    for i in 1 2 3 4 5 6 7 8; do printf 'echo ignored\n' | put "$r/ign-many/gen$i/f.sh"; printf 'gen%s/\n' "$i" >>"$r/ign-many/.gitignore"; done
    git -C "$r/ign-many" init -q
    printf 'echo hi\n' | put "$r/ign-none/keep.sh"; git -C "$r/ign-none" init -q
    # .git as a file: one that names nothing, and one that names a real one.
    printf 'echo hi\n' | put "$r/git-file/keep.sh"; printf 'gitdir: /nowhere/at/all\n' >"$r/git-file/.git"
    printf 'echo hi\n' | put "$r/git-apart/keep.sh"; printf 'echo ignored\n' | put "$r/git-apart/out/f.sh"; printf 'out/\n' >"$r/git-apart/.gitignore"
    git init -q --separate-git-dir "$r/git-apart.git" "$r/git-apart"
    # Projects for the real survey: node with and without its packages.
    printf '{"name":"a","version":"1.0.0"}\n' | put "$r/node-two/a/package.json"; printf 'export const a = 1;\n' | put "$r/node-two/a/index.js"
    printf '{"name":"b","version":"1.0.0"}\n' | put "$r/node-two/b/package.json"; printf 'export const b = 1;\n' | put "$r/node-two/b/index.js"
    mkdir -p "$r/node-two/b/node_modules/dep"; printf '{"name":"dep","version":"1.0.0"}\n' >"$r/node-two/b/node_modules/dep/package.json"
    # A made-up spread-wings for each thing a survey can say.
    sw() { put "$r/sw/$1"; chmod +x "$r/sw/$1"; }
    sw kinds <<'EOF'
#!/bin/sh
cat <<'JSON'
{"root":"x","projects":[
 {"kind":"node","path":".","package_manager":{"name":"pnpm"},"dependencies_installed":{"installed":false}},
 {"kind":"node","path":"web","package_manager":{"name":"bun"},"dependencies_installed":{"installed":true}},
 {"kind":"node","path":"web/app","package_manager":{"name":"pnpm"},"dependencies_installed":{}},
 {"kind":"node","path":"out/built","package_manager":{"name":"yarn"},"dependencies_installed":{"installed":false}},
 {"kind":"node","path":"outside","package_manager":{"name":""}},
 {"kind":"node","path":"node_modules/x","package_manager":{"name":"npm"}},
 {"kind":"python","path":"a/gen","package_manager":{"name":"poetry"}},
 {"kind":"python","path":"out","package_manager":{"name":"hatch"}},
 {"kind":"python","path":"py","package_manager":{"name":"uv"}},
 {"kind":"python","path":"py2","package_manager":{"name":"pip"}},
 {"kind":"python","path":"py3"},
 {"kind":"rust","path":"crate"},
 {"kind":"go","path":"svc","package_manager":{"name":"go"}},
 {"kind":"java","path":"jvm","package_manager":{"name":"gradle"}},
 {"kind":"deno","path":"edge"},
 {"kind":"swift","path":"ios"},
 {"kind":7,"path":"odd"},
 {"kind":"go"},
 {"path":"nameless"}
]}
JSON
EOF
    sw one-pnp <<'EOF'
#!/bin/sh
printf '%s' '{"projects":[{"kind":"node","path":".","package_manager":{"name":"pnpm"}},{"kind":"node","path":"b","package_manager":{"name":"pn"}},{"kind":"node","path":"c","package_manager":{"name":"pnpm"}}]}'
EOF
    sw all-installed <<'EOF'
#!/bin/sh
printf '%s\n' '{"projects":[{"kind":"node","path":".","dependencies_installed":{"installed":true}}]}'
EOF
    sw json-exit1 <<'EOF'
#!/bin/sh
printf '%s\n' '{"projects":[{"kind":"go","path":"."}]}'
exit 1
EOF
    sw probe <<'EOF'
#!/bin/sh
# Says whether it runs sealed: sealed, /run holds nothing.
if [ -z "$(ls -A /run 2>/dev/null)" ]; then how=sealed; else how=open; fi
printf '{"projects":[{"kind":"go","path":"%s"}]}\n' "$how"
EOF
    sw none <<'EOF'
#!/bin/sh
printf '%s\n' '{"projects":[]}'
EOF
    sw unknown-only <<'EOF'
#!/bin/sh
printf '%s\n' '{"projects":[{"kind":"swift","path":"ios"}]}'
EOF
    sw no-projects <<'EOF'
#!/bin/sh
printf '%s\n' '{"other":1}'
EOF
    sw projects-not-a-list <<'EOF'
#!/bin/sh
printf '%s\n' '{"projects":"none"}'
EOF
    sw not-json <<'EOF'
#!/bin/sh
echo "hello"
echo "and a complaint" >&2
EOF
    sw bad-json <<'EOF'
#!/bin/sh
printf '%s\n' '{"projects":[{"kind":"node","path":"."},]}'
EOF
    sw nothing <<'EOF'
#!/bin/sh
exit 0
EOF
    sw exit3 <<'EOF'
#!/bin/sh
i=0; while [ $i -lt 30 ]; do echo "line $i of what went wrong" >&2; i=$((i + 1)); done
exit 3
EOF
    sw usage <<'EOF'
#!/bin/sh
echo "usage: spread-wings index <repo> <graph.db>" >&2
exit 2
EOF
    sw usage-out <<'EOF'
#!/bin/sh
echo "usage: spread-wings index <repo> <graph.db>"
exit 0
EOF
    : >"$r/ready"
fi

# ---- running a case ----
# What the carried part of a map writes into the map folder. A case that
# starts from a folder with files in it (PREP) also watches three it
# removes or leaves, which no later part makes again for a repo with no
# Python.
WRITTEN="git-ignored.txt git-ignored-all.txt survey.json scip-started"
# The lines of the report the carried part writes: the Goose program's
# report starts with these, and the Rust program's is these and no more.
# The last is the made-up spread-wings' own complaint, which runs over
# several lines inside "projects: not surveyed (...)".
OPENING='^(languages:|not mapped, git ignores |projects: |node: dependencies are not installed |map schema |clean rebuild: cached |line [0-9]+ of what went wrong)'
WATCHED="python-files.tsv python-pieces.tsv other.txt"
total=0; bad=0
tidy() { sed -E -e 's/ in [0-9]+ ms$//' -e 's/^(.*): [0-9]+ ms$/\1: N ms/' -e 's/^(.*): exit (-?[0-9]+) after [0-9]+ ms$/\1: exit \2 after N ms/' -e "s|$2|<its folder>|g" -e 's/^goose runtime error: //' -e '$s/ \([^()]*\.goose:[0-9]+\)$//' "$1"; }
# case_of <name> <repo> [--clean] [NAME=value...]: both programs map the
# repo into maps/<name> of their own folder. PREP names a function that
# fills that folder first.
case_of() {
    local name=$1 repo=$2; shift 2
    local clean=()
    if [ "${1:-}" = --clean ]; then clean=(--clean); shift; fi
    total=$((total + 1))
    local kept="$base/said/$name"
    if [ ! -e "$kept/code" ]; then
        rm -rf "${kept:?}" "${base:?}/old/maps/$name"
        mkdir -p "$kept" "$base/old/maps"
        [ -n "${PREP:-}" ] && "$PREP" "$base/old/maps/$name"
        if [ -n "${LISTED:-}" ]; then mkdir -p "$base/old/home/data"; printf '%s\n' "$LISTED" >"$base/old/home/data/trusted-repos"; fi
        (cd "$base/old" && env -u SWAN_SPREAD_WINGS -u SWAN_TRUST_BUILD -u SWAN_SANDBOX "$@" home/bin/swan map "$repo" "maps/$name" "${clean[@]}" >"$kept/out" 2>"$kept/err" </dev/null; echo $? >"$kept/code.tmp")
        rm -rf "${base:?}/old/home/data"
        mv "$kept/code.tmp" "$kept/code"
    fi
    rm -rf "${work:?}/new/maps/$name"; mkdir -p "$work/new/maps"
    [ -n "${PREP:-}" ] && "$PREP" "$work/new/maps/$name"
    if [ -n "${LISTED:-}" ]; then mkdir -p "$work/new/home/data"; printf '%s\n' "$LISTED" >"$work/new/home/data/trusted-repos"; fi
    (cd "$work/new" && env -u SWAN_SPREAD_WINGS -u SWAN_TRUST_BUILD -u SWAN_SANDBOX "$@" home/bin/swan map "$repo" "maps/$name" "${clean[@]}" >"$work/out" 2>"$work/err" </dev/null); local code=$?
    rm -rf "${work:?}/new/home/data"
    local old_code; old_code=$(cat "$kept/code")
    tidy "$kept/out" "$base/old" >"$work/old.out"; tidy "$kept/err" "$base/old" >"$work/old.err"
    tidy "$work/out" "$work/new" >"$work/new.out"; tidy "$work/err" "$work/new" >"$work/new.err"
    local why=""
    if [ "$code" = 70 ]; then
        # The carried part: what it printed, less the line end print adds,
        # is the opening of what the Goose program printed, whole; and its
        # standard error, less the line that says where the carrying stops,
        # starts the Goose program's.
        head -c -1 "$work/new.out" >"$work/new.out.cut"
        grep -v '^swan (rust): map is not carried over yet' "$work/new.err" >"$work/new.err.cut"
        awk -v opening="$OPENING" '$0 !~ opening { exit } { print }' "$work/old.out" >"$work/old.out.cut"
        cmp -s "$work/new.out.cut" "$work/old.out.cut" || why="the opening of its report is not the Goose program's"
        [ -n "$why" ] || [ -s "$work/new.err.cut" ] || why="it says nothing on standard error"
        [ -n "$why" ] || cmp -s "$work/new.err.cut" <(head -c "$(stat -c %s "$work/new.err.cut")" "$work/old.err") || why="its standard error so far is not the Goose program's"
    else
        cmp -s "$work/new.out" "$work/old.out" || why="standard output differs"
        [ -n "$why" ] || cmp -s "$work/new.err" "$work/old.err" || why="standard error differs"
        [ -n "$why" ] || [ "$code" = "$old_code" ] || why="exit code differs: Goose $old_code, Rust $code"
    fi
    local n="$work/new/maps/$name" o="$base/old/maps/$name" f
    if [ -z "$why" ] && [ "$code" = 70 ]; then
        for f in $WRITTEN ${PREP:+$WATCHED}; do
            if { [ -e "$n/$f" ] && [ ! -e "$o/$f" ]; } || { [ ! -e "$n/$f" ] && [ -e "$o/$f" ]; }; then
                why="the map folder's $f is there for one program only"; break
            fi
            if [ -e "$n/$f" ] && ! cmp -s "$n/$f" "$o/$f"; then why="the map folder's $f differs"; break; fi
        done
    elif [ -z "$why" ] && { [ -d "$n" ] || [ -d "$o" ]; }; then
        diff -r -x swan.db.lock "$n" "$o" >"$work/d" 2>&1 || why="the map folders differ: $(head -2 "$work/d" | tr '\n' ' ' | sed "s|$work/new|<Rust>|g; s|$base/old|<Goose>|g" | cut -c1-200)"
    fi
    if [ -n "$why" ]; then
        bad=$((bad + 1)); echo "DIFFERENT ($name)"; echo "    $why"
        echo "    Goose (exit $old_code):"; head -5 "$work/old.out" | cut -c1-200 | sed 's/^/      /'; head -3 "$work/old.err" | cut -c1-200 | sed 's/^/      ! /'
        echo "    Rust (exit $code):"; head -5 "$work/new.out" | cut -c1-200 | sed 's/^/      /'; head -3 "$work/new.err" | cut -c1-200 | sed 's/^/      ! /'
    fi
}

# ---- what a repo holds ----
case_of plain "$r/plain"
case_of langs "$r/langs"
case_of order "$r/order"
case_of go-first "$r/go-first"
case_of goose-first "$r/goose-first"
case_of goose-only "$r/goose-only"
case_of rs-only "$r/rs-only"
case_of scripts-dot "$r/scripts-dot"
case_of scripts-only "$r/scripts-only"
case_of no-scripts "$r/no-scripts"
case_of cargo-only "$r/cargo-only"
case_of nothing "$r/nothing"
case_of slashes "$r/plain///"
case_of not-there "$r/not-there"
case_of a-file "$r/plain/a.ts"
# ---- a virtualenv: named only once the repo is trusted ----
case_of venv-dot "$r/venv-dot"
case_of venv-dot-trusted "$r/venv-dot" SWAN_TRUST_BUILD=1
case_of venv-plain-trusted "$r/venv-plain" SWAN_TRUST_BUILD=1
case_of venv-both-trusted "$r/venv-both" SWAN_TRUST_BUILD=1
case_of venv-trust-not-1 "$r/venv-dot" SWAN_TRUST_BUILD=yes
LISTED="$r/venv-dot" case_of venv-dot-listed "$r/venv-dot"
LISTED="$r/venv-dot-more" case_of venv-dot-listed-longer "$r/venv-dot"
# ---- what git ignores ----
case_of ign "$r/ign"
case_of ign-one "$r/ign-one"
case_of ign-many "$r/ign-many"
case_of ign-none "$r/ign-none"
case_of git-file "$r/git-file"
case_of git-apart "$r/git-apart"
case_of ign-unsealed "$r/ign" SWAN_SANDBOX=0
# ---- the survey ----
case_of node-two "$r/node-two"
case_of sw-kinds "$r/plain" "SWAN_SPREAD_WINGS=$r/sw/kinds"
case_of sw-kinds-ignored "$r/ign" "SWAN_SPREAD_WINGS=$r/sw/kinds"
case_of sw-probe "$r/plain" "SWAN_SPREAD_WINGS=$r/sw/probe"
case_of sw-probe-unsealed "$r/plain" "SWAN_SPREAD_WINGS=$r/sw/probe" SWAN_SANDBOX=0
case_of sw-probe-sandbox-1 "$r/plain" "SWAN_SPREAD_WINGS=$r/sw/probe" SWAN_SANDBOX=1
for s in all-installed json-exit1 one-pnp none unknown-only no-projects projects-not-a-list not-json bad-json nothing exit3 usage usage-out; do
    case_of "sw-$s" "$r/plain" "SWAN_SPREAD_WINGS=$r/sw/$s"
done
case_of sw-not-there "$r/plain" "SWAN_SPREAD_WINGS=$r/sw/not-there"
case_of sw-empty-name "$r/plain" SWAN_SPREAD_WINGS=
# ---- an older map, a clean one, a map folder that cannot be one ----
# A map of plain, made by the Goose program, to start from.
if [ ! -e "$base/plain-map/swan.db" ]; then
    rm -rf "${base:?}/plain-map"
    (cd "$base/old" && home/bin/swan map "$r/plain" "$base/plain-map" >/dev/null 2>&1 </dev/null)
    [ -e "$base/plain-map/swan.db" ] || { echo "port-map: the Goose program made no map of the plain repo"; exit 2; }
fi
prep_plain() { cp -r "$base/plain-map" "$1"; }
prep_older() { cp -r "$base/plain-map" "$1"; sqlite3 "$1/swan.db" "UPDATE meta SET value = '8' WHERE key = 'schema_version'"; }
prep_no_version() { cp -r "$base/plain-map" "$1"; sqlite3 "$1/swan.db" "DELETE FROM meta WHERE key = 'schema_version'"; }
prep_no_root() { cp -r "$base/plain-map" "$1"; sqlite3 "$1/swan.db" "DELETE FROM meta WHERE key = 'root'"; }
prep_garbage() { mkdir -p "$1"; printf 'this is no database\n' >"$1/swan.db"; }
prep_caches() { cp -r "$base/plain-map" "$1"; for f in index-manifest.tsv tsc-files.txt typescript-layers.txt python-files.tsv python-pieces.tsv other.txt; do printf 'old\n' >"$1/$f"; done; }
prep_older_caches() { prep_caches "$1"; sqlite3 "$1/swan.db" "UPDATE meta SET value = '8' WHERE key = 'schema_version'"; }
prep_file() { printf 'a file\n' >"$1"; }
case_of clean-fresh "$r/plain" --clean
PREP=prep_plain case_of again "$r/plain"
PREP=prep_plain case_of clean-same-root "$r/plain" --clean
PREP=prep_plain case_of clean-other-root "$r/order" --clean
PREP=prep_no_root case_of clean-no-root "$r/plain" --clean
PREP=prep_garbage case_of clean-garbage "$r/plain" --clean
PREP=prep_garbage case_of garbage "$r/plain"
PREP=prep_older case_of older "$r/plain"
PREP=prep_older case_of clean-older "$r/plain" --clean
PREP=prep_no_version case_of no-version "$r/plain"
PREP=prep_caches case_of clean-caches "$r/plain" --clean
PREP=prep_caches case_of caches-kept "$r/plain"
PREP=prep_older_caches case_of older-caches "$r/plain"
PREP=prep_file case_of out-is-a-file "$r/plain"
# ---- fixtures ----
for f in tiny-ts tiny-py tiny-go tiny-rs tiny-java tiny-lua tiny-game go-modules; do
    [ -d "fixtures/$f" ] && case_of "fixture-$f" "$here/fixtures/$f"
done

if [ $bad = 0 ]; then echo "the same: $total of $total"; exit 0; fi
echo "DIFFERENT: $bad of $total"
exit 1
