#!/usr/bin/env python3
"""Proves the store's judge can fail (AGENTS.md rule 4: a check never seen
failing may be testing nothing).

Builds copies of the Rust program, each broken in one place on purpose, and
runs scripts/port-store.sh against each. Every copy must be caught.

    scripts/port-prove.py <flattened-dir> <repo-root>

Give it a small repo: every copy is a whole port-store.sh run (10 s each on
Agent-Reach, and they run side by side). The tree is not touched: the copies
are made and built in a temporary folder.

Exit 0: every break was caught. 1: one was not (the judge has a hole), or a
break no longer fits the source (mend BREAKS below, then run again).
"""
import os
import shutil
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor

# (file in rust/src, what is broken, the text as it is, the text broken)
BREAKS = [
    ("index.rs", "which symbol a reference sits in: the smallest body no longer wins",
     "let size = (e.el - e.sl) * 100000 + (e.ec - e.sc);",
     "let size = (e.el - e.sl) + (e.ec - e.sc);"),
    ("util.rs", "the fingerprint of a file's rows: one hash constant changed",
     "const K2: u64 = 15485907386658061715;",
     "const K2: u64 = 15485907386658061717;"),
    ("index.rs", "rows with no relationships.tsv: made an error",
     'sys::read_file(&in_dir(b"relationships.tsv"), &mut text);',
     'if !sys::read_file(&in_dir(b"relationships.tsv"), &mut text) { die(b"cannot read relationships.tsv"); }'),
    ("query.rs", "an answer: every column one too small",
     "push_int(out, st.col_int(6) + 1);",
     "push_int(out, st.col_int(6));"),
    ("fresh.rs", "staleness: a file edited since the SCIP run is called fresh",
     "if m != self.edited_mtime(file, &mut mark) {",
     "if m != self.edited_mtime(file, &mut mark) && file.is_empty() {"),
    ("walk.rs", "new files: hidden folders are walked",
     "if name[0] != b'.' && !SKIP_DIRS",
     "if !SKIP_DIRS"),
    ("diag.rs", "diagnostics: a stale one is called fresh, and a fresh one stale",
     "        if file_changed {",
     "        if !file_changed {"),
    ("sys.rs", "a refusal: the second writer's message reworded",
     'b"swan: another writer is in progress for "',
     'b"swan: another writer holds "'),
    ("sys.rs", "a refusal: the missing folder's message reworded",
     'b"swan: cannot resolve map directory for writer lock: "',
     'b"swan: cannot find the map folder: "'),
]


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    here = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
    rows, repo = os.path.realpath(sys.argv[1]), os.path.realpath(sys.argv[2])
    cargo = shutil.which("cargo") or os.path.expanduser("~/.cargo/bin/cargo")
    work = tempfile.mkdtemp(prefix="port-prove-")
    try:
        sys.exit(prove(here, rows, repo, cargo, work))
    finally:
        shutil.rmtree(work, ignore_errors=True)


def step_of(line):
    """The step of port-store.sh that a line of its output is about."""
    if ": TABLES DIFFER" in line:
        return "the tables at " + line.split(": TABLES DIFFER")[0].split(" (")[0]
    if line.startswith("DIFFERENT ("):
        return line[len("DIFFERENT ("):].split("): swan")[0]
    return "the questions of " + line.split(": ")[0].split(" (")[0]


def prove(here, rows, repo, cargo, work):
    # One copy of rust/ is edited, built and put back as it was for each
    # break, so only the one crate is compiled each time.
    copy = os.path.join(work, "rust")
    shutil.copytree(os.path.join(here, "rust"), copy, ignore=shutil.ignore_patterns("target"))
    # rust/build.rs finds goose-treesitter's C through the import line of
    # src/swan.goose beside rust/, in the Goose build's cache.
    os.makedirs(os.path.join(work, "src"), exist_ok=True)
    shutil.copy(os.path.join(here, "src", "swan.goose"), os.path.join(work, "src", "swan.goose"))
    os.environ.setdefault("GOOSE_HOME", os.path.join(here, ".tools", "goose-home"))
    built = []
    unfit = 0
    for n, (name, what, good, broken) in enumerate(BREAKS, 1):
        path = os.path.join(copy, "src", name)
        text = open(path, encoding="utf-8").read()
        if text.count(good) != 1:
            print(f"break {n} no longer fits rust/src/{name} ({what}): its text is there {text.count(good)} times")
            unfit += 1
            continue
        open(path, "w", encoding="utf-8").write(text.replace(good, broken))
        made = subprocess.run([cargo, "build", "--release", "--manifest-path", os.path.join(copy, "Cargo.toml")],
                              env=dict(os.environ, CARGO_TARGET_DIR=os.path.join(work, "target")),
                              capture_output=True, text=True)
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
        ran = subprocess.run([os.path.join(here, "scripts", "port-store.sh"), rows, repo],
                             env=dict(os.environ, SWAN_NEW=program, PORT_JOBS="8"), capture_output=True, text=True)
        return n, what, ran.returncode, ran.stdout

    missed = 0
    with ThreadPoolExecutor(len(built) or 1) as pool:
        for n, what, code, said in pool.map(judge, built):
            caught = [line for line in said.splitlines()
                      if "TABLES DIFFER" in line or line.startswith("DIFFERENT (")
                      or ("answered differently" in line and ", 0 answered differently" not in line)]
            steps = list(dict.fromkeys(step_of(line) for line in caught))
            if code == 1 and caught:
                print(f"break {n} caught ({what}) by: {'; '.join(steps)[:260]}")
            else:
                missed += 1
                print(f"break {n} NOT CAUGHT ({what}): port-store.sh exit {code}")
                print("    " + "\n    ".join(said.splitlines()[-6:]))
    print(f"{len(built) - missed} of {len(BREAKS)} breaks caught" + (f", {unfit} did not fit or build" if unfit else ""))
    return 0 if missed == 0 and unfit == 0 else 1


if __name__ == "__main__":
    main()
