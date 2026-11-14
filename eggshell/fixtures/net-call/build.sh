#!/bin/sh
# Non-hostile fixture: a repo build step that tries to reach the network
# (dependency download, telemetry). Sealed by eggshell, there is no network,
# so this must fail.
if getent hosts github.com >/dev/null 2>&1; then
  echo "build.sh: NETWORK REACHABLE (leak)"
else
  echo "build.sh: no DNS / no network (good)"
fi
python3 - <<'PY' 2>/dev/null || echo "build.sh: socket connect failed (good)"
import socket
s = socket.socket(); s.settimeout(3)
s.connect(("github.com", 443))
print("build.sh: TCP CONNECT SUCCEEDED (leak)")
PY
