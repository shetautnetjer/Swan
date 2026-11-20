#!/usr/bin/env python3
"""Proves stage 2's judge can fail (AGENTS.md rule 4: a check never seen
failing may be testing nothing).

Builds copies of the Rust program, each broken in one place on purpose, and
runs scripts/port-plan.sh against each. Every copy must be caught.

    scripts/port-prove-plan.py

The tree is not touched: the copies are made and built in a temporary
folder.

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
    ("rustproj.rs", "the limit: 11 projects instead of 12",
     "const RUST_PROJECT_LIMIT: usize = 12;", "const RUST_PROJECT_LIMIT: usize = 11;"),
    ("rustproj.rs", "a manifest's comments are read as text",
     "let t = trim(if hash >= 0 { &raw[..hash as usize] } else { raw });", "let t = trim(raw); let _ = hash;"),
    ("rustproj.rs", "an exclude array ends after its first line",
     "                if find(t, b\"]\") >= 0 {\n                    in_exclude = false;",
     "                if true {\n                    in_exclude = false;"),
    ("rustproj.rs", "a path inside a word (mypath) counts",
     "let word = p + a == 0 || {", "let word = true || {"),
    ("rustproj.rs", "\"..\" may leave the repo",
     "if parts.is_empty() {\n                    out_of_repo = true;",
     "if parts.is_empty() {\n                    out_of_repo = false;"),
    ("rustproj.rs", "an excluded folder's own subfolders are not cut off",
     "(x == d || cargo_inside(d, x))", "(x == d)"),
    ("rustproj.rs", "a pinned toolchain no older than the default gets its library",
     "rustup_minor(&rh, &dflt) > pinned", "rustup_minor(&rh, &dflt) >= pinned - 20"),
    ("rustproj.rs", "the plain rust-toolchain file is not read",
     "} else if sys::read_file(&[dir, b\"/rust-toolchain\"].concat(), &mut text) {",
     "} else if false && sys::read_file(&[dir, b\"/rust-toolchain\"].concat(), &mut text) {"),
    ("rustproj.rs", "the missing-toolchain warning reworded",
     "b\", which is not installed; indexing with \"", "b\", not installed; using \""),
    ("rustproj.rs", "the library path written without JSON escapes",
     "json_string(&mut c, std_src);", "c.push(b'\"'); c.extend_from_slice(std_src); c.push(b'\"');"),
    ("main.rs", "a repo that does not exist is not refused",
     "None => die(&[&b\"swan: no such path: \"[..], p].concat()),", "None => p.to_vec(),"),
    ("gradle.rs", "Kotlin's nested comments are not nested",
     "s[i + 1] == b'*' && kotlin {",
     "s[i + 1] == b'*' && false {"),
    ("gradle.rs", "Groovy's comments are nested too",
     "s[i + 1] == b'*' && kotlin {",
     "s[i + 1] == b'*' {"),
    ("gradle.rs", 'a backslash escapes in a Kotlin raw string',
     "if c == b'\\\\' && (!triple || !kotlin) && i + 1 < n {\n                out.push(s[i + 1]);",
     "if c == b'\\\\' && i + 1 < n {\n                out.push(s[i + 1]);"),
    ("gradle.rs", 'strings do not hide comment marks',
     '            if c == b\'"\' || c == b\'\\\'\' {\n                q = c;\n                if i + 2 < n && s[i + 1] == c && s[i + 2] == c {\n                    triple = true;\n                    out.push(c);',
     '            if false {\n                q = c;\n                if i + 2 < n && s[i + 1] == c && s[i + 2] == c {\n                    triple = true;\n                    out.push(c);'),
    ("gradle.rs", 'a slash after a value starts a slashy string',
     'word == b"return" || word == b"case"',
     'true || word == b"case"'),
    ("gradle.rs", 'a slash after postfix ++ starts a slashy string',
     'return i < 2 || s[i - 2] != c;',
     'return true;'),
    ("gradle.rs", 'a slash after return is division',
     'word == b"return" ||',
     'word == b"retur" ||'),
    ("gradle.rs", '\\/ does not escape in a slashy string',
     "if c == b'\\\\' && i + 1 < n && s[i + 1] == b'/' {\n                out.push(b'/');",
     "if false {\n                out.push(b'/');"),
    ("gradle.rs", 'dollar-slashy strings not known',
     "} else if !kotlin && c == b'$' && i + 1 < n && s[i + 1] == b'/' {\n            out.push(c);",
     '} else if false {\n            out.push(c);'),
    ("gradle.rs", '$/ does not escape in a dollar-slashy string',
     "if c == b'$' && i + 1 < n && (s[i + 1] == b'$' || s[i + 1] == b'/') {\n                out.push(s[i + 1]);",
     "if c == b'$' && i + 1 < n && s[i + 1] == b'$' {\n                out.push(s[i + 1]);"),
    ("gradle.rs", 'a reaction ends at its first inner )',
     "} else if depth > 0 && c == b'(' {\n                depth += 1;",
     '} else if false {\n                depth += 1;'),
    ("gradle.rs", 'a word ending in withId is a reaction',
     'if depth == 0 && q == 0 && (i == 0 || !is_ident(s[i - 1])) {',
     'if depth == 0 && q == 0 {'),
    ("gradle.rs", "a space before a reaction's ( hides it",
     'while j < n && is_blank(s[j]) {',
     'while false && j < n {'),
    ("gradle.rs", 'a chained "version " line ends the entry',
     ' || starts_with(line, b"version ")',
     ''),
    ("gradle.rs", 'an include list ending in a comma does not go on',
     'open = depth > 0 || ends_with(line, b",");',
     'open = depth > 0;'),
    ("gradle.rs", 'an include call over lines does not go on',
     'open = depth > 0 || ends_with(line, b",");',
     'open = ends_with(line, b",");'),
    ("gradle.rs", "a name without ':' is taken as it is",
     'if starts_with(name, b":") { name.to_vec() } else { [&b":"[..], name].concat() }',
     'name.to_vec()'),
    ("gradle.rs", "a name with '/' is taken",
     ' || find(name, b"/") >= 0',
     ''),
    ("gradle.rs", 'an include inside a string over lines counts',
     '        if in_string {\n            continue;\n        }',
     '        if false && in_string {\n            continue;\n        }'),
    ("gradle.rs", 'includeBuild counts as include',
     "            && line.len() > 7\n            && (line[7] == b'(' || line[7] == b' ' || line[7] == b'\\t');",
     '            && line.len() > 7;'),
    ("gradle.rs", 'settings.gradle wins over settings.gradle.kts',
     'let kotlin = sys::read_file(&[repo, b"/settings.gradle.kts"].concat(), &mut s);',
     'let kotlin = !sys::read_file(&[repo, b"/settings.gradle"].concat(), &mut s) && sys::read_file(&[repo, b"/settings.gradle.kts"].concat(), &mut s);'),
    ("gradle.rs", "a module's build.gradle wins over build.gradle.kts",
     'let kotlin = sys::read_file(&[dir, b"/build.gradle.kts"].concat(), &mut b);',
     'let kotlin = !sys::read_file(&[dir, b"/build.gradle"].concat(), &mut b) && sys::read_file(&[dir, b"/build.gradle.kts"].concat(), &mut b);'),
    ("gradle.rs", "'_' in a catalog key is kept",
     "if *c == b'-' || *c == b'_' {",
     "if *c == b'-' {"),
    ("gradle.rs", 'com.android.test gets unit tests',
     'if ANDROID_PLUGINS[k as usize] != b"com.android.test" {',
     'if true {'),
    ("gradle.rs", '"id:version" in a catalog is not read',
     ' || find(s, &[q, p, b":"].concat()) >= 0',
     ''),
]


def main():
    if len(sys.argv) != 1:
        sys.exit(__doc__)
    here = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
    cargo = shutil.which("cargo") or os.path.expanduser("~/.cargo/bin/cargo")
    work = tempfile.mkdtemp(prefix="port-prove-")
    try:
        sys.exit(prove(here, cargo, work))
    finally:
        shutil.rmtree(work, ignore_errors=True)


def prove(here, cargo, work):
    # One copy of rust/ is edited, built and put back as it was for each
    # break, so only the one crate is compiled each time.
    copy = os.path.join(work, "rust")
    shutil.copytree(os.path.join(here, "rust"), copy, ignore=shutil.ignore_patterns("target"))
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
        ran = subprocess.run([os.path.join(here, "scripts", "port-plan.sh")],
                             env=dict(os.environ, SWAN_NEW=program), capture_output=True, text=True)
        return n, what, ran.returncode, ran.stdout

    missed = 0
    with ThreadPoolExecutor(len(built) or 1) as pool:
        for n, what, code, said in pool.map(judge, built):
            caught = [line for line in said.splitlines() if line.startswith("DIFFERENT (")]
            steps = list(dict.fromkeys(line[len("DIFFERENT ("):].rstrip(")") for line in caught))
            if code == 1 and caught:
                print(f"break {n} caught ({what}) by: {'; '.join(steps)[:260]}")
            else:
                missed += 1
                print(f"break {n} NOT CAUGHT ({what}): port-plan.sh exit {code}")
                print("    " + "\n    ".join(said.splitlines()[-6:]))
    print(f"{len(built) - missed} of {len(BREAKS)} breaks caught" + (f", {unfit} did not fit or build" if unfit else ""))
    return 0 if missed == 0 and unfit == 0 else 1


if __name__ == "__main__":
    main()
