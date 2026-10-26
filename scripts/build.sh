#!/usr/bin/env bash
# Builds bin/swan: Goose compiles src/ to C, and the C compiler links it with
# the vendored SQLite and the swan-lsp library (src/swan.build). The library
# (lsp/) is Goose compiled to C on its own, only when lsp/ has changed, so
# swan's own build never includes it. Build files stay under .tools/.
set -euo pipefail
cd "$(dirname "$0")/.."
GOOSE=${GOOSE:-.tools/goose/goose-v2026.3-linux-x64/goose}
export GOOSE_HOME=${GOOSE_HOME:-$PWD/.tools/goose-home}
mkdir -p bin build
if [ ! -f build/swanlsp.c ] || [ -n "$(find lsp -newer build/swanlsp.c -print -quit)" ]; then
    "$GOOSE" --standalone --header build/swanlsp.h -o build/swanlsp.c lsp/swanlsp.goose >/dev/null
fi
"$GOOSE" build src/swan.goose -o bin/swan "$@"
