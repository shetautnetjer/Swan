#!/usr/bin/env bash
# Builds Swan, maps the tiny-ts fixture, drives the MCP server end to end,
# and checks that a refresh after edits equals a fresh build.
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/build.sh >/dev/null
scripts/index-repo.sh fixtures/tiny-ts data/tiny-ts >/dev/null
bun tests/mcp_smoke.ts bin/swan data/tiny-ts/swan.db
tests/refresh_check.sh
bun tests/edit_check.ts
bun tests/rust_check.ts
bun tests/diag_check.ts
bun tests/lang_check.ts
bun tests/split_check.ts
bun tests/live_check.ts
bun tests/structural_check.ts
bun tests/kotlin_live_check.ts
