#!/usr/bin/env bash
# Fetches the pinned Goose compiler and rust-analyzer into .tools/ and the
# SCIP indexers for TypeScript and Python into tools/node_modules. Nothing is
# installed system-wide.
set -euo pipefail
cd "$(dirname "$0")/.."
GOOSE_TAG=v2026.3
GOOSE_SHA256=06ac30284338269d3996d457412bf4f2b47c1f9a5601de65b6317187fe78d5c9
dir=.tools/goose/goose-$GOOSE_TAG-linux-x64
if [ ! -x "$dir/goose" ]; then
  mkdir -p .tools/dl .tools/goose
  tgz=.tools/dl/goose-$GOOSE_TAG-linux-x64.tar.gz
  curl -fsSL -o "$tgz" "https://github.com/aardappel/goose/releases/download/$GOOSE_TAG/goose-$GOOSE_TAG-linux-x64.tar.gz"
  echo "$GOOSE_SHA256  $tgz" | sha256sum -c -
  tar -xzf "$tgz" -C .tools/goose
fi
# rust-analyzer, for Rust repos (its built-in `scip` command).
RA_TAG=2026-10-19
RA_SHA256=8fde1c9dae81459f98e99eedae3654846a9166abea686306c26e57773be558da
if [ ! -x .tools/rust-analyzer/rust-analyzer ]; then
  mkdir -p .tools/rust-analyzer
  gz=.tools/rust-analyzer/rust-analyzer-$RA_TAG.gz
  curl -fsSL -o "$gz" "https://github.com/rust-lang/rust-analyzer/releases/download/$RA_TAG/rust-analyzer-x86_64-unknown-linux-gnu.gz"
  echo "$RA_SHA256  $gz" | sha256sum -c -
  gunzip -c "$gz" > .tools/rust-analyzer/rust-analyzer
  chmod +x .tools/rust-analyzer/rust-analyzer
fi
(cd tools && npm install --no-fund --no-audit --silent)
echo "goose: $dir/goose"
