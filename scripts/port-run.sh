#!/usr/bin/env bash
# Stage 4's judge for running a step (docs/rust-port.md): `swan trust <repo>`
# and `swan doctor [...]`, the two commands that need only Swan's own folder
# and one program started, say the same, exit the same and leave the same
# data/trusted-repos from the Goose program and the Rust port.
#
# Each program is copied into a made-up home of its own (home/bin/swan, with
# this repository's scripts/, skills/ and tools/*.json beside it), so
# neither touches an installed Swan or its list of trusted repos. It is
# started from the folder above its home. To see
# how a step is run, and not only that it ran, the program a step starts
# is replaced: `trust` starts `mkdir` from PATH, so a made-up `mkdir` shows
# what it is given, what becomes of its exit code, its output, a signal and
# the ten-second deadline; `doctor` starts python3 on scripts/doctor.py, so
# a made-up doctor.py shows the same for a step whose output is printed.
#
#   scripts/port-run.sh
#
# SWAN_OLD, SWAN_NEW: as for port-compare.sh. PORT_RUN_QUICK=1 leaves out
# the three cases that wait for the deadline (ten seconds in each program).
# Prints one "DIFFERENT (<case>)" block for each disagreement, then "the
# same: N of N" or "DIFFERENT: K of N".
# Exit 0: all the same. 1: some differ. 2: a comparison could not be made
# (a program is missing). 3: a command is not carried yet.
set -uo pipefail
cd "$(dirname "$0")/.."
here=$PWD
export LC_ALL=C
old=${SWAN_OLD:-bin/swan}
new=${SWAN_NEW:-build/rust/release/swan}
[ -x "$old" ] || { echo "port-run: no Goose program at $old"; exit 2; }
[ -x "$new" ] || { echo "port-run: no Rust program at $new"; exit 2; }

work=$(mktemp -d)
trap 'chmod -R u+rwx "$work" 2>/dev/null; rm -rf "$work"' EXIT
each="$work/each"
mkdir -p "$each/old/home/bin" "$each/new/home/bin"
cp "$old" "$each/old/home/bin/swan"
cp "$new" "$each/new/home/bin/swan"
# Each program is started through this, from the folder above its home: the
# step it runs finds programs on PORT_RUN_PATH when that is set.
for side in old new; do
    cat >"$each/$side/start" <<'EOF'
#!/bin/sh
if [ -n "${PORT_RUN_PATH+set}" ]; then PATH=$PORT_RUN_PATH; export PATH; fi
exec "${0%/*}/home/bin/swan" "$@"
EOF
    chmod +x "$each/$side/start"
done
export SWAN_OLD="$each/old/start" SWAN_NEW="$each/new/start"

# home: each home as an installed one is, less the indexers themselves.
home() {
    local side
    for side in old new; do
        chmod -R u+rwx "$each/$side/home" 2>/dev/null
        find "$each/$side/home" -mindepth 1 -maxdepth 1 ! -name bin -exec rm -rf {} +
        mkdir -p "$each/$side/home/tools"
        cp -r "$here/scripts" "$each/$side/home/scripts"
        cp -r "$here/skills" "$each/$side/home/skills"
        cp "$here/tools/modules.json" "$here/tools/package.json" "$here/tools/package-lock.json" "$each/$side/home/tools/" 2>/dev/null
        [ -f "$here/bin/swan-flatten" ] && cp "$here/bin/swan-flatten" "$each/$side/home/bin/swan-flatten"
    done
    return 0
}
both() { local side; for side in old new; do (cd "$each/$side/home" && "$@"); done; }
# doctor_py: standard input becomes scripts/doctor.py of both homes.
doctor_py() { cat >"$work/doctor.py"; cp "$work/doctor.py" "$each/old/home/scripts/doctor.py"; cp "$work/doctor.py" "$each/new/home/scripts/doctor.py"; }
# fake <name>: standard input becomes a program named mkdir, alone in a
# folder; prints the folder.
fake() { mkdir -p "$work/fake/$1"; cat >"$work/fake/$1/mkdir"; chmod +x "$work/fake/$1/mkdir"; printf '%s' "$work/fake/$1"; }

total=0; bad=0
# same_data: data/ of each home holds the same files, bytes and permissions.
same_data() {
    [ -e "$each/old/home/data" ] || [ -e "$each/new/home/data" ] || return 0
    if ! diff -r "$each/old/home/data" "$each/new/home/data" >"$work/d" 2>&1; then
        { echo "data/ differs (Goose < > Rust):"; head -6 "$work/d" | sed "s|$each/||g" | cut -c1-200; } >"$work/report"; return 1
    fi
    if [ -d "$each/old/home/data" ] && ! diff <(cd "$each/old/home" && find data | sort | xargs -d '\n' stat -c '%a %F %n') <(cd "$each/new/home" && find data | sort | xargs -d '\n' stat -c '%a %F %n') >"$work/d" 2>&1; then
        { echo "permissions or kinds in data/ differ (Goose < > Rust):"; head -6 "$work/d"; } >"$work/report"; return 1
    fi
    return 0
}
# run <case> <swan arguments...>: both programs, each in its own home as it
# is now.
run() {
    local label=$1; shift
    total=$((total + 1))
    PORT_EACH_IN="$each" scripts/port-compare.sh "$@" >"$work/report" 2>&1
    local code=$?
    if [ $code = 3 ]; then echo "port-run: $1 is not carried over yet"; exit 3; fi
    if [ $code = 2 ]; then echo "port-run: no comparison could be made ($label):"; sed 's/^/    /' "$work/report"; exit 2; fi
    if [ $code = 0 ]; then same_data || code=1; fi
    if [ $code = 0 ] && [ -n "${DEADLINE:-}" ]; then deadline_held || code=1; fi
    if [ $code != 0 ]; then bad=$((bad + 1)); echo "DIFFERENT ($label)"; sed 's/^/    /' "$work/report"; fi
}

# deadline_held: after a case that waits for the ten-second deadline, each
# program waited about that long and nothing the step started still runs.
tag="100.$$"
deadline_held() {
    local took_old took_new
    IFS=$'\t' read -r took_old took_new _ < <(tail -1 "$work/times")
    if [ "$took_old" -lt 9000 ] || [ "$took_old" -gt 15000 ] || [ "$took_new" -lt 9000 ] || [ "$took_new" -gt 15000 ]; then
        echo "the deadline is ten seconds: the Goose program took $took_old ms, the Rust program $took_new ms" >"$work/report"; return 1
    fi
    if pgrep -f "sleep $tag" >/dev/null; then
        pkill -9 -f "sleep $tag"
        echo "a program the step started was left running after the deadline" >"$work/report"; return 1
    fi
    return 0
}

# ---- repos to trust ----
r="$work/repos"
mkdir -p "$r/one" "$r/two" "$r/one-more" "$r/with space"
ln -s one "$r/link"
printf 'a file\n' >"$r/a-file"

# ---- trust ----
home; run "trust: the first repo" trust "$r/one"
run "trust: the same repo again" trust "$r/one"
run "trust: a second repo" trust "$r/two"
run "trust: a repo whose name starts as another's" trust "$r/one-more"
run "trust: by a link" trust "$r/link"
run "trust: slashes after the repo" trust "$r/two///"
run "trust: a name with a space" trust "$r/with space"
run "trust: a file" trust "$r/a-file"
home; run "trust: a repo that is not there" trust "$r/not-there"
home; both mkdir data; both sh -c 'printf "%s" "$1" >data/trusted-repos' sh "$r/two"; run "trust: a list with no line end" trust "$r/one"
home; both mkdir data; both sh -c 'printf "%s\n" "$1" >data/trusted-repos' sh "$r/one-more"; run "trust: a list that holds a longer name" trust "$r/one"
home; both mkdir data; both sh -c 'printf "\n\n%s\n\n" "$1" >data/trusted-repos' sh "$r/one"; run "trust: a list with empty lines, the repo in it" trust "$r/one"
home; both sh -c ': >data'; run "trust: data is a file" trust "$r/one"
home; both mkdir data; both chmod 555 data; run "trust: data cannot be written" trust "$r/one"
home; both mkdir -p data/trusted-repos; run "trust: the list is a folder" trust "$r/one"
# How the step is run: a made-up mkdir, found on PATH.
export PORT_RUN_VAR="from the judge"
home; PORT_RUN_PATH=$(fake says <<'EOF'
#!/bin/sh
{ echo "arguments: $# [$1] [$2]"; echo "folder: $(pwd)"; echo "PATH: $PATH"; echo "a variable: ${PORT_RUN_VAR:-unset}"; echo "to read: $(/usr/bin/wc -c)"; } >&2
echo "this goes nowhere"
exit 1
EOF
) run "a step: what it is given" trust "$r/one"
home; PORT_RUN_PATH=$(fake exit3 <<'EOF'
#!/bin/sh
i=0; while [ $i -lt 200 ]; do echo "line $i of what went wrong" >&2; i=$((i + 1)); done
exit 3
EOF
) run "a step: exit 3 and a long account" trust "$r/one"
for n in 599 600 601; do
    home; PORT_RUN_PATH=$(fake "err$n" <<EOF
#!/bin/sh
/usr/bin/head -c $n /dev/zero | /usr/bin/tr '\\0' e >&2
exit 1
EOF
    ) run "a step: $n bytes of error text" trust "$r/one"
done
home; PORT_RUN_PATH=$(fake raw <<'EOF'
#!/bin/sh
printf 'not UTF-8: \377\376 and a line end in the middle\nthen more' >&2
exit 2
EOF
) run "a step: error text that is not UTF-8" trust "$r/one"
home; PORT_RUN_PATH=$(fake big <<'EOF'
#!/bin/sh
/usr/bin/head -c 3000000 /dev/zero | /usr/bin/tr '\0' o
/usr/bin/head -c 3000000 /dev/zero | /usr/bin/tr '\0' e >&2
exit 4
EOF
) run "a step: three megabytes on each stream" trust "$r/one"
home; PORT_RUN_PATH=$(fake kill9 <<'EOF'
#!/bin/sh
kill -9 $$
EOF
) run "a step: ended by signal 9" trust "$r/one"
home; PORT_RUN_PATH=$(fake kill15 <<'EOF'
#!/bin/sh
echo "about to end" >&2
kill -15 $$
EOF
) run "a step: ended by signal 15" trust "$r/one"
home; PORT_RUN_PATH=$(fake works <<'EOF'
#!/bin/sh
exec /usr/bin/mkdir "$@"
EOF
) run "a step: a made-up mkdir that works" trust "$r/one"
mkdir -p "$work/fake/none"
home; PORT_RUN_PATH="$work/fake/none" run "a step: no such program" trust "$r/one"
# With nowhere to look the Goose program names an error left over from
# before (docs/rust-port.md, "What differs"): only that each says one.
home; PORT_ERR=any PORT_RUN_PATH="" run "a step: an empty PATH" trust "$r/one"
mkdir -p "$work/fake/plain" && printf '#!/bin/sh\nexit 0\n' >"$work/fake/plain/mkdir"
home; PORT_RUN_PATH="$work/fake/plain" run "a step: a program that may not be run" trust "$r/one"
home; PORT_RUN_PATH="$work/fake/plain:$work/fake/works" run "a step: one that may not be run, then one that may" trust "$r/one"
home; PORT_RUN_PATH="$work/fake/none:$work/fake/works:$work/fake/exit3" run "a step: the first folder of PATH that has it" trust "$r/one"
mkdir -p "$work/fake/folder/mkdir"
home; PORT_RUN_PATH="$work/fake/folder" run "a step: a folder of that name" trust "$r/one"
mkdir -p "$work/fake/nobang" && printf 'echo "ran with no first line" >&2\nexit 7\n' >"$work/fake/nobang/mkdir" && chmod +x "$work/fake/nobang/mkdir"
home; PORT_RUN_PATH="$work/fake/nobang" run "a step: a program file with no #! line" trust "$r/one"
home; PORT_RUN_PATH="$work/fake/nobang:$work/fake/works" run "a step: one with no #! line, then one that runs" trust "$r/one"
if [ -z "${PORT_RUN_QUICK:-}" ]; then
    export PORT_TIMES="$work/times"
    home; DEADLINE=yes PORT_RUN_PATH=$(fake never <<EOF
#!/bin/sh
echo "started" >&2
exec /usr/bin/sleep $tag
EOF
    ) run "a step: one that never ends (the deadline)" trust "$r/one"
    home; DEADLINE=yes PORT_RUN_PATH=$(fake silent <<EOF
#!/bin/sh
exec >/dev/null 2>&1
exec /usr/bin/sleep $tag
EOF
    ) run "a step: one that closes its output and goes on" trust "$r/one"
    home; DEADLINE=yes PORT_RUN_PATH=$(fake child <<EOF
#!/bin/sh
/usr/bin/sleep $tag &
exit 0
EOF
    ) run "a step: one that ends and leaves a child holding its output" trust "$r/one"
    unset PORT_TIMES
fi

# ---- doctor ----
home
run "doctor" doctor
run "doctor --json" doctor --json
run "doctor --profile core" doctor --profile core
run "doctor --profile core --json" doctor --profile core --json
run "doctor --profile python-typescript" doctor --profile python-typescript
run "doctor --profile bogus" doctor --profile bogus
run "doctor --home x" doctor --home x
run "doctor --home=x" doctor --home=x
run "doctor --json --home" doctor --json --home
run "doctor, a word it does not know" doctor extra
home; both rm scripts/doctor.py; run "doctor, with no scripts/doctor.py" doctor
home; doctor_py <<'EOF'
import os, sys
print("arguments:", sys.argv[1:])
print("folder:", os.getcwd())
print("PATH:", os.environ.get("PATH"))
print("PATH is there", open("/proc/self/environ", "rb").read().split(b"\0").count(b"PATH=" + os.environ["PATH"].encode()), "time(s)")
print("a variable:", os.environ.get("PORT_RUN_VAR"))
print("to read:", len(sys.stdin.buffer.read()))
print("isolated:", sys.flags.isolated)
EOF
run "a doctor: what it is given" doctor one "two words" --json
mkdir -p "$work/fake/python" && printf '#!/bin/sh\necho "the wrong python3"\nexit 9\n' >"$work/fake/python/python3" && chmod +x "$work/fake/python/python3"
PORT_RUN_PATH="$work/fake/python" run "a doctor: python3 from the step's own PATH, not the caller's" doctor
home; doctor_py <<'EOF'
import sys
sys.stdout.write("printed, with no line end")
sys.stderr.write("and a complaint\n")
sys.exit(5)
EOF
run "a doctor: exit 5, what it printed and a complaint" doctor
home; doctor_py <<'EOF'
import sys
sys.stdout.buffer.write(b"not UTF-8: \xff\xfe\nand a second line\n")
sys.stdout.buffer.write(b"o" * 2000000)
sys.stderr.buffer.write(b"e" * 2000000)
EOF
run "a doctor: two megabytes on each stream, bytes that are not UTF-8" doctor
home; doctor_py <<'EOF'
import os, signal
print("before the end", flush=True)
os.kill(os.getpid(), signal.SIGKILL)
EOF
run "a doctor: ended by signal 9" doctor
home; doctor_py <<'EOF'
print("nothing wrong")
EOF
run "a doctor: nothing on standard error" doctor

if [ $bad = 0 ]; then echo "the same: $total of $total"; exit 0; fi
echo "DIFFERENT: $bad of $total"
exit 1
