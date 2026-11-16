#!/usr/bin/env bash
# Builds Swan, maps the tiny-ts fixture, drives the MCP server end to end,
# and checks that a refresh after edits equals a fresh build.
set -euo pipefail
cd "$(dirname "$0")/.."
# The fixtures are ours: let indexers and servers run their build files
# (tests/trust_check.ts checks what happens without this).
export SWAN_TRUST_BUILD=1
scripts/build.sh >/dev/null
scripts/index-repo.sh fixtures/tiny-ts data/tiny-ts >/dev/null
# Run every check, even after one fails, so a failure early on doesn't hide
# the rest; then report them all and exit nonzero if any failed.
failed=()
check() { echo "== $*"; if "$@"; then :; else failed+=("$*"); fi; }
check bun tests/mcp_smoke.ts bin/swan data/tiny-ts/swan.db
check bun tests/maps_check.ts
check tests/refresh_check.sh
check tests/cosmetic_check.sh
check tests/layer_check.sh
check bun tests/edit_check.ts
check bun tests/rust_check.ts
check bun tests/diag_check.ts
check bun tests/lang_check.ts
check bun tests/agnostic_check.ts
check bun tests/split_check.ts
check bun tests/live_check.ts
check bun tests/structural_check.ts
check bun tests/kotlin_live_check.ts
check bun tests/game_live_check.ts
# tests/trust_check.ts runs without SWAN_TRUST_BUILD (it checks untrusted repos).
check env -u SWAN_TRUST_BUILD bun tests/trust_check.ts
if [ ${#failed[@]} -gt 0 ]; then
  echo
  echo "${#failed[@]} check script(s) failed:"
  printf '  %s\n' "${failed[@]}"
  exit 1
fi
echo
echo "all check scripts passed"
