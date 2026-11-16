#!/bin/sh
# Proves the egg shell end to end:
#   A. the pure-Goose front end (egg.goose) compiles and its validation
#      accepts a good request and rejects a bad one (needs the Goose compiler;
#      set GOOSE=/path/to/goose, else this part skips);
#   B. the sealing runner (eggshell) blocks an outside-write and a network call
#      while a benign static map still builds, and keeps the repo read-only.
# Non-hostile fixtures only. Run from an exec-allowed copy (/mnt is noexec).
set -u
HERE=$(cd "$(dirname "$0")" && pwd); cd "$HERE"
EGG="$HERE/eggshell"
GOOSE="${GOOSE:-}"
pass=0; fail=0; skip=0
ok(){ echo "  PASS: $1"; pass=$((pass+1)); }
bad(){ echo "  FAIL: $1"; fail=$((fail+1)); }
sk(){ echo "  SKIP: $1"; skip=$((skip+1)); }

echo "== A. pure-Goose front end (egg.goose) =="
if [ -n "$GOOSE" ] && [ -x "$GOOSE" ]; then
  if "$GOOSE" build egg.goose >/tmp/egg_build.log 2>&1; then
    ok "egg.goose compiles (goose build)"
    out=$(./egg /some/repo "$HOME/out" -- sh -c true 2>/tmp/egg_err.log)
    if [ $? -eq 0 ] && printf '%s' "$out" | grep -q 'eggshell /some/repo .* -- sh -c true'; then
      ok "valid request builds the sealed command"
    else
      echo "   got: $out"; bad "sealed command wrong or request rejected"
    fi
    if ./egg /some/repo /tmp/out -- sh -c true >/dev/null 2>&1; then
      ok "out under /tmp is accepted (the runner seals it safely)"
    else
      bad "out under /tmp was wrongly rejected"
    fi
  else
    bad "egg.goose did NOT compile"; sed -n '1,25p' /tmp/egg_build.log
  fi
else
  sk "no Goose compiler (set GOOSE=/path/to/goose) — skipped the Goose build/validate checks"
fi

echo "== B. sealing runner (eggshell) =="
if ! unshare --user --map-root-user true 2>/dev/null; then
  sk "unprivileged namespaces unavailable; eggshell would REFUSE (exit 3) — the safe outcome"
else
  "$EGG" /definitely/not/a/dir "$HERE" -- true >/dev/null 2>&1; rc=$?
  [ "$rc" = 2 ] && ok "eggshell executes" || { bad "eggshell did NOT execute (exit $rc)"; echo "RESULT: aborting"; exit 1; }
  OUT="$HOME/.eggshell-test-out.$$"; mkdir -p "$OUT"; trap 'rm -rf "$OUT" "$HOME/eggshell_leak_probe"' EXIT
  "$EGG" fixtures/writes-outside "$OUT" -- sh -c 'echo x > "$HOME/eggshell_leak_probe" 2>/dev/null; true' >/dev/null 2>&1
  [ -f "$HOME/eggshell_leak_probe" ] && bad "outside write leaked to host" || ok "outside write blocked"
  "$EGG" fixtures/net-call "$OUT" -- sh build.sh 2>&1 | grep -qiE 'leak|REACHABLE|SUCCEEDED' && bad "network reachable in sandbox" || ok "network blocked"
  "$EGG" fixtures/benign-map "$OUT" -- sh -c 'grep -nE "^(def|class) " *.py > "$EGG_OUT/index.txt"' >/dev/null 2>&1
  [ -s "$OUT/index.txt" ] && ok "benign map still builds ($(wc -l < "$OUT/index.txt") symbols)" || bad "benign map did not build"
  "$EGG" fixtures/benign-map "$OUT" -- sh -c 'echo tampered >> a.py 2>/dev/null; true' >/dev/null 2>&1
  grep -q tampered fixtures/benign-map/a.py 2>/dev/null && { bad "repo was modified"; git -C "$HERE" checkout -- fixtures/benign-map/a.py 2>/dev/null || true; } || ok "repo stayed read-only"

  # The seal must cover every mount, not only /: on many systems (btrfs
  # subvolumes, a separate /home or data disk) the repo and the real home sit
  # on their own mount. Write to the real home by absolute path, and to /tmp.
  REAL_HOME="$HOME"
  probe="$REAL_HOME/.eggshell_leak_probe2.$$"
  tprobe="/tmp/.eggshell_leak_probe3.$$"
  trap 'rm -rf "$OUT" "$HOME/eggshell_leak_probe" "$probe" "$tprobe"' EXIT
  "$EGG" fixtures/writes-outside "$OUT" -- sh -c "echo x > '$probe' 2>/dev/null; echo x > '$tprobe' 2>/dev/null; true" >/dev/null 2>&1
  [ -e "$probe" ] && bad "write to the real home (a separate mount here: $(findmnt -n -o TARGET --target "$REAL_HOME")) leaked" || ok "write to the real home blocked"
  [ -e "$tprobe" ] && bad "write to /tmp leaked" || ok "write to /tmp blocked"

  # Host services over unix sockets (DNS through systemd-resolved, D-Bus,
  # the user runtime dir) must be out of reach in a sealed run.
  seen=$("$EGG" fixtures/benign-map "$OUT" -- sh -c '
    for s in /run/systemd/resolve/io.systemd.Resolve /run/dbus/system_bus_socket /run/user; do
      [ -e "$s" ] && echo "$s"
    done; true' 2>/dev/null)
  [ -n "$seen" ] && bad "host sockets visible in sandbox: $seen" || ok "host sockets under /run hidden"

  # Trusted runs (--allow-net) still work and still keep the repo read-only.
  "$EGG" fixtures/benign-map "$OUT" --allow-net -- sh -c 'echo tampered >> a.py 2>/dev/null; echo ran > "$EGG_OUT/allow-net.txt"' >/dev/null 2>&1
  { [ -s "$OUT/allow-net.txt" ] && ! grep -q tampered fixtures/benign-map/a.py; } && ok "--allow-net runs, repo still read-only" || bad "--allow-net run wrong"
  git -C "$HERE" checkout -- fixtures/benign-map/a.py 2>/dev/null || true

  # --rw grants exactly the named directory; the repo stays read-only
  # unless it is the one granted; broad grants are refused.
  rwdir="$OUT.rw"; mkdir -p "$rwdir"
  "$EGG" fixtures/benign-map "$OUT" --rw "$rwdir" -- sh -c "echo ok > '$rwdir/granted'; echo tampered >> a.py 2>/dev/null; true" >/dev/null 2>&1
  { [ -s "$rwdir/granted" ] && ! grep -q tampered fixtures/benign-map/a.py; } && ok "--rw grants only the named directory" || bad "--rw grant wrong"
  git -C "$HERE" checkout -- fixtures/benign-map/a.py 2>/dev/null || true
  "$EGG" fixtures/benign-map "$OUT" --rw "$HOME" -- true >/dev/null 2>&1; rc=$?
  [ "$rc" = 2 ] && ok "--rw of the whole home refused" || bad "--rw of the whole home allowed (exit $rc)"
  rm -rf "$rwdir"

  # A repo under /run would disappear with it: refuse rather than guess.
  "$EGG" /run "$OUT" -- true >/dev/null 2>&1; rc=$?
  [ "$rc" = 3 ] && ok "repo under /run refused" || bad "repo under /run not refused (exit $rc)"
fi

echo
echo "RESULT: $pass passed, $fail failed, $skip skipped"
[ "$fail" -eq 0 ]
