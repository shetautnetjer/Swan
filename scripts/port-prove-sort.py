#!/usr/bin/env python3
"""Proves stage 4's comparison for sorting can fail (AGENTS.md rule 4: a check
never seen failing may be testing nothing).

Builds copies of the Rust dumper (rust/src/bin/port-sort.rs, which sorts
with rust/src/gsort.rs), each broken in one place on purpose, and runs
scripts/port-sort.sh against each, after the unbroken one passes it. Every
copy must be caught.

    scripts/port-prove-sort.py            every break
    scripts/port-prove-sort.py 3 9        only these (as numbered in a run)
    scripts/port-prove-sort.py --fit      whether each break still fits the source; builds nothing

The tree is not touched: the copies are made and built in a temporary
folder.

Exit 0: every break was caught. 1: one was not (the comparison has a hole),
or a break no longer fits the source (mend BREAKS below, then run again). 2:
the comparison does not pass the unbroken dumper, so no break proves
anything.

Not among the breaks, because no list can show them:
- which of the two sides of a split is sorted first (the smaller, so that
  the ranges set aside stay few): the sides do not touch, and each comes
  out the same whenever it is sorted;
- a list of ten taken the long way round (looked over for a run, then
  sorted as a range): it is insertion sorted there too, and the turning of
  a start in strict reverse moves no element past one equal to it.
"""
import os
import shutil
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor

# (file in rust/src, what is broken, the text as it is, the text broken)
BREAKS = [
    ('gsort.rs', 'insertion moves an element past those equal to it',
     '            if !f(x, y) {\n                break;\n            }\n            v[j] = y;',
     '            if f(y, x) {\n                break;\n            }\n            v[j] = y;'),
    ('gsort.rs', 'a list of eleven is sorted by insertion alone',
     '    if n <= 10 {\n        sort_insertion(xs, f);',
     '    if n <= 11 {\n        sort_insertion(xs, f);'),
    ('gsort.rs', 'a start in reverse is not turned',
     '        v[..e].reverse();\n',
     ''),
    ('gsort.rs', 'a start in reverse is not looked for',
     '    if f(v[1], v[0]) {\n        while e < v.len() {',
     '    if f(v[1], v[0]) && v.is_empty() {\n        while e < v.len() {'),
    ('gsort.rs', 'a run in reverse goes on through equal elements',
     '            if !f(v[e], v[e - 1]) {\n                break;\n            }\n            e += 1;\n        }\n        v[..e].reverse();',
     '            if f(v[e - 1], v[e]) {\n                break;\n            }\n            e += 1;\n        }\n        v[..e].reverse();'),
    ('gsort.rs', 'a run in order ends at an equal element',
     '            if f(v[e], v[e - 1]) {\n                break;\n            }\n            e += 1;\n        }\n    }\n    e',
     '            if !f(v[e - 1], v[e]) {\n                break;\n            }\n            e += 1;\n        }\n    }\n    e'),
    ('gsort.rs', 'a list already in order is sorted all the same',
     '    if r == n {\n        return;\n    }',
     '    let _ = r;'),
    ('gsort.rs', 'the heapsort is reached in half the rounds',
     '    let mut limit: i64 = 2 * (63 - (n as u64).leading_zeros() as i64);',
     '    let mut limit: i64 = 63 - (n as u64).leading_zeros() as i64;'),
    ('gsort.rs', 'the heapsort is never reached',
     '        if len > 10 && limit > 0 {',
     '        if len > 10 {'),
    ('gsort.rs', 'a range of eleven is sorted by insertion',
     '        if len > 10 && limit > 0 {',
     '        if len > 11 && limit > 0 {'),
    ('gsort.rs', 'a range set aside comes back with the rounds of the one sorted before it',
     '        limit = l as i64;\n',
     '        let _ = l;\n'),
    ('gsort.rs', 'the first element is the pivot',
     '            xs[lo..hi].swap(0, pivot);\n',
     '            let _ = pivot;\n'),
    ('gsort.rs', 'the middle one of a pivot\'s three is taken from three eighths of the way',
     '    let b = n8 * 4;',
     '    let b = n8 * 3;'),
    ('gsort.rs', 'the last one of a pivot\'s three is taken from six eighths of the way',
     '    let c = n8 * 7;',
     '    let c = n8 * 6;'),
    ('gsort.rs', 'a range of 128 has a pivot of three',
     '    if v.len() < 128 {',
     '    if v.len() < 129 {'),
    ('gsort.rs', 'a range of 127 has a pivot of nine',
     '    if v.len() < 128 {',
     '    if v.len() < 127 {'),
    ('gsort.rs', 'the nine of a pivot are taken further apart',
     '    let m8 = n8 / 8;',
     '    let m8 = n8 / 4;'),
    ('gsort.rs', 'the first of a pivot of nine\'s medians is the first element',
     '    let ma = sort_median3(v, a, a + m8 * 4, a + m8 * 7, f);',
     '    let ma = a;'),
    ('gsort.rs', 'the middle median of a pivot of nine is the pivot',
     '    sort_median3(v, ma, mb, mc, f)',
     '    let _ = (ma, mc);\n    mb'),
    ('gsort.rs', 'the median of three is the second where it is the first',
     '    if x != f(v[a], v[c]) {\n        return a;\n    }',
     '    if x != f(v[a], v[c]) {\n        return b;\n    }'),
    ('gsort.rs', 'the median of three is the second where it is the third',
     '    if f(v[b], v[c]) != x {\n        return c;\n    }',
     '    if f(v[b], v[c]) != x {\n        return b;\n    }'),
    ('gsort.rs', 'elements equal to the pivot go before it',
     '        lt += if f(x, p) { 1 } else { 0 };',
     '        lt += if !f(p, x) { 1 } else { 0 };'),
    ('gsort.rs', 'the pivot is not put in its place',
     '            let m = sort_partition(&mut xs[lo..hi], f);\n            xs[lo..hi].swap(0, m);',
     '            let m = sort_partition(&mut xs[lo..hi], f);'),
    ('gsort.rs', 'no pass for the elements equal to the pivot',
     '            if lo > 0 && !f(xs[lo - 1], xs[lo]) {',
     '            if lo > n && !f(xs[lo - 1], xs[lo]) {'),
    ('gsort.rs', 'the pass for the elements equal to the pivot moves none',
     '                let m = sort_partition(&mut xs[lo..hi], &|a, b| !f(b, a));',
     '                let m = sort_partition(&mut xs[lo..hi], &|a, b| f(a, b));'),
    ('gsort.rs', 'the heap is built the other way up',
     '    let after = |a: T, b: T| f(b, a);',
     '    let after = |a: T, b: T| f(a, b);'),
    ('gsort.rs', 'the heap never looks at a right child',
     '        if r < n && f(xs[r], xs[l]) {\n            m = r;\n        }',
     '        let _ = r;'),
    ('gsort.rs', 'an element sinks in the heap past those equal to it',
     '        if !f(xs[m], x) {\n            break;\n        }\n        xs[i] = xs[m];',
     '        if f(x, xs[m]) {\n            break;\n        }\n        xs[i] = xs[m];'),
    ('gsort.rs', 'the heap prefers the right child of two equal',
     '        if r < n && f(xs[r], xs[l]) {\n            m = r;\n        }',
     '        if r < n && !f(xs[l], xs[r]) {\n            m = r;\n        }'),
    ('gsort.rs', 'the heap is built from one element short',
     '    let mut i = v.len() / 2;\n    while i > 0 {',
     '    let mut i = v.len() / 2 - 1;\n    while i > 0 {'),
]

JUDGE = "port-sort.sh"


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
    shutil.copy(os.path.join(work, "target", "release", "port-sort"), base)
    ran = subprocess.run([judge_script], env=dict(os.environ, PORT_SORT_RUST=base),
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
        shutil.copy(os.path.join(work, "target", "release", "port-sort"), program)
        built.append((n, what, program))

    def judge(item):
        n, what, program = item
        ran = subprocess.run([judge_script], env=dict(os.environ, PORT_SORT_RUST=program),
                             capture_output=True, encoding="utf-8", errors="replace")
        return n, what, ran.returncode, ran.stdout

    missed = 0
    # One judge a core: each makes its lists and sorts them twice.
    with ThreadPoolExecutor(max(1, min(len(built), os.cpu_count() or 4))) as pool:
        for n, what, code, said in pool.map(judge, built):
            caught = [line for line in said.splitlines() if line.startswith("DIFFERENT: t")]
            steps = list(dict.fromkeys(line[len("DIFFERENT: "):] for line in caught))
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
