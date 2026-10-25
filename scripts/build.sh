#!/usr/bin/env bash
# Builds bin/swan: Goose compiles src/ to C, and the C compiler links it with
# the vendored SQLite (src/swan.build). Build files stay under .tools/.
set -euo pipefail
cd "$(dirname "$0")/.."
GOOSE=${GOOSE:-.tools/goose/goose-v2026.3-linux-x64/goose}
export GOOSE_HOME=${GOOSE_HOME:-$PWD/.tools/goose-home}
mkdir -p bin
"$GOOSE" build src/swan.goose -o bin/swan "$@"
