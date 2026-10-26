#!/usr/bin/env bash
# Fetches the pinned Goose compiler, rust-analyzer, a JDK, scip-java,
# scip-clang, clang's headers and CUDA headers into .tools/ and the
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
# scip-clang, for C, C++ and CUDA.
SCIP_CLANG=v0.4.1
SCIP_CLANG_SHA256=a434d26a079fd80e1996ba79276cb1ef86b2b2ad28b13e24386285db32c59046
if [ ! -x .tools/scip-clang/scip-clang ]; then
  mkdir -p .tools/scip-clang
  curl -fsSL -o .tools/scip-clang/scip-clang "https://github.com/sourcegraph/scip-clang/releases/download/$SCIP_CLANG/scip-clang-x86_64-linux"
  echo "$SCIP_CLANG_SHA256  .tools/scip-clang/scip-clang" | sha256sum -c -
  chmod +x .tools/scip-clang/scip-clang
fi
# clang 21's builtin headers (scip-clang 0.4.1 is built on clang 21) and a
# stand-in clang++ that tells scip-clang where they are. CUDA indexing needs
# __clang_cuda_runtime_wrapper.h from them. A sparse checkout is ~8 MB, where
# a full LLVM release is 2 GB.
if [ ! -x .tools/llvm/bin/clang++ ]; then
  mkdir -p .tools/llvm/bin
  git clone -q --depth 1 --branch llvmorg-21.1.0 --filter=blob:none --sparse https://github.com/llvm/llvm-project.git .tools/llvm/src
  git -C .tools/llvm/src sparse-checkout set clang/lib/Headers
  rm -rf .tools/llvm/resource && mkdir -p .tools/llvm/resource
  cp -r .tools/llvm/src/clang/lib/Headers .tools/llvm/resource/include
  res="$PWD/.tools/llvm/resource" bin="$PWD/.tools/llvm/bin"
  cat > .tools/llvm/bin/clang++ <<STUB
#!/bin/sh
# Stand-in for clang++ for scip-clang, which asks a compiler only where
# clang's builtin headers are (-print-resource-dir) and where it is
# installed (-###).
for a in "\$@"; do
  case "\$a" in
    -print-resource-dir) echo "$res"; exit 0;;
    -###) echo "clang version 21.1.0 (swan stand-in)" >&2; echo "InstalledDir: $bin" >&2; exit 0;;
  esac
done
echo "swan's clang++ stand-in only answers -print-resource-dir and -### (got: \$*)" >&2
exit 1
STUB
  chmod +x .tools/llvm/bin/clang++
  ln -sf clang++ .tools/llvm/bin/clang
fi
# CUDA headers without the CUDA toolkit: NVIDIA's own pip wheels, laid out
# the way clang's --cuda-path expects. No nvcc and no GPU are needed to index.
if [ ! -d .tools/cuda-sdk/include ]; then
  uv venv -q .tools/cuda-venv
  uv pip install -q --python .tools/cuda-venv/bin/python nvidia-cuda-runtime-cu12==12.9.79 \
    nvidia-cuda-nvcc-cu12==12.9.86 nvidia-cuda-cccl-cu12==12.9.27 nvidia-curand-cu12
  sp=$(ls -d "$PWD"/.tools/cuda-venv/lib/python*/site-packages/nvidia)
  mkdir -p .tools/cuda-sdk/include .tools/cuda-sdk/bin .tools/cuda-sdk/lib64
  for d in cuda_runtime cuda_nvcc cuda_cccl curand; do
    [ -d "$sp/$d/include" ] && for f in "$sp/$d/include"/*; do ln -sfn "$f" .tools/cuda-sdk/include/; done
  done
  ln -sfn "$sp/cuda_nvcc/nvvm" .tools/cuda-sdk/nvvm
  ln -sf "$sp/cuda_nvcc/bin/ptxas" .tools/cuda-sdk/bin/ptxas
  for f in "$sp"/cuda_runtime/lib/*; do ln -sf "$f" .tools/cuda-sdk/lib64/; done
  echo '{"cuda":{"name":"CUDA SDK","version":"12.9.1"}}' > .tools/cuda-sdk/version.json
fi
# ruff (lint, format) and pytest for Python repos without their own.
if [ ! -x .tools/py-tools/bin/ruff ]; then
  uv venv -q .tools/py-tools
  uv pip install -q --python .tools/py-tools/bin/python ruff==0.17.2 pytest==9.1.1
fi
# Tree-sitter's runtime and grammars (npm tarballs, which carry the generated
# C), for structural search: pkg/treesitter compiles them once.
TS_PKGS=(
  "07aeba8dd71630e7e72b2d4ca3bd2680c3471824100cc5ebff44e78a6ed0b6d3 tree-sitter-0.25.1"
  "8e9ecd7687665d2fa1b3c07fbd1f4380b7d285850d6954629e2156e1b757451e tree-sitter-c-0.24.1"
  "615d152f70e7a6bed8f15a93c3c0c264c40dc71c1b6a1445646fff9439e776bc tree-sitter-cpp-0.23.4"
  "93a855b34aadae8269a9f6d31431f2ce0a9f60dbb8fd495cc489205bf1832efe tree-sitter-cuda-0.21.2"
  "6b6c1b62605f9d8bb80efd2ebe5951a87b182faafa3eeb67c460a667818551b6 tree-sitter-java-0.23.5"
  "6214ce23d03aba525ba8edd6ca7caf365c969f2c2dbfc353e376ca54507ffb92 tree-sitter-javascript-0.25.0"
  "63b76b3fa8181fd79eaad4abcdb21e2babcb504dbfc7710a89934fa456d26096 tree-sitter-python-0.25.0"
  "4248da0b9ea40fec13ef010822e7b92a9d1ebdf74f6f2733539b1dbbb086c5bb tree-sitter-rust-0.24.0"
  "0fdf63c35930a75885145d75ee63cb879da2d49db9bfe454bd8e60b08ba778a1 tree-sitter-typescript-0.23.2"
)
# Kotlin's grammar is published under a scope, so its URL and folder are spelled out.
KT_SUM=28916be3fdb0487dbd4fd0ea62281f969f15cab2bf13132ceb18d2fb167aa697
KT_TGZ=.tools/tree-sitter/pkg/tree-sitter-grammars-tree-sitter-kotlin-1.1.0.tgz
if [ ! -d .tools/tree-sitter/tree-sitter-kotlin ]; then
  mkdir -p .tools/tree-sitter/pkg .tools/tree-sitter/tree-sitter-kotlin
  curl -fsSL -o "$KT_TGZ" "https://registry.npmjs.org/@tree-sitter-grammars/tree-sitter-kotlin/-/tree-sitter-kotlin-1.1.0.tgz"
  echo "$KT_SUM  $KT_TGZ" | sha256sum -c -
  tar -xzf "$KT_TGZ" -C .tools/tree-sitter/tree-sitter-kotlin --strip-components=1
fi
for entry in "${TS_PKGS[@]}"; do
  sum=${entry%% *}; pkg=${entry#* }; name=${pkg%-*.*.*}
  if [ ! -d ".tools/tree-sitter/$name" ]; then
    mkdir -p .tools/tree-sitter/pkg ".tools/tree-sitter/$name"
    curl -fsSL -o ".tools/tree-sitter/pkg/$pkg.tgz" "https://registry.npmjs.org/$name/-/$pkg.tgz"
    echo "$sum  .tools/tree-sitter/pkg/$pkg.tgz" | sha256sum -c -
    tar -xzf ".tools/tree-sitter/pkg/$pkg.tgz" -C ".tools/tree-sitter/$name" --strip-components=1
  fi
done
(cd tools && npm install --no-fund --no-audit --silent)
echo "goose: $dir/goose"
