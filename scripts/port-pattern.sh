#!/usr/bin/env bash
# Stage 3's judge for structural search (docs/rust-port.md): `swan query
# <db> pattern <pattern> [relative_path]` gives the same bytes from the Goose
# program and the Rust port. It writes a made-up repo with code in each of
# the 17 languages Swan has a grammar for (the corners the matcher has to
# get right: strings and comments that hold a `$`, raw and triple-quoted
# strings, C# verbatim strings, PHP heredocs, Lua long brackets, GDScript's
# indentation, `$$$` runs and the commas around them), maps it with the Goose
# program, edits one file after so its matches are stale, and asks every
# pattern below of that map and of each map given, through
# scripts/port-compare.sh.
#
#   scripts/port-pattern.sh [map.db...]
#
# SWAN_OLD, SWAN_NEW: as for port-compare.sh.
# Prints one "DIFFERENT (<map> <pattern> [<path>])" block for each
# disagreement, then "the same: N of N" or "DIFFERENT: K of N".
# Exit 0: all the same. 1: some differ. 2: a comparison could not be made.
set -uo pipefail
cd "$(dirname "$0")/.."
old=${SWAN_OLD:-bin/swan}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
r="$work/repo"
put() { mkdir -p "$(dirname "$1")"; cat >"$1"; }

put "$r/a.ts" <<'EOF'
const x = foo(1, 2);
function f(a: number) { return a + 1; }
let s = "$HOME";
obj.unwrap();
call(x);
call(x, y, z);
if (a) { b(); } else { c(); }
const o = { key: 1 };
const p = { other: 2, key: 3 };
let t = y + y;
let u = y + z;
bar(1, 2,);
// $X
const long = foo("xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx");
EOF
put "$r/b.tsx" <<'EOF'
const el = <div className="x">{name}</div>;
const ok = foo(el);
EOF
put "$r/src/c.js" <<'EOF'
foo(`tmpl $X`);
a.b.c();
x = y + y;
x = y + z;
call(only);
EOF
put "$r/src/d.py" <<'EOF'
def f(a, b):
    return a + b

print("$X")
x = foo(1)
if a:
    pass
'''doc $X'''
'''it's $X'''
# comment $X
def g(q):
    return q
EOF
put "$r/e.rs" <<'EOF'
fn main() {
    let v = x.unwrap();
    let r = r#"raw "$X" "#;
    y.unwrap();
    z.expect("m");
    let w = foo(1);
}
fn empty() {}
EOF
put "$r/f.java" <<'EOF'
class A {
    void m() {
        foo(1);
        String s = """
            text $X
            """;
        if (a) { b(); }
    }
}
EOF
put "$r/g.c" <<'EOF'
int main() { return foo(1); }
char c = '"';
int add(int a, int b) { return a + a; }
EOF
put "$r/g.h" <<'EOF'
int foo(int x);
EOF
put "$r/h.cpp" <<'EOF'
int main() { auto v = foo(1); if (v) { return v; } return 0; }
EOF
put "$r/i.cu" <<'EOF'
__global__ void k(int *a) { a[0] = foo(1); }
EOF
put "$r/j.kt" <<'EOF'
fun f() {
    val s = """raw $X"""
    foo(1)
    val t = x.unwrap()
    val q = """a " $X"""
}
EOF
put "$r/sub/k.lua" <<'EOF'
local x = foo(1) -- c $X
local s = [[long $X]]
local function f()
  local y = foo(2)
  local function inner()
    return foo(4)
  end
  return y
end
EOF
put "$r/l.frag" <<'EOF'
void main() { gl_FragColor = vec4(1.0, 0.0, 0.0, 1.0); }
EOF
put "$r/m.hlsl" <<'EOF'
float4 main() : SV_Target { return float4(1, 1, 1, 1); }
EOF
put "$r/n.wgsl" <<'EOF'
fn f() -> f32 { let v = foo(1.0); return v; }
EOF
put "$r/o.gd" <<'EOF'
func _ready():
	print("hi")
	foo(1)
EOF
put "$r/p.cs" <<'EOF'
class A { void M() { var s = @"verbatim ""$X"""; Foo(1); var t = foo(2); Bar(@"a\", 5); } }
EOF
put "$r/q.php" <<'EOF'
<?php
$x = foo(1);
echo <<<EOT
$X text
EOT;
EOF
put "$r/z.sh" <<'EOF'
#!/bin/sh
greet() { echo hi; }
EOF
# Some indexers fail on code this small or are not installed; the map is
# made all the same from those that ran (syntax-index at least).
"$old" map "$r" "$work/map" >"$work/map.log" 2>&1
[ -f "$work/map/swan.db" ] || { echo "port-pattern: the Goose program made no map of the made-up repo:"; tail -5 "$work/map.log"; exit 2; }
# Edited after the map: its matches are stale.
printf 'x2 = foo(3)\n' >>"$r/src/d.py"

# The patterns, one per line; a line "<pattern>\t<path>" also asks under a path.
patterns=$(cat <<'EOF'
$X.unwrap()
foo($A)
foo($$$ARGS)
call($X, $$$REST)
$A + $A
$A + $B
if ($C) { $$$B }
return $X
"$HOME"
print("$X")
{ $$$A, key: $V }
$_.$M($$$)
fn $F() { $$$B }
$$X
))) not code (((
// $X
r#"raw "$X" "#
@"verbatim ""$X"""
[[long $X]]
'''doc $X'''
"""raw $X"""
<div className="x">{$N}</div>
vec4($$$A)
$X = foo($Y)
local $X = foo($Y)
$X.expect($M)
foo($_)
$F($$$)
local s = [[long $X]]
Bar(@"a\", $Y)
'''it's $X'''
"""a " $X"""
if ($V) { return $V; }
call($$$A, $B)
bar($A, $B)
EOF
)
multi=("$(printf 'def $F($$$P):\n    return $R')" "$(printf "# don't\\nfoo(\$A)")" "$(printf "// it's\\nfoo(\$A)")" "$(printf 'func $F():\n\tprint($X)')" "$(printf '<<<EOT\n$X text\nEOT')" "")
paths=("" "e.rs" "sub" "src/d.py" "nowhere")
# Asked of the made-up map only: on a real repo each would match millions of nodes.
small=('$X')

total=0; bad=0
ask() {   # ask <db> <label> <pattern> [path]
    local db=$1 label=$2; shift 2
    total=$((total + 1))
    scripts/port-compare.sh query "$db" pattern "$@" >"$work/report" 2>&1
    local code=$?
    if [ $code = 2 ]; then echo "port-pattern: no comparison could be made ($label):"; sed 's/^/    /' "$work/report"; exit 2; fi
    if [ $code != 0 ]; then bad=$((bad + 1)); echo "DIFFERENT ($label $(printf '%q ' "$@"))"; sed 's/^/    /' "$work/report"; fi
}
judge_map() {   # judge_map <db> <label>
    local db=$1 label=$2 p
    while IFS= read -r p; do
        for path in "${paths[@]}"; do
            if [ -z "$path" ]; then ask "$db" "$label" "$p"; else ask "$db" "$label" "$p" "$path"; fi
        done
    done <<<"$patterns"
    for p in "${multi[@]}"; do ask "$db" "$label" "$p"; done
}
judge_map "$work/map/swan.db" made-up
for p in "${small[@]}"; do ask "$work/map/swan.db" made-up "$p"; done
for db in "$@"; do judge_map "$db" "$db"; done
if [ $bad = 0 ]; then echo "the same: $total of $total"; exit 0; fi
echo "DIFFERENT: $bad of $total"
exit 1
