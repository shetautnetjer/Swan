#!/usr/bin/env bash
# Stage 4's judge for `swan map` (docs/rust-port.md), for as much of the map
# as is carried. Each program maps the same repo from a made-up home of its
# own, and the two are compared:
#   - what the Rust program says is what the Goose program says in the part
#     of the map that is carried (it stops with exit 70 where the carrying
#     has got to): the lines of the report that part writes (OPENING below)
#     and the accounts of the steps it runs (STEPS below), all of them and
#     no others; when it ends another way, all that is said and the exit
#     code;
#   - the files of the map folder that the carried part writes or removes
#     (WRITTEN below; CACHED too, but for a clean map, which holds those
#     back until it ends and must not have them yet) are there or not in
#     both, with the same bytes, and
#     the texts it keeps (texts/) are the Goose program's: the same for a new
#     map (but for those a later part keeps, of files no walk reaches); for
#     a map over an older one, at least those, since the Goose program drops
#     the ones no record names when it ends. When the Rust program ends as
#     the Goose program does, the whole folder;
#   - the indexers in its home are left as the Goose program leaves them:
#     TypeScript's file and scip-python's two, patched or not, marked or not.
# The repos are made up here to hold the corners of what is carried: what
# git ignores, which languages a repo holds, a virtualenv, the survey (with
# a made-up spread-wings that says what each case needs), an older map and
# a clean one, the content stamps (enough files to start workers, a second
# map, an edit of a comment only, a file whose indexed text is unknown),
# and TypeScript's config, tsc's list of files and the projects of a repo
# (with the real tsc, and with a made-up one that says what each case
# needs), and Python's pieces (a virtualenv read and not run, one run once
# the repo is trusted, the survey's virtualenvs, a src layout, which pieces
# are kept on a second map). Some fixtures are mapped too.
#
#   scripts/port-map.sh
#
# The Goose program runs every indexer for each repo, which takes some
# minutes in all, so what it said and wrote is kept in build/port-map/ and
# used again while the Goose program, the made-up repos and the case are
# the same. The Rust program's cases run side by side, PORT_MAP_JOBS at a
# time (default 8). Nothing is written outside build/port-map/, and the seal
# is never loosened but for the made-up repos this script trusts by name.
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

put() { mkdir -p "$(dirname "$1")"; cat >"$1"; }
# pkg <site-packages> <name> <version>: a package as pip leaves it there.
pkg() {
    printf 'Metadata-Version: 2.1\nName: %s\nVersion: %s\n' "$2" "$3" | put "$1/$2-$3.dist-info/METADATA"
    printf '%s/__init__.py,,\n%s-%s.dist-info/METADATA,,\n' "$2" "$2" "$3" >"$1/$2-$3.dist-info/RECORD"
    printf 'def %s():\n    return 1\n' "$2" | put "$1/$2/__init__.py"
}
# pyf <file> <bytes> <text>: a Python file of exactly that size, the text and then a comment.
pyf() { local have; mkdir -p "$(dirname "$1")"; printf "$3" >"$1"; have=$(stat -c %s "$1"); printf '# %0*d\n' $(($2 - have - 3)) 0 >>"$1"; }
TSI='tools/node_modules/@sourcegraph/scip-typescript/dist/src'
PYD='tools/node_modules/@sourcegraph/scip-python/dist'

# ---- the homes ----
# Each program maps from a made-up home of its own: its programs in bin/,
# and tools/ as this checkout's, by links, but for what a map may change
# (the TypeScript indexer's package, whose FileIndexer.js it patches, and
# scip-python's, whose pyright-internal.js and scip-python.js it patches)
# and what a case may swap for a made-up one (tsc, in node_modules/.bin):
# those are the home's own. The Goose program has one home, kept; the Rust program
# gets a new one for every case, so that its cases can run side by side.
# home_of <folder> <the folder its programs are in>
home_of() {
    local h=$1 e
    mkdir -p "$h/bin" "$h/tools/node_modules/@sourcegraph"
    ln "$2"/* "$h/bin/"
    ln -s "$here/.tools" "$h/.tools"
    for e in "$here"/tools/*; do [ "${e##*/}" = node_modules ] || ln -s "$e" "$h/tools/"; done
    for e in "$here"/tools/node_modules/* "$here"/tools/node_modules/.[!.]*; do
        case "${e##*/}" in .bin | @sourcegraph) ;; *) ln -s "$e" "$h/tools/node_modules/" ;; esac
    done
    cp -a "$here/tools/node_modules/.bin" "$h/tools/node_modules/.bin"
    for e in "$here"/tools/node_modules/@sourcegraph/*; do case "${e##*/}" in scip-typescript | scip-python) ;; *) ln -s "$e" "$h/tools/node_modules/@sourcegraph/" ;; esac; done
    cp -al "$here/tools/node_modules/@sourcegraph/scip-typescript" "$h/tools/node_modules/@sourcegraph/scip-typescript"
    # scip-python's package: its files as hard links, its folders (the
    # typeshed, thousands of files) as links. The two files a map patches
    # and their marks are made the home's own by home_as_installed.
    mkdir -p "$h/$PYD"
    for e in "$here/${PYD%/dist}"/*; do
        [ "${e##*/}" = dist ] && continue
        if [ -d "$e" ]; then ln -s "$e" "$h/${PYD%/dist}/"; else ln "$e" "$h/${PYD%/dist}/"; fi
    done
    for e in "$here/$PYD"/*; do if [ -d "$e" ]; then ln -s "$e" "$h/$PYD/"; else ln "$e" "$h/$PYD/"; fi; done
    home_as_installed "$h"
}
# As Swan's installer leaves a home: the indexers patched and marked so, and
# the real tsc. The files are the home's own, never a link to the checkout's.
home_as_installed() {
    rm -f "$1/$TSI/FileIndexer.js" "$1/$TSI/.swan-stable-names" "$1/tools/node_modules/.bin/tsc"
    rm -rf "$1/tools/node_modules/.bin/tsc-says"
    cp "$base/ts-indexer.patched" "$1/$TSI/FileIndexer.js"
    printf '%s stable' "$(stat -c %s "$base/ts-indexer.patched")" >"$1/$TSI/.swan-stable-names"
    ln -s ../typescript/bin/tsc "$1/tools/node_modules/.bin/tsc"
    rm -f "$1/$PYD/pyright-internal.js" "$1/$PYD/scip-python.js" "$1/$PYD/.swan-reach-patch" "$1/$PYD/.swan-site-patch"
    cp "$base/py-reach.patched" "$1/$PYD/pyright-internal.js"; cp "$base/py-site.patched" "$1/$PYD/scip-python.js"
    printf '%s' "$(stat -c %s "$base/py-reach.patched")" >"$1/$PYD/.swan-reach-patch"
    printf '%s' "$(stat -c %s "$base/py-site.patched")" >"$1/$PYD/.swan-site-patch"
}
# What a case may do to a home before a map (HOME_PREP="<function> [word]").
home_plain() { rm -f "$1/$TSI/FileIndexer.js" "$1/$TSI/.swan-stable-names"; cp "$base/ts-indexer.plain" "$1/$TSI/FileIndexer.js"; }
home_plain_marked() { home_plain "$1"; printf '%s stable' "$(stat -c %s "$base/ts-indexer.plain")" >"$1/$TSI/.swan-stable-names"; }
home_unmarked() { rm -f "$1/$TSI/.swan-stable-names"; }
home_mark() { rm -f "$2/$TSI/.swan-stable-names"; printf "$1" "$(stat -c %s "$base/ts-indexer.patched")" >"$2/$TSI/.swan-stable-names"; }
home_no_indexer() { rm -f "$1/$TSI/FileIndexer.js" "$1/$TSI/.swan-stable-names"; }
home_empty_indexer() { home_no_indexer "$1"; : >"$1/$TSI/FileIndexer.js"; }
home_half_indexer() { home_no_indexer "$1"; head -c $(($(stat -c %s "$base/ts-indexer.plain") / 2)) "$base/ts-indexer.plain" >"$1/$TSI/FileIndexer.js"; }
# home_tsc <what it says> <home>: a made-up tsc, which says what $r/tsc/<name>/ holds.
home_tsc() {
    rm -f "$2/tools/node_modules/.bin/tsc"
    cp "$r/tsc/tsc" "$2/tools/node_modules/.bin/tsc"
    cp -r "$r/tsc/$1" "$2/tools/node_modules/.bin/tsc-says"
}
# How the indexers were left: their bytes, and their marks.
home_state() {
    local f
    if [ -e "$1/$TSI/FileIndexer.js" ]; then sha256sum <"$1/$TSI/FileIndexer.js"; else echo "no indexer"; fi
    if [ -e "$1/$TSI/.swan-stable-names" ]; then cat "$1/$TSI/.swan-stable-names"; echo; else echo "no mark"; fi
    for f in pyright-internal.js scip-python.js; do if [ -e "$1/$PYD/$f" ]; then sha256sum <"$1/$PYD/$f"; else echo "no $f"; fi; done
    for f in .swan-reach-patch .swan-site-patch; do if [ -e "$1/$PYD/$f" ]; then echo "$f: $(cat "$1/$PYD/$f" | od -An -c | tr -s ' \n' ' ')"; else echo "no $f"; fi; done
}

# ---- made-up repos, made once ----
make_repos() {
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
    # Enough Python files to start stamp workers by the usual floor of 256.
    mkdir -p "$r/py-many/pkg"
    for i in $(seq 1 300); do printf 'def f%s(x):\n    return x + %s\n' "$i" "$i" >"$r/py-many/pkg/m$i.py"; done
    # One program four ways: as first mapped, with a comment changed, with
    # its code changed, and with another file beside it.
    printf '// first\nexport function add(a: number, b: number): number { return a + b; }\n' | put "$r/cos/a.ts"
    printf '# first\ndef add(a, b):\n    return a + b\n' | put "$r/cos/b.py"
    cp -r "$r/cos" "$r/cos-comment"; printf '// second, and longer\nexport function add(a: number, b: number): number { return a + b; }\n' >"$r/cos-comment/a.ts"
    printf '# second, and longer\ndef add(a, b):\n    return a + b\n' >"$r/cos-comment/b.py"
    cp -r "$r/cos" "$r/cos-code"; printf '// first\nexport function add(a: number, b: number): number { return a - b; }\n' >"$r/cos-code/a.ts"
    cp -r "$r/cos" "$r/cos-more"; printf 'export const more = 1;\n' >"$r/cos-more/c.ts"
    # A comment changed with the file's time kept, and one changed with its size kept.
    cp -r "$r/cos" "$r/cos-same-time"; printf '// second, and longer\nexport function add(a: number, b: number): number { return a + b; }\n' >"$r/cos-same-time/a.ts"
    touch -r "$r/cos/a.ts" "$r/cos-same-time/a.ts"
    cp -r "$r/cos" "$r/cos-same-size"; printf '// other\nexport function add(a: number, b: number): number { return a + b; }\n' >"$r/cos-same-size/a.ts"
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
    # ---- TypeScript: its config, and what tsc lists ----
    # A config of the repo's own, with a file outside what it includes.
    printf '{"compilerOptions":{"strict":true},"include":["src"]}\n' | put "$r/ts-config/tsconfig.json"
    printf 'export const a = 1;\n' | put "$r/ts-config/src/a.ts"
    printf 'import { a } from "./a";\nexport const b = a + 1;\n' | put "$r/ts-config/src/b.ts"
    printf 'export const outside = 1;\n' | put "$r/ts-config/tools/gen.ts"
    # Roots that import a file the config does not include.
    printf '{"include":["src"]}\n' | put "$r/ts-outside/tsconfig.json"
    printf 'import { l } from "../lib/l";\nexport const a = l;\n' | put "$r/ts-outside/src/a.ts"
    printf 'export const l = 1;\n' | put "$r/ts-outside/lib/l.ts"
    # Configs tsc cannot read: one that extends a package that is not there
    # (with sources, and alone), and one that takes in no file.
    printf '{"extends":"@nowhere/tsconfig/base.json","include":["src"]}\n' | put "$r/ts-config-bad/tsconfig.json"
    printf 'export const a = 1;\n' | put "$r/ts-config-bad/src/a.ts"
    printf '{"extends":"@nowhere/tsconfig/base.json"}\n' | put "$r/ts-config-bad-only/tsconfig.json"
    printf '{"include":["nothing"]}\n' | put "$r/ts-config-empty/tsconfig.json"; printf 'export const a = 1;\n' | put "$r/ts-config-empty/a.ts"
    # A type library that is not installed: tsc complains and lists the files all the same.
    printf '{"compilerOptions":{"types":["node"]},"include":["src"]}\n' | put "$r/ts-types-missing/tsconfig.json"
    printf 'export const a = 1;\n' | put "$r/ts-types-missing/src/a.ts"
    # More than one project: a tsconfig.json below the root, and a root that names another config.
    printf '{"include":["src"]}\n' | put "$r/ts-nested/tsconfig.json"; printf 'export const a = 1;\n' | put "$r/ts-nested/src/a.ts"
    printf '{"include":["*.ts"]}\n' | put "$r/ts-nested/packages/x/tsconfig.json"; printf 'export const x = 1;\n' | put "$r/ts-nested/packages/x/x.ts"
    printf '{"extends":"./tsconfig.json"}\n' | put "$r/ts-nested/packages/x/tsconfig.build.json"
    printf '{"include":["src"],"references":[{"path":"./tsconfig.lib.json"}]}\n' | put "$r/ts-refs/tsconfig.json"
    printf '{"compilerOptions":{"composite":true},"include":["lib"]}\n' | put "$r/ts-refs/tsconfig.lib.json"
    printf 'export const a = 1;\n' | put "$r/ts-refs/src/a.ts"; printf 'export const l = 1;\n' | put "$r/ts-refs/lib/l.ts"
    # Configs of another name, at the root and below it, make no second project.
    printf '{"include":["src"]}\n' | put "$r/ts-other-name/tsconfig.json"; printf '{"include":["src"]}\n' | put "$r/ts-other-name/tsconfig.app.json"
    printf '{"include":["*.ts"]}\n' | put "$r/ts-other-name/conf/tsconfig.app.json"; printf 'export const a = 1;\n' | put "$r/ts-other-name/src/a.ts"
    # JavaScript alone, and a file of every ending that counts, with one that does not.
    printf 'export const a = 1;\n' | put "$r/js-only/index.js"; printf 'export const u = 1;\n' | put "$r/js-only/lib/util.mjs"
    for f in a.ts b.tsx c.mts d.cts e.js f.jsx g.mjs h.cjs not.tsz; do printf 'export {};\n' | put "$r/ts-endings/$f"; done
    # What git ignores is left out of Swan's own config, whatever its name holds.
    printf 'export const a = 1;\n' | put "$r/ts-ign/a.ts"
    for d in out "with space" 'q"d'; do printf 'export const g = 1;\n' | put "$r/ts-ign/$d/gen.ts"; done
    printf 'out/\nwith space/\nq"d/\n' >"$r/ts-ign/.gitignore"; git -C "$r/ts-ign" init -q
    # TypeScript beside each language that takes a place of its own when indexers run side by side.
    for d in ts-cargo ts-java ts-c ts-cuda ts-c-cuda ts-rs ts-kt ts-py-seven; do printf 'export const a = 1;\n' | put "$r/$d/a.ts"; done
    cp "$r/langs/Cargo.toml" "$r/langs/d.rs" "$r/ts-cargo/"
    printf 'class E {}\n' >"$r/ts-java/E.java"
    printf 'int h(void) { return 0; }\n' >"$r/ts-c/h.c"; printf '\n' >"$r/ts-cuda/g.cu"
    printf 'int h(void) { return 0; }\n' >"$r/ts-c-cuda/h.c"; printf '\n' >"$r/ts-c-cuda/g.cu"
    printf 'fn f() {}\n' >"$r/ts-rs/d.rs"; printf 'fun f() {}\n' >"$r/ts-kt/f.kt"
    # Seven packages: one piece each when Python is planned for six places, one in all when for eight.
    for i in 0 1 2 3 4 5 6; do : | put "$r/ts-py-seven/p$i/__init__.py"; printf 'def f%s(x):\n    return x\n' "$i" >"$r/ts-py-seven/p$i/m.py"; done
    # Repos the Goose program maps once and that are changed after (make_before).
    for d in ts-edit-config ts-edit-pkg ts-edit-nested ts-edit-code ts-edit-touch ts-edit-more ts-edit-gone; do
        printf '{"include":["src"]}\n' | put "$r/$d/tsconfig.json"; printf '{"name":"e","version":"1.0.0"}\n' | put "$r/$d/package.json"
        printf 'export const a = 1;\n' | put "$r/$d/src/a.ts"; printf 'export const b = 1;\n' | put "$r/$d/src/b.ts"
    done
    printf '{"include":["*.ts"]}\n' | put "$r/ts-edit-nested/packages/x/tsconfig.json"; printf 'export const x = 1;\n' | put "$r/ts-edit-nested/packages/x/x.ts"
    # For the made-up tsc: sources with no config, the same with one, and a
    # repo for each thing that changes what a child is given. (Its answers
    # for the other projects are made further down, once it is there.)
    for d in ts-fake ts-fake-config; do
        printf 'export const a = 1;\n' | put "$r/$d/a.ts"; printf 'export const b = 1;\n' | put "$r/$d/b.ts"; printf 'export const c = 1;\n' | put "$r/$d/sub/c.ts"
    done
    ln -s a.ts "$r/ts-fake/link.ts"
    printf '{"include":["*.ts","sub"]}\n' >"$r/ts-fake-config/tsconfig.json"
    for d in ts-env ts-env-java ts-env-kt ts-env-c ts-env-cuda ts-env-cs ts-env-venv ts-env-all; do
        printf '{}\n' | put "$r/$d/tsconfig.json"; printf 'export const a = 1;\n' | put "$r/$d/a.ts"
    done
    printf 'class E {}\n' >"$r/ts-env-java/E.java"; printf 'fun f() {}\n' >"$r/ts-env-kt/f.kt"
    printf 'int h(void) { return 0; }\n' >"$r/ts-env-c/h.c"; printf '\n' >"$r/ts-env-cuda/g.cu"; printf 'class O {}\n' >"$r/ts-env-cs/O.cs"
    printf 'home = /usr/bin\n' | put "$r/ts-env-venv/.venv/pyvenv.cfg"
    printf 'class E {}\n' >"$r/ts-env-all/E.java"; printf 'int h(void) { return 0; }\n' >"$r/ts-env-all/h.c"; printf 'class O {}\n' >"$r/ts-env-all/O.cs"
    printf 'home = /usr/bin\n' | put "$r/ts-env-all/.venv/pyvenv.cfg"
    mkdir -p "$r/clangbin"; printf '#!/bin/sh\n' >"$r/clangbin/clang++"; chmod +x "$r/clangbin/clang++"
    # The made-up tsc. It says what the files in tsc-says/ beside it hold, for
    # the config it is asked about and for what it is asked (--showConfig,
    # --listFilesOnly): the file named for the config's folder and name
    # (show-x@tsconfig.json) if there is one, else the one for the repo's own
    # config or for the one Swan writes in the map folder (show-repo,
    # show-own). @REPO@ stands for the repo and @CFG@ for the config's
    # folder. With a file named env there, it first says what it was given
    # to run with; with one named needs-env, it answers only when it was
    # given what a child of the map is given.
    put "$r/tsc/tsc" <<'EOF'
#!/bin/sh
d=${0%/*}/tsc-says
cfg=$2
dir=${cfg%/*}
case "$cfg" in
    */tsproject/tsconfig.json) kind=own; repo=$(sed -n 's|.*"include":\["\(.*\)/\*\*/\*"\],"exclude".*|\1|p' "$cfg") ;;
    *) kind=repo; repo=$dir ;;
esac
case "$3" in --showConfig) what=show ;; --listFilesOnly) what=list ;; *) exit 64 ;; esac
if [ -e "$d/needs-env" ] && [ -z "${NODE_OPTIONS:-}" ]; then echo "made-up tsc: nothing given to run with" >&2; exit 9; fi
if [ -e "$d/env" ] && [ "$what-$kind" = show-repo ]; then
    printf 'PATH=%s NODE_OPTIONS=%s VIRTUAL_ENV=%s JAVA_HOME=%s\n' "$PATH" "${NODE_OPTIONS-unset}" "${VIRTUAL_ENV-unset}" "${JAVA_HOME-unset}"
fi
say=$what-$kind
[ -e "$d/$what-${dir##*/}@${cfg##*/}" ] && say=$what-${dir##*/}@${cfg##*/}
[ -e "$d/$say" ] && sed -e "s|@REPO@|$repo|g" -e "s|@CFG@|$dir|g" "$d/$say"
[ -e "$d/$say.err" ] && cat "$d/$say.err" >&2
exit "$(cat "$d/$say.code" 2>/dev/null || echo 0)"
EOF
    chmod +x "$r/tsc/tsc"
    says() { put "$r/tsc/$1/$2"; }
    : | says env env; echo 1 | says env show-repo.code
    # says_own <name> <exit of the list> <exit of the config>: the usual list
    # and config, for a repo with no config of its own; a case then changes one.
    says_own() {
        printf '@REPO@/a.ts\n@REPO@/b.ts\n@REPO@/sub/c.ts\n' | says "$1" list-own
        printf '{\n    "files": [\n        "@REPO@/b.ts",\n        "@REPO@/a.ts"\n    ]\n}\n' | says "$1" show-own
        echo "$2" | says "$1" list-own.code; echo "$3" | says "$1" show-own.code
    }
    says_own roots-good 0 0
    says_own show-fails 0 1
    says_own list-exit1 1 0
    says_own list-exit2 2 0
    says_own list-exit3 3 0
    says_own list-exit1-none 1 0; printf '/nowhere/a.ts\n' | says list-exit1-none list-own
    says_own list-exit1-prefix 1 0; printf '@REPO@-other/a.ts\n' | says list-exit1-prefix list-own
    says_own list-none 0 0; printf '/nowhere/a.ts\n' | says list-none list-own
    says_own show-none-listed 0 0; printf '{\n    "files": [\n        "@REPO@/zzz.ts"\n    ]\n}\n' | says show-none-listed show-own
    says_own show-no-files 0 0; printf '{\n    "include": [\n        "x"\n    ]\n}\n' | says show-no-files show-own
    says_own show-nospace 0 0; printf '{\n    "files":[\n        "@REPO@/a.ts"\n    ]\n}\n' | says show-nospace show-own
    says_own show-empty-files 0 0; printf '{\n    "files": [\n    ]\n}\n' | says show-empty-files show-own
    says_own show-unclosed 0 0; printf '{\n    "files": [\n        "@REPO@/a.ts",\n        "@REPO@/b.ts"' | says show-unclosed show-own
    says_own show-short 0 0; printf '{\n    "files": [\n        "@REPO@/a.ts",\n        ""\n    ]\n}\n' | says show-short show-own
    says_own show-unquoted 0 0; printf '{\n    "files": [\n        "@REPO@/b.ts",\n        @REPO@/a.ts"\n    ]\n}\n' | says show-unquoted show-own
    says_own show-unquoted-end 0 0; printf '{\n    "files": [\n        "@REPO@/b.ts",\n        "@REPO@/a.ts\n    ]\n}\n' | says show-unquoted-end show-own
    says_own show-backslash 0 0
    says show-backslash show-own <<'EOF'
{
    "files": [
        "@REPO@/b.ts",
        "C:\\repo\\a.ts"
    ]
}
EOF
    # Roots in the config's order, however tsc reached them; a path given
    # three ways; one real file listed under two names; names that are not
    # listed, or are nowhere.
    says roots-order list-own <<'EOF'
/nowhere/lib.es5.d.ts
@REPO@/sub/c.ts
  @REPO@/b.ts 	
@REPO@/a.ts
@CFG@/tsconfig.json

@REPO@/link.ts
EOF
    says roots-order show-own <<'EOF'
{
    "compilerOptions": {
        "allowJs": true
    },
    "files": [
        "./tsconfig.json",
        "@REPO@/b.ts",
        "tsconfig.json",
        "@REPO@/a.ts",
        "@REPO@/sub/c.ts",
        "@REPO@/not-listed.ts",
        "/nowhere/else.ts"
    ],
    "include": [
        "x"
    ]
}
EOF
    # The repo's own config: what is said of one tsc cannot read, and the
    # roots of one it can, given from the config's folder.
    probe() { printf "$2" | says "$1" show-repo; echo "$3" | says "$1" show-repo.code; }
    probe probe-first-line 'error TS5083: Cannot read file.\nsecond line\n' 1
    probe probe-leading-newline '\nA line\nB line\n' 1
    probe probe-no-newline 'only words' 2
    probe probe-spaces '   spaced out \t \nmore\n' 1
    probe probe-silent '' 1
    probe probe-stderr '' 1; printf 'words on standard error\n' | says probe-stderr show-repo.err
    probe probe-ok '{\n    "files": [\n        "./a.ts",\n        "sub/c.ts",\n        "sub/../b.ts",\n        "./gone.ts"\n    ]\n}\n' 0
    printf '@REPO@/b.ts\n@REPO@/gone.ts\n@REPO@/sub/c.ts\n@REPO@/a.ts\n/nowhere/lib.d.ts\n' | says probe-ok list-repo
    # ---- TypeScript: the other projects of a repo ----
    # A root that names two folders, each a project.
    printf '{"files":[],"references":[{"path":"./app"},{"path":"./node"}]}\n' | put "$r/ts-proj-dirs/tsconfig.json"
    printf '{"compilerOptions":{"composite":true},"include":["*.ts"]}\n' | put "$r/ts-proj-dirs/app/tsconfig.json"; printf 'export const a = 1;\n' | put "$r/ts-proj-dirs/app/a.ts"
    printf '{"compilerOptions":{"composite":true},"include":["*.ts"]}\n' | put "$r/ts-proj-dirs/node/tsconfig.json"; printf 'export const n = 1;\n' | put "$r/ts-proj-dirs/node/n.ts"
    # A config that names a config that names a third: each is followed.
    printf '{"include":["src"],"references":[{"path":"./tsconfig.a.json"}]}\n' | put "$r/ts-proj-chain/tsconfig.json"
    printf '{"compilerOptions":{"composite":true},"include":["a"],"references":[{"path":"./deep/tsconfig.b.json"}]}\n' | put "$r/ts-proj-chain/tsconfig.a.json"
    printf '{"compilerOptions":{"composite":true},"include":["b"]}\n' | put "$r/ts-proj-chain/deep/tsconfig.b.json"
    printf 'export const s = 1;\n' | put "$r/ts-proj-chain/src/s.ts"; printf 'export const a = 1;\n' | put "$r/ts-proj-chain/a/a.ts"; printf 'export const b = 1;\n' | put "$r/ts-proj-chain/deep/b/b.ts"
    # Configs tsc cannot read: one of two below the root, and the only one.
    printf '{"include":["src"]}\n' | put "$r/ts-proj-unread/tsconfig.json"; printf 'export const s = 1;\n' | put "$r/ts-proj-unread/src/s.ts"
    printf '{"include":["*.ts"]}\n' | put "$r/ts-proj-unread/packages/good/tsconfig.json"; printf 'export const g = 1;\n' | put "$r/ts-proj-unread/packages/good/g.ts"
    printf '{"extends":"@nowhere/tsconfig/base.json"}\n' | put "$r/ts-proj-unread/packages/bad/tsconfig.json"; printf 'export const b = 1;\n' | put "$r/ts-proj-unread/packages/bad/b.ts"
    printf '{"include":["src"]}\n' | put "$r/ts-proj-all-unread/tsconfig.json"; printf 'export const s = 1;\n' | put "$r/ts-proj-all-unread/src/s.ts"
    printf '{"extends":"@nowhere/tsconfig/base.json"}\n' | put "$r/ts-proj-all-unread/packages/bad/tsconfig.json"; printf 'export const b = 1;\n' | put "$r/ts-proj-all-unread/packages/bad/b.ts"
    # A file more than one config lists goes to the nearest above it.
    printf '{"include":["**/*.ts"]}\n' | put "$r/ts-proj-overlap/tsconfig.json"; printf 'export const s = 1;\n' | put "$r/ts-proj-overlap/src/s.ts"
    printf '{"include":["**/*.ts"]}\n' | put "$r/ts-proj-overlap/packages/tsconfig.json"; printf 'export const p = 1;\n' | put "$r/ts-proj-overlap/packages/p.ts"
    printf '{"include":["*.ts"]}\n' | put "$r/ts-proj-overlap/packages/x/tsconfig.json"; printf 'export const x = 1;\n' | put "$r/ts-proj-overlap/packages/x/x.ts"
    # Two configs in one folder that list the same file: tsconfig.json has it,
    # whichever of the two is asked first.
    printf '{"include":["src"]}\n' | put "$r/ts-proj-same-folder/tsconfig.json"; printf 'export const s = 1;\n' | put "$r/ts-proj-same-folder/src/s.ts"
    printf '{"include":["*.ts"],"references":[{"path":"./tsconfig.app.json"}]}\n' | put "$r/ts-proj-same-folder/app/tsconfig.json"
    printf '{"compilerOptions":{"composite":true},"include":["*.ts"]}\n' | put "$r/ts-proj-same-folder/app/tsconfig.app.json"; printf 'export const a = 1;\n' | put "$r/ts-proj-same-folder/app/a.ts"
    cp -r "$r/ts-proj-same-folder" "$r/ts-proj-same-folder-ref-first"
    printf '{"include":["src"],"references":[{"path":"./app/tsconfig.app.json"}]}\n' >"$r/ts-proj-same-folder-ref-first/tsconfig.json"
    printf '{"include":["*.ts"]}\n' >"$r/ts-proj-same-folder-ref-first/app/tsconfig.json"
    # Swan's own config at the root (the repo's cannot be read, or there is
    # none): a config below takes every file it lists.
    printf '{"extends":"@nowhere/tsconfig/base.json"}\n' | put "$r/ts-proj-own-base/tsconfig.json"; printf 'export const s = 1;\n' | put "$r/ts-proj-own-base/src/s.ts"
    printf '{"include":["*.ts"]}\n' | put "$r/ts-proj-own-base/packages/x/tsconfig.json"; printf 'export const x = 1;\n' | put "$r/ts-proj-own-base/packages/x/x.ts"
    printf 'export const s = 1;\n' | put "$r/ts-proj-no-root/src/s.ts"; printf 'export const t = 1;\n' | put "$r/ts-proj-no-root/src/t.ts"
    printf '{"files":["x.ts","../../src/s.ts"]}\n' | put "$r/ts-proj-no-root/packages/x/tsconfig.json"; printf 'export const x = 1;\n' | put "$r/ts-proj-no-root/packages/x/x.ts"
    # A config the root names in a folder no walk enters; a root that names
    # itself; a root and a config beside it (named from below) that list
    # the same file; two
    # configs in a folder with no tsconfig.json that list the same file; two
    # projects that list a file outside both.
    printf '{"include":["src"],"references":[{"path":"./.cfg"}]}\n' | put "$r/ts-proj-hidden-ref/tsconfig.json"; printf 'export const s = 1;\n' | put "$r/ts-proj-hidden-ref/src/s.ts"
    printf '{"compilerOptions":{"composite":true},"include":["*.ts"]}\n' | put "$r/ts-proj-hidden-ref/.cfg/tsconfig.json"; printf 'export const h = 1;\n' | put "$r/ts-proj-hidden-ref/.cfg/h.ts"
    printf '{"include":["src"],"references":[{"path":"./tsconfig.json"}]}\n' | put "$r/ts-proj-self-ref/tsconfig.json"; printf 'export const s = 1;\n' | put "$r/ts-proj-self-ref/src/s.ts"
    printf '{"include":["src"]}\n' | put "$r/ts-proj-root-same/tsconfig.json"; printf '{"include":["src"]}\n' | put "$r/ts-proj-root-same/tsconfig.app.json"
    printf 'export const s = 1;\n' | put "$r/ts-proj-root-same/src/s.ts"; printf 'export const p = 1;\n' | put "$r/ts-proj-root-same/pkg/p.ts"
    printf '{"include":["*.ts"],"references":[{"path":"../tsconfig.app.json"}]}\n' | put "$r/ts-proj-root-same/pkg/tsconfig.json"
    printf '{"include":["src"],"references":[{"path":"./app/tsconfig.one.json"},{"path":"./app/tsconfig.two.json"}]}\n' | put "$r/ts-proj-two-refs/tsconfig.json"
    printf 'export const s = 1;\n' | put "$r/ts-proj-two-refs/src/s.ts"; printf 'export const a = 1;\n' | put "$r/ts-proj-two-refs/app/a.ts"
    for n in one two; do printf '{"compilerOptions":{"composite":true},"include":["*.ts"]}\n' >"$r/ts-proj-two-refs/app/tsconfig.$n.json"; done
    printf '{"include":["src"]}\n' | put "$r/ts-proj-outside/tsconfig.json"; printf 'export const s = 1;\n' | put "$r/ts-proj-outside/src/s.ts"
    printf 'export const shared = 1;\n' | put "$r/ts-proj-outside/shared/s.ts"
    for n in a b; do printf '{"files":["../../shared/s.ts","%s.ts"]}\n' "$n" | put "$r/ts-proj-outside/packages/$n/tsconfig.json"; printf 'export const p = 1;\n' >"$r/ts-proj-outside/packages/$n/$n.ts"; done
    # As many configs as are asked, and one more (for the made-up tsc).
    printf 'export const a = 1;\n' | put "$r/ts-proj-64/a.ts"
    for i in $(seq 10 73); do printf '{}\n' | put "$r/ts-proj-64/p$i/tsconfig.json"; printf 'export const x = 1;\n' >"$r/ts-proj-64/p$i/x.ts"; done
    cp -r "$r/ts-proj-64" "$r/ts-proj-66"
    for i in 74 75; do printf '{}\n' | put "$r/ts-proj-66/p$i/tsconfig.json"; printf 'export const x = 1;\n' >"$r/ts-proj-66/p$i/x.ts"; done
    printf '@REPO@/a.ts\n' | says projects-many list-own; printf '{\n    "files": [\n        "@REPO@/a.ts"\n    ]\n}\n' | says projects-many show-own
    printf '{"files":["./x.ts"]}\n' | says projects-many show-repo
    printf '{"files":["./x.ts"],"references":[{"path":"../p11"},{"path":"../p12/tsconfig.json"}]}\n' | says projects-many show-p10@tsconfig.json
    # Swan's own config at the root, with roots (which only a made-up tsc
    # gives it): a config below takes a file inside its folder, and one
    # outside that it lists.
    printf 'export const s = 1;\n' | put "$r/ts-proj-own-fake/src/s.ts"; printf 'export const t = 1;\n' | put "$r/ts-proj-own-fake/src/t.ts"
    printf '{}\n' | put "$r/ts-proj-own-fake/packages/x/tsconfig.json"; printf 'export const x = 1;\n' | put "$r/ts-proj-own-fake/packages/x/x.ts"
    printf '@REPO@/src/s.ts\n@REPO@/src/t.ts\n@REPO@/packages/x/x.ts\n' | says projects-own list-own
    printf '{\n    "files": [\n        "@REPO@/src/s.ts",\n        "@REPO@/src/t.ts",\n        "@REPO@/packages/x/x.ts"\n    ]\n}\n' | says projects-own show-own
    printf '{"files":["./x.ts","../../src/s.ts"]}\n' | says projects-own show-repo
    # What tsc says of a config, each way it can be wrong (for the made-up tsc).
    printf '{}\n' | put "$r/ts-proj-fake/tsconfig.json"; printf 'export const a = 1;\n' | put "$r/ts-proj-fake/a.ts"
    for d in n1 n2 n3 n4 n5 n6 n7; do printf '{}\n' | put "$r/ts-proj-fake/$d/tsconfig.json"; printf 'export const x = 1;\n' >"$r/ts-proj-fake/$d/x.ts"; done
    printf '{}\n' >"$r/ts-proj-fake/n1/tsconfig.extra.json"; mkdir -p "$r/ts-proj-fake/empty-dir"; ln -s a.ts "$r/ts-proj-fake/alink.ts"
    : | says projects needs-env
    printf '@REPO@/alink.ts\n@REPO@/n1/x.ts\n@REPO@/n6/x.ts\n' | says projects list-repo
    says projects show-repo <<'EOF'
{
    "files": [
        "./alink.ts",
        "./n1/x.ts",
        "./n6/x.ts"
    ]
}
EOF
    # n1: its file, and the configs it names: a folder, a file, and ones that
    # are not there, not named, or not names at all.
    says projects show-n1@tsconfig.json <<'EOF'
{"files": ["./x.ts", "x.ts"],
 "references": [{"path": "./tsconfig.extra.json"}, {"path": "./missing.json"}, {"path": ""}, {"nopath": 1}, 7, {"path": 5},
                {"path": "../empty-dir"}, {"path": "@CFG@/../n7"}]}
EOF
    printf '{"files": ["x.ts", "../n5/x.ts"]}\n' | says projects show-n1@tsconfig.extra.json
    printf 'error TS5083: Cannot read file.\n' | says projects show-n2@tsconfig.json
    printf '{"files": ["./x.ts"]}\n' | says projects show-n3@tsconfig.json; echo 1 | says projects show-n3@tsconfig.json.code
    printf '{"files": "./x.ts"}\n' | says projects show-n4@tsconfig.json
    printf '{"files": ["", 5, null, {"a": "./x.ts"}, "./x.ts", "./gone.ts"]}\n' | says projects show-n5@tsconfig.json
    printf '{"files": ["./x.ts", "../a.ts", "/nowhere/z.ts"], "references": "none"}\n' | says projects show-n6@tsconfig.json
    printf '["./x.ts"]\n' | says projects show-n7@tsconfig.json

    # ---- TypeScript: the chunks of a project, and the layers over them ----
    # chunky <repo>: fifteen sources and a declaration file, sixteen files in
    # all. a.ts is the largest and b.ts, which uses it, the next, so two
    # chunks hold one each; c.ts uses b.ts; d.ts to n.ts use nothing and
    # nothing uses them, each larger than the one before but m.ts and n.ts,
    # which are of one size; ref.ts names the declaration file with a
    # reference; a.ts imports a helper outside the config's include.
    chunky() {
        local d=$1 i=0 f
        printf '{"compilerOptions":{"strict":true},"include":["src"]}\n' | put "$d/tsconfig.json"
        printf '{"name":"c","version":"1.0.0"}\n' | put "$d/package.json"
        printf 'export const help = 1;\n' | put "$d/lib/helper.ts"
        printf 'declare const ambient: number;\n' | put "$d/src/types.d.ts"
        { printf 'import { help } from "../lib/helper";\nexport const a = help + 1;\n'; printf '// %0900d\n' 0; } | put "$d/src/a.ts"
        { printf 'import { a } from "./a";\nexport const b = a + 1;\n'; printf '// %0800d\n' 0; } | put "$d/src/b.ts"
        { printf 'import { b } from "./b";\nexport const c = b + 1;\n'; printf '// %0700d\n' 0; } | put "$d/src/c.ts"
        printf '/// <reference path="./types.d.ts" />\nexport const r = ambient;\n' | put "$d/src/ref.ts"
        for f in d e f g h i j k l m n; do
            i=$((i + 1))
            { printf 'export const %s = %s;\n' "$f" "$i"; printf '// %0*d\n' $((40 * (i < 11 ? i : 10))) 0; } | put "$d/src/$f.ts"
        done
    }
    chunky "$r/ts-chunks"
    for d in same edit comment more gone pkg decl lone helper many many5 twice ref; do chunky "$r/ts-ch-$d"; done
    # chunky_projects <repo>: a root that names two projects and has no files
    # of its own. app: nine sources (a2.ts uses a1.ts), one with a reference,
    # and a declaration file; lib: four sources and a declaration file.
    chunky_projects() {
        local d=$1 i
        printf '{"files":[],"references":[{"path":"./app"},{"path":"./lib"}]}\n' | put "$d/tsconfig.json"
        printf '{"compilerOptions":{"composite":true,"strict":true},"include":["*.ts"]}\n' | put "$d/app/tsconfig.json"
        printf '{"compilerOptions":{"composite":true,"strict":true},"include":["*.ts"]}\n' | put "$d/lib/tsconfig.json"
        printf 'declare const inApp: number;\n' | put "$d/app/types.d.ts"; printf 'declare const inLib: number;\n' | put "$d/lib/decl.d.ts"
        { printf 'export const a1 = 1;\n'; printf '// %0600d\n' 0; } | put "$d/app/a1.ts"
        { printf 'import { a1 } from "./a1";\nexport const a2 = a1 + 1;\n'; printf '// %0500d\n' 0; } | put "$d/app/a2.ts"
        for i in 3 4 5 6 7 8 9; do { printf 'export const a%s = %s;\n' "$i" "$i"; printf '// %0*d\n' $((30 * i)) 0; } | put "$d/app/a$i.ts"; done
        printf '/// <reference path="./types.d.ts" />\nexport const ar = inApp;\n' | put "$d/app/ref.ts"
        for i in 1 2 3; do { printf 'export const l%s = %s;\n' "$i" "$i"; printf '// %0*d\n' $((50 * i)) 0; } | put "$d/lib/l$i.ts"; done
        printf '/// <reference path="./decl.d.ts" />\nexport const lr = inLib;\n' | put "$d/lib/lref.ts"
    }
    chunky_projects "$r/ts-chp"
    for d in same one two; do chunky_projects "$r/ts-chp-$d"; done
    # Fourteen sources of three sizes, in no order of size: which chunk each
    # lands in is the order the Goose program's sort leaves equal sizes in,
    # which is not the order they come in.
    printf '{"include":["*.ts"]}\n' | put "$r/ts-ties/tsconfig.json"
    i=0; for w in 30 10 20 10 30 10 20 10 30 10 20 10 30 10; do i=$((i + 1)); { printf 'export const t = 1;\n'; printf '// %0*d\n' "$w" 0; } >"$r/ts-ties/t$(printf '%02d' $i).ts"; done
    # Two empty sources among six in pairs of one size: an empty source
    # weighs a byte, so the two go to a chunk each.
    printf '{"include":["*.ts"]}\n' | put "$r/ts-empty/tsconfig.json"; : >"$r/ts-empty/y.ts"; : >"$r/ts-empty/z.ts"
    i=0; for w in 40 40 30 30 20 20; do i=$((i + 1)); { printf 'export const e = 1;\n'; printf '// %0*d\n' "$w" 0; } >"$r/ts-empty/e$i.ts"; done
    # A root's source that imports one another project owns.
    printf '{"include":["src"]}\n' | put "$r/ts-proj-import/tsconfig.json"
    printf 'import { x } from "../packages/x/x";\nexport const s = x;\n' | put "$r/ts-proj-import/src/s.ts"
    printf '{"include":["*.ts"]}\n' | put "$r/ts-proj-import/packages/x/tsconfig.json"; printf 'export const x = 1;\n' | put "$r/ts-proj-import/packages/x/x.ts"
    # Eight sources are enough for two chunks, seven are not.
    printf '{"include":["*.ts"]}\n' | put "$r/ts-eight/tsconfig.json"
    for i in 1 2 3 4 5 6 7 8; do { printf 'export const e%s = %s;\n' "$i" "$i"; printf '// %0*d\n' $((25 * i)) 0; } >"$r/ts-eight/e$i.ts"; done
    cp -r "$r/ts-eight" "$r/ts-seven"; rm "$r/ts-seven/e8.ts"
    # A reference counts where it is whole within a source's first 4096
    # bytes: at its start, ending on the last of them, one byte further, and
    # far beyond.
    printf '{"include":["*.ts"]}\n' | put "$r/ts-ref-far/tsconfig.json"; printf 'declare const far: number;\n' >"$r/ts-ref-far/t.d.ts"
    printf '/// <reference path="./t.d.ts" />\nexport const r0 = far;\n' >"$r/ts-ref-far/r0.ts"
    i=0; for w in 4079 4080 5000; do i=$((i + 1)); { printf '//%0*d\n' "$w" 0; printf '/// <reference path="./t.d.ts" />\nexport const r%s = far;\n' "$i"; } >"$r/ts-ref-far/r$i.ts"; done
    for i in 1 2 3 4 5; do { printf 'export const p%s = %s;\n' "$i" "$i"; printf '// %0*d\n' $((35 * i)) 0; } >"$r/ts-ref-far/p$i.ts"; done
    # What tsc lists that is no source of the repo to put in a chunk (for
    # the made-up tsc): a file in node_modules, one outside the repo whose
    # path has a / where the repo's ends, one in a folder whose name starts
    # with the repo's, a declaration file; and two that are: an empty file
    # and one that is not there. And what it compiles that is no root: a
    # file of the repo, which counts among what the chunks share, and the
    # same kinds of file that are none of the repo's.
    printf '{}\n' | put "$r/ts-fake-chunks/tsconfig.json"; : >"$r/ts-fake-chunks/empty.ts"; printf 'declare const d: number;\n' >"$r/ts-fake-chunks/types.d.ts"
    i=0; for f in a b c d e f g; do i=$((i + 1)); { printf 'export const %s = 1;\n' "$f"; printf '// %0*d\n' $((20 * i)) 0; } >"$r/ts-fake-chunks/$f.ts"; done
    printf 'export const p = 1;\n' | put "$r/ts-fake-chunks/node_modules/p/index.ts"; printf 'export const q = 1;\n' >"$r/ts-fake-chunks/node_modules/p/dep.ts"
    printf 'export const s = 1;\n' | put "$r/ts-fake-chunksx/sibling.ts"; printf 'export const o = 1;\n' >"$r/ts-fake-chunksx/other.ts"
    printf 'export const i = 1;\n' | put "$r/ts-fake-chunks/lib/imported.ts"
    far="/$(printf '%*s' $((${#r} + 14)) '' | tr ' ' n)"
    {
        for f in a b c d e f g empty gone; do printf '@REPO@/%s.ts\n' "$f"; done
        printf '@REPO@/types.d.ts\n@REPO@/node_modules/p/index.ts\n@REPO@x/sibling.ts\n/nowhere/z.ts\n%s/z.ts\n' "$far"
        printf '@REPO@/lib/imported.ts\n@REPO@/node_modules/p/dep.ts\n@REPO@x/other.ts\n/nowhere/y.ts\n%s/y.ts\n' "$far"
    } | says chunks-odd list-repo
    {
        printf '{\n    "files": [\n'
        for f in a b c d e f g empty gone; do printf '        "./%s.ts",\n' "$f"; done
        printf '        "./types.d.ts",\n        "./node_modules/p/index.ts",\n        "@REPO@x/sibling.ts",\n        "/nowhere/z.ts",\n        "%s/z.ts"\n    ]\n}\n' "$far"
    } | says chunks-odd show-repo
    # ---- Python ----
    # A virtualenv at the top that is read and not run: two packages, and a
    # pyvenv.cfg whose lines try what counts as naming the Python.
    printf 'import alpha\nx = alpha.alpha()\n' | put "$r/py-venv/a.py"
    printf 'home = /usr/bin\n=3.1\nversions = 3.2\nversion\n  version   =   3.9.18  \nversion = 3.3\n' | put "$r/py-venv/.venv/pyvenv.cfg"
    pkg "$r/py-venv/.venv/lib/python3.9/site-packages" alpha 1.0; pkg "$r/py-venv/.venv/lib/python3.9/site-packages" beta 2.5
    for d in same more newer; do cp -r "$r/py-venv" "$r/py-venv-$d"; done
    # One package; the first line that could name the Python names none.
    printf 'x = 1\n' | put "$r/py-venv-one/a.py"
    printf 'version =\nversion_info = 3.11.4\nversion = 3.3\n' | put "$r/py-venv-one/.venv/pyvenv.cfg"
    pkg "$r/py-venv-one/.venv/lib/python3.11/site-packages" alpha 1.0
    # No Python named, and the virtualenv under its other name.
    printf 'x = 1\n' | put "$r/py-venv-nover/a.py"; printf 'home = /usr/bin\n' | put "$r/py-venv-nover/venv/pyvenv.cfg"
    pkg "$r/py-venv-nover/venv/lib/python3.12/site-packages" alpha 1.0
    # Under lib: two Pythons, a folder that is no Python's, one with no
    # site-packages, one whose site-packages is a file.
    printf 'x = 1\n' | put "$r/py-venv-libs/a.py"; printf 'version = 3.10.1\n' | put "$r/py-venv-libs/.venv/pyvenv.cfg"
    pkg "$r/py-venv-libs/.venv/lib/python3.9/site-packages" alpha 1.0; pkg "$r/py-venv-libs/.venv/lib/python3.10/site-packages" beta 2.5
    pkg "$r/py-venv-libs/.venv/lib/notpython/site-packages" gamma 3.0
    mkdir -p "$r/py-venv-libs/.venv/lib/python3.8"; : | put "$r/py-venv-libs/.venv/lib/python3.7/site-packages"
    # A virtualenv under each name: the first is the one.
    printf 'x = 1\n' | put "$r/py-venv-both/a.py"
    printf 'version = 3.9.1\n' | put "$r/py-venv-both/.venv/pyvenv.cfg"; pkg "$r/py-venv-both/.venv/lib/python3.9/site-packages" alpha 1.0
    printf 'version = 3.8.1\n' | put "$r/py-venv-both/venv/pyvenv.cfg"; pkg "$r/py-venv-both/venv/lib/python3.8/site-packages" beta 2.5
    # The survey's virtualenvs (a made-up spread-wings names them): the one
    # at the top, which the walk found already; one named twice; one with
    # no Python named; one with no folder of packages; one in a folder git
    # ignores; and what names none: a project of another kind, one with no
    # environment, an empty name, a name that is no text, a project with
    # no path, a kind that is no text. Each of those has packages, so that
    # one taken by mistake is counted and named.
    for d in py-envs py-envs-late; do
        printf 'x = 1\n' | put "$r/$d/a.py"
        for v in svc tool out web nopath odd; do
            printf 'y = 1\n' | put "$r/$d/$v/m.py"; pkg "$r/$d/$v/.venv/lib/python3.12/site-packages" "p$v" 1.0; printf 'version = 3.0.0\n' >"$r/$d/$v/.venv/pyvenv.cfg"
        done
        pkg "$r/$d/.venv/lib/python3.9/site-packages" alpha 1.0
        printf 'home = /usr/bin\n' | put "$r/$d/nolib/.venv/pyvenv.cfg"
        printf 'out/\n' >"$r/$d/.gitignore"; git -C "$r/$d" init -q
    done
    printf 'version = 3.9.18\n' >"$r/py-envs/.venv/pyvenv.cfg"; printf 'home = /usr/bin\n' >"$r/py-envs-late/.venv/pyvenv.cfg"
    sw py-envs <<'EOF'
#!/bin/sh
cat <<'JSON'
{"projects":[
 {"kind":"python","path":".","environment":{"venv":".venv","python":"3.1.1"}},
 {"kind":"python","path":"svc","environment":{"venv":"svc/.venv","python":" 3.12.1\n"}},
 {"kind":"python","path":"svc/sub","environment":{"venv":"svc/.venv","python":"3.2.2"}},
 {"kind":"python","path":"tool","environment":{"venv":"tool/.venv"}},
 {"kind":"python","path":"nolib","environment":{"venv":"nolib/.venv","python":"3.7.0"}},
 {"kind":"python","path":"out","environment":{"venv":"out/.venv","python":"3.6.0"}},
 {"kind":"node","path":"web","environment":{"venv":"web/.venv","python":"3.5.0"}},
 {"kind":"python","path":"bare"},
 {"kind":"python","path":"empty","environment":{"venv":""}},
 {"kind":"python","path":"num","environment":{"venv":7}},
 {"kind":"python","environment":{"venv":"nopath/.venv"}},
 {"kind":7,"path":"odd","environment":{"venv":"odd/.venv"}}
]}
JSON
EOF
    sw py-envs-nover <<'EOF'
#!/bin/sh
printf '%s\n' '{"projects":[{"kind":"python","path":"svc","environment":{"venv":"svc/.venv"}},{"kind":"python","path":"tool","environment":{"venv":"tool/.venv","python":""}}]}'
EOF
    # No virtualenv the walk finds at the top: the survey's alone, with the
    # Python the survey says; then one whose name ends another's; then one
    # that is not there.
    printf 'x = 1\n' | put "$r/py-envs-sub/a.py"; printf 'y = 1\n' | put "$r/py-envs-sub/svc/m.py"
    pkg "$r/py-envs-sub/svc/.venv/lib/python3.12/site-packages" psvc 1.0; printf 'version = 3.0.0\n' >"$r/py-envs-sub/svc/.venv/pyvenv.cfg"
    pkg "$r/py-envs-sub/.venv/lib/python3.9/site-packages" alpha 1.0
    sw py-envs-sub <<'EOF'
#!/bin/sh
printf '%s\n' '{"projects":[{"kind":"python","path":"svc","environment":{"venv":"svc/.venv","python":" 3.12.1 "}}]}'
EOF
    sw py-envs-inner <<'EOF'
#!/bin/sh
printf '%s\n' '{"projects":[{"kind":"python","path":"svc","environment":{"venv":"svc/.venv","python":"3.12.1"}},{"kind":"python","path":".","environment":{"venv":".venv"}}]}'
EOF
    sw py-envs-ghost <<'EOF'
#!/bin/sh
printf '%s\n' '{"projects":[{"kind":"python","path":"ghost","environment":{"venv":"ghost/.venv","python":"3.12.1"}}]}'
EOF
    # A virtualenv that is run, once the repo is trusted: its python is a
    # made-up one that has pip, has none, or answers nothing.
    fakepy() { put "$r/$1/.venv/bin/python"; chmod +x "$r/$1/.venv/bin/python"; printf 'x = 1\n' >"$r/$1/a.py"; printf 'version = 3.10.2\n' >"$r/$1/.venv/pyvenv.cfg"; }
    fakepy py-run <<'EOF'
#!/bin/sh
[ "$1" = -m ] && { echo "pip 1.0 from nowhere"; exit 0; }
echo "asked: $1" >&2; exit 3
EOF
    pkg "$r/py-run/.venv/lib/python3.10/site-packages" alpha 1.0
    fakepy py-run-nopip <<'EOF'
#!/bin/sh
[ "$1" = -c ] && { printf '%s\n' '[{"name": "made", "version": "1", "files": []}, {"name": "up", "version": "2", "files": []}]'; exit 0; }
echo "no module named pip" >&2; exit 1
EOF
    fakepy py-run-broken <<'EOF'
#!/bin/sh
echo "this python answers nothing: $1" >&2; exit 2
EOF
    # A src layout: a package under src, a module under src, a src that
    # holds neither, and a src that is a file.
    : | put "$r/py-src/src/pkg/__init__.py"; printf 'def core():\n    return 1\n' >"$r/py-src/src/pkg/core.py"; printf 'from pkg.core import core\n' | put "$r/py-src/tests/test_core.py"
    printf 'def mod():\n    return 1\n' | put "$r/py-src-mod/src/mod.py"; printf 'x = 1\n' >"$r/py-src-mod/a.py"
    printf 'words\n' | put "$r/py-src-not/src/readme.txt"; printf 'x = 1\n' | put "$r/py-src-not/src/sub/x.py"
    printf 'words\n' | put "$r/py-src-file/src"; printf 'x = 1\n' >"$r/py-src-file/a.py"
    # Pieces, with room for six: five folders that are a piece each (p1 and
    # p10 among them: one name starts the other) and one too big to be a
    # piece, whose two files are a piece each. A file of p2 uses what p1
    # defines.
    for p in 1 3 4 10; do pyf "$r/py-dep/p$p/mod.py" 40 "def f$p(x):\n    return x + 1\n"; pyf "$r/py-dep/p$p/__init__.py" 40 ''; done
    pyf "$r/py-dep/p2/use.py" 40 'from p1.mod import f1\ny = f1(2)\n'; pyf "$r/py-dep/p2/__init__.py" 40 ''
    pyf "$r/py-dep/q/a.py" 60 'def qa(x):\n    return x + 1\n'; pyf "$r/py-dep/q/b.py" 60 'def qb(x):\n    return x + 1\n'
    for d in same edit file gone more; do cp -r "$r/py-dep" "$r/py-dep-$d"; done
    # ---- Rust ----
    # A cargo project at the top; one with a second project inside it (a
    # workspace of its own, as a fuzz crate is); fourteen side by side, two
    # more than one map takes; and one that pins a toolchain no machine
    # has, with a project inside that the pin holds for too.
    # With the lock file cargo would write: a trusted map may write in the
    # repo, and the second program must find the repo as the first did.
    crate() {
        printf '[package]\nname = "%s"\nversion = "0.1.0"\nedition = "2021"\n%b' "$2" "${3:-}" | put "$1/Cargo.toml"; printf 'fn main() {\n    println!("{}", 1 + 1);\n}\n' | put "$1/src/main.rs"
        printf '# This file is automatically @generated by Cargo.\n# It is not intended for manual editing.\nversion = 4\n\n[[package]]\nname = "%s"\nversion = "0.1.0"\n' "$2" >"$1/Cargo.lock"
    }
    crate "$r/rs-root" root
    crate "$r/rs-two" two; crate "$r/rs-two/fuzz" fuzz '[workspace]\n'
    cp -r "$r/rs-two" "$r/rs-two-edit"
    for i in 01 02 03 04 05 06 07 08 09 10 11 12 13 14; do crate "$r/rs-many/c$i" "c$i"; done
    crate "$r/rs-pin" pin; crate "$r/rs-pin/fuzz" fuzz '[workspace]\n'; printf '[toolchain]\nchannel = "1.50.0"\n' >"$r/rs-pin/rust-toolchain.toml"
    # And one that pins a toolchain this machine may have beside a newer one.
    crate "$r/rs-pin-old" pinold; printf '[toolchain]\nchannel = "1.88.0"\n' >"$r/rs-pin-old/rust-toolchain.toml"
    # ---- Java, C#, C and CUDA ----
    # Java with no build tool, and with each file that names one; Kotlin
    # with Gradle, which scip-java maps, and with Maven, which nothing does.
    printf 'class A { int f() { return 1; } }\n' | put "$r/java-plain/A.java"
    for d in java-maven java-gradle java-gradle-kts java-settings java-settings-kts java-both; do cp -r "$r/java-plain" "$r/$d"; done
    printf '<project/>\n' >"$r/java-maven/pom.xml"; printf '\n' >"$r/java-gradle/build.gradle"; printf '\n' >"$r/java-gradle-kts/build.gradle.kts"
    printf '\n' >"$r/java-settings/settings.gradle"; printf '\n' >"$r/java-settings-kts/settings.gradle.kts"
    printf '<project/>\n' >"$r/java-both/pom.xml"; printf '\n' >"$r/java-both/build.gradle"
    printf 'fun f() = 1\n' | put "$r/kt-gradle/f.kt"; printf '\n' >"$r/kt-gradle/build.gradle.kts"
    printf 'fun f() = 1\n' | put "$r/kt-maven/f.kt"; printf '<project/>\n' >"$r/kt-maven/pom.xml"
    # C# with a project file of each kind at the top, and with one only below it.
    printf 'class A { }\n' | put "$r/cs-proj/A.cs"; printf '<Project Sdk="Microsoft.NET.Sdk"/>\n' >"$r/cs-proj/app.csproj"
    printf 'class A { }\n' | put "$r/cs-sln/A.cs"; printf '\n' >"$r/cs-sln/app.sln"
    printf 'class A { }\n' | put "$r/cs-slnx/A.cs"; printf '<Solution/>\n' >"$r/cs-slnx/app.slnx"
    printf 'class A { }\n' | put "$r/cs-none/A.cs"; printf '<Project/>\n' | put "$r/cs-none/sub/app.csproj"
    # C and C++ under each ending, CUDA, a header alone, and a repo with
    # its own list of compile commands, at the top, under build, and both.
    printf 'int f(void) { return 1; }\n' | put "$r/c-plain/a.c"; printf 'int g() { return 2; }\n' >"$r/c-plain/b.cpp"; printf 'int f(void);\n' >"$r/c-plain/a.h"
    printf 'int h() { return 3; }\n' >"$r/c-plain/c.cc"; printf 'int i() { return 4; }\n' >"$r/c-plain/d.cxx"
    printf '__global__ void k() {}\n' | put "$r/cu-plain/k.cu"; printf 'int f(void) { return 1; }\n' >"$r/cu-plain/a.c"
    cp -r "$r/c-plain" "$r/c-compdb"; printf '[]\n' >"$r/c-compdb/compile_commands.json"
    cp -r "$r/c-plain" "$r/c-build-compdb"; printf '[]\n' | put "$r/c-build-compdb/build/compile_commands.json"
    cp -r "$r/c-plain" "$r/c-both-compdb"; printf '[]\n' >"$r/c-both-compdb/compile_commands.json"; printf '[]\n' | put "$r/c-both-compdb/build/compile_commands.json"
    printf 'int f(void);\n' | put "$r/c-header/a.h"
    # Go modules below the top of the repo, with a file outside both, and
    # the same with a go.work at the top.
    for m in a b; do printf 'module example.com/%s\n\ngo 1.21\n' "$m" | put "$r/go-mods/svc/$m/go.mod"; printf 'package %s\n\nfunc F() int { return 1 }\n' "$m" >"$r/go-mods/svc/$m/$m.go"; done
    printf 'package main\n\nfunc main() {}\n' >"$r/go-mods/stray.go"
    cp -r "$r/go-mods" "$r/go-work"; printf 'go 1.21\n\nuse (\n\t./svc/a\n\t./svc/b\n)\n' >"$r/go-work/go.work"
    sw go-top <<'EOF'
#!/bin/sh
printf '%s\n' '{"projects":[{"kind":"go","path":"svc/a"},{"kind":"go","path":"."},{"kind":"go","path":"svc/b"}]}'
EOF
    sw go-one <<'EOF'
#!/bin/sh
printf '%s\n' '{"projects":[{"kind":"go","path":"svc/b"},{"kind":"python","path":"svc/a"},{"kind":"go"}]}'
EOF
    # Everything that waits for trust, in one repo.
    crate "$r/wait-all" waits; printf 'class A { }\n' >"$r/wait-all/A.java"; printf '<project/>\n' >"$r/wait-all/pom.xml"; printf 'class B { }\n' >"$r/wait-all/B.cs"; printf '\n' >"$r/wait-all/app.sln"
}

# The Goose program maps these once, as they are made, and they are changed
# after: a later map of each starts from what was kept of the earlier state.
BEFORE="ts-edit-config ts-edit-pkg ts-edit-nested ts-edit-code ts-edit-touch ts-edit-more ts-edit-gone"
# These with room for two indexers at once, so that TypeScript is in two
# chunks, and these with room for four: app in two chunks and lib in one.
BEFORE_TWO="ts-ch-same ts-ch-edit ts-ch-comment ts-ch-more ts-ch-gone ts-ch-pkg ts-ch-decl ts-ch-lone ts-ch-helper ts-ch-many ts-ch-many5 ts-ch-twice ts-ch-ref"
BEFORE_FOUR="ts-chp-same ts-chp-one ts-chp-two"
# These hold Python, mapped with room for six pieces.
BEFORE_PY="py-dep-same py-dep-edit py-dep-file py-dep-gone py-dep-more py-venv-same py-venv-more py-venv-newer"
make_before() {
    local d jobs f
    for jobs in 2 4; do
        for d in $([ $jobs = 2 ] && echo "$BEFORE_TWO" || echo "$BEFORE_FOUR"); do
            home_as_installed "$base/old/home"
            (cd "$base/old" && env "${UNSET[@]}" SWAN_JOBS=$jobs home/bin/swan map "$r/$d" "$base/before/$d" >/dev/null 2>&1 </dev/null)
            [ -e "$base/before/$d/index-typescript-1.scip" ] || { echo "port-map: the Goose program made no second chunk for $d"; exit 2; }
        done
    done
    # One changed twice: after its first change it is mapped again, which
    # leaves a layer over its chunks, and then it is changed once more.
    sed -i 's/help + 1/help + 2/' "$r/ts-ch-twice/src/a.ts"
    (cd "$base/old" && env "${UNSET[@]}" SWAN_JOBS=2 home/bin/swan map "$r/ts-ch-twice" "$base/before/ts-ch-twice" >/dev/null 2>&1 </dev/null)
    [ -e "$base/before/ts-ch-twice/index-typescript-layer-0.scip" ] || { echo "port-map: the Goose program made no layer for ts-ch-twice"; exit 2; }
    sed -i 's/= 1;/= 100;/' "$r/ts-ch-twice/src/d.ts"
    sed -i 's/help + 1/help + 2/' "$r/ts-ch-edit/src/a.ts"
    sed -i 's|^// 0|// 1|' "$r/ts-ch-comment/src/a.ts"
    printf 'export const more = 1;\n' >"$r/ts-ch-more/src/more.ts"
    rm "$r/ts-ch-gone/src/b.ts"
    printf '{"name":"c","version":"1.0.1"}\n' >"$r/ts-ch-pkg/package.json"
    printf 'declare const ambient: number;\ndeclare const other: string;\n' >"$r/ts-ch-decl/src/types.d.ts"
    sed -i 's/= 1;/= 100;/' "$r/ts-ch-lone/src/d.ts"
    printf 'export const help = 2;\n' >"$r/ts-ch-helper/lib/helper.ts"
    for f in d e f g; do sed -i 's/;$/ + 100;/' "$r/ts-ch-many/src/$f.ts"; done
    for f in d e f g h; do sed -i 's/;$/ + 100;/' "$r/ts-ch-many5/src/$f.ts"; done
    sed -i 's/= ambient;/= ambient + 1;/' "$r/ts-ch-ref/src/ref.ts"
    sed -i 's/= 1;/= 100;/' "$r/ts-chp-one/app/a1.ts"
    sed -i 's/= 1;/= 100;/' "$r/ts-chp-two/app/a1.ts" "$r/ts-chp-two/lib/l1.ts"
    for d in $BEFORE; do
        home_as_installed "$base/old/home"
        (cd "$base/old" && env "${UNSET[@]}" home/bin/swan map "$r/$d" "$base/before/$d" >/dev/null 2>&1 </dev/null)
        [ -e "$base/before/$d/tsc-files.txt" ] || { echo "port-map: the Goose program kept no list of tsc's files for $d"; exit 2; }
    done
    printf '{"compilerOptions":{"strict":true},"include":["src"]}\n' >"$r/ts-edit-config/tsconfig.json"
    printf '{"name":"e","version":"1.0.1"}\n' >"$r/ts-edit-pkg/package.json"
    printf '{"include":["*.ts"],"exclude":["none"]}\n' >"$r/ts-edit-nested/packages/x/tsconfig.json"
    printf 'export const a = 2;\n' >"$r/ts-edit-code/src/a.ts"
    touch "$r/ts-edit-touch/tsconfig.json" "$r/ts-edit-touch/package.json" "$r/ts-edit-touch/src/a.ts"
    printf 'export const c = 1;\n' >"$r/ts-edit-more/src/c.ts"
    rm "$r/ts-edit-gone/src/b.ts"
    # Python. Changed after: a file that another piece uses; a file that is
    # a piece itself; a file gone, which leaves too few to split; a folder
    # more; a package more in the virtualenv; another Python named there.
    for d in $BEFORE_PY; do
        home_as_installed "$base/old/home"
        (cd "$base/old" && env "${UNSET[@]}" SWAN_JOBS=6 home/bin/swan map "$r/$d" "$base/before/$d" >/dev/null 2>&1 </dev/null)
        [ -e "$base/before/$d/python-pieces.tsv" ] || { echo "port-map: the Goose program kept no record of Python's pieces for $d"; exit 2; }
    done
    [ "$(wc -l <"$base/before/py-dep-same/python-pieces.tsv")" = 7 ] || { echo "port-map: the Goose program did not plan seven pieces for py-dep-same"; exit 2; }
    sed -i 's/x + 1/x + 2/' "$r/py-dep-edit/p1/mod.py" "$r/py-dep-file/q/a.py"
    rm "$r/py-dep-gone/p3/mod.py"
    pyf "$r/py-dep-more/p5/mod.py" 40 'def f5(x):\n    return x + 1\n'; pyf "$r/py-dep-more/p5/__init__.py" 40 ''
    pkg "$r/py-venv-more/.venv/lib/python3.9/site-packages" gamma 3.0
    sed -i 's/3\.9\.18/3.9.19/' "$r/py-venv-newer/.venv/pyvenv.cfg"
    # Rust: a source changed after.
    home_as_installed "$base/old/home"
    (cd "$base/old" && env "${UNSET[@]}" home/bin/swan map "$r/rs-two-edit" "$base/before/rs-two-edit" >/dev/null 2>&1 </dev/null)
    [ -e "$base/before/rs-two-edit/index-rust.scip" ] || { echo "port-map: the Goose program made no index of rs-two-edit's cargo project"; exit 2; }
    sed -i 's/1 + 1/1 + 2/' "$r/rs-two-edit/src/main.rs"
}

# Everything of one Goose program and one set of made-up repos lives in one
# folder, at the same path every run: the repos, the Goose program's home
# and what it said of each case.
key=$( { sha256sum <"$old"; declare -f make_repos make_before home_of home_as_installed pkg pyf | sha256sum; } | sha256sum | cut -c1-16)
base="$here/build/port-map/$key"
mkdir -p "$base"
# What an earlier Goose program or set of repos left is of no use.
find "$here/build/port-map" -mindepth 1 -maxdepth 1 -type d ! -name "$key" ! -name 'run.*' -mmin +30 -exec rm -rf {} + 2>/dev/null
work=$(mktemp -d "$here/build/port-map/run.XXXXXX")
# A home holds links to this checkout's files: only the map folders are
# made writable before all is removed. PORT_MAP_KEEP=1 leaves the folder.
trap '[ -n "${PORT_MAP_KEEP:-}" ] || { chmod -R u+rwx "${work:?}"/c/*/maps 2>/dev/null; rm -rf "${work:?}"; }' EXIT
r="$base/repos"
# What a map must not be handed down from whoever runs this.
UNSET=(-u SWAN_SPREAD_WINGS -u SWAN_TRUST_BUILD -u SWAN_SANDBOX -u SWAN_JOBS -u SWAN_TS_LAYER_MIN -u SWAN_SCIP_TYPESCRIPT_PATCH -u SWAN_SCIP_PYTHON_PATCH
       -u CUDA_PATH -u SWAN_NODE_HEAP_MB -u SWAN_STAMP_JOBS -u SWAN_STAMP_MIN -u SWAN_STAMP_MODE -u JAVA_HOME -u VIRTUAL_ENV -u NODE_OPTIONS)
# The indexer's file without Swan's patch and with it, as the Goose program makes them.
if [ ! -e "$base/ts-indexer.patched" ]; then
    rm -rf "${base:?}/tsi"; mkdir -p "$base/tsi"
    cp "$TSI/FileIndexer.js" "$base/tsi/FileIndexer.js"
    "$old" scip-typescript-patch "$base/tsi/FileIndexer.js" --revert >/dev/null 2>&1
    cp "$base/tsi/FileIndexer.js" "$base/ts-indexer.plain"
    "$old" scip-typescript-patch "$base/tsi/FileIndexer.js" >/dev/null 2>&1
    cmp -s "$base/ts-indexer.plain" "$base/tsi/FileIndexer.js" && { echo "port-map: the Goose program does not patch $TSI/FileIndexer.js"; exit 2; }
    mv "$base/tsi/FileIndexer.js" "$base/ts-indexer.patched"
fi
# scip-python's two files without Swan's fixes and with them, the same way.
if [ ! -e "$base/py-site.patched" ]; then
    rm -rf "${base:?}/pyi"; mkdir -p "$base/pyi"
    for f in pyright-internal.js scip-python.js; do
        cp "$PYD/$f" "$base/pyi/$f"
        "$old" scip-python-patch "$base/pyi/$f" --revert >/dev/null 2>&1
        cp "$base/pyi/$f" "$base/pyi/$f.plain"
        "$old" scip-python-patch "$base/pyi/$f" >/dev/null 2>&1
        cmp -s "$base/pyi/$f.plain" "$base/pyi/$f" && { echo "port-map: the Goose program does not patch $PYD/$f"; exit 2; }
    done
    mv "$base/pyi/pyright-internal.js.plain" "$base/py-reach.plain"; mv "$base/pyi/pyright-internal.js" "$base/py-reach.patched"
    mv "$base/pyi/scip-python.js.plain" "$base/py-site.plain"; mv "$base/pyi/scip-python.js" "$base/py-site.patched"
fi
if [ ! -e "$r/ready" ]; then
    rm -rf "${r:?}" "${base:?}/before" "${base:?}/said" "${base:?}/old"
    make_repos
    : >"$r/ready"
fi
if [ ! -e "$base/old/home/ready" ]; then
    rm -rf "${base:?}/old"; mkdir -p "$base/old/programs"
    cp bin/eggshell bin/spread-wings bin/swan-flatten "$base/old/programs/"; cp "$old" "$base/old/programs/swan"
    home_of "$base/old/home" "$base/old/programs"
    : >"$base/old/home/ready"
fi
if [ ! -e "$base/before/ready" ]; then rm -rf "${base:?}/before"; mkdir -p "$base/before"; make_before; : >"$base/before/ready"; fi
mkdir -p "$work/programs" "$work/verdict"
cp bin/eggshell bin/spread-wings bin/swan-flatten "$work/programs/"; cp "$new" "$work/programs/swan"

# ---- running a case ----
# What the carried part of a map writes into the map folder. A case of the
# plain repo that starts from a folder with files in it (WATCH) also watches
# one it leaves, and a case may name more of its own (ALSO): indexes of
# Python pieces no longer planned, which a map removes. A case may also
# name what a later part writes over, which is then not compared (LATER):
# the record of Python's pieces loses the pieces whose indexer failed.
# The config of each of TypeScript's chunks and layers (tsproject-<n>/,
# tsproject-layer-<id>/) is compared as well, wherever either program has one,
# and rust-analyzer's settings (rust-analyzer-<hash>.json) the same way.
WRITTEN="git-ignored.txt git-ignored-all.txt survey.json scip-started tsproject/tsconfig.json python-env.json py-standin/python3 py-standin/python py-standin/standin.py scip-java.json compile_commands.json"
# What it keeps to use again. A clean map holds these back until it ends.
CACHED="tsc-files.txt tsc-program.txt tsc-projects.txt typescript-chunks.txt typescript-shared.txt typescript-files.tsv typescript-layers.txt python-files.tsv python-pieces.tsv"
# The lines of the report the carried part writes: the Goose program's
# report starts with these, and the Rust program's is these and no more.
# Two are the ends of what a made-up program said over more than one line:
# spread-wings inside "projects: not surveyed (...)", tsc inside
# "typescript: the repo's tsconfig.json cannot be read (...)".
OPENING='^(languages:|not mapped, git ignores |projects: |node: dependencies are not installed |map schema |clean rebuild: cached |line [0-9]+ of what went wrong|stamps: |cosmetic edits: [0-9]+ file.s. changed only |reindexing [0-9]+ file.s. whose indexed text is unknown|typescript: the repo.s tsconfig.json cannot be read |.*[)]; indexing with Swan.s own config$|scip-typescript: applied Swan.s stable names |scip-typescript: Swan.s stable names are not applied |typescript: [0-9]+ more tsconfig |scip-typescript( [0-9]+/[0-9]+)?: reused .no changes.$|scip-python: applied Swan.s reachability memo |scip-python: Swan.s reachability memo does not fit |scip-python: a package in a virtualenv inside the repo is now named |scip-python: Swan.s fix for packages in a virtualenv inside the repo does not fit |python: [0-9]+ packages? read from the project.?.? own virtualenvs? |python: [0-9]+ pieces reused$|rust: [0-9]+ more cargo projects not mapped |rust-analyzer scip: reused .no changes.$|rust project .*: reused .no changes.$|scip-(java|dotnet|clang): reused .no changes.$|not run: |[a-z]+: [0-9]+ modules below the top of the repo, each mapped from its own folder)'
# Two lines the carried part can write are left out of these on purpose:
# "lsp-index <language>: reused (no changes)" and "syntax-index: reused (no
# changes)". Those two indexes are made by Swan itself, and what says
# whether one is kept takes in the program that made it (its path and its
# size), so the Rust program never keeps one the Goose program made.
# The steps the carried part runs and gives an account of on standard
# error: the Goose program's standard error starts with these (each with
# whatever its step said when it failed), and the Rust program's is these
# and no more. A program that leaves a step out says less, and that is a
# difference like any other.
STEPS='^(mkdir|tsc --listFilesOnly|tsc --showConfig|python packages [(]read from the virtualenv[)]|python packages [(]importlib[.]metadata[)]): '
WATCHED="other.txt"
PAR=${PORT_MAP_JOBS:-8}
total=0
tidy() { sed -E -e 's/ in [0-9]+ ms$//' -e 's/^swan map: [0-9]+ ms in all/swan map: N ms in all/' -e 's/^(.*): [0-9]+ ms$/\1: N ms/' -e 's/^(.*): exit (-?[0-9]+) after [0-9]+ ms$/\1: exit \2 after N ms/' -e "s|$2|<its folder>|g" -e 's/^goose runtime error: //' -e '$s/ \([^()]*\.goose:[0-9]+\)$//' "$1"; }
# The prep_ and home_ functions there are so far: the Goose program maps a
# case again when one of them changes.
# Every table of a map as text, its own folder and its two times apart.
db_text() { sqlite3 -readonly "$1" .dump 2>&1 | sed -E -e "s|$2|<its folder>|g" -e "s/^(INSERT INTO meta VALUES\('(scip_time|built_at)',)[^)]*\);$/\1N);/"; }
# A copy of a map the Goose program made, with its records of where its
# indexes are (index-manifest.tsv, python-pieces.tsv) moved with it, as if
# made where it is.
prep_copy() { local f; cp -r "$1" "$2"; for f in index-manifest.tsv python-pieces.tsv; do [ ! -f "$2/$f" ] || sed -i "s|$1/|$2/|g" "$2/$f"; done; }
preps() { declare -f $(compgen -A function | grep -E '^(prep_|home_|mtime_ns$)') | sha256sum | cut -c1-16; }
# case_of <name> <repo> [--clean] [NAME=value...]: both programs map the
# repo into maps/<name> of their own folder. PREP names a function that
# fills that folder first, HOME_PREP one that changes the home ("<function>
# [word]"), DEPENDS the case whose kept map PREP copies.
case_of() {
    local name=$1 repo=$2; shift 2
    local clean=()
    if [ "${1:-}" = --clean ]; then clean=(--clean); shift; fi
    total=$((total + 1))
    local kept="$base/said/$name"
    local sig="$repo|${clean[*]:-}|$*|${PREP:-}|${HOME_PREP:-}|${LISTED:-}|${DEPENDS:+$(stat -c %Y "$base/said/$DEPENDS/code")}|$(preps)"
    if [ ! -e "$kept/code" ] || [ "$(cat "$kept/sig" 2>/dev/null)" != "$sig" ]; then
        rm -rf "${kept:?}" "${base:?}/old/maps/$name"
        mkdir -p "$kept" "$base/old/maps"
        home_as_installed "$base/old/home"
        [ -n "${HOME_PREP:-}" ] && $HOME_PREP "$base/old/home"
        [ -n "${PREP:-}" ] && "$PREP" "$base/old/maps/$name"
        if [ -n "${LISTED:-}" ]; then mkdir -p "$base/old/home/data"; printf '%s\n' "$LISTED" >"$base/old/home/data/trusted-repos"; fi
        (cd "$base/old" && env "${UNSET[@]}" "$@" home/bin/swan map "$repo" "maps/$name" "${clean[@]}" >"$kept/out" 2>"$kept/err" </dev/null; echo $? >"$kept/code.tmp")
        rm -rf "${base:?}/old/home/data"
        home_state "$base/old/home" >"$kept/home"
        printf '%s' "$sig" >"$kept/sig"
        mv "$kept/code.tmp" "$kept/code"
    fi
    while [ "$(jobs -rp | wc -l)" -ge "$PAR" ]; do wait -n; done
    (
        w="$work/c/$name"; n="$w/maps/$name"; o="$base/old/maps/$name"
        mkdir -p "$w/maps"
        home_of "$w/home" "$work/programs"
        [ -n "${HOME_PREP:-}" ] && $HOME_PREP "$w/home"
        [ -n "${PREP:-}" ] && "$PREP" "$n"
        if [ -n "${LISTED:-}" ]; then mkdir -p "$w/home/data"; printf '%s\n' "$LISTED" >"$w/home/data/trusted-repos"; fi
        (cd "$w" && env "${UNSET[@]}" "$@" home/bin/swan map "$repo" "maps/$name" "${clean[@]}" >"$w/out" 2>"$w/err" </dev/null); code=$?
        rm -rf "${w:?}/home/data"
        old_code=$(cat "$kept/code")
        tidy "$kept/out" "$base/old" >"$w/old.out"; tidy "$kept/err" "$base/old" >"$w/old.err"
        tidy "$w/out" "$w" >"$w/new.out"; tidy "$w/err" "$w" >"$w/new.err"
        why=""
        if [ "$code" = 70 ]; then
            # The carried part: what it printed, less the line end print adds,
            # is the opening of what the Goose program printed, whole; and its
            # standard error, less the line that says where the carrying stops,
            # is the Goose program's as far as the steps that are carried.
            head -c -1 "$w/new.out" >"$w/new.out.cut"
            grep -v '^swan (rust): map is not carried over yet' "$w/new.err" >"$w/new.err.cut"
            awk -v opening="$OPENING" '$0 !~ opening { exit } { print }' "$w/old.out" >"$w/old.out.cut"
            cmp -s "$w/new.out.cut" "$w/old.out.cut" || why="the opening of its report is not the Goose program's"
            [ -n "$why" ] || [ -s "$w/new.err.cut" ] || why="it says nothing on standard error"
            awk -v steps="$STEPS" '/^.+: (N ms|exit -?[0-9]+ after N ms)$/ && $0 !~ steps { exit } { print }' "$w/old.err" >"$w/old.err.cut"
            [ -n "$why" ] || cmp -s "$w/new.err.cut" "$w/old.err.cut" || why="its standard error is not the Goose program's for the steps that are carried"
        else
            cmp -s "$w/new.out" "$w/old.out" || why="standard output differs"
            [ -n "$why" ] || cmp -s "$w/new.err" "$w/old.err" || why="standard error differs"
            [ -n "$why" ] || [ "$code" = "$old_code" ] || why="exit code differs: Goose $old_code, Rust $code"
        fi
        if [ -z "$why" ] && [ "$code" = 70 ]; then
            configs=$(for d in "$n" "$o"; do (cd "$d" 2>/dev/null && ls -d tsproject-*/tsconfig.json rust-analyzer-*.json 2>/dev/null); done | sort -u | tr '\n' ' ')
            for f in $WRITTEN $configs ${WATCH:+$WATCHED} ${ALSO:-} $([ ${#clean[@]} = 0 ] && echo "$CACHED"); do
                case " ${LATER:-} " in *" $f "*) continue ;; esac
                if { [ -e "$n/$f" ] && [ ! -e "$o/$f" ]; } || { [ ! -e "$n/$f" ] && [ -e "$o/$f" ]; }; then
                    why="the map folder's $f is there for one program only"; break
                fi
                [ -d "$n/$f" ] && continue
                # With Swan's own config for TypeScript, which is in the map
                # folder, the fingerprint of what the chunks share takes in
                # that folder's path, and each program has its own.
                [ "$f" = typescript-shared.txt ] && [ -e "$o/tsproject/tsconfig.json" ] && continue
                # The same bytes, each program's own folder apart.
                if [ -e "$n/$f" ] && ! cmp -s <(sed "s|$w|<its folder>|g" "$n/$f") <(sed "s|$base/old|<its folder>|g" "$o/$f"); then why="the map folder's $f differs"; break; fi
                # And, for the stand-in a map makes runnable, whether it can be run.
                case "$f" in py-standin/*) [ ! -e "$n/$f" ] || [ "$(stat -c %a "$n/$f")" = "$(stat -c %a "$o/$f")" ] || { why="the map folder's $f is not runnable as the Goose program's is"; break; } ;; esac
            done
            # A clean map holds back what it keeps until its rows are published.
            if [ -z "$why" ] && [ ${#clean[@]} != 0 ]; then
                for f in $CACHED; do [ ! -e "$n/$f" ] || { why="a clean map wrote $f before it ended"; break; }; done
            fi
            # The kept texts: the Goose program's, and for a new map no others.
            # The Goose program keeps more where a later part stamps a file no
            # walk reaches (one in a hidden folder, one that is not there):
            # LATER_TEXTS says how many, and so many may be missing.
            if [ -z "$why" ] && [ -d "$o/texts" ]; then
                later=0
                for f in "$o"/texts/*; do
                    [ -e "$f" ] || continue
                    if [ ! -e "$n/texts/${f##*/}" ]; then later=$((later + 1)); continue; fi
                    cmp -s "$f" "$n/texts/${f##*/}" || { why="the kept text ${f##*/} is not the Goose program's"; break; }
                done
                [ -n "$why" ] || [ "$later" = "${LATER_TEXTS:-0}" ] || why="$later of the texts the Goose program keeps are not kept, where ${LATER_TEXTS:-0} are a later part's"
                if [ -z "$why" ] && [ -z "${PREP:-}" ] && [ "$(ls "$o/texts" | wc -l)" != "$(($(ls "$n/texts" 2>/dev/null | wc -l) + later))" ]; then why="more texts are kept than the Goose program keeps"; fi
            fi
        elif [ -z "$why" ] && { [ -d "$n" ] || [ -d "$o" ]; }; then
            # The record of where the indexes are names the folder itself,
            # which is each program's own: it is compared with that apart.
            diff -r -x swan.db.lock -x index-manifest.tsv -x swan.db "$n" "$o" >"$w/d" 2>&1 || why="the map folders differ: $(head -2 "$w/d" | tr '\n' ' ' | sed "s|$w|<Rust>|g; s|$base/old|<Goose>|g" | cut -c1-200)"
            # The map itself: the same bytes, or, where a map was made, the
            # same rows in every table, each program's own folder and the
            # two times a map notes of itself apart.
            if [ -z "$why" ] && { [ -e "$n/swan.db" ] || [ -e "$o/swan.db" ]; } && ! cmp -s "$n/swan.db" "$o/swan.db"; then
                { [ -e "$n/swan.db" ] && [ -e "$o/swan.db" ] && db_text "$n/swan.db" "$w" >"$w/db.new" && db_text "$o/swan.db" "$base/old" >"$w/db.old" && cmp -s "$w/db.new" "$w/db.old"; } || why="the map's rows differ (swan.db): $(diff "$w/db.old" "$w/db.new" 2>&1 | grep '^[<>]' | head -2 | cut -c1-150 | tr '\n' ' ')"
            fi
            if [ -z "$why" ] && { [ -e "$n/index-manifest.tsv" ] || [ -e "$o/index-manifest.tsv" ]; }; then
                { [ -e "$n/index-manifest.tsv" ] && [ -e "$o/index-manifest.tsv" ] && cmp -s <(sed "s|$w|<its folder>|g" "$n/index-manifest.tsv") <(sed "s|$base/old|<its folder>|g" "$o/index-manifest.tsv"); } || why="the map folder's index-manifest.tsv differs"
            fi
        fi
        if [ -z "$why" ] && ! home_state "$w/home" | cmp -s - "$kept/home"; then
            why="an indexer in its home is not left as the Goose program leaves it: $(home_state "$w/home" | diff "$kept/home" - | grep '^[<>]' | cut -c1-60 | tr '\n' ' ')"
        fi
        if [ -n "$why" ]; then
            echo "DIFFERENT ($name)"; echo "    $why"
            echo "    Goose (exit $old_code):"; head -6 "$w/old.out" | cut -c1-230 | sed 's/^/      /'; head -4 "$w/old.err" | cut -c1-200 | sed 's/^/      ! /'
            echo "    Rust (exit $code):"; head -6 "$w/new.out" | cut -c1-230 | sed 's/^/      /'; head -4 "$w/new.err" | cut -c1-200 | sed 's/^/      ! /'
        fi
        [ -n "${PORT_MAP_KEEP:-}" ] || { chmod -R u+rwx "$w/maps" 2>/dev/null; rm -rf "${w:?}"; }
    ) >"$work/verdict/$(printf '%04d' "$total")" 2>&1 &
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
    home_as_installed "$base/old/home"
    (cd "$base/old" && env "${UNSET[@]}" home/bin/swan map "$r/plain" "$base/plain-map" >/dev/null 2>&1 </dev/null)
    [ -e "$base/plain-map/swan.db" ] || { echo "port-map: the Goose program made no map of the plain repo"; exit 2; }
fi
prep_plain() { prep_copy "$base/plain-map" "$1"; }
prep_older() { prep_copy "$base/plain-map" "$1"; sqlite3 "$1/swan.db" "UPDATE meta SET value = '8' WHERE key = 'schema_version'"; }
prep_no_version() { prep_copy "$base/plain-map" "$1"; sqlite3 "$1/swan.db" "DELETE FROM meta WHERE key = 'schema_version'"; }
prep_no_root() { prep_copy "$base/plain-map" "$1"; sqlite3 "$1/swan.db" "DELETE FROM meta WHERE key = 'root'"; }
prep_garbage() { mkdir -p "$1"; printf 'this is no database\n' >"$1/swan.db"; }
prep_caches() { prep_copy "$base/plain-map" "$1"; for f in index-manifest.tsv tsc-files.txt typescript-layers.txt python-files.tsv python-pieces.tsv other.txt; do printf 'old\n' >"$1/$f"; done; }
prep_older_caches() { prep_caches "$1"; sqlite3 "$1/swan.db" "UPDATE meta SET value = '8' WHERE key = 'schema_version'"; }
prep_file() { printf 'a file\n' >"$1"; }
case_of clean-fresh "$r/plain" --clean
WATCH=yes PREP=prep_plain case_of again "$r/plain"
WATCH=yes PREP=prep_plain case_of clean-same-root "$r/plain" --clean
WATCH=yes PREP=prep_plain case_of clean-other-root "$r/order" --clean
WATCH=yes PREP=prep_no_root case_of clean-no-root "$r/plain" --clean
WATCH=yes PREP=prep_garbage case_of clean-garbage "$r/plain" --clean
WATCH=yes PREP=prep_garbage case_of garbage "$r/plain"
WATCH=yes PREP=prep_older case_of older "$r/plain"
WATCH=yes PREP=prep_older case_of clean-older "$r/plain" --clean
WATCH=yes PREP=prep_no_version case_of no-version "$r/plain"
WATCH=yes PREP=prep_caches case_of clean-caches "$r/plain" --clean
WATCH=yes PREP=prep_caches case_of caches-kept "$r/plain"
WATCH=yes PREP=prep_older_caches case_of older-caches "$r/plain"
WATCH=yes PREP=prep_file case_of out-is-a-file "$r/plain"
# ---- the content stamps ----
case_of py-many "$r/py-many"
case_of py-many-one-job "$r/py-many" SWAN_STAMP_JOBS=1
case_of py-many-three-jobs "$r/py-many" SWAN_STAMP_JOBS=3
case_of cos-workers "$r/cos" SWAN_STAMP_JOBS=2 SWAN_STAMP_MIN=1
case_of cos-threads "$r/cos" SWAN_STAMP_JOBS=2 SWAN_STAMP_MIN=1 SWAN_STAMP_MODE=threads
# A map of cos, made by the Goose program, to start from.
if [ ! -e "$base/cos-map/swan.db" ]; then
    rm -rf "${base:?}/cos-map"
    home_as_installed "$base/old/home"
    (cd "$base/old" && env "${UNSET[@]}" home/bin/swan map "$r/cos" "$base/cos-map" >/dev/null 2>&1 </dev/null)
    [ -e "$base/cos-map/indexed-texts.tsv" ] || { echo "port-map: the Goose program made no map of the cos repo"; exit 2; }
fi
mtime_ns() { stat -c '%.9Y' "$1" | tr -d .; }
prep_cos() { prep_copy "$base/cos-map" "$1"; }
prep_cos_no_texts() { prep_copy "$base/cos-map" "$1"; rm -f "$1"/texts/*; }
prep_cos_unknown() { prep_copy "$base/cos-map" "$1"; sed -i -E 's/^(a\.ts)\t[^\t]+\t/\1\t?\t/' "$1/indexed-texts.tsv"; }
prep_cos_short_line() { prep_copy "$base/cos-map" "$1"; sed -i -E 's/^(a\.ts\t[^\t]+)\t.*$/\1/' "$1/indexed-texts.tsv"; }
prep_cos_no_record() { prep_copy "$base/cos-map" "$1"; : >"$1/indexed-texts.tsv"; }
prep_cos_bad_stamp() { prep_copy "$base/cos-map" "$1"; sed -i -E 's/^(a\.ts\t[0-9]+\t[0-9]+)\t-?[0-9]+\t/\1\tnot-a-number\t/' "$1/content-stamps.tsv"; }
# Rows Swan moved itself: the time it noted in the map, and the text they match now.
prep_cos_moved() { prep_copy "$base/cos-map" "$1"; sqlite3 "$1/swan.db" "UPDATE files SET edited_mtime = 123 WHERE file = 'a.ts'"; printf 'a.ts\t%s\t123\n' "$2" >"$1/row-basis.tsv"; }
prep_cos_moved_known() { prep_cos_moved "$1" "$(cut -f2 "$base/cos-map/indexed-texts.tsv" | head -1)"; }
prep_cos_moved_lost() { prep_cos_moved "$1" 4242; }
prep_cos_moved_other_time() { prep_cos_moved_known "$1"; sed -i -E 's/\t123$/\t999/' "$1/row-basis.tsv"; }
prep_py_many() { prep_copy "$base/old/maps/py-many" "$1"; }
prep_cos_moved_now() { prep_copy "$base/cos-map" "$1"; sqlite3 "$1/swan.db" "UPDATE files SET edited_mtime = $(mtime_ns "$r/cos-comment/a.ts") WHERE file = 'a.ts'"; }
PREP=prep_cos case_of cos-again "$r/cos"
PREP=prep_cos case_of cos-clean "$r/cos" --clean
PREP=prep_cos case_of cos-comment "$r/cos-comment"
PREP=prep_cos case_of cos-code "$r/cos-code"
PREP=prep_cos case_of cos-more "$r/cos-more"
PREP=prep_cos_no_texts case_of cos-comment-no-texts "$r/cos-comment"
PREP=prep_cos_no_texts case_of cos-again-no-texts "$r/cos"
PREP=prep_cos_unknown case_of cos-unknown "$r/cos"
PREP=prep_cos_unknown case_of cos-comment-unknown "$r/cos-comment"
PREP=prep_cos_short_line case_of cos-comment-short-line "$r/cos-comment"
PREP=prep_cos_no_record case_of cos-comment-no-record "$r/cos-comment"
PREP=prep_cos_bad_stamp case_of cos-bad-stamp "$r/cos"
PREP=prep_cos case_of cos-same-time "$r/cos-same-time"
PREP=prep_cos case_of cos-same-size "$r/cos-same-size"
PREP=prep_cos_unknown case_of cos-unknown-clean "$r/cos" --clean
PREP=prep_cos_unknown case_of cos-code-unknown "$r/cos-code"
DEPENDS=py-many PREP=prep_py_many case_of py-many-again "$r/py-many"
PREP=prep_cos_moved_known case_of cos-comment-moved-known "$r/cos-comment"
PREP=prep_cos_moved_lost case_of cos-comment-moved-lost "$r/cos-comment"
PREP=prep_cos_moved_other_time case_of cos-comment-moved-other-time "$r/cos-comment"
PREP=prep_cos_moved_now case_of cos-comment-moved-now "$r/cos-comment"
# ---- TypeScript: its config, the indexer's patch, tsc's list of files ----
case_of ts-config "$r/ts-config"
case_of ts-config-one-job "$r/ts-config" SWAN_JOBS=1
case_of ts-outside "$r/ts-outside"
case_of ts-config-bad "$r/ts-config-bad"
case_of ts-config-bad-only "$r/ts-config-bad-only"
case_of ts-config-empty "$r/ts-config-empty"
case_of ts-types-missing "$r/ts-types-missing"
case_of ts-nested "$r/ts-nested"
case_of ts-nested-one-job "$r/ts-nested" SWAN_JOBS=1
case_of ts-refs "$r/ts-refs"
case_of ts-refs-one-job "$r/ts-refs" SWAN_JOBS=1
case_of ts-other-name-one-job "$r/ts-other-name" SWAN_JOBS=1
case_of ts-other-name "$r/ts-other-name"
case_of js-only "$r/js-only"
case_of ts-ign "$r/ts-ign"
case_of ts-clean "$r/ts-config" --clean
# When tsc is asked at all: with places to split into, or with files enough
# (200, or $SWAN_TS_LAYER_MIN) or projects enough to make one chunk worth it.
case_of plain-one-job "$r/plain" SWAN_JOBS=1
case_of plain-two-jobs "$r/plain" SWAN_JOBS=2
case_of plain-jobs-zero "$r/plain" SWAN_JOBS=0
case_of plain-jobs-word "$r/plain" SWAN_JOBS=many
case_of plain-layer-1 "$r/plain" SWAN_JOBS=1 SWAN_TS_LAYER_MIN=1
case_of endings-layer-8 "$r/ts-endings" SWAN_JOBS=1 SWAN_TS_LAYER_MIN=8
case_of endings-layer-9 "$r/ts-endings" SWAN_JOBS=1 SWAN_TS_LAYER_MIN=9
case_of endings-layer-zero "$r/ts-endings" SWAN_JOBS=1 SWAN_TS_LAYER_MIN=0
case_of endings-layer-word "$r/ts-endings" SWAN_JOBS=1 SWAN_TS_LAYER_MIN=few
# The places other languages take: Python's pieces (planned for six places
# at most), one for a cargo project, one for Java, one for C and CUDA.
case_of cos-two-jobs "$r/cos" SWAN_JOBS=2
case_of cos-three-jobs "$r/cos" SWAN_JOBS=3
for d in ts-cargo ts-java ts-c ts-cuda ts-rs ts-kt; do case_of "$d-two-jobs" "$r/$d" SWAN_JOBS=2; done
case_of ts-cargo-three-jobs "$r/ts-cargo" SWAN_JOBS=3
case_of ts-c-cuda-three-jobs "$r/ts-c-cuda" SWAN_JOBS=3
case_of ts-py-seven-eight-jobs "$r/ts-py-seven" SWAN_JOBS=8
case_of ts-py-seven-nine-jobs "$r/ts-py-seven" SWAN_JOBS=9
# The indexer's patch: put in where it is missing, and marked; a mark is
# believed while it names the file's size; an indexer that cannot be
# patched, or is not to be, is said so and TypeScript runs whole.
HOME_PREP=home_plain case_of patch-plain "$r/plain"
HOME_PREP=home_plain_marked case_of patch-plain-marked "$r/plain"
HOME_PREP=home_unmarked case_of patch-unmarked "$r/plain"
HOME_PREP='home_mark 9%s\040stable' case_of patch-mark-other-size "$r/plain"
HOME_PREP='home_mark %s\040stale' case_of patch-mark-other-words "$r/plain"
HOME_PREP='home_mark \040%s\040stable\n' case_of patch-mark-spaced "$r/plain"
HOME_PREP=home_no_indexer case_of patch-no-indexer "$r/plain"
HOME_PREP=home_empty_indexer case_of patch-empty-indexer "$r/plain"
HOME_PREP=home_half_indexer case_of patch-half-indexer "$r/plain"
HOME_PREP=home_half_indexer case_of patch-half-nested "$r/ts-nested" SWAN_JOBS=1
case_of patch-off "$r/plain" SWAN_SCIP_TYPESCRIPT_PATCH=0
HOME_PREP=home_plain case_of patch-off-plain "$r/plain" SWAN_SCIP_TYPESCRIPT_PATCH=0
HOME_PREP=home_plain_marked case_of patch-off-plain-marked "$r/plain" SWAN_SCIP_TYPESCRIPT_PATCH=0
HOME_PREP=home_plain case_of patch-on-plain "$r/plain" SWAN_SCIP_TYPESCRIPT_PATCH=1
HOME_PREP=home_plain case_of patch-00-plain "$r/plain" SWAN_SCIP_TYPESCRIPT_PATCH=00
HOME_PREP=home_plain case_of patch-plain-no-typescript "$r/rs-only"
# tsc's list is kept, and asked for again when a file comes or goes or a
# config changes, and not when only code does.
prep_ts_config() { prep_copy "$base/old/maps/ts-config" "$1"; }
prep_ts_old_list() { prep_ts_config "$1"; sed -i '1s/ roots$//' "$1/tsc-files.txt"; }
prep_ts_longer_key() { prep_ts_config "$1"; sed -i '1s/ roots$/ roots and more/' "$1/tsc-files.txt"; }
prep_ts_other_program() { prep_ts_config "$1"; sed -i '1s/^/9/' "$1/tsc-program.txt"; }
prep_ts_no_program() { prep_ts_config "$1"; rm -f "$1/tsc-program.txt"; }
prep_ts_no_list() { prep_ts_config "$1"; rm -f "$1/tsc-files.txt"; }
prep_before() { prep_copy "$base/before/${1##*/}" "$1"; }
DEPENDS=ts-config PREP=prep_ts_config case_of ts-config-again "$r/ts-config"
DEPENDS=ts-config PREP=prep_ts_config case_of ts-config-again-clean "$r/ts-config" --clean
DEPENDS=ts-config PREP=prep_ts_config case_of ts-config-again-one-job "$r/ts-config" SWAN_JOBS=1
DEPENDS=ts-config PREP=prep_ts_old_list case_of ts-config-old-list "$r/ts-config"
DEPENDS=ts-config PREP=prep_ts_longer_key case_of ts-config-longer-key "$r/ts-config"
DEPENDS=ts-config PREP=prep_ts_other_program case_of ts-config-other-program "$r/ts-config"
DEPENDS=ts-config PREP=prep_ts_no_program case_of ts-config-no-program "$r/ts-config"
DEPENDS=ts-config PREP=prep_ts_no_list case_of ts-config-no-list "$r/ts-config"
for d in $BEFORE; do PREP=prep_before case_of "$d" "$r/$d"; done
# What tsc says, from a made-up tsc: which of its answers are taken, and
# which of the files it lists are roots.
for s in roots-order roots-good show-fails show-none-listed show-no-files show-nospace show-empty-files show-unclosed show-short show-unquoted show-unquoted-end show-backslash \
         list-exit1 list-exit2 list-exit3 list-exit1-none list-exit1-prefix list-none; do
    HOME_PREP="home_tsc $s" case_of "tsc-$s" "$r/ts-fake"
done
for s in probe-first-line probe-leading-newline probe-no-newline probe-spaces probe-silent probe-stderr probe-ok; do
    HOME_PREP="home_tsc $s" case_of "tsc-$s" "$r/ts-fake-config"
done
# What a child is given to run with, said by the made-up tsc: Swan's own
# programs first on PATH, a JDK where there is Java or Kotlin, a stand-in
# clang++ where there is C and no clang++, .NET where there is C#, the
# repo's virtualenv once it is trusted, and room for Node.
P=/usr/local/bin:/usr/bin:/bin
env_case() { local name=$1 repo=$2; shift 2; HOME_PREP="home_tsc env" case_of "env-$name" "$r/$repo" "$@"; }
env_case plain ts-env "PATH=$P"
env_case heap ts-env "PATH=$P" SWAN_NODE_HEAP_MB=123
env_case heap-empty ts-env "PATH=$P" SWAN_NODE_HEAP_MB=
env_case java ts-env-java "PATH=$P"
env_case java-home ts-env-java "PATH=$P" JAVA_HOME=/opt/made-up-jdk
env_case java-home-empty ts-env-java "PATH=$P" JAVA_HOME=
env_case java-home-no-java ts-env "PATH=$P" JAVA_HOME=/opt/made-up-jdk
env_case kt ts-env-kt "PATH=$P"
env_case c ts-env-c "PATH=$P"
env_case c-clang ts-env-c "PATH=$P:$r/clangbin"
env_case cuda ts-env-cuda "PATH=$P"
env_case cs ts-env-cs "PATH=$P"
env_case venv ts-env-venv "PATH=$P"
env_case venv-trusted ts-env-venv "PATH=$P" SWAN_TRUST_BUILD=1
env_case all ts-env-all "PATH=$P" SWAN_TRUST_BUILD=1
# ---- TypeScript: the other projects of a repo ----
# Which config owns each file: the nearest above it that lists it; in one
# folder, its tsconfig.json. What tsc cannot read is counted and said.
case_of ts-proj-dirs "$r/ts-proj-dirs"
case_of ts-proj-dirs-one-job "$r/ts-proj-dirs" SWAN_JOBS=1
case_of ts-proj-dirs-clean "$r/ts-proj-dirs" --clean
case_of ts-proj-chain "$r/ts-proj-chain"
case_of ts-proj-unread "$r/ts-proj-unread"
case_of ts-proj-all-unread "$r/ts-proj-all-unread"
case_of ts-proj-overlap "$r/ts-proj-overlap"
case_of ts-proj-same-folder "$r/ts-proj-same-folder"
case_of ts-proj-same-folder-ref-first "$r/ts-proj-same-folder-ref-first"
case_of ts-proj-root-same "$r/ts-proj-root-same"
case_of ts-proj-own-base "$r/ts-proj-own-base"
case_of ts-proj-no-root "$r/ts-proj-no-root"
case_of ts-proj-hidden-ref "$r/ts-proj-hidden-ref"
case_of ts-proj-self-ref "$r/ts-proj-self-ref"
case_of ts-proj-two-refs "$r/ts-proj-two-refs"
case_of ts-proj-outside "$r/ts-proj-outside"
HOME_PREP="home_tsc projects-many" case_of ts-proj-64 "$r/ts-proj-64"
HOME_PREP="home_tsc projects-many" case_of ts-proj-66 "$r/ts-proj-66"
HOME_PREP="home_tsc projects" case_of ts-proj-fake "$r/ts-proj-fake"
HOME_PREP="home_tsc projects-own" case_of ts-proj-own-fake "$r/ts-proj-own-fake"
# The answer is kept under the key of tsc's list, and asked for again without it.
prep_ts_dirs() { prep_copy "$base/old/maps/ts-proj-dirs" "$1"; }
prep_ts_dirs_other_key() { prep_ts_dirs "$1"; sed -i '1s/^/9/' "$1/tsc-projects.txt"; }
prep_ts_dirs_no_projects() { prep_ts_dirs "$1"; rm -f "$1/tsc-projects.txt"; }
DEPENDS=ts-proj-dirs PREP=prep_ts_dirs case_of ts-proj-dirs-again "$r/ts-proj-dirs"
DEPENDS=ts-proj-dirs PREP=prep_ts_dirs_other_key case_of ts-proj-dirs-other-key "$r/ts-proj-dirs"
DEPENDS=ts-proj-dirs PREP=prep_ts_dirs_no_projects case_of ts-proj-dirs-no-projects "$r/ts-proj-dirs"
# ---- TypeScript: the chunks of a project, and the layers over them ----
# How a project is cut: its sources by size, largest first, each into the
# lightest chunk; as many chunks as there is room for, with four sources or
# more to each; one chunk of all when there is room for none but the project
# is large enough for layers.
case_of ts-chunks-two "$r/ts-chunks" SWAN_JOBS=2
case_of ts-chunks-three "$r/ts-chunks" SWAN_JOBS=3
case_of ts-chunks-four "$r/ts-chunks" SWAN_JOBS=4
case_of ts-chunks-one "$r/ts-chunks" SWAN_JOBS=1 SWAN_TS_LAYER_MIN=1
case_of ts-chunks-none "$r/ts-chunks" SWAN_JOBS=1
case_of ts-chunks-clean "$r/ts-chunks" --clean SWAN_JOBS=2
case_of ts-ties-two "$r/ts-ties" SWAN_JOBS=2
case_of ts-ties-three "$r/ts-ties" SWAN_JOBS=3
case_of ts-empty "$r/ts-empty" SWAN_JOBS=2
case_of ts-eight "$r/ts-eight" SWAN_JOBS=2
case_of ts-seven "$r/ts-seven" SWAN_JOBS=2
case_of ts-ref-far "$r/ts-ref-far" SWAN_JOBS=2
HOME_PREP="home_tsc chunks-odd" case_of ts-fake-chunks "$r/ts-fake-chunks" SWAN_JOBS=2
# Several projects: each cut by itself, with its part of the room.
case_of ts-proj-import "$r/ts-proj-import" SWAN_JOBS=1
case_of ts-chp-one-job "$r/ts-chp" SWAN_JOBS=1
case_of ts-chp-two-jobs "$r/ts-chp" SWAN_JOBS=2
case_of ts-chp-four-jobs "$r/ts-chp" SWAN_JOBS=4
case_of ts-chp-eight-jobs "$r/ts-chp" SWAN_JOBS=8
# A second map of a repo that was changed after its first (make_before): a
# chunk is kept while its files, what the chunks share and the plan are the
# same; a small change is indexed as a layer over the chunks.
for d in $BEFORE_TWO; do PREP=prep_before case_of "$d" "$r/$d" SWAN_JOBS=2; done
for d in $BEFORE_FOUR; do PREP=prep_before case_of "$d" "$r/$d" SWAN_JOBS=4; done
prep_same() { prep_copy "$base/before/ts-ch-same" "$1"; }
prep_edit() { prep_copy "$base/before/ts-ch-edit" "$1"; }
prep_lone() { prep_copy "$base/before/ts-ch-lone" "$1"; }
prep_chp() { prep_copy "$base/before/ts-chp-same" "$1"; }
PREP=prep_same case_of ch-same-clean "$r/ts-ch-same" --clean SWAN_JOBS=2
PREP=prep_same case_of ch-same-three-jobs "$r/ts-ch-same" SWAN_JOBS=3
PREP=prep_same case_of ch-same-one-job "$r/ts-ch-same" SWAN_JOBS=1
PREP=prep_same case_of ch-same-one-chunk "$r/ts-ch-same" SWAN_JOBS=1 SWAN_TS_LAYER_MIN=1
PREP=prep_edit case_of ch-edit-clean "$r/ts-ch-edit" --clean SWAN_JOBS=2
PREP=prep_edit case_of ch-edit-three-jobs "$r/ts-ch-edit" SWAN_JOBS=3
PREP=prep_chp case_of chp-same-two-jobs "$r/ts-chp-same" SWAN_JOBS=2
# What says an index can be kept: its line in the record, with this label,
# this fingerprint and this file, and the file there.
prep_same_no_index() { prep_same "$1"; rm "$1/index-typescript-1.scip"; }
prep_same_other_fp() { prep_same "$1"; sed -i -E '/^scip-typescript 0\/2\t/s/\t[0-9]+\t/\t1\t/' "$1/index-manifest.tsv"; }
prep_same_other_label() { prep_same "$1"; sed -i -E 's|^scip-typescript 0/2\t|scip-typescript 0/3\t|' "$1/index-manifest.tsv"; }
prep_same_other_target() { prep_same "$1"; sed -i -E '/^scip-typescript 1\/2\t/s|index-typescript-1\.scip$|index-typescript-0.scip|' "$1/index-manifest.tsv"; }
prep_same_four_fields() { prep_same "$1"; sed -i -E '/^scip-typescript 1\/2\t/s|$|\tmore|' "$1/index-manifest.tsv"; }
prep_same_no_record() { prep_same "$1"; rm "$1/index-manifest.tsv"; }
for p in no_index other_fp other_label other_target four_fields no_record; do PREP=prep_same_$p case_of "ch-same-${p//_/-}" "$r/ts-ch-same" SWAN_JOBS=2; done
# The last map's plan is kept while it holds the same files, however they
# are arranged in it, and one project's in each chunk.
prep_plan() { "${@:2}" <"$1/typescript-chunks.txt" >"$1/plan.new"; mv "$1/plan.new" "$1/typescript-chunks.txt"; }
prep_same_swapped() { prep_same "$1"; prep_plan "$1" tac; }
prep_same_one_line() { prep_same "$1"; prep_plan "$1" paste -s; }
prep_same_blank() { prep_same "$1"; prep_plan "$1" sed 1G; }
prep_same_no_newline() { prep_same "$1"; prep_plan "$1" head -c -1; }
prep_same_other_file() { prep_same "$1"; prep_plan "$1" sed 's|/src/d\.ts|/src/zz.ts|'; }
prep_same_fewer() { prep_same "$1"; prep_plan "$1" sed 's|\t[^\t]*/src/d\.ts||'; }
prep_same_twice() { prep_same "$1"; prep_plan "$1" sed -E '1s|^([^\t]*)\t|\1\t\1\t|'; }
prep_same_empty_plan() { prep_same "$1"; : >"$1/typescript-chunks.txt"; }
prep_same_no_plan() { prep_same "$1"; rm "$1/typescript-chunks.txt"; }
for p in swapped one_line blank no_newline other_file fewer twice empty_plan no_plan; do PREP=prep_same_$p case_of "ch-same-${p//_/-}" "$r/ts-ch-same" SWAN_JOBS=2; done
prep_chp_merged() { prep_chp "$1"; { sed -n 1p "$1/typescript-chunks.txt"; sed -n '2,3p' "$1/typescript-chunks.txt" | paste -s; } >"$1/plan.new"; mv "$1/plan.new" "$1/typescript-chunks.txt"; }
PREP=prep_chp_merged case_of chp-merged "$r/ts-chp-same" SWAN_JOBS=4
# Layers: kept while the chunks, what they share and the layers' own indexes
# are there, the layers cover no more than a quarter of the files, and there
# are no more than six. prep_layers <map folder> <id> <files>...: the folder
# says it has these layers, newest first, each with an index.
prep_layers() { local d=$1; shift; : >"$d/typescript-layers.txt"; while [ $# -gt 0 ]; do printf '%s\t%s\n' "$1" "$2" >>"$d/typescript-layers.txt"; : >"$d/index-typescript-layer-$1.scip"; shift 2; done; }
prep_same_layers() { prep_same "$1"; prep_layers "$1" 3 src/d.ts 1 src/e.ts,,src/f.ts,src/g.ts; }
prep_same_layers_shared() { prep_same_layers "$1"; printf '1' >"$1/typescript-shared.txt"; }
prep_same_layers_no_shared() { prep_same_layers "$1"; rm "$1/typescript-shared.txt"; }
prep_same_layers_missing() { prep_same_layers "$1"; rm "$1/index-typescript-layer-1.scip"; }
prep_same_layers_no_chunk() { prep_same_layers "$1"; rm "$1/index-typescript-0.scip"; }
prep_same_layers_six() { prep_same "$1"; prep_layers "$1" 0 src/d.ts 1 src/d.ts 2 src/d.ts 3 src/d.ts 4 src/d.ts 5 src/d.ts; }
prep_same_layers_seven() { prep_same "$1"; prep_layers "$1" 0 src/d.ts 1 src/d.ts 2 src/d.ts 3 src/d.ts 4 src/d.ts 5 src/d.ts 6 src/d.ts; }
prep_same_layers_quarter() { prep_same "$1"; prep_layers "$1" 0 src/d.ts,src/e.ts,src/f.ts,src/g.ts; }
prep_same_layers_over() { prep_same "$1"; prep_layers "$1" 0 src/d.ts,src/e.ts,src/f.ts,src/g.ts,src/h.ts; }
prep_same_layers_odd_lines() { prep_same_layers "$1"; printf 'no tab in this line\n\n\tsrc/h.ts\n' >>"$1/typescript-layers.txt"; }
prep_same_layers_swapped() { prep_same_layers "$1"; prep_plan "$1" tac; }
for p in layers layers_shared layers_no_shared layers_missing layers_no_chunk layers_six layers_seven layers_quarter layers_over layers_odd_lines layers_swapped; do
    PREP=prep_same_$p case_of "ch-same-${p//_/-}" "$r/ts-ch-same" SWAN_JOBS=2
done
PREP=prep_same_layers case_of ch-same-layers-clean "$r/ts-ch-same" --clean SWAN_JOBS=2
# What counts as changed: a file whose stamp is not the last map's, the
# files that use what it defines (by the last map's rows), and a file whose
# indexed text is unknown.
prep_same_unknown() { prep_same "$1"; sed -i -E 's/^(src\/d\.ts)\t[^\t]+\t/\1\t?\t/' "$1/indexed-texts.tsv"; }
prep_same_stamp() { prep_same "$1"; sed -i -E 's/^(src\/d\.ts)\t.*/\1\t7/' "$1/typescript-files.tsv"; }
prep_same_stamp_decl() { prep_same "$1"; sed -i -E 's/^(src\/types\.d\.ts)\t.*/\1\t7/' "$1/typescript-files.tsv"; }
prep_same_stamps_gone() { prep_same "$1"; printf 'src/zz.ts\t5\nsrc/yy.ts\t6\nno tab here\nsrc/d\t9\n' >>"$1/typescript-files.tsv"; }
prep_same_stamp_missing() { prep_same "$1"; sed -i '/^src\/d\.ts\t/d' "$1/typescript-files.tsv"; }
prep_same_stamp_twice() { prep_same "$1"; printf 'src/d.ts\t7\n' >>"$1/typescript-files.tsv"; }
prep_same_stamp_user() { prep_same "$1"; sed -i -E 's/^(src\/b\.ts)\t.*/\1\t7/' "$1/typescript-files.tsv"; }
# Files gone since the last map, whose rows still say what they defined:
# the files that used those are changed, taken in the order the Goose
# program's dictionary gives the gone files back. A file that only defines
# again what a gone file defined (d.ts here) is not.
prep_same_gone_defs() {
    local f
    prep_same "$1"; printf 'src/was-a.ts\t5\nsrc/was-b.ts\t6\nsrc/was-types.d.ts\t7\nsrc/was-d.ts\t8\n' >>"$1/typescript-files.tsv"
    for f in a.ts b.ts types.d.ts d.ts; do sqlite3 "$1/swan.db" "UPDATE symbols SET def_file = 'src/was-$f' WHERE def_file = 'src/$f'"; done
}
for p in unknown stamp stamp_decl stamps_gone stamp_missing stamp_twice stamp_user gone_defs; do PREP=prep_same_$p case_of "ch-same-${p//_/-}" "$r/ts-ch-same" SWAN_JOBS=2; done
prep_edit_shared() { prep_edit "$1"; printf '1' >"$1/typescript-shared.txt"; }
prep_edit_no_db() { prep_edit "$1"; rm "$1/swan.db"; }
prep_edit_no_table() { prep_edit "$1"; sqlite3 "$1/swan.db" "DROP TABLE occurrences"; }
prep_edit_no_stamps() { prep_edit "$1"; : >"$1/typescript-files.tsv"; }
prep_edit_user_too() { prep_edit "$1"; sed -i -E 's/^(src\/b\.ts)\t.*/\1\t7/' "$1/typescript-files.tsv"; }
prep_edit_layers() { prep_edit "$1"; prep_layers "$1" x src/d.ts 5 src/e.ts 2 src/a.ts; }
prep_edit_layers_five() { prep_edit "$1"; prep_layers "$1" 0 src/d.ts 1 src/d.ts 2 src/d.ts 3 src/d.ts 4 src/d.ts; }
prep_edit_layers_six() { prep_edit "$1"; prep_layers "$1" 0 src/d.ts 1 src/d.ts 2 src/d.ts 3 src/d.ts 4 src/d.ts 5 src/d.ts; }
prep_edit_layers_quarter() { prep_edit "$1"; prep_layers "$1" 0 src/d.ts,src/e.ts; }
prep_edit_layers_over() { prep_edit "$1"; prep_layers "$1" 0 src/d.ts,src/e.ts,src/f.ts; }
for p in shared no_db no_table no_stamps user_too layers layers_five layers_six layers_quarter layers_over; do PREP=prep_edit_$p case_of "ch-edit-${p//_/-}" "$r/ts-ch-edit" SWAN_JOBS=2; done
prep_lone_shared() { prep_lone "$1"; printf '1' >"$1/typescript-shared.txt"; }
PREP=prep_lone_shared case_of ch-lone-shared "$r/ts-ch-lone" SWAN_JOBS=2
# ---- Python: scip-python's two fixes, as a map finds them in its home ----
home_py_gone() { rm -f "$1/$PYD/pyright-internal.js" "$1/$PYD/scip-python.js" "$1/$PYD/.swan-reach-patch" "$1/$PYD/.swan-site-patch"; }
home_py_plain() { home_py_gone "$1"; cp "$base/py-reach.plain" "$1/$PYD/pyright-internal.js"; cp "$base/py-site.plain" "$1/$PYD/scip-python.js"; }
home_py_plain_marked() { home_py_plain "$1"; printf '%s' "$(stat -c %s "$base/py-reach.plain")" >"$1/$PYD/.swan-reach-patch"; printf '%s' "$(stat -c %s "$base/py-site.plain")" >"$1/$PYD/.swan-site-patch"; }
home_py_unmarked() { rm -f "$1/$PYD/.swan-reach-patch" "$1/$PYD/.swan-site-patch"; }
# home_py_marks <format> <home>: what the marks say of each file's size.
home_py_marks() { home_py_unmarked "$2"; printf "$1" "$(stat -c %s "$base/py-reach.patched")" >"$2/$PYD/.swan-reach-patch"; printf "$1" "$(stat -c %s "$base/py-site.patched")" >"$2/$PYD/.swan-site-patch"; }
home_py_reach_plain() { rm -f "$1/$PYD/pyright-internal.js" "$1/$PYD/.swan-reach-patch"; cp "$base/py-reach.plain" "$1/$PYD/pyright-internal.js"; }
home_py_site_plain() { rm -f "$1/$PYD/scip-python.js" "$1/$PYD/.swan-site-patch"; cp "$base/py-site.plain" "$1/$PYD/scip-python.js"; }
home_py_empty() { home_py_gone "$1"; : >"$1/$PYD/pyright-internal.js"; : >"$1/$PYD/scip-python.js"; }
home_py_other() { home_py_gone "$1"; printf 'no bundle of pyright\n' >"$1/$PYD/pyright-internal.js"; printf 'no scip-python\n' >"$1/$PYD/scip-python.js"; }
PYR="$r/py-src-not"
HOME_PREP=home_py_plain case_of py-home-plain "$PYR"
HOME_PREP=home_py_plain case_of py-home-plain-off "$PYR" SWAN_SCIP_PYTHON_PATCH=0
HOME_PREP=home_py_plain case_of py-home-plain-on "$PYR" SWAN_SCIP_PYTHON_PATCH=1
HOME_PREP=home_py_plain case_of py-home-plain-00 "$PYR" SWAN_SCIP_PYTHON_PATCH=00
HOME_PREP=home_py_plain case_of py-home-plain-no-word "$PYR" SWAN_SCIP_PYTHON_PATCH=
HOME_PREP=home_py_plain_marked case_of py-home-plain-marked "$PYR"
HOME_PREP=home_py_unmarked case_of py-home-unmarked "$PYR"
HOME_PREP=home_py_unmarked case_of py-home-unmarked-off "$PYR" SWAN_SCIP_PYTHON_PATCH=0
HOME_PREP='home_py_marks %s1' case_of py-home-other-size "$PYR"
HOME_PREP='home_py_marks \n%s\n' case_of py-home-mark-lines "$PYR"
HOME_PREP='home_py_marks x%s' case_of py-home-mark-word "$PYR"
HOME_PREP=home_py_reach_plain case_of py-home-reach-plain "$PYR"
HOME_PREP=home_py_site_plain case_of py-home-site-plain "$PYR"
# Without its two files scip-python fails, and where the indexers' runs are
# read (a later part) the Goose program takes the failed piece out of the record.
LATER=python-pieces.tsv HOME_PREP=home_py_gone case_of py-home-gone "$PYR"
LATER=python-pieces.tsv HOME_PREP=home_py_empty case_of py-home-empty "$PYR"
LATER=python-pieces.tsv HOME_PREP=home_py_other case_of py-home-other "$PYR"
HOME_PREP=home_py_plain case_of py-home-no-python "$r/plain"
# ---- Python: a virtualenv that is read, and one that is run ----
case_of py-venv "$r/py-venv"
case_of py-venv-trusted "$r/py-venv" SWAN_TRUST_BUILD=1
case_of py-venv-unsealed "$r/py-venv" SWAN_SANDBOX=0
case_of py-venv-clean "$r/py-venv" --clean
case_of py-venv-one "$r/py-venv-one"
case_of py-venv-nover "$r/py-venv-nover"
case_of py-venv-libs "$r/py-venv-libs"
case_of py-venv-both "$r/py-venv-both"
case_of py-venv-both-trusted "$r/py-venv-both" SWAN_TRUST_BUILD=1
case_of py-run "$r/py-run" SWAN_TRUST_BUILD=1
case_of py-run-untrusted "$r/py-run"
LISTED="$r/py-run" case_of py-run-listed "$r/py-run"
case_of py-run-nopip "$r/py-run-nopip" SWAN_TRUST_BUILD=1
case_of py-run-broken "$r/py-run-broken" SWAN_TRUST_BUILD=1
# ---- Python: the survey's virtualenvs ----
case_of py-envs "$r/py-envs" "SWAN_SPREAD_WINGS=$r/sw/py-envs"
case_of py-envs-late "$r/py-envs-late" "SWAN_SPREAD_WINGS=$r/sw/py-envs"
case_of py-envs-nover "$r/py-envs-late" "SWAN_SPREAD_WINGS=$r/sw/py-envs-nover"
case_of py-envs-sub "$r/py-envs-sub" "SWAN_SPREAD_WINGS=$r/sw/py-envs-sub"
case_of py-envs-inner "$r/py-envs-sub" "SWAN_SPREAD_WINGS=$r/sw/py-envs-inner"
case_of py-envs-ghost "$r/py-envs-sub" "SWAN_SPREAD_WINGS=$r/sw/py-envs-ghost"
case_of py-envs-not-surveyed "$r/py-envs" "SWAN_SPREAD_WINGS=$r/sw/not-there"
case_of py-envs-trusted "$r/py-envs" "SWAN_SPREAD_WINGS=$r/sw/py-envs" SWAN_TRUST_BUILD=1
case_of py-envs-real-survey "$r/py-envs"
# ---- Python: a src layout ----
case_of py-src "$r/py-src"
case_of py-src-mod "$r/py-src-mod"
case_of py-src-not "$r/py-src-not"
case_of py-src-file "$r/py-src-file"
# ---- Python: the pieces, and which of their indexes are kept ----
case_of py-dep "$r/py-dep" SWAN_JOBS=6
case_of py-dep-one-job "$r/py-dep" SWAN_JOBS=1
case_of py-dep-two-jobs "$r/py-dep" SWAN_JOBS=2
case_of py-dep-nine-jobs "$r/py-dep" SWAN_JOBS=9
prep_dep() { prep_copy "$base/before/py-dep-same" "$1"; }
# The index a piece's line names; and a file's stamp in the record, made another.
prep_dep_index() { awk -F'\t' -v p="$2" '$1 == p { print $3 }' "$1/python-pieces.tsv"; }
prep_dep_set_stamp() { sed -i -E "s|^($2)\t.*|\1\t7|" "$1/python-files.tsv"; }
prep_dep_no_index() { prep_dep "$1"; rm "$(prep_dep_index "$1" p3)"; }
prep_dep_other_fp() { prep_dep "$1"; sed -i -E '/^p3\t/s/\t[^\t]+\t/\t1-n2\t/' "$1/python-pieces.tsv"; }
prep_dep_old_names() { prep_dep "$1"; sed -i -E '/^p3\t/s/-n2\t/\t/' "$1/python-pieces.tsv"; }
prep_dep_four_fields() { prep_dep "$1"; sed -i -E '/^p3\t/s/$/\tmore/' "$1/python-pieces.tsv"; }
prep_dep_two_fields() { prep_dep "$1"; sed -i -E '/^p3\t/s/\t[^\t]+$//' "$1/python-pieces.tsv"; }
prep_dep_other_target() { prep_dep "$1"; sed -i -E "/^p3\t/s|\t[^\t]+$|\t$1/swan.db|" "$1/python-pieces.tsv"; }
prep_dep_other_piece() { prep_dep "$1"; sed -i -E 's/^p3\t/p33\t/' "$1/python-pieces.tsv"; }
prep_dep_no_pieces() { prep_dep "$1"; rm "$1/python-pieces.tsv"; }
prep_dep_stamp_p10() { prep_dep "$1"; prep_dep_set_stamp "$1" 'p10/mod\.py'; }
prep_dep_stamp_used() { prep_dep "$1"; prep_dep_set_stamp "$1" 'p1/mod\.py'; }
prep_dep_stamp_file() { prep_dep "$1"; prep_dep_set_stamp "$1" 'q/a\.py'; }
prep_dep_stamps_gone() { prep_dep "$1"; printf 'p3/zz.py\t5\nno tab here\np4\t9\n' >>"$1/python-files.tsv"; }
prep_dep_no_stamps() { prep_dep "$1"; : >"$1/python-files.tsv"; }
prep_dep_stamps_missing() { prep_dep "$1"; rm "$1/python-files.tsv"; }
prep_dep_unknown() { prep_dep "$1"; sed -i -E 's/^(p4\/mod\.py)\t[^\t]+\t/\1\t?\t/' "$1/indexed-texts.tsv"; }
prep_dep_stale() { prep_dep "$1"; for f in index-python-1.scip index-python-notes.txt index-pythonx.txt; do printf 'old\n' >"$1/$f"; done; mkdir "$1/index-python-folder"; }
prep_dep_edit_no_db() { prep_copy "$base/before/py-dep-edit" "$1"; rm "$1/swan.db"; }
prep_venv_same() { prep_copy "$base/before/py-venv-same" "$1"; }
prep_py_many_stamp() { prep_py_many "$1"; sed -i -E 's/^(pkg\/m100\.py)\t.*/\1\t7/' "$1/python-files.tsv"; }
STALE="index-python-1.scip index-python-notes.txt index-pythonx.txt index-python-folder"
PREP=prep_dep case_of py-dep-again "$r/py-dep-same" SWAN_JOBS=6
PREP=prep_dep case_of py-dep-again-clean "$r/py-dep-same" --clean SWAN_JOBS=6
ALSO="$(cd "$base/before/py-dep-same" && ls index-python-*.scip | tr '\n' ' ')" PREP=prep_dep case_of py-dep-again-one-job "$r/py-dep-same" SWAN_JOBS=1
for p in no_index other_fp old_names four_fields two_fields other_target other_piece no_pieces stamp_p10 stamp_used stamp_file stamps_gone no_stamps stamps_missing unknown; do
    PREP=prep_dep_$p case_of "py-dep-$(printf '%s' "$p" | tr _ -)" "$r/py-dep-same" SWAN_JOBS=6
done
ALSO=$STALE PREP=prep_dep_stale case_of py-dep-stale "$r/py-dep-same" SWAN_JOBS=6
ALSO=$STALE PREP=prep_dep_stale case_of py-dep-stale-clean "$r/py-dep-same" --clean SWAN_JOBS=6
PREP=prep_before case_of py-dep-edit "$r/py-dep-edit" SWAN_JOBS=6
PREP=prep_before case_of py-dep-file "$r/py-dep-file" SWAN_JOBS=6
ALSO="$(cd "$base/before/py-dep-gone" && ls index-python-*.scip | tr '\n' ' ')" PREP=prep_before case_of py-dep-gone "$r/py-dep-gone" SWAN_JOBS=6
PREP=prep_before case_of py-dep-more "$r/py-dep-more" SWAN_JOBS=6
PREP=prep_dep_edit_no_db case_of py-dep-edit-no-db "$r/py-dep-edit" SWAN_JOBS=6
PREP=prep_before case_of py-venv-same "$r/py-venv-same"
PREP=prep_before case_of py-venv-more "$r/py-venv-more"
PREP=prep_before case_of py-venv-newer "$r/py-venv-newer"
PREP=prep_venv_same case_of py-venv-same-trusted "$r/py-venv-same" SWAN_TRUST_BUILD=1
DEPENDS=py-many PREP=prep_py_many_stamp case_of py-many-stamp "$r/py-many"
# ---- Rust: the cargo projects ----
case_of rs-root "$r/rs-root"
case_of rs-root-trusted "$r/rs-root" SWAN_TRUST_BUILD=1
case_of rs-root-unsealed-trusted "$r/rs-root" SWAN_SANDBOX=0 SWAN_TRUST_BUILD=1
# Not trusted and not sealed, cargo is not run, and the indexes of Rust an
# earlier map left go: every index-rust*.scip, and nothing else.
RS_STALE="index-rust.scip index-rust-7.scip index-rustx.scip index-rust.txt index-rus.scip index-other.scip"
prep_rs_stale() { local f; mkdir -p "$1"; for f in $RS_STALE; do printf 'old\n' >"$1/$f"; done; }
ALSO=$RS_STALE PREP=prep_rs_stale case_of rs-root-unsealed "$r/rs-root" SWAN_SANDBOX=0
case_of rs-two "$r/rs-two"
prep_rs_two() { prep_copy "$base/old/maps/rs-two" "$1"; }
DEPENDS=rs-two PREP=prep_rs_two case_of rs-two-again "$r/rs-two"
PREP=prep_before case_of rs-two-edit "$r/rs-two-edit"
case_of rs-many "$r/rs-many"
case_of rs-pin "$r/rs-pin"
case_of rs-pin-old "$r/rs-pin-old"
# ---- Java, C#, C and CUDA, and what waits for trust ----
# What waits is not run, and the index an earlier map left of it goes: its
# own, and no other language's. (Where nothing is left to run the map ends
# before the part that removes every index no job names.)
WAITS="index-java.scip index-csharp.scip index-rust.scip index-cxx.scip index-java.txt"
prep_wait() { local f; mkdir -p "$1"; for f in $WAITS; do printf 'old\n' >"$1/$f"; done; }
case_of java-plain "$r/java-plain"
case_of java-plain-trusted "$r/java-plain" SWAN_TRUST_BUILD=1
prep_java_plain() { prep_copy "$base/old/maps/java-plain" "$1"; }
DEPENDS=java-plain PREP=prep_java_plain case_of java-plain-again "$r/java-plain"
for d in java-maven java-gradle java-gradle-kts java-settings java-settings-kts java-both kt-gradle kt-maven cs-proj cs-sln cs-slnx cs-none; do
    ALSO=$WAITS PREP=prep_wait case_of "$d" "$r/$d"
done
case_of c-plain "$r/c-plain"
prep_c_plain() { prep_copy "$base/old/maps/c-plain" "$1"; }
DEPENDS=c-plain PREP=prep_c_plain case_of c-plain-again "$r/c-plain"
case_of cu-plain "$r/cu-plain"
case_of cu-plain-cuda-path "$r/cu-plain" CUDA_PATH=/nowhere/cuda
case_of cu-plain-cuda-path-empty "$r/cu-plain" CUDA_PATH=
for d in c-compdb c-build-compdb c-both-compdb c-header; do case_of "$d" "$r/$d"; done
# ---- the language servers' languages, and a repo with nothing to run ----
case_of go-mods "$r/go-mods"
case_of go-work "$r/go-work"
case_of go-mods-top "$r/go-mods" "SWAN_SPREAD_WINGS=$r/sw/go-top"
case_of go-mods-one "$r/go-mods" "SWAN_SPREAD_WINGS=$r/sw/go-one"
case_of go-mods-not-surveyed "$r/go-mods" "SWAN_SPREAD_WINGS=$r/sw/not-there"
case_of kt-maven-clean "$r/kt-maven" --clean
prep_kt_maven() { prep_copy "$base/old/maps/kt-maven" "$1"; }
DEPENDS=kt-maven PREP=prep_kt_maven case_of kt-maven-again "$r/kt-maven"
DEPENDS=kt-maven PREP=prep_kt_maven case_of kt-maven-again-clean "$r/kt-maven" --clean
case_of nothing-clean "$r/nothing" --clean
case_of wait-all "$r/wait-all"
ALSO=$WAITS PREP=prep_wait case_of wait-all-unsealed "$r/wait-all" SWAN_SANDBOX=0
# ---- fixtures ----
for f in tiny-ts tiny-py tiny-go tiny-rs tiny-java tiny-lua tiny-game go-modules; do
    [ -d "fixtures/$f" ] && case_of "fixture-$f" "$here/fixtures/$f"
done

wait
bad=0
for v in "$work"/verdict/*; do [ -s "$v" ] && { bad=$((bad + 1)); cat "$v"; }; done
if [ $bad = 0 ]; then echo "the same: $total of $total"; exit 0; fi
echo "DIFFERENT: $bad of $total"
exit 1
