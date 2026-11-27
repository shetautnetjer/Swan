#!/usr/bin/env bash
# The verify gate's own test (docs/superpowers/specs/2026-11-27-verify-gate.md, "Judged by"): each case is a git repo
# made from a fixture, a base commit, and a change in the working tree; scripts/swan-verify judges it in a microVM.
# Runs on the host (it forks VMs; needs `cua` and the checkpoint). Prints ok/FAIL per case; exit 1 if any failed.
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
verify="$here/scripts/swan-verify"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
failed=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; echo "     $(jq -c '{verdict, new: [.new[]? | {step, key}], fixed: [.fixed[]? | .key], already_failing, why}' "$out" 2>/dev/null | cut -c1-400)"; failed=1; fi; }
repo() { rm -rf "$tmp/r"; cp -r "$here/fixtures/$1" "$tmp/r"; cd "$tmp/r"; git init -q; }
commit() { git add -A; git -c user.name=t -c user.email=t@t commit -qm "$1"; }
judge() { out="$tmp/out.json"; "$verify" "$tmp/r" --no-cache >"$out" 2>"$tmp/err.txt"; code=$?; }
has_new() { jq -e --arg s "$1" --arg k "$2" '[.new[] | select(.step == $s and (.key | contains($k)))] | length == 1' "$out" >/dev/null; }

# Rust: a type error.
repo tiny-rs; commit base
sed -i '0,/Tile { side }/s//Tile { side: "x" }/' src/lib.rs
judge
check "rust: a type error is new, with its file" '[ $code = 1 ] && has_new "cargo check" "src/lib.rs: mismatched types"'
git checkout -q src/lib.rs; judge
check "rust: the clean tree passes" '[ $code = 0 ]'

# Go: a failing test.
repo tiny-go
cat > shapes/shapes_test.go <<'EOF'
package shapes

import "testing"

func TestOne(t *testing.T) {
	if 1+1 != 2 {
		t.Fatal("arithmetic")
	}
}
EOF
commit base
sed -i 's/1+1 != 2/1+1 != 3/' shapes/shapes_test.go
judge
check "go: a test that now fails is new, by name" '[ $code = 1 ] && has_new "go test" "TestOne"'

# A failure already at base is not the change's; a fix is reported as fixed.
commit broken
echo "// a comment" >> main.go
judge
check "go: a failure already at base is not blamed on the change" '[ $code = 0 ] && [ "$(jq .already_failing "$out")" -ge 1 ]'
sed -i 's/1+1 != 3/1+1 != 2/' shapes/shapes_test.go
judge
check "go: a fixed test is reported as fixed" '[ $code = 0 ] && jq -e "[.fixed[] | select(.key | contains(\"TestOne\"))] | length == 1" "$out" >/dev/null'

# TypeScript: a type error.
repo tiny-ts; commit base
echo 'export const n: number = "x";' >> src/kinds.ts
judge
check "typescript: a type error is new, with its code" '[ $code = 1 ] && has_new "tsc" "TS2322"'

# Python: a failing test (test_square expects 9 for a square of side 3; it now expects 10).
repo tiny-py; commit base
sed -i 's/Square(3)\]), 9)/Square(3)]), 10)/' test_shapes.py
git diff --quiet && { echo "FAIL python: the fault was not planted"; failed=1; }
judge
check "python: a test that now fails is new, by name" '[ $code = 1 ] && has_new "pytest" "test_square"'

# The network: private ranges are closed, the public internet is not.
repo tiny-go
cat > shapes/net_test.go <<'EOF'
package shapes

import (
	"net"
	"strings"
	"testing"
	"time"
)

// A blackhole route refuses at once, before a packet leaves ("invalid argument" or "unreachable"). A timeout or
// "connection refused" would mean the packet went out.
func TestPrivateClosed(t *testing.T) {
	for _, addr := range []string{"192.168.0.1:80", "10.0.0.1:80", "100.100.100.100:53", "172.17.0.1:53"} {
		_, err := net.DialTimeout("tcp", addr, 2*time.Second)
		if err == nil || !(strings.Contains(err.Error(), "invalid argument") || strings.Contains(err.Error(), "unreachable")) {
			t.Errorf("%s not closed by a route: %v", addr, err)
		}
	}
}

func TestPublicOpen(t *testing.T) {
	c, err := net.DialTimeout("tcp", "proxy.golang.org:443", 10*time.Second)
	if err != nil {
		t.Fatalf("proxy.golang.org: %v", err)
	}
	c.Close()
}
EOF
cp shapes/net_test.go "$tmp/net_test.go"; rm shapes/net_test.go; commit base; cp "$tmp/net_test.go" shapes/
judge
check "network: private ranges get no connection, the public internet does" '[ $code = 0 ] && [ "$(jq "[.closed_networks[]] | length" "$out")" -ge 5 ]'

exit $failed
