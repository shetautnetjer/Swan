#!/usr/bin/env python3
"""Proves stage 4's comparison for reading JSON can fail (AGENTS.md rule 4: a
check never seen failing may be testing nothing).

Builds copies of the Rust dumper (rust/src/bin/port-json.rs, which reads
with rust/src/json.rs), each broken in one place on purpose, and runs
scripts/port-json.sh against each, after the unbroken one passes it. Every
copy must be caught.

    scripts/port-prove-json.py            every break
    scripts/port-prove-json.py 3 9        only these (as numbered in a run)
    scripts/port-prove-json.py --fit      whether each break still fits the source; builds nothing

The tree is not touched: the copies are made and built in a temporary
folder.

Exit 0: every break was caught. 1: one was not (the comparison has a hole),
or a break no longer fits the source (mend BREAKS below, then run again). 2:
the comparison does not pass the unbroken dumper, so no break proves
anything.

Not among the breaks: a u-escape cut short by the end of its string. The
four bytes read then take in the closing quote, which is no hex digit, so
the text is refused with or without the check.
"""
import os
import shutil
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor

# (file in rust/src, what is broken, the text as it is, the text broken)
BREAKS = [
    ('json.rs', 'a carriage return is not white space',
     "    c == b' ' || c == b'\\n' || c == b'\\r' || c == b'\\t'",
     "    c == b' ' || c == b'\\n' || c == b'\\t'"),
    ('json.rs', 'a string may hold a raw control character',
     '        if c < 0x20 {\n            return None;\n        }',
     '        let _ = c < 0x20;'),
    ('json.rs', 'an escape is passed over as one byte',
     '            escaped = true;\n            pos += 2;',
     '            escaped = true;\n            pos += 1;'),
    ('json.rs', '\\/ is no escape',
     "        if e == b'\"' || e == b'\\\\' || e == b'/' {",
     "        if e == b'\"' || e == b'\\\\' {"),
    ('json.rs', '\\b is the letter b',
     '            out.push(8);',
     "            out.push(b'b');"),
    ('json.rs', 'hex digits A to F are not digits',
     "        b'A'..=b'F' => (c - b'A') as i64 + 10,",
     "        b'A'..=b'F' => -1,"),
    ('json.rs', 'any escape after a high surrogate is paired with it',
     '                if (0xDC00..0xE000).contains(&lo) {',
     '                if lo >= 0 {'),
    ('json.rs', 'a surrogate pair makes another code point',
     '                    cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);',
     '                    cp = 0x10000 + ((cp - 0xD800) << 9) + (lo - 0xDC00);'),
    ('json.rs', 'a number may start with 0 and go on',
     "    if !(int_digits > 0 && (int_digits == 1 || text[int_start] != b'0')) {",
     '    if int_digits == 0 {'),
    ('json.rs', 'a point needs no digit after it',
     '        if pos == frac_start {\n            return None;\n        }',
     '        let _ = frac_start;'),
    ('json.rs', 'an exponent needs no digit',
     '        if p == start {\n            return None;\n        }',
     '        let _ = start;'),
    ('json.rs', "an exponent's sign may not be +",
     "        if p < text.len() && (text[p] == b'-' || text[p] == b'+') {",
     "        if p < text.len() && text[p] == b'-' {"),
    ('json.rs', 'a number with a fraction is an integer',
     '            return None;\n        }\n        whole = false;\n    }\n    if pos < text.len() && (text[pos] == b\'e\'',
     '            return None;\n        }\n    }\n    if pos < text.len() && (text[pos] == b\'e\''),
    ('json.rs', 'a number with an exponent is an integer',
     '        pos = p;\n        whole = false;',
     '        pos = p;'),
    ('json.rs', 'an integer of nineteen digits is no integer',
     '    if whole && int_digits <= 19 {',
     '    if whole && int_digits <= 18 {'),
    ('json.rs', 'the least 64-bit integer is no integer',
     '        } else if neg && mant == max + 1 {\n            int = Some(i64::MIN);\n        }',
     '        }'),
    ('json.rs', 'a word need only start right',
     '    if !(*pos + w.len() <= text.len() && &text[*pos..*pos + w.len()] == w) {\n        return None;\n    }',
     '    if *pos + w.len() > text.len() {\n        return None;\n    }'),
    ('json.rs', 'anything may follow the value',
     '        if !outer.is_empty() || pos != text.len() {',
     '        if !outer.is_empty() {'),
    ('json.rs', 'either bracket closes a container',
     "            if d != (if is_obj { b'}' } else { b']' }) {\n                return None;\n            }",
     "            if d != b'}' && d != b']' {\n                return None;\n            }"),
    ('json.rs', 'a key needs no colon',
     "            if !(pos < text.len() && text[pos] == b':') {\n                return None;\n            }\n            pos += 1;",
     "            if pos < text.len() && text[pos] == b':' {\n                pos += 1;\n            }"),
    ('json.rs', 'a member is found by the start of its key',
     '            if self.nodes[i].key == key {',
     '            if self.nodes[i].key.starts_with(key) {'),
    ('json.rs', 'a string with an escape is kept as written',
     '    if !escaped {\n        return Some(text[start..end].to_vec());\n    }',
     '    if !escaped || text.len() > 1 {\n        return Some(text[start..end].to_vec());\n    }'),
    ('json.rs', 'a member is linked from its parent only, not from the one before',
     '        if let Some(l) = last {\n            nodes[l].next = Some(node);\n        } else if let Some(p) = parent {',
     '        if let Some(p) = parent {'),
]

JUDGE = "port-json.sh"


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
    shutil.copy(os.path.join(work, "target", "release", "port-json"), base)
    ran = subprocess.run([judge_script], env=dict(os.environ, PORT_JSON_RUST=base),
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
        shutil.copy(os.path.join(work, "target", "release", "port-json"), program)
        built.append((n, what, program))

    def judge(item):
        n, what, program = item
        ran = subprocess.run([judge_script], env=dict(os.environ, PORT_JSON_RUST=program),
                             capture_output=True, encoding="utf-8", errors="replace")
        return n, what, ran.returncode, ran.stdout

    missed = 0
    # One judge a core: each runs dozens of comparisons.
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
