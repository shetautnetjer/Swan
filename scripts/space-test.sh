#!/usr/bin/env bash
# Runs this checkout's build and tests in a throwaway microVM, not on this
# machine: a fork of the test checkpoint (scripts/space-base.sh makes it),
# which holds a clean Ubuntu with Swan's tools already in place. A fork
# starts in about a second; it is deleted when the run ends.
#
#   scripts/space-test.sh                 build, then the full suite
#   scripts/space-test.sh bin/swan-check rust lang    (builds first, then runs these)
#   SWAN_SPACE_KEEP=1 scripts/space-test.sh    keep the fork to look around
#
# What runs there is the working tree as it is now (tracked and new files,
# the lsp submodule included), over the checkpoint's copy. Needs the `cua`
# CLI and its daemon. The exit status is the command's own.
set -euo pipefail
cd "$(dirname "$0")/.."
checkpoint=${SWAN_SPACE_CHECKPOINT:-swan-test-v4}
guest=/home/cua/Work/Swan
name="swan-test-$(date +%H%M%S)-$$"

command -v cua >/dev/null 2>&1 || { echo "space-test: the cua CLI is not installed" >&2; exit 2; }
cua sb checkpoints 2>/dev/null | grep -qw "$checkpoint" || {
  echo "space-test: no checkpoint '$checkpoint'; make it with scripts/space-base.sh" >&2; exit 2; }

work=$(mktemp -d)
cleanup() {
  rm -rf "$work"
  if [ -n "${SWAN_SPACE_KEEP:-}" ]; then echo "space-test: kept $name (delete it with: cua sb rm -f $name)" >&2
  else cua sb rm -f "$name" >/dev/null 2>&1 || true; fi
}
trap cleanup EXIT

t0=$(date +%s)
cua sb fork "$checkpoint" "$name" >/dev/null
# The tree as it is: tracked files (submodules too) and new ones, minus
# files deleted here.
{ git ls-files -z --recurse-submodules; git ls-files -z -o --exclude-standard; } |
  while IFS= read -r -d '' f; do if [ -e "$f" ]; then printf '%s\0' "$f"; fi; done |
  tar --null -T - -czf "$work/src.tgz"
cua sb cp "$work/src.tgz" "$name:/tmp/src.tgz" >/dev/null
# Out with the checkpoint's tracked files (so a file deleted here is gone
# there), in with this tree. Tools, caches and build output stay.
cua sb exec "$name" --timeout 300 -- \
  "cd $guest && git ls-files -z --recurse-submodules | xargs -0 rm -f && tar -xzf /tmp/src.tgz && rm /tmp/src.tgz"
echo "space-test: $name ready in $(( $(date +%s) - t0 )) s (fork of $checkpoint, tree synced)" >&2

# Every run builds this tree first: a command given here (bin/swan-check
# lang) otherwise ran the checkpoint's old binaries, which lack any check
# added since, and passed without them.
build="scripts/build.sh >/tmp/build.log 2>&1 || { tail -30 /tmp/build.log; exit 1; }"
if [ $# -eq 0 ]; then set -- "$build; SWAN_TRUST_BUILD=1 scripts/test.sh"; else set -- "$build; $*"; fi
cua sb exec "$name" --cwd "$guest" --timeout 0 -- "$*"
