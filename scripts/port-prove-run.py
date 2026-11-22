#!/usr/bin/env python3
"""Proves stage 4's judge for running a step can fail (AGENTS.md rule 4: a
check never seen failing may be testing nothing).

Builds copies of the Rust program, each broken in one place on purpose, and
runs scripts/port-run.sh against each, after the unbroken program passes
it. Every copy must be caught.

    scripts/port-prove-run.py            every break
    scripts/port-prove-run.py 3 9        only these (as numbered in a run)
    scripts/port-prove-run.py --fit      whether each break still fits the source; builds nothing

The tree is not touched: the copies are made and built in a temporary
folder. The judge waits for a ten-second deadline three times in each
program, so a run takes a minute more than its builds, and the two breaks
that take the deadline away take 100 seconds.

Exit 0: every break was caught. 1: one was not (the judge has a hole), or a
break no longer fits the source (mend BREAKS below, then run again). 2: the
judge does not pass the unbroken program, so no break proves anything.

Not among the breaks, because `trust` and `doctor` cannot show them:
- a program named with a folder in its name (both steps name theirs bare),
  and the name a program is started under when it is found on PATH (a
  script sees its own path either way);
- a step's folder that is not there, and a step with nothing to start;
- what a step may read: the judge gives both programs nothing to read;
- `doctor`'s deadline of a minute.
"""
import os
import shutil
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor

# (file in rust/src, what is broken, the text as it is, the text broken)
BREAKS = [
    # How a step's program is found and started (sys.rs, run).
    ('sys.rs', "a step's own variables are not set",
     "            if let Some(eq) = e.iter().position(|&b| b == b'=') {\n                c.env(OsStr::from_bytes(&e[..eq]), OsStr::from_bytes(&e[eq + 1..]));\n            }",
     '            let _ = (e, &mut c);'),
    ('sys.rs', "a step's program is looked for on the caller's PATH",
     '        let ours = env.iter().find(|e| e.starts_with(b"PATH=")).map(|e| e[5..].to_vec());',
     '        let ours: Option<Vec<u8>> = None;'),
    ('sys.rs', 'the last folder of PATH that has the program is taken',
     '    for place in &places {',
     '    for place in places.iter().rev() {'),
    ('sys.rs', 'only the first folder of PATH is tried',
     '            Err(e) => why = e.raw_os_error().unwrap_or(libc::ENOENT),',
     '            Err(e) => {\n                why = e.raw_os_error().unwrap_or(libc::ENOENT);\n                break;\n            }'),
    ('sys.rs', "a step runs in the caller's folder",
     '        if !cwd.is_empty() {\n            c.current_dir(path(cwd));\n        }\n        for e in env {',
     '        for e in env {'),
    ('sys.rs', 'a step is not given a group of its own',
     'c.stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::piped()).process_group(0);',
     'c.stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::piped());'),
    ('sys.rs', 'other words when a program cannot be started',
     '        err.extend_from_slice(b"swan_run: cannot run ");',
     '        err.extend_from_slice(b"swan_run: could not run ");'),
    ('sys.rs', 'why a program cannot be started is always "no such file"',
     '        err.extend_from_slice(&strerror(why));',
     '        err.extend_from_slice(&strerror(libc::ENOENT));'),
    ('sys.rs', '126 when a program cannot be started',
     "        err.push(b'\\n');\n        return 127;\n    };",
     "        err.push(b'\\n');\n        return 126;\n    };"),
    # What comes back from it.
    ('sys.rs', 'what a step prints and what it complains of change places',
     '(if i == 0 { &mut *out } else { &mut *err })',
     '(if i == 1 { &mut *out } else { &mut *err })'),
    ('sys.rs', 'no deadline',
     '    let deadline = if timeout_ms > 0 { Some(Instant::now() + Duration::from_millis(timeout_ms as u64)) } else { None };',
     '    let deadline: Option<Instant> = if timeout_ms < 0 { Some(Instant::now() + Duration::from_millis(timeout_ms as u64)) } else { None };'),
    ('sys.rs', 'a deadline ten times as long',
     'Some(Instant::now() + Duration::from_millis(timeout_ms as u64))',
     'Some(Instant::now() + Duration::from_millis(timeout_ms as u64 * 10))'),
    ('sys.rs', 'no deadline once a step has closed its output',
     '            Some(d) if Instant::now() >= d => timed_out = true,',
     '            Some(d) if Instant::now() >= d + Duration::from_secs(1000) => timed_out = true,'),
    ('sys.rs', 'a step past its deadline is not ended',
     '    if timed_out {\n        unsafe { libc::kill(-group, libc::SIGKILL) };\n    }',
     '    let _ = group;'),
    ('sys.rs', 'only the step itself is ended at the deadline, not what it started',
     '        unsafe { libc::kill(-group, libc::SIGKILL) };\n    }\n    drop(streams);',
     '        unsafe { libc::kill(group, libc::SIGKILL) };\n    }\n    drop(streams);'),
    ('sys.rs', '-1 for a step ended at its deadline',
     '    if timed_out {\n        return -2;\n    }',
     '    if timed_out {\n        return -1;\n    }'),
    ('sys.rs', "a signal's number, not 128 more",
     '        Some(s) => s.code().or_else(|| s.signal().map(|g| 128 + g)).unwrap_or(-1),',
     '        Some(s) => s.code().or_else(|| s.signal()).unwrap_or(-1),'),
    # The account of a step (run.rs).
    ('run.rs', 'the last 500 bytes of what went wrong, not 600',
     '        let tail = if err.len() > 600 { &err[err.len() - 600..] } else { &err[..] };',
     '        let tail = if err.len() > 500 { &err[err.len() - 500..] } else { &err[..] };'),
    ('run.rs', 'the first 600 bytes of what went wrong, not the last',
     '        let tail = if err.len() > 600 { &err[err.len() - 600..] } else { &err[..] };',
     '        let tail = if err.len() > 600 { &err[..600] } else { &err[..] };'),
    ('run.rs', 'no account of a step that went well',
     '    if code == 0 {\n        sys::write_stderr(&[label, format!(": {} ms\\n", ms).as_bytes()].concat());\n    } else {',
     '    if code == 0 {\n    } else {'),
    ('run.rs', 'other words for a step that failed',
     'format!(": exit {} after {} ms\\n", code, ms)',
     'format!(": code {} after {} ms\\n", code, ms)'),
    ('run.rs', "Swan's home is its bin folder",
     '    exe[..up].to_vec()',
     '    exe[..bin].to_vec()'),
    # trust.
    ('pipeline.rs', 'a repo is trusted by the path it was given, not its real one',
     '    let repo = crate::abs_path(repo_arg);\n    let tf = trust_file();',
     '    let repo = repo_arg.to_vec();\n    let tf = trust_file();'),
    ('pipeline.rs', 'a repo already trusted is added again',
     '    if !contains_line(&saved, &repo) {',
     '    if true || !contains_line(&saved, &repo) {'),
    ('pipeline.rs', 'a repo is trusted when a longer name holds its path',
     '    if !contains_line(&saved, &repo) {',
     '    if !saved.windows(repo.len()).any(|w| w == &repo[..]) {'),
    ('pipeline.rs', 'a list with no line end gets none before the new line',
     "        if !saved.is_empty() && saved[saved.len() - 1] != b'\\n' {\n            saved.push(b'\\n');\n        }\n",
     ''),
    ('pipeline.rs', 'mkdir without -p',
     '&[b"mkdir", b"-p", &data]',
     '&[b"mkdir", &data]'),
    ('pipeline.rs', 'the list is kept somewhere else',
     'b"/data/trusted-repos"',
     'b"/data/trusted"'),
    ('pipeline.rs', 'a list that cannot be written is no failure',
     '            report.extend_from_slice(&tf);\n            return false;',
     '            report.extend_from_slice(&tf);\n            return true;'),
    ('pipeline.rs', 'other words when the list cannot be written',
     '            report.extend_from_slice(b"could not write ");',
     '            report.extend_from_slice(b"cannot write ");'),
    ('main.rs', 'another exit code when trust fails',
     '        let ok = pipeline::trust_main(&a[2], &mut report);\n        print(&report);\n        if !ok {\n            exit(1);',
     '        let ok = pipeline::trust_main(&a[2], &mut report);\n        print(&report);\n        if !ok {\n            exit(3);'),
    # doctor.
    ('main.rs', 'doctor runs with another PATH',
     'b"PATH=/usr/local/bin:/usr/bin:/bin"',
     'b"PATH=/usr/bin:/bin"'),
    ('main.rs', "doctor runs in the caller's folder",
     'run::run_step(b"doctor", &argv, &home, &[',
     'run::run_step(b"doctor", &argv, b"", &['),
    ('main.rs', 'python3 without -I',
     'vec![b"python3", b"-I", &script, b"--home", &home]',
     'vec![b"python3", &script, b"--home", &home]'),
    ('main.rs', 'doctor is told another home',
     'vec![b"python3", b"-I", &script, b"--home", &home]',
     'vec![b"python3", b"-I", &script, b"--home", &script]'),
    ('main.rs', "doctor's own words are not passed on",
     '            argv.push(arg);\n',
     ''),
    ('main.rs', '--home is passed on',
     '            if arg.as_slice() == b"--home" || arg.starts_with(b"--home=") {\n                usage();\n            }\n            argv.push(arg);',
     '            argv.push(arg);'),
    ('main.rs', 'what doctor printed is not printed',
     '        print(&result);\n        exit(code);',
     '        exit(code);'),
    ('main.rs', "doctor's exit code is not passed on",
     '        print(&result);\n        exit(code);',
     '        print(&result);\n        exit(i32::from(code != 0));'),
]

JUDGE = "port-run.sh"


def main():
    if sys.argv[1:] != ["--fit"] and not all(a.isdigit() and 1 <= int(a) <= len(BREAKS) for a in sys.argv[1:]):
        sys.exit(__doc__)
    only = {int(a) for a in sys.argv[1:] if a.isdigit()}
    here = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
    if sys.argv[1:] == ["--fit"]:
        # Only whether each break still fits the source: nothing is built.
        unfit = 0
        for n, (name, what, good, _) in enumerate(BREAKS, 1):
            count = open(os.path.join(here, "rust", "src", name), encoding="utf-8").read().count(good)
            if count != 1:
                unfit += 1
                print(f"break {n} does not fit rust/src/{name} ({what}): its text is there {count} times")
        print(f"{len(BREAKS) - unfit} of {len(BREAKS)} breaks fit")
        sys.exit(1 if unfit else 0)
    cargo = shutil.which("cargo") or os.path.expanduser("~/.cargo/bin/cargo")
    work = tempfile.mkdtemp(prefix="port-prove-")
    try:
        sys.exit(prove(here, cargo, work, only))
    finally:
        shutil.rmtree(work, ignore_errors=True)


def prove(here, cargo, work, only):
    # One copy of rust/ is edited, built and put back as it was for each
    # break, so only the one crate is compiled each time.
    copy = os.path.join(work, "rust")
    shutil.copytree(os.path.join(here, "rust"), copy, ignore=shutil.ignore_patterns("target"))
    # rust/build.rs finds goose-treesitter's C through the import line of
    # src/swan.goose beside rust/, in the Goose build's cache.
    os.makedirs(os.path.join(work, "src"), exist_ok=True)
    shutil.copy(os.path.join(here, "src", "swan.goose"), os.path.join(work, "src", "swan.goose"))
    os.environ.setdefault("GOOSE_HOME", os.path.join(here, ".tools", "goose-home"))
    judge_script = os.path.join(here, "scripts", JUDGE)

    def build():
        return subprocess.run([cargo, "build", "--release", "--manifest-path", os.path.join(copy, "Cargo.toml")],
                              env=dict(os.environ, CARGO_TARGET_DIR=os.path.join(work, "target")),
                              capture_output=True, text=True)

    # The unbroken program first: a judge that does not pass it would "catch"
    # every break by failing for some other reason (review on #75).
    made = build()
    if made.returncode != 0:
        print(f"the unbroken program does not build:\n{made.stderr[-600:]}")
        return 2
    base = os.path.join(work, "swan-0")
    shutil.copy(os.path.join(work, "target", "release", "swan"), base)
    ran = subprocess.run([judge_script], env=dict(os.environ, SWAN_NEW=base),
                         capture_output=True, encoding="utf-8", errors="replace")
    last = (ran.stdout.strip().splitlines() or [""])[-1]
    if ran.returncode != 0 or not last.startswith("the same:"):
        print(f"the judge does not pass the unbroken program ({JUDGE} exit {ran.returncode}), so it proves nothing:")
        print("    " + "\n    ".join((ran.stdout + ran.stderr).strip().splitlines()[-8:]))
        return 2
    print(f"the unbroken program: {last}", flush=True)
    built = []
    unfit = 0
    for n, (name, what, good, broken) in enumerate(BREAKS, 1):
        if only and n not in only:
            continue
        path = os.path.join(copy, "src", name)
        text = open(path, encoding="utf-8").read()
        if text.count(good) != 1:
            print(f"break {n} no longer fits rust/src/{name} ({what}): its text is there {text.count(good)} times")
            unfit += 1
            continue
        open(path, "w", encoding="utf-8").write(text.replace(good, broken))
        made = build()
        open(path, "w", encoding="utf-8").write(text)
        if made.returncode != 0:
            print(f"break {n} does not build ({what}):\n{made.stderr[-600:]}")
            unfit += 1
            continue
        program = os.path.join(work, f"swan-{n}")
        shutil.copy(os.path.join(work, "target", "release", "swan"), program)
        built.append((n, what, program))

    def judge(item):
        n, what, program = item
        ran = subprocess.run([judge_script], env=dict(os.environ, SWAN_NEW=program),
                             capture_output=True, encoding="utf-8", errors="replace")
        return n, what, ran.returncode, ran.stdout

    missed = 0
    # One judge a core: each runs dozens of comparisons.
    with ThreadPoolExecutor(max(1, min(len(built), os.cpu_count() or 4))) as pool:
        for n, what, code, said in pool.map(judge, built):
            caught = [line for line in said.splitlines() if line.startswith("DIFFERENT (")]
            steps = list(dict.fromkeys(line[len("DIFFERENT ("):].rstrip(")") for line in caught))
            if code == 2:
                missed += 1
                print(f"break {n} NOT JUDGED ({what}): the judge could not compare ({JUDGE} exit 2)")
                print("    " + "\n    ".join(said.splitlines()[-4:]))
            elif code == 1 and caught:
                print(f"break {n} caught ({what}) by {len(steps)} of the cases: {'; '.join(steps)[:120]}")
            else:
                missed += 1
                print(f"break {n} NOT CAUGHT ({what}): {JUDGE} exit {code}")
                print("    " + "\n    ".join(said.splitlines()[-6:]))
    print(f"{len(built) - missed} of {len(only) or len(BREAKS)} breaks caught" + (f", {unfit} did not fit or build" if unfit else ""))
    return 0 if missed == 0 and unfit == 0 else 1


if __name__ == "__main__":
    main()
