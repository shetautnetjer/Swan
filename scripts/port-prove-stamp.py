#!/usr/bin/env python3
"""Proves stage 3's judge for the stamps can fail (AGENTS.md rule 4: a check
never seen failing may be testing nothing).

Builds copies of the Rust program, each broken in one place on purpose, and
runs scripts/port-stamp.sh against each, after the unbroken program passes
it. Every copy must be caught.

    scripts/port-prove-stamp.py            every break
    scripts/port-prove-stamp.py 3 9        only these (as numbered in a run)
    scripts/port-prove-stamp.py --fit      whether each break still fits the source; builds nothing

The tree is not touched: the copies are made and built in a temporary
folder.

Exit 0: every break was caught. 1: one was not (the judge has a hole), or a
break no longer fits the source (mend BREAKS below, then run again). 2: the
judge does not pass the unbroken program, so no break proves anything.

Not among the breaks, because neither command can show them:
- stamp_known and line_of_path: `stamp-bench` starts from no stamps, so no
  file is ever known. They are judged with the map, at stage 4;
- a worker that fails leaving its files to be stamped again: nothing here
  makes one worker fail while the others run;
- a kept text written again when it is there: the same bytes either way.
The two breaks of the worker count need a machine with more than two
processors to show.
"""
import os
import shutil
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor

PY_COMMENTS = '        return starts_with(c, b"# type:") || starts_with(c, b"#type:") || starts_with(c, b"# pyright:") || starts_with(c, b"# mypy:");'
JS_COMMENTS = '    starts_with(c, b"///") || starts_with(c, b"//!") || starts_with(c, b"/*!") || find(c, b"@jsx") >= 0 || find(c, b"@ts-") >= 0 || find(c, b"@flow") >= 0'
LANGS = '    if l == b"typescript" || l == b"tsx" || l == b"javascript" || l == b"python" {'
ELIGIBLE_BENCH = """            if cosmetic_lang(name).is_empty() {
                return;
            }
            stamp_line(&repo, &full[repo.len() + 1..], &texts, &mut pre);
            n += 1;"""
ELIGIBLE_AGAIN = """                if cosmetic_lang(name).is_empty() {
                    return;
                }
                stamp_line(&repo, &full[repo.len() + 1..], &texts, &mut pre);"""
ELIGIBLE_COUNT = """            if cosmetic_lang(name).is_empty() {
                return;
            }
            n_all += 1;"""
ELIGIBLE_PRE = """        if cosmetic_lang(name).is_empty() {
            return;
        }
        let rel = &full[repo.len() + 1..];"""

# (file in rust/src, what is broken, the text as it is, the text broken)
BREAKS = [
    # Which files are stamped by their code.
    ('change.rs', 'Python is stamped by its bytes', LANGS,
     '    if l == b"typescript" || l == b"tsx" || l == b"javascript" {'),
    ('change.rs', 'TSX is stamped by its bytes', LANGS,
     '    if l == b"typescript" || l == b"javascript" || l == b"python" {'),
    ('change.rs', 'JavaScript is stamped by its bytes', LANGS,
     '    if l == b"typescript" || l == b"tsx" || l == b"python" {'),
    # Which comments count as code.
    ('change.rs', "Python's `# type:` comment does not count", PY_COMMENTS,
     PY_COMMENTS.replace('starts_with(c, b"# type:") || ', '')),
    ('change.rs', "Python's `#type:` comment does not count", PY_COMMENTS,
     PY_COMMENTS.replace('starts_with(c, b"#type:") || ', '')),
    ('change.rs', "Python's `# pyright:` comment does not count", PY_COMMENTS,
     PY_COMMENTS.replace('starts_with(c, b"# pyright:") || ', '')),
    ('change.rs', "Python's `# mypy:` comment does not count", PY_COMMENTS,
     PY_COMMENTS.replace(' || starts_with(c, b"# mypy:")', '')),
    ('change.rs', 'a /** */ comment does not count',
     '    if starts_with(c, b"/**") && c != b"/**/" {',
     '    if false && starts_with(c, b"/**") && c != b"/**/" {'),
    ('change.rs', 'the empty /**/ counts',
     '    if starts_with(c, b"/**") && c != b"/**/" {',
     '    if starts_with(c, b"/**") {'),
    ('change.rs', 'a /// comment does not count', JS_COMMENTS,
     JS_COMMENTS.replace('starts_with(c, b"///") || ', '')),
    ('change.rs', 'a //! comment does not count', JS_COMMENTS,
     JS_COMMENTS.replace('starts_with(c, b"//!") || ', '')),
    ('change.rs', 'a /*! comment does not count', JS_COMMENTS,
     JS_COMMENTS.replace('starts_with(c, b"/*!") || ', '')),
    ('change.rs', 'an @jsx comment does not count', JS_COMMENTS,
     JS_COMMENTS.replace('find(c, b"@jsx") >= 0 || ', '')),
    ('change.rs', 'an @ts- comment does not count', JS_COMMENTS,
     JS_COMMENTS.replace('find(c, b"@ts-") >= 0 || ', '')),
    ('change.rs', 'an @flow comment does not count', JS_COMMENTS,
     JS_COMMENTS.replace(' || find(c, b"@flow") >= 0', '')),
    # The hash of the code.
    ('change.rs', 'a comment that does not count is hashed',
     '        if dropped(i) {\n            continue;\n        }\n',
     ''),
    ('change.rs', 'a file with a parse error is stamped by its code',
     '        if (flags(nodes, i) & CH_ERROR) != 0 {\n            return false;',
     '        if false {\n            return false;'),
    ('change.rs', 'a comment left out is counted among the children',
     '            if !dropped(c) {\n                kids += 1;\n            }',
     '            kids += 1;'),
    ('change.rs', 'how many children a node has is not hashed',
     '        h = hash_combine(h, hash_int(sym(&nodes, i) * 65536 + kids));',
     '        h = hash_combine(h, hash_int(sym(&nodes, i) * 65536));'),
    ('change.rs', "a leaf's text is not hashed",
     '        if leaf {\n            h = hash_combine(h, hash(&text[start(&nodes, i) as usize..end(&nodes, i) as usize]));',
     '        if false {\n            h = hash_combine(h, hash(&text[start(&nodes, i) as usize..end(&nodes, i) as usize]));'),
    ('change.rs', 'the language is not hashed',
     '    let mut h: u64 = hash(lang);',
     '    let mut h: u64 = 0;'),
    ('util.rs', "a whole number's hash is not folded",
     '    h ^ (h >> 32)\n}\n\npub fn hash_combine',
     '    h\n}\n\npub fn hash_combine'),
    # A stamp line.
    ('stamp.rs', 'a file stamped by its code keeps the stamp of its bytes',
     '            st = h;\n',
     '            let _ = h;\n'),
    ('stamp.rs', 'a file stamped by its code says by its bytes',
     "    line.push(if by_code { b'c' } else { b'b' });",
     "    line.push(if by_code { b'b' } else { b'c' });"),
    ('stamp.rs', "the bytes' hash is of the name",
     '    let raw = hash(&text);',
     '    let raw = hash(rel);'),
    ('stamp.rs', 'the size is one more',
     '    push_int(line, size);',
     '    push_int(line, size + 1);'),
    ('stamp.rs', 'the time is in microseconds',
     '    push_int(line, mt);',
     '    push_int(line, mt / 1000);'),
    ('stamp.rs', 'no text is kept',
     '            if !sys::file_exists(&keep) {\n                sys::write_file(&keep, &text);\n            }\n',
     '            let _ = &keep;\n'),
    ('stamp.rs', 'a kept text has another name',
     '            let mut keep = [texts_dir, b"/t"].concat();',
     '            let mut keep = [texts_dir, b"/x"].concat();'),
    # How many workers.
    ('stamp.rs', 'at most two workers by default',
     '    sys::cpu_count().clamp(1, 32)',
     '    sys::cpu_count().clamp(1, 2)'),
    ('stamp.rs', 'SWAN_STAMP_JOBS=0 is taken',
     '    if let Some(n) = parse_int(&sys::env(b"SWAN_STAMP_JOBS")) {\n        if n > 0 {',
     '    if let Some(n) = parse_int(&sys::env(b"SWAN_STAMP_JOBS")) {\n        if n >= 0 {'),
    ('stamp.rs', 'the usual floor is 128 files',
     '    let mut min_files: i64 = 256;',
     '    let mut min_files: i64 = 128;'),
    ('stamp.rs', 'SWAN_STAMP_MIN=0 is taken',
     '    if let Some(m) = parse_int(&sys::env(b"SWAN_STAMP_MIN")) {\n        if m > 0 {',
     '    if let Some(m) = parse_int(&sys::env(b"SWAN_STAMP_MIN")) {\n        if m >= 0 {'),
    ('stamp.rs', 'a negative SWAN_STAMP_MIN is taken',
     '    if let Some(m) = parse_int(&sys::env(b"SWAN_STAMP_MIN")) {\n        if m > 0 {',
     '    if let Some(m) = parse_int(&sys::env(b"SWAN_STAMP_MIN")) {\n        if m != 0 {'),
    ('stamp.rs', 'workers start under the floor',
     '    if n < min_files {\n        return;\n    }',
     '    if false && n < min_files {\n        return;\n    }'),
    ('stamp.rs', 'a worker for each floor of files, not each 64',
     '    let k = k_max.min(n / min_files.clamp(1, 64)).max(1);',
     '    let k = k_max.min(n / min_files.max(1)).max(1);'),
    ('stamp.rs', 'the files are dealt to the workers one place on',
     '            if i % k == w {',
     '            if (i + 1) % k == w {'),
    ('stamp.rs', 'threads are used for any mode',
     '    if sys::env(b"SWAN_STAMP_MODE") == b"threads" {',
     '    if !sys::env(b"SWAN_STAMP_MODE").is_empty() {'),
    ('stamp.rs', 'threads are never used',
     '    if sys::env(b"SWAN_STAMP_MODE") == b"threads" {',
     '    if false && sys::env(b"SWAN_STAMP_MODE") == b"threads" {'),
    ('stamp.rs', 'as many threads as the machine has, whatever was asked',
     '    let k = k_want.min(sys::hardware_threads()).max(1);',
     '    let k = sys::hardware_threads().max(k_want + 1);'),
    ('stamp.rs', 'a worker keeps its texts beside the stamps',
     '[&exe, b"stamp-worker", repo, &list, &part, texts_dir]',
     '[&exe, b"stamp-worker", repo, &list, &part, out]'),
    # What workers leave behind.
    ("stamp.rs", "a worker's lines are left in the out folder",
     '        sys::delete_file(&part);\n        sys::delete_file(&part_path(out, b"prestamp-", w, b".txt"));',
     '        sys::delete_file(&part_path(out, b"prestamp-", w, b".txt"));'),
    ("stamp.rs", "a worker's list is left in the out folder",
     '        sys::delete_file(&part_path(out, b"prestamp-", w, b".txt"));\n',
     ''),
    ("stamp.rs", "a worker's log is left in the out folder",
     '        sys::delete_file(&part_path(out, b"prestamp-log-", w, b".txt"));\n',
     ''),
    # stamp-bench.
    ('stamp.rs', 'one job still goes to the workers',
     '    if stamp_jobs() == 1 {',
     '    if false && stamp_jobs() == 1 {'),
    ('stamp.rs', 'files the workers left are not stamped again',
     '        if got != n_all {',
     '        if false && got != n_all {'),
    ('stamp.rs', 'the out folder is not made',
     '    sys::make_dir(out_arg);\n',
     ''),
    ('stamp.rs', 'the folder of kept texts is not made',
     '    sys::make_dir(&texts);\n',
     ''),
    ('sys.rs', 'the out folder is made however deep',
     '    let _ = fs::create_dir(path(p));',
     '    let _ = fs::create_dir_all(path(p));'),
    ('stamp.rs', 'the lines go to another file',
     'b"/stamps.tsv"',
     'b"/stamp.tsv"'),
    ('stamp.rs', 'one process stamps every file, whatever its language', ELIGIBLE_BENCH,
     "            let _ = name;\n            stamp_line(&repo, &full[repo.len() + 1..], &texts, &mut pre);\n            n += 1;"),
    ('stamp.rs', 'stamping again takes every file, whatever its language', ELIGIBLE_AGAIN,
     "                let _ = name;\n                stamp_line(&repo, &full[repo.len() + 1..], &texts, &mut pre);"),
    ('stamp.rs', 'every file is counted as one to stamp', ELIGIBLE_COUNT,
     "            let _ = name;\n            n_all += 1;"),
    ('stamp.rs', 'the workers are given every file, whatever its language', ELIGIBLE_PRE,
     "        let _ = name;\n        let rel = &full[repo.len() + 1..];"),
    ('main.rs', 'another exit code when stamp-bench cannot write',
     '        if !stamp::stamp_bench_main(&a[2], &a[3]) {\n            exit(1);',
     '        if !stamp::stamp_bench_main(&a[2], &a[3]) {\n            exit(3);'),
    # stamp-worker.
    ('stamp.rs', 'a list that is not there is no failure',
     '    if !sys::read_file(list, &mut names) {\n        return false;',
     '    if !sys::read_file(list, &mut names) {\n        return true;'),
    ('stamp.rs', 'an empty line of a list is stamped',
     '        if rel.is_empty() {\n            continue;\n        }\n        stamp_line(repo, rel, texts_dir, &mut lines);',
     '        stamp_line(repo, rel, texts_dir, &mut lines);'),
    ('stamp.rs', 'lines that cannot be written are no failure',
     '    sys::write_file(out_path, &lines)\n}',
     '    sys::write_file(out_path, &lines);\n    true\n}'),
    ('main.rs', 'another exit code when stamp-worker fails',
     '        if !stamp::stamp_worker_main(&a[2], &a[3], &a[4], &a[5]) {\n            exit(1);',
     '        if !stamp::stamp_worker_main(&a[2], &a[3], &a[4], &a[5]) {\n            exit(3);'),
]

JUDGE = "port-stamp.sh"


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
