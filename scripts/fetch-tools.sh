#!/usr/bin/env bash
# Fetches the pinned Goose compiler, rust-analyzer, clangd, lua-language-server,
# the shader language server, Blender's Python stubs, a JDK, scip-java,
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
# JetBrains' Kotlin language server (standalone, with its own JBR), for live
# Kotlin answers. About 1.5 GB unpacked; it keeps its caches in the map's
# folder (--system-path).
KLS=263.7084.0
KLS_SHA256=ae0c4b01e17ab73a4a5227a78ea99e6dcbe3e499600315b22759a4e4cddd11df
if [ ! -x ".tools/kotlin-lsp/kotlin-server-$KLS/bin/intellij-server" ]; then
  mkdir -p .tools/kotlin-lsp
  tgz=.tools/kotlin-lsp/kotlin-server-$KLS.tar.gz
  curl -fsSL -o "$tgz" "https://download.jetbrains.com/language-server/kotlin-server/$KLS/kotlin-server-$KLS.tar.gz"
  echo "$KLS_SHA256  $tgz" | sha256sum -c -
  tar -xzf "$tgz" -C .tools/kotlin-lsp
  rm "$tgz"
fi
# Gradle, as the Kotlin server and Kotlin maps run it, keeps its home here;
# its daemons quit after 10 idle minutes and keep to 2 GB.
mkdir -p .tools/gradle-home
[ -f .tools/gradle-home/gradle.properties ] || printf 'org.gradle.daemon.idletimeout=600000\norg.gradle.jvmargs=-Xmx2g\n' > .tools/gradle-home/gradle.properties
# Language servers for game and 3D code (live errors): clangd for C and C++,
# lua-language-server, and shader-validator's server for GLSL, HLSL and WGSL;
# plus Blender's Python stubs (fake-bpy-module) so pyright knows bpy.
fetch_zip() {   # dir url sha256 kind
  [ -e ".tools/$1/.done" ] && return 0
  mkdir -p ".tools/$1"
  curl -fsSL -o ".tools/$1/dl" "$2"
  echo "$3  .tools/$1/dl" | sha256sum -c -
  case "$4" in
    zip) unzip -q -o ".tools/$1/dl" -d ".tools/$1" ;;
    tgz) tar -xzf ".tools/$1/dl" -C ".tools/$1" ;;
  esac
  rm ".tools/$1/dl"
  touch ".tools/$1/.done"
}
fetch_zip clangd https://github.com/clangd/clangd/releases/download/23.1.0/clangd-linux-23.1.0.zip \
  e53b1a96196095faedb7642cf64964f7fb9ad4a0c1f00dd2c172a3d9dcbafdfd zip
fetch_zip lua-ls https://github.com/LuaLS/lua-language-server/releases/download/3.19.2/lua-language-server-3.19.2-linux-x64.tar.gz \
  93ad326b10f6c00911dd8c450fa098332dbd8f9f45d1052f5636a2d54479b947 tgz
if [ ! -x .tools/shader-ls/bin/shader-language-server ]; then
  mkdir -p .tools/shader-ls/bin
  curl -fsSL -o .tools/shader-ls/s.vsix https://github.com/antaalt/shader-validator/releases/download/v1.6.0/shader-validator-linux-x64.vsix
  echo "0ff5679108593b81055911f2b90a7b65cdd354e11792feb422d5daa42377a74f  .tools/shader-ls/s.vsix" | sha256sum -c -
  unzip -q -o .tools/shader-ls/s.vsix -d .tools/shader-ls/vsix
  cp .tools/shader-ls/vsix/extension/bin/linux-x64/* .tools/shader-ls/bin/
  cp .tools/shader-ls/vsix/extension/LICENSE* .tools/shader-ls/ 2>/dev/null || true
  rm -rf .tools/shader-ls/vsix .tools/shader-ls/s.vsix
  chmod +x .tools/shader-ls/bin/shader-language-server
fi
[ -d .tools/blender-stubs/bpy-stubs ] || uv pip install -q --target .tools/blender-stubs "fake-bpy-module-5.0==20260730"
(cd tools && npm install --no-fund --no-audit --silent)
# The lsp/ submodule (goose-lsp), if the clone was not recursive.
git submodule update --init lsp
echo "goose: $dir/goose"
