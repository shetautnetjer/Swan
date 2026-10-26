#!/usr/bin/env bash
# Fetches the pinned Goose compiler and rust-analyzer into .tools/ and the
# SCIP indexers for TypeScript and Python, and pyright, into tools/node_modules. Nothing is
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
# A JDK and scip-java, for Java repos. The scip-java launcher fetches its own
# jars on first use.
JDK=jdk-21.0.13+9
JDK_SHA256=d7f5d5cf865a2902b70ff549b97586a7d3f234e016f041ab447ea740c7d66d1c
if [ ! -x ".tools/jdk/$JDK/bin/java" ]; then
  mkdir -p .tools/jdk
  curl -fsSL -o .tools/jdk/jdk21.tgz "https://github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.13%2B9/OpenJDK21U-jdk_x64_linux_hotspot_21.0.13_9.tar.gz"
  echo "$JDK_SHA256  .tools/jdk/jdk21.tgz" | sha256sum -c -
  tar -xzf .tools/jdk/jdk21.tgz -C .tools/jdk
fi
SCIP_JAVA=v0.13.2
SCIP_JAVA_SHA256=5248136592d19ea2c468f64ebd18587d32de7c961536ff19346f8a025af1d13c
if [ ! -x .tools/scip-java/scip-java ]; then
  mkdir -p .tools/scip-java
  curl -fsSL -o .tools/scip-java/scip-java "https://github.com/scip-code/scip-java/releases/download/$SCIP_JAVA/scip-java-$SCIP_JAVA"
  echo "$SCIP_JAVA_SHA256  .tools/scip-java/scip-java" | sha256sum -c -
  chmod +x .tools/scip-java/scip-java
fi
(cd tools && npm install --no-fund --no-audit --silent)
echo "goose: $dir/goose"
