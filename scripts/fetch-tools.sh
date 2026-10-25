#!/usr/bin/env bash
# Fetches the pinned Goose compiler into .tools/ and the SCIP indexer into
# tools/node_modules. Nothing is installed system-wide.
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
(cd tools && npm install --no-fund --no-audit --silent)
echo "goose: $dir/goose"
