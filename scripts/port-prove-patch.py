#!/usr/bin/env python3
"""Proves stage 4's judge for the indexer patches can fail (AGENTS.md rule 4:
a check never seen failing may be testing nothing).

Builds copies of the Rust program, each broken in one place on purpose, and
runs scripts/port-patch.sh against each, after the unbroken program passes
it. Every copy must be caught.

    scripts/port-prove-patch.py            every break
    scripts/port-prove-patch.py 3 9        only these (as numbered in a run)
    scripts/port-prove-patch.py --fit      whether each break still fits the source; builds nothing

The tree is not touched: the copies are made and built in a temporary
folder.

Exit 0: every break was caught. 1: one was not (the judge has a hole), or a
break no longer fits the source (mend BREAKS below, then run again). 2: the
judge does not pass the unbroken program, so no break proves anything.

Not among the breaks, because the two commands cannot show them:
- counting a site again from one byte on, not from its end: no site of the
  three patches overlaps itself;
- the new file flushed to disk before it is renamed, and removed when the
  rename fails: nothing here makes a rename fail after the file is written.
The break of a folder that cannot be written needs a run that is not root.
"""
import os
import shutil
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor

ONCE = '        if pypatch_count(text, from_of(k)) != 1 {'
FROM = '    let from_of = |k: usize| if revert { sites[2 * k + 1] } else { sites[2 * k] };'
PY_CALL = 'let r = if util::ends_with(&a[2], b"scip-python.js") { pypatch::pysite_file(&a[2], n == 4) } else { pypatch::pypatch_file(&a[2], n == 4) };'

# (file in rust/src, what is broken, the text as it is, the text broken)
BREAKS = [
    # When a file is patched at all.
    ('pypatch.rs', 'a site that is there twice is patched', ONCE,
     '        if pypatch_count(text, from_of(k)) == 0 {'),
    ('pypatch.rs', 'a file missing a site is patched', ONCE,
     '        if pypatch_count(text, from_of(k)) > 1 {'),
    ('pypatch.rs', 'a file with the mark is patched, one without reverted',
     '    if has != revert {',
     '    if has == revert {'),
    ('pypatch.rs', 'the mark is not looked for',
     '    if has != revert {\n        return b"already";\n    }\n',
     '    let _ = has;\n'),
    ('pypatch.rs', 'a file that cannot be read is "already"',
     '    if !sys::read_file(path, &mut text) {\n        return b"no match";',
     '    if !sys::read_file(path, &mut text) {\n        return b"already";'),
    ('pypatch.rs', 'a file that cannot be written is "patched"',
     '    if !sys::write_file_atomic(path, &out) {\n        return b"no match";',
     '    if !sys::write_file_atomic(path, &out) {\n        return b"patched";'),
    ('pypatch.rs', '"reverted" for a patch and "patched" for a revert',
     '    if revert {\n        b"reverted"\n    } else {\n        b"patched"\n    }',
     '    if revert {\n        b"patched"\n    } else {\n        b"reverted"\n    }'),
    # How the text is rebuilt.
    ('pypatch.rs', 'a revert looks for the old text', FROM,
     '    let from_of = |k: usize| sites[2 * k + usize::from(false && revert)];'),
    ('pypatch.rs', 'a patch looks for the new text', FROM,
     '    let from_of = |k: usize| sites[2 * k + usize::from(true || revert)];'),
    ('pypatch.rs', 'a patch writes the old text back',
     '    let to_of = |k: usize| if revert { sites[2 * k] } else { sites[2 * k + 1] };',
     '    let to_of = |k: usize| sites[2 * k + usize::from(false && revert)];'),
    ('pypatch.rs', 'the last site in the file is taken first',
     '            if i >= 0 && (best < 0 || i < best) {',
     '            if i >= 0 && (best < 0 || i > best) {'),
    ('pypatch.rs', 'the old text stays after the new',
     '        at = at + best as usize + from_of(best_k).len();',
     '        at = at + best as usize + from_of(best_k).len().min(1);'),
    ('pypatch.rs', 'the text after the last site is dropped',
     '            out.extend_from_slice(&text[at..]);\n            break;',
     '            break;'),
    ('pypatch.rs', 'the text before a site is dropped',
     '        out.extend_from_slice(&text[at..at + best as usize]);\n',
     ''),
    # The marks and the sites themselves.
    ('pypatch.rs', "the reachability memo's mark is another word",
     'const PYPATCH_MARK: &[u8] = b"__swanReach";',
     'const PYPATCH_MARK: &[u8] = b"__swanReachX";'),
    ('pypatch.rs', "the package fix's mark is another word",
     'const PYSITE_MARK: &[u8] = b"__swanSite";',
     'const PYSITE_MARK: &[u8] = b"__swanSiteX";'),
    ('tspatch.rs', "the stable names' mark is another word",
     'const TSPATCH_MARK: &[u8] = b"function swanOrdinal(";',
     'const TSPATCH_MARK: &[u8] = b"function swanOrdinalX(";'),
    ('pypatch.rs', "one byte of the reachability memo's new text differs",
     '__swanProv.delete(n.id)}}function b(e,t){",',
     '__swanProv.delete(n.id);}}function b(e,t){",'),
    ('pypatch.rs', "one byte of the package fix's new text differs",
     'if(n>=768)return n>780?780:n})(process.env.SWAN_PY_VERSION),",',
     'if(n>=768)return n>781?780:n})(process.env.SWAN_PY_VERSION),",'),
    ('tspatch.rs', "one byte of the stable names' new text differs",
     'return table.get(node) ?? 0;',
     'return table.get(node) ?? 1;'),
    ('tspatch.rs', "one byte of the stable names' old text differs",
     'counter = new Counter_1.Counter();',
     'counter = new Counter_2.Counter();'),
    # The commands.
    ('main.rs', 'only a file named exactly scip-python.js gets the package fix', PY_CALL,
     PY_CALL.replace('util::ends_with(&a[2], b"scip-python.js")', '&a[2][..] == b"scip-python.js"')),
    ('main.rs', 'the name must end /scip-python.js for the package fix', PY_CALL,
     PY_CALL.replace('b"scip-python.js")', 'b"/scip-python.js")')),
    ('main.rs', "--revert patches scip-python.js", PY_CALL,
     PY_CALL.replace('pypatch::pysite_file(&a[2], n == 4)', 'pypatch::pysite_file(&a[2], false)')),
    ('main.rs', "--revert patches pyright-internal.js", PY_CALL,
     PY_CALL.replace('pypatch::pypatch_file(&a[2], n == 4)', 'pypatch::pypatch_file(&a[2], false)')),
    ('main.rs', "--revert patches FileIndexer.js",
     '        let r = tspatch::tspatch_file(&a[2], n == 4);',
     '        let r = tspatch::tspatch_file(&a[2], false);'),
    ('main.rs', 'another exit code when the Python patch does not fit',
     '        print(r);\n        if r == b"no match" {\n            exit(1);\n        }\n    } else if cmd == b"scip-typescript-patch"',
     '        print(r);\n        if r == b"no match" {\n            exit(3);\n        }\n    } else if cmd == b"scip-typescript-patch"'),
    ('main.rs', 'another exit code when the TypeScript patch does not fit',
     '        let r = tspatch::tspatch_file(&a[2], n == 4);\n        print(r);\n        if r == b"no match" {\n            exit(1);',
     '        let r = tspatch::tspatch_file(&a[2], n == 4);\n        print(r);\n        if r == b"no match" {\n            exit(3);'),
    # Replacing the file.
    ('sys.rs', 'the new file is copied over the old, and left beside it',
     '    if written && fs::rename(path(&tmp), path(p)).is_ok() {',
     '    if written && fs::copy(path(&tmp), path(p)).is_ok() {'),
]

JUDGE = "port-patch.sh"


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
