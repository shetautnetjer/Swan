#!/usr/bin/env bash
# Builds Swan, maps the tiny-ts fixture, and drives the MCP server end to end.
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/build.sh >/dev/null
scripts/index-repo.sh fixtures/tiny-ts data/tiny-ts >/dev/null
bun tests/mcp_smoke.ts bin/swan data/tiny-ts/swan.db
