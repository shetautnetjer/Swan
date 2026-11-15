#!/usr/bin/env bash
# Builds bin/swan: Goose compiles src/ to C, and the C compiler links it with
# its native helpers and the goose-lsp library (src/swan.build). The library
# (the lsp/ submodule) is Goose compiled to C on its own, only when it has
# changed, so swan's own build never includes it. SQLite and tree-sitter are
# Goose packages (goose-sqlite, goose-treesitter), built once and cached.
# Build files stay under .tools/.
set -euo pipefail
cd "$(dirname "$0")/.."
GOOSE=${GOOSE:-.tools/goose/goose-v2026.3-linux-x64/goose}
export GOOSE_HOME=${GOOSE_HOME:-$PWD/.tools/goose-home}
mkdir -p bin build
if [ ! -f build/golsp.c ] || [ -n "$(find -L lsp -newer build/golsp.c -print -quit)" ]; then
    GOOSE="$GOOSE" lsp/scripts/build.sh build
fi
"$GOOSE" build src/swan.goose -o bin/swan "$@"
# the egg-shell sealing runner sits beside the swan binary (swan_home/bin)
install -m 755 eggshell/eggshell bin/eggshell
# the native flattener, when cargo is here; without it Swan uses tools/scip-flatten.ts
if command -v cargo >/dev/null 2>&1 && [ -f native/swan-flatten/Cargo.toml ]; then
    CARGO_TARGET_DIR=${CARGO_TARGET_DIR:-$PWD/build/swan-flatten} cargo build --release --quiet --manifest-path native/swan-flatten/Cargo.toml
    install -m 755 "${CARGO_TARGET_DIR:-$PWD/build/swan-flatten}/release/swan-flatten" bin/swan-flatten
fi
