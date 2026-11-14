#!/bin/sh
# Non-hostile fixture: a repo build step that tries to write a marker file
# OUTSIDE the repo. Sealed by eggshell, this write must fail and leave nothing
# on the host.
MARKER="${OUTSIDE_MARKER:-$HOME/eggshell_leak_marker}"
echo "pwned-by-build $(date)" > "$MARKER" 2>&1
echo "build.sh: tried to write $MARKER (exit $?)"
