#!/usr/bin/env bash
# Makes the checkpoint scripts/space-test.sh forks: a Firecracker microVM
# (clean Ubuntu, `cua` Spaces) holding this checkout, its fetched tools
# (.tools, tools/node_modules) and, when it sits beside this one, the
# spread-wings checkout; built there, the full suite passed there, then
# saved with its memory as a pinned checkpoint.
#
#   scripts/space-base.sh            make checkpoint swan-test-v1
#   SWAN_SPACE_CHECKPOINT=swan-test-v2 scripts/space-base.sh
#
# Run it again after scripts/fetch-tools.sh changed what .tools holds (a
# new pinned indexer or language server); source changes need no new
# checkpoint, space-test.sh syncs them into each fork. Takes about five
# minutes and 3 GB of upload to the VM. Needs the `cua` CLI, KVM, and a
# complete dev checkout (scripts/fetch-tools.sh done).
set -euo pipefail
cd "$(dirname "$0")/.."
checkpoint=${SWAN_SPACE_CHECKPOINT:-swan-test-v1}
base="$checkpoint-base"
repo=$PWD
dir=$(basename "$repo")
sw="$(dirname "$repo")/spread-wings"

command -v cua >/dev/null 2>&1 || { echo "space-base: the cua CLI is not installed" >&2; exit 2; }
[ -x .tools/py-tools/bin/python ] || { echo "space-base: .tools is incomplete; run scripts/fetch-tools.sh" >&2; exit 2; }
if cua sb checkpoints 2>/dev/null | grep -qw "$checkpoint"; then
  echo "space-base: checkpoint '$checkpoint' exists; pick another name (SWAN_SPACE_CHECKPOINT) or remove it: cua sb checkpoints unpin $checkpoint && cua sb checkpoints rm $checkpoint" >&2; exit 2
fi
x() { cua sb exec "$base" --timeout "${T:-600}" -- "$1"; }

work=$(mktemp -d "${XDG_CACHE_HOME:-$HOME/.cache}/swan-space-base.XXXXXX")
trap 'rm -rf "$work"' EXIT

# A base left by a run that failed (it is kept then, to look at) goes first.
cua sb ls 2>/dev/null | grep -qw "local:$base" && cua sb rm -f "$base" >/dev/null
trap 'rm -rf "$work"; [ "${ok:-}" = 1 ] || echo "space-base: failed; the VM is kept to look at: cua sb exec $base -- ... (the next run deletes it)" >&2' EXIT

echo "== create $base (microVM, 16 vCPUs, 16 GB)" >&2
cua sb create linux --kind microvm --name "$base" --cpu 16 --memory 16GB >/dev/null
x "sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq sqlite3 zstd libcurl4-openssl-dev >/dev/null"

# The venvs under .tools name two absolute paths of this machine: this
# checkout, and the Python uv gave them. Both are copied, and the same
# paths are made to lead to the copies inside the VM.
pylink=$(dirname "$(dirname "$(readlink .tools/py-tools/bin/python)")")   # .../cpython-3.12-linux-x86_64-gnu
pyreal=$(readlink -f "$pylink")

echo "== pack" >&2
# Generated folders stay behind (bin, build, data, Goose's build cache,
# downloads): the VM builds its own. Excludes are anchored: a bare
# `target` once dropped a CUDA header named nv/target.
tar -I 'zstd -T0 -3' -cf "$work/base.tar.zst" \
  --transform "s,^$dir/,Work/Swan/," --transform "s,^$dir\$,Work/Swan," \
  --transform "s,^spread-wings,Work/spread-wings," --transform "s,^$(basename "$pyreal"),uv-python/$(basename "$pyreal")," \
  --exclude="$dir/bin" --exclude="$dir/build" --exclude="$dir/data" \
  --exclude="$dir/.tools/dl" --exclude="$dir/.tools/goose-home/build" --exclude="spread-wings/bin" \
  -C "$(dirname "$repo")" "$dir" $([ -d "$sw" ] && echo "-C $(dirname "$sw") spread-wings") \
  -C "$(dirname "$pyreal")" "$(basename "$pyreal")"
echo "== upload $(du -h "$work/base.tar.zst" | cut -f1)" >&2
cua sb cp "$work/base.tar.zst" "$base:/home/cua/base.tar.zst" >/dev/null
T=900 x "cd /home/cua && tar -I zstd -xf base.tar.zst && rm base.tar.zst \
  && sudo mkdir -p '$(dirname "$repo")' '$(dirname "$pylink")' \
  && sudo ln -sfn /home/cua/Work/Swan '$repo' \
  && sudo ln -sfn '/home/cua/uv-python/$(basename "$pyreal")' '$pylink' \
  && Work/Swan/.tools/py-tools/bin/python --version"

echo "== build and test there" >&2
T=1200 x "cd /home/cua/Work/Swan && scripts/build.sh >/tmp/build.log 2>&1 || { tail -30 /tmp/build.log; exit 1; }"
if [ -d "$sw" ]; then
  T=600 x "cd /home/cua/Work/spread-wings && GOOSE=/home/cua/Work/Swan/.tools/goose/goose-v2026.3-linux-x64/goose GOOSE_HOME=/home/cua/Work/Swan/.tools/goose-home scripts/build.sh >/tmp/sw-build.log 2>&1 && tests/test.sh | tail -1"
fi
T=2400 x "cd /home/cua/Work/Swan && SWAN_TRUST_BUILD=1 scripts/test.sh >/tmp/swan-test.log 2>&1; s=\$?; grep 'checks passed' /tmp/swan-test.log; grep '^FAIL' /tmp/swan-test.log | head -20; exit \$s"

echo "== checkpoint $checkpoint" >&2
# Nothing the tests left running (Gradle daemons, language servers) goes
# into the saved memory.
# ([g]radle: so pkill does not match, and kill, the shell running this line.)
x "pkill -f '[g]radle'; pkill -f '[k]otlin-lsp'; pkill '^java\$'; sleep 2; sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null"
cua sb checkpoint "$base" "$checkpoint" --pin >/dev/null
cua sb rm -f "$base" >/dev/null
ok=1
echo "space-base: checkpoint $checkpoint is ready; scripts/space-test.sh forks it" >&2
