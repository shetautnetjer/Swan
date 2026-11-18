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
# Spread-Wings (the wings/ submodule, pinned to a commit): the broad map
# beside Swan's exact one. Its own program, built here from its sources and
# installed beside bin/swan, where Swan looks for it first (src/wings.goose).
if [ ! -f wings/src/spread-wings.goose ]; then
    echo "build.sh: wings/ is empty; run: git submodule update --init wings" >&2; exit 1
fi
if [ ! -f bin/spread-wings ] || [ -n "$(find -L wings/src wings/native -newer bin/spread-wings -print -quit)" ]; then
    "$GOOSE" build wings/src/spread-wings.goose -o bin/spread-wings
fi
# Swan's test runner (tests/check/), Goose like Swan: bin/swan-check [suite...]
"$GOOSE" build tests/check/check.goose -o bin/swan-check
# the egg-shell sealing runner sits beside the swan binary (swan_home/bin)
install -m 755 eggshell/eggshell bin/eggshell
# the SCIP flattener (native/swan-flatten, Rust) is required: Swan has no other.
# cargo from PATH, else rustup's default home.
CARGO=$(command -v cargo || true)
[ -n "$CARGO" ] || { [ -x "$HOME/.cargo/bin/cargo" ] && CARGO="$HOME/.cargo/bin/cargo"; }
[ -n "$CARGO" ] || { echo "build.sh: cargo (Rust) is required for bin/swan-flatten; install rustup" >&2; exit 1; }
if true; then
    # SWAN_FLATTEN_PROFILE=quick builds faster for trying changes (no LTO); release is what ships.
    flatten_profile=${SWAN_FLATTEN_PROFILE:-release}
    # Cargo puts the built-in dev and test profiles in target/debug.
    case "$flatten_profile" in dev|test) flatten_dir=debug ;; *) flatten_dir=$flatten_profile ;; esac
    CARGO_TARGET_DIR=${CARGO_TARGET_DIR:-$PWD/build/swan-flatten} "$CARGO" build --profile "$flatten_profile" --quiet --manifest-path native/swan-flatten/Cargo.toml
    install -m 755 "${CARGO_TARGET_DIR:-$PWD/build/swan-flatten}/$flatten_dir/swan-flatten" bin/swan-flatten
fi
