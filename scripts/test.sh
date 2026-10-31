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
bun tests/mcp_smoke.ts bin/swan data/tiny-ts/swan.db
bun tests/maps_check.ts
tests/refresh_check.sh
bun tests/edit_check.ts
bun tests/rust_check.ts
bun tests/diag_check.ts
bun tests/lang_check.ts
bun tests/split_check.ts
bun tests/live_check.ts
bun tests/structural_check.ts
bun tests/kotlin_live_check.ts
bun tests/game_live_check.ts
bun tests/trust_check.ts
