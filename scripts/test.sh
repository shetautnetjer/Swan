#!/usr/bin/env bash
# Builds Swan, maps the tiny-ts fixture, drives the MCP server end to end,
# and checks that a refresh after edits equals a fresh build.
set -euo pipefail
cd "$(dirname "$0")/.."
# The fixtures are ours: let indexers and servers run their build files
# (the trust suite, tests/check/trust_suite.goose, checks what happens without it).
export SWAN_TRUST_BUILD=1
scripts/build.sh >/dev/null
scripts/index-repo.sh fixtures/tiny-ts data/tiny-ts >/dev/null
# Suites ported to Goose (tests/check/) run to the end; the result counts at the end.
check_failed=0
bin/swan-check mcp maps || check_failed=1
tests/refresh_check.sh
tests/cosmetic_check.sh
tests/layer_check.sh
tests/pieces_check.sh
# The installer's, the packager's and the map-locking tests (Python, 2 s).
py_out=$(python3 -m unittest discover -s tests -p 'test_*.py' 2>&1) || check_failed=1
echo "$py_out" | tail -3
bin/swan-check rust split agnostic diag kotlin game live trust edit lang structural pypatch || check_failed=1
# The Goose suites ran to the end; fail now if any of their checks did.
[ "$check_failed" -eq 0 ]
