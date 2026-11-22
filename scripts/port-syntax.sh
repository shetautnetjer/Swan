#!/usr/bin/env bash
# Stage 3's judge for the syntax-level index (docs/rust-port.md): `swan
# syntax-index <repo> <out.scip> [--skip go]` writes the same index, says
# the same on standard error and exits the same from the Goose program and
# the Rust port. It writes a made-up repo that holds the corners of each of
# the five languages (Go, shell, Make, Ruby, Lua) and of the walk (folders
# left out, links, sizes, #! lines, names that need quoting, line ends), and
# runs the command on it, on each fixture, on this repository and on each
# repo given, through scripts/port-compare.sh; then compares the two index
# files byte for byte.
#
#   scripts/port-syntax.sh [repo...]
#
# SWAN_OLD, SWAN_NEW: as for port-compare.sh.
# Prints one "DIFFERENT (<case>)" block for each disagreement, then "the
# same: N of N" or "DIFFERENT: K of N".
# Exit 0: all the same. 1: some differ. 2: a comparison could not be made
# (a program is missing). 3: the command is not carried yet.
set -uo pipefail
# A repo given by a path from where this was started is found from there.
given=(); for a in "$@"; do given+=("$(realpath -- "$a" 2>/dev/null || printf '%s' "$a")"); done
set -- "${given[@]+"${given[@]}"}"
cd "$(dirname "$0")/.."
here=$PWD

work=$(mktemp -d)
trap 'chmod -R u+rwx "$work" 2>/dev/null; rm -rf "$work"' EXIT
r="$work/repo"

# put <file>: standard input into the file, byte for byte.
put() { mkdir -p "$(dirname "$1")"; cat >"$1"; }
# putt <file>: the same, with each <TAB> turned into a tab.
putt() { mkdir -p "$(dirname "$1")"; sed $'s/<TAB>/\t/g' >"$1"; }

# ---- Go ----
putt "$r/go/a.go" <<'EOF'
package a

import "fmt"

// func Commented(x int) {}
func Plain(x int) int {
<TAB>return x + 1
}

func Generic[T any](x T) T { return x }

func MultiLine(
<TAB>a int,
<TAB>b struct{ x int },
) (int, error) {
<TAB>if a > 0 {
<TAB><TAB>return a, nil
<TAB>}
<TAB>return 0, nil
}

func NoBody(x int) int

func BraceNext(x int)
{
<TAB>Plain(x)
}

func BraceLater(x int)

{
<TAB>Plain(x)
}

type T struct {
<TAB>n int
}

type Iface interface {
<TAB>M() int
}

type Alias = int
type Num int
type Box[K comparable] struct {
<TAB>k K
}
type Open[K comparable
type (
<TAB>A struct {
<TAB><TAB>x int
<TAB>}
<TAB>B interface {
<TAB><TAB>M()
<TAB>}
<TAB>C int
<TAB>D[X any] struct{}
)

func (t *T) M() int { return t.n }
func (T) Static() {}
func (t T) Gen[K any]() {}
func (b *Box[K]) Get() K { return b.k }
func (p *pkg.Thing) Far() {}
func (t *T) Spaced () {}
func ( t  *T ) Wide( ) {}
func () Empty() {}
func (*T) StarOnly() {}
func Run() {}
func (t *T) Run() {}
func Dup() {}
func Dup() {}
func Dup() {}
func Dup() {}

var Counter = 0
const Limit = 10
var (
<TAB>grouped = 1
)
const (
<TAB>alsoGrouped = 2
)
var<TAB>TabVar = 1
variance = 2
constant = 3
typed = 4
function = 5
funcall(5)

func uses() {
<TAB>s := "call Plain here // not a comment { "
<TAB>r := `raw { string Plain`
<TAB>w := `C:\`; Plain(1)
<TAB>c := '{'
<TAB>d := '"'
<TAB>e := "esc \" quote {"
<TAB>t := T{}
<TAB>t.M()
<TAB>t.Plain()
<TAB>Plain(Counter + Limit) // Limit in a comment
<TAB>fmt.Println(s, r, w, c, d, e, M, Static)
<TAB>x.Static()
<TAB>x.Run()
<TAB>Run()
<TAB>Dup()
}
EOF
putt "$r/go/b.go" <<'EOF'
package a

func Plain(y int) int { return y }

type U struct{}

func (u U) M() int { return 1 }

func second() { Plain(2); u.M(); Generic(1) }
EOF
putt "$r/go/c.go" <<'EOF'
package a

func third() {
<TAB>Plain(3)
<TAB>v.M()
<TAB>Shared()
}
EOF
putt "$r/other/d.go" <<'EOF'
package other

func Plain(z int) int { return z }

func fourth() { Plain(4); Generic(2); Counter++; Shared() }
EOF
for i in 1 2 3 4; do printf 'package many\n\nfunc Many() {}\nfunc Shared() {}\n' | put "$r/many/m$i.go"; done
printf 'package many\n\nfunc caller() { Many(); Shared() }\n' | put "$r/many/m5.go"
printf 'package far\n\nfunc faraway() { Many(); Generic(3) }\n' | put "$r/far/f.go"

# ---- shell ----
putt "$r/sh/lib.sh" <<'EOF'
#!/bin/bash
# comment with a brace { and the name helper
function helper {
  echo "in helper ${1}"
}
function with_parens() {
  helper a
}
plain() {
  with_parens; helper
}
spaced ()   {
  :
}
wide ( ) {
  :
}
ns::fn() { echo ns; }
dash-name() { echo d; }
dot.name() { echo d; }
function ns:two { :; }
brace_next()
{
  plain
}
brace_later()

{
  plain
}
oneline() { helper; }
hash_in_word() { echo a#b; }
not_a_func( arg ) { :; }
3bad() { :; }
  indented() { plain; }
function 9bad { :; }
function
function   tabbed<TAB>{ :; }
functional() { :; }
echo after # helper in a comment
x=helper#notcomment
y=a#helper
ns::fn; dash-name; dot.name; ns:two; shared
unbalanced() {
  echo "{"
  if true; then
    echo x
  fi
plain
EOF
printf 'helper2() { helper; plain; }\nshared() { :; }\n' | put "$r/sh/b.bash"
printf 'zfn() { helper; }\n' | put "$r/sh/z.zsh"
printf 'kfn() { helper; }\n' | put "$r/sh/k.ksh"
printf 'shared() { :; }\nuse_far() { helper; shared; }\n' | put "$r/sh2/other.sh"
# A definition line over 200 bytes, with a two-byte character across byte 200.
{ printf 'longsig() { echo '; head -c 182 /dev/zero | tr '\0' x; printf '\xc3\xa9\xc3\xa9 tail; }\n'; } | put "$r/sh/long.sh"

# ---- scripts named only by their #! line ----
printf '#!/bin/sh\nrun_main() { :; }\n' | put "$r/bin/run"
printf '#!/usr/bin/env bash\ntool_main() { run_main; }\n' | put "$r/bin/tool"
printf '#!/usr/bin/env ruby\ndef rb_main\nend\n' | put "$r/bin/rb"
printf '#!/usr/bin/python3\ndef py_main(): pass\n' | put "$r/bin/py"
printf '#! /bin/zsh -f\nzs_main() { :; }\n' | put "$r/bin/zs"
printf '#!/bin/dash\nda_main() { :; }\n' | put "$r/bin/da"
printf '#!/bin/ksh\nks_main() { :; }\n' | put "$r/bin/ksh-one"
printf '#!/usr/bin/env shx\nshx_main() { :; }\n' | put "$r/bin/shx"
printf '#!/usr/bin/perl\n# sh\nlate_main() { :; }\n' | put "$r/bin/late"
{ printf '#!/'; head -c 130 /dev/zero | tr '\0' p; printf '/bash\nfar_main() { :; }\n'; } | put "$r/bin/far"
printf 'echo hi\nnobang() { :; }\n' | put "$r/bin/nobang"
printf '#!/bin/sh\ndotted() { :; }\n' | put "$r/bin/has.dot"
: | put "$r/bin/empty"

# ---- Make ----
putt "$r/Makefile" <<'EOF'
# all: in a comment
VAR := 1
OTHER ::= 2
PLAIN = 3
all: build test
<TAB>@echo all
<TAB>$(MAKE) build

build: src/x.o
<TAB>cc -o build src/x.o
src/x.o: src/x.c
<TAB>cc -c src/x.c
double:: thing
.PHONY: all build
%.o: %.c
<TAB>cc -c $<
spaced : all
<TAB>true
 spaced-recipe: all
9target: all
colon_at_end:
noeq:=x
clean: # trailing comment
<TAB>rm -f build
<TAB># a recipe comment
last: all 9target a#clean
EOF
putt "$r/sub/rules.mk" <<'EOF'
include ../Makefile
extra: all build
<TAB>echo extra
EOF
printf 'gnu: all\n\techo gnu\n' | put "$r/sub/gnu/GNUmakefile"
printf 'lower: all\n' | put "$r/sub/low/makefile"

# ---- Ruby ----
put "$r/rb/app.rb" <<'EOF'
# class Commented
module Outer
  class Inner < Base
    def initialize(a, b)
      @a = a
    end

    def ready?
      true
    end

    def save!
      ready?
    end

    def name=(v)
      @name = v
    end

    def self.build(x)
      new(x, x)
    end

    def one_line; end
  end

  class Deep::Er::Name
  end

  module A::B
  end
end

class lower
end
class
class   Spaced
  def helper ; end
end
def top_level(x)
  puts "a#{helper} #not_comment helper"
  Inner.build(x).save!
  ready? ; helper
end
def tricky
  x = 1
endless = 2
end
definitely = 3
classY = 4
def no_end(x)
  x
EOF
put "$r/rb/other.rb" <<'EOF'
class Other
  def use
    helper; ready?; save!; build(1); Name; Inner
  end
end
EOF
put "$r/Rakefile" <<'EOF'
task :default do
  rake_helper
end
def rake_helper
  top_level(1)
end
EOF

# ---- Lua ----
put "$r/lua/mod.lua" <<'EOF'
-- function commented()
local M = {}
function M.new(name)
  return setmetatable({ name = name }, M)
end
function M:hit(n)
  self.hp = self.hp - n -- comment new
end
local function helper(x)
  return x
end
function global_fn(a, b)
  return helper(a) + b
end
function a.b.c:d()
end
function M.()
end
local x = function(y) return y end
function(z) end
function (anon)
function M.global_fn()
end
local   function   spaced  (q)
end
localfunction nope()
function oddity
functional(1)
function no_end(x)
  return M.new(x), M:hit(1), global_fn(1, 2)
EOF
put "$r/lua/use.lua" <<'EOF'
local m = require("mod")
m.new("a"); m:hit(2); global_fn(1, 2); helper(3); d()
m.global_fn(1)
EOF
printf 'function last_line()\nend' | put "$r/nonl/a.lua"
printf 'nonl_sh() { :; }' | put "$r/nonl/b.sh"

# ---- the walk ----
# Folders a walk leaves out, by name and for being hidden.
for d in node_modules/x vendor dist build target obj venv sub/venv .hidden __pycache__ .gradle; do
    printf 'left_out() { :; }\n' | put "$r/$d/a.sh"
done
# A hidden file is read; a folder named like a file is a folder.
printf 'hidden_file() { :; }\n' | put "$r/.dot.sh"
printf 'inner() { :; }\n' | put "$r/dir.sh/inner.sh"
# Folders the map's git-ignored.txt can name.
printf 'ignored_one() { :; }\n' | put "$r/ignored-dir/x.sh"
printf 'package gen\n\nfunc Generated() {}\n' | put "$r/sub/gen/y.go"
# Links are not followed, to a file or to a folder.
ln -s sh/lib.sh "$r/link.sh"
ln -s sh "$r/linkdir"
# A file of exactly the largest size read, and one byte more.
mkdir -p "$r/big"
{ printf 'big_exact() { :; }\n'; head -c 1000000 /dev/zero | tr '\0' '#'; } | head -c 999999 >"$r/big/exact.sh"; printf '\n' >>"$r/big/exact.sh"
{ printf 'big_over() { :; }\n'; head -c 1000000 /dev/zero | tr '\0' '#'; } | head -c 1000000 >"$r/big/over.sh"; printf '\n' >>"$r/big/over.sh"
[ "$(stat -c %s "$r/big/exact.sh")" = 1000000 ] && [ "$(stat -c %s "$r/big/over.sh")" = 1000001 ] || { echo "port-syntax: the two big files are not 1,000,000 and 1,000,001 bytes"; exit 2; }
# Line ends with a carriage return.
printf 'crlf_fn() {\r\n  helper\r\n}\r\ncrlf_fn\r\n' | put "$r/crlf/win.sh"
printf 'package crlf\r\n\r\nfunc Win() {\r\n\tWin()\r\n}\r\nvar CrVar = 1\r\nconst CrConst = 2\r\ntype CrType int\r\nfunc CrNoBody()\r\n' | put "$r/crlf/win.go"
printf 'crall: dep\r\n\techo x\r\n' | put "$r/crlf/Makefile"
printf 'def cr_no_end\r\n  1\r\n' | put "$r/crlf/a.rb"
# A last line that ends in a carriage return and no line end.
printf 'tail_fn() { :; }\r' | put "$r/crlf/tail.sh"
# Empty files.
: | put "$r/empty/e.sh"; : | put "$r/empty/e.go"; : | put "$r/empty/Makefile"; : | put "$r/empty/e.rb"; : | put "$r/empty/e.lua"
# Bytes that are not UTF-8, in a file and in a name; names that need quoting.
printf 'raw_fn() { echo "\xff\xfe"; }\n\xff raw_fn\n' | put "$r/raw/bin.sh"
printf 'raw_name() { :; }\n' | put "$r/raw/$(printf 'x\xff').sh"
printf 'spaced_name() { :; }\n' | put "$r/we ird/naïve/a b.sh"
printf 'tick() { :; }\n' | put "$r/odd\`tick/q\`r.sh"
printf 'plus() { :; }\n' | put "$r/plus+minus-\$x/z.sh"
# The order of a walk: bytewise, a folder finished before its next sibling.
for d in Z a _u a-b a.b a0 a/inner; do printf 'ordered() { :; }\n' | put "$r/order/$d/f.sh"; done
printf 'ordered() { :; }\nuse_order() { ordered; }\n' | put "$r/order/a.sh"
# A file that cannot be read is left out (unless this runs as root).
printf 'secret() { :; }\n' | put "$r/perm/secret.sh"; chmod 000 "$r/perm/secret.sh"
printf 'open_fn() { secret; }\n' | put "$r/perm/open.sh"

# ---- running both programs ----
each="$work/each"
mkdir -p "$each/old/m" "$each/new/m" "$each/old/ign" "$each/new/ign"
for side in old new; do
    printf 'ignored-dir\nsub/gen\nnot/there\nsh/lib.sh\n' >"$each/$side/ign/git-ignored.txt"
    printf 'sh\nrb\n' >"$each/$side/git-ignored.txt"
    cp -a "$r" "$each/$side/rel" 2>/dev/null
done
# A repo whose own name needs quoting.
odd="$work/we ird\`repo"
mkdir -p "$odd" && printf 'odd_fn() { :; }\n' >"$odd/a.sh"
printf 'not a folder\n' >"$work/a-file"

total=0; bad=0
# judge <case> <repo> <index> [--skip <lang>]: the index is a path from each
# program's own folder.
judge() {
    local label=$1; shift
    local o="$each/old/$2" n="$each/new/$2"
    rm -f "$o" "$n"
    total=$((total + 1))
    PORT_EACH_IN=$each scripts/port-compare.sh syntax-index "$@" >"$work/report" 2>&1
    local code=$?
    if [ $code = 3 ]; then echo "port-syntax: syntax-index is not carried over yet"; exit 3; fi
    if [ $code = 2 ]; then echo "port-syntax: no comparison could be made ($label):"; sed 's/^/    /' "$work/report"; exit 2; fi
    if [ $code = 0 ]; then
        if [ -e "$o" ] && [ -e "$n" ]; then
            if ! cmp -s "$o" "$n"; then
                code=1
                {
                    echo "the index differs (Goose $(stat -c %s "$o") bytes, Rust $(stat -c %s "$n") bytes); its text, Goose < > Rust:"
                    diff <(tr -c '[:print:]' '\n' <"$o" | grep .) <(tr -c '[:print:]' '\n' <"$n" | grep .) | head -20
                } >"$work/report"
            fi
        elif [ -e "$o" ] || [ -e "$n" ]; then
            code=1
            echo "only one program wrote the index" >"$work/report"
        fi
    fi
    if [ $code != 0 ]; then bad=$((bad + 1)); echo "DIFFERENT ($label)"; sed 's/^/    /' "$work/report"; fi
}

judge "made-up" "$r" m/out.scip
judge "made-up --skip go" "$r" m/out.scip --skip go
judge "made-up --skip rust" "$r" m/out.scip --skip rust
judge "made-up, folders git ignores" "$r" ign/out.scip
judge "made-up, folders git ignores, --skip go" "$r" ign/out.scip --skip go
judge "made-up, slashes after the repo" "$r///" m/out.scip
judge "made-up, the index beside git-ignored.txt with no folder named" "$r" out.scip
judge "made-up, the index in ./" "$r" ./out.scip
judge "made-up, no folder for the index" "$r" nowhere/out.scip
judge "made-up, by a path from the program's folder" rel m/out.scip
judge "made-up, the program's own folder" . m/dot.scip
judge "a repo that is not there" "$work/not-there" m/out.scip
judge "a repo that is a file" "$work/a-file" m/out.scip
judge "a repo whose name needs quoting" "$odd" m/out.scip
judge "one folder of the made-up repo" "$r/sh" m/out.scip
for repo in "$here"/fixtures/*/ "$here" "$@"; do
    repo=$(realpath "$repo")
    judge "${repo#"$here"/}" "$repo" m/out.scip
    judge "${repo#"$here"/} --skip go" "$repo" m/out.scip --skip go
done

if [ $bad = 0 ]; then echo "the same: $total of $total"; exit 0; fi
echo "DIFFERENT: $bad of $total"
exit 1
