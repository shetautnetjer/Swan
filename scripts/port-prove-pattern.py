#!/usr/bin/env python3
"""Proves stage 3's judge for structural search can fail (AGENTS.md rule 4:
a check never seen failing may be testing nothing).

Builds copies of the Rust program, each broken in one place on purpose, and
runs scripts/port-pattern.sh against each, after the unbroken program
passes it. Every copy must be caught.

    scripts/port-prove-pattern.py

The tree is not touched: the copies are made and built in a temporary
folder.

Exit 0: every break was caught. 1: one was not (the judge has a hole), or a
break no longer fits the source (mend BREAKS below, then run again). 2: the
judge does not pass the unbroken program, so no break proves anything.
"""
import os
import shutil
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor

# (file in rust/src, what is broken, the text as it is, the text broken)
BREAKS = [
    ('treesitter.rs', 'a string\'s $ is renamed ("$HOME" no longer the string)',
     '        if c == b\'"\' || (single && c == b\'\\\'\') || (js && c == b\'`\') {\n            let mut e = i + 1;',
     '        if false {\n            let mut e = i + 1;'),
    ('treesitter.rs', "a Lua long string's $ is renamed",
     "        if lua && c == b'[' {\n            let long = lua_long_bracket(pattern, i);",
     '        if false {\n            let long = lua_long_bracket(pattern, i);'),
    ('treesitter.rs', "a Rust raw string's $ is renamed",
     'if lang == b"rust" && c == b\'r\' && (i == 0 || !is_word(&pattern[i - 1..i])) {',
     'if false {'),
    ('treesitter.rs', "a C# verbatim string's $ is renamed",
     '            if verbatim && q < n && pattern[q] == b\'"\' {',
     '            if false && verbatim && q < n && pattern[q] == b\'"\' {'),
    ('treesitter.rs', "a Python triple-quoted string's $ is renamed",
     'let triple_ok = py || gd || ((lang == b"kotlin" || lang == b"java") && c == b\'"\');',
     'let triple_ok = gd || ((lang == b"kotlin" || lang == b"java") && c == b\'"\');'),
    ('treesitter.rs', "a Kotlin raw string's $ is renamed",
     'let triple_ok = py || gd || ((lang == b"kotlin" || lang == b"java") && c == b\'"\');',
     'let triple_ok = py || gd || (lang == b"java" && c == b\'"\');'),
    ('treesitter.rs', "a PHP heredoc's $ is renamed",
     "if php && c == b'<' && i + 3 < n && pattern[i + 1] == b'<' && pattern[i + 2] == b'<' {",
     'if false {'),
    ('treesitter.rs', "a comment's $ is renamed",
     '        if slash_comment || hash_comment {',
     '        if false {'),
    ('treesitter.rs', '$$$ with no name is not anonymous',
     '            out.extend_from_slice(if e > i + d { &pattern[i + d..e] } else { b"_" });',
     '            out.extend_from_slice(if e > i + d { &pattern[i + d..e] } else { b"R" });'),
    # Not a break: indenting a GDScript pattern's further lines into the
    # function (context 7) cannot be seen. The grammar at the commit Swan
    # pins reads the same statements at the top of a file as inside a
    # function, so a pattern that parses in the function has already parsed
    # bare, and one that does not parse bare does not parse in the function
    # either: 22 texts parsed both ways had the same errors, and 10 multi-line
    # patterns on godot-demo-projects gave the same bytes from the Goose
    # program and a copy without the indenting.
    ('treesitter.rs', 'a pattern is not tried inside a function (Rust, C)',
     '        1 => (b"fn zswan_ctx() {\\n", b"\\n}"),',
     '        1 => (b"", b""),'),
    ('treesitter.rs', 'a PHP pattern is read as HTML outside <?php',
     '            if lang == b"php" && k < 5 {\n                continue;\n            }',
     '            let _ = k;'),
    ('treesitter.rs', 'a pattern with errors in it compiles',
     '                    if !(t.starts_with(b"zswan_mv") && is_word(t)) {\n                        bad = true;',
     '                    if false && !(t.starts_with(b"zswan_mv") && is_word(t)) {\n                        bad = true;'),
    ('treesitter.rs', "a file must hold the metavariables' names too",
     '                            if !leaf[j..e].starts_with(b"zswan_mv") {',
     '                            if true {'),
    ('treesitter.rs', 'an anonymous $_ captures',
     "        if !name.is_empty() && name[0] == b'_' {\n            return true; // anonymous",
     '        if false {\n            return true; // anonymous'),
    ('treesitter.rs', 'a name used twice need not match the same text',
     '                return self.span_text(x, y) == self.span_text(a, b);',
     '                return true || self.span_text(x, y) == self.span_text(a, b);'),
    ('treesitter.rs', '$X may be an unnamed node (punctuation)',
     '            return (flags(tn, t) & F_NAMED as i64) != 0 && self.bind(&name, t, t);',
     '            return self.bind(&name, t, t);'),
    ('treesitter.rs', 'an empty $$$ before a comma still needs the comma',
     '            if pn >= 0 && (flags(pnodes, pn) & F_NAMED as i64) == 0 && pat.ptext(pn) == b"," {',
     '            if false {'),
    ('treesitter.rs', 'a comma before an empty trailing $$$ is needed',
     '        if (flags(pnodes, p) & F_NAMED as i64) == 0 && pat.ptext(p) == b"," && pn >= 0 && pat.meta(pn, &mut name) == 3 {',
     '        if false {'),
    ('treesitter.rs', 'punctuation the pattern leaves out is not skipped',
     '        if self.unnamed(t) && self.match_seq(p, solid(tn, next(tn, t))) {',
     '        if false && self.unnamed(t) {'),
    ('treesitter.rs', 'a $$$ run takes no siblings',
     '        if pat.meta(p, &mut name) == 3 {\n            if self.bind(&name, -1, -1) && self.match_seq(pn, t) {\n                return true;\n            }\n            self.binds.truncate(mark);',
     '        if pat.meta(p, &mut name) == 3 {\n            return self.bind(&name, -1, -1) && self.match_seq(pn, t);\n        }\n        if false {'),
    ('treesitter.rs', "a capture's name and text swapped",
     '                    caps.extend_from_slice(&b.name);\n                    caps.push(0x1f);\n                    caps.extend_from_slice(m.span_text(b.a, b.b));',
     '                    caps.extend_from_slice(m.span_text(b.a, b.b));\n                    caps.push(0x1f);\n                    caps.extend_from_slice(&b.name);'),
    ('treesitter.rs', 'files given back in the wrong order',
     '        results.into_iter().map(|r| r.unwrap_or_default()).collect()',
     '        results.into_iter().rev().map(|r| r.unwrap_or_default()).collect()'),
    ('treesitter.rs', 'a comment can be a match',
     '            if (flags(&t_nodes, i) & F_EXTRA as i64) == 0 && m.match_node(self.p_root, i) {',
     '            if m.match_node(self.p_root, i) {'),
    ('treesitter.rs', '".rs" files have no grammar',
     '    if e(b".rs") {\n        return b"rust";',
     '    if e(b".rs") && false {\n        return b"rust";'),
    ('structural.rs', 'languages searched in another order',
     '    b"typescript", b"tsx", b"javascript",',
     '    b"tsx", b"typescript", b"javascript",'),
    ('structural.rs', "a match's text not cut at 200 bytes",
     '    if one.len() > 200 {',
     '    if one.len() > 2000 {'),
    ('structural.rs', "a match's end line is its first",
     '                push_int(&mut body, r + count_newlines(mt) + 1);',
     '                push_int(&mut body, r + 1);'),
    ('structural.rs', 'the outermost symbol named, not the innermost',
     '                            || spans[j + 1] - spans[j] < spans[b + 1] - spans[b]',
     '                            || spans[j + 1] - spans[j] > spans[b + 1] - spans[b]'),
    ('structural.rs', "a stale file's matches not marked",
     '                if stale_file {',
     '                if false && stale_file {'),
    ('structural.rs', 'why a language was skipped left out',
     '            skipped.extend_from_slice(b",\\"why\\":");\n            json_string(&mut skipped, &why);',
     '            let _ = &why;'),
    ('structural.rs', 'a relative_path that is a file searches nothing',
     '    if sys::file_exists(&base) {\n        take(&base);',
     '    if sys::file_exists(&base) {\n        let _ = &base;'),
    ('structural.rs', 'files a pattern does not parse for counted as searched',
     '        let mut why: Vec<u8> = Vec::new();\n        if !pat.compile(l, pattern, &mut why) {',
     '        let mut why: Vec<u8> = Vec::new();\n        searched += count;\n        if !pat.compile(l, pattern, &mut why) {'),
    ('structural.rs', 'an empty pattern searched',
     '    if pattern.is_empty() {\n        out.extend_from_slice(b"pattern is required");',
     '    if false {\n        out.extend_from_slice(b"pattern is required");'),
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
    # rust/build.rs finds goose-treesitter's C through the import line of
    # src/swan.goose beside rust/, in the Goose build's cache.
    os.makedirs(os.path.join(work, "src"), exist_ok=True)
    shutil.copy(os.path.join(here, "src", "swan.goose"), os.path.join(work, "src", "swan.goose"))
    os.environ.setdefault("GOOSE_HOME", os.path.join(here, ".tools", "goose-home"))
    # The unbroken program first: a judge that does not pass it would "catch"
    # every break by failing for some other reason (review on #75).
    made = subprocess.run([cargo, "build", "--release", "--manifest-path", os.path.join(copy, "Cargo.toml")],
                          env=dict(os.environ, CARGO_TARGET_DIR=os.path.join(work, "target")),
                          capture_output=True, text=True)
    if made.returncode != 0:
        print(f"the unbroken program does not build:\n{made.stderr[-600:]}")
        return 2
    base = os.path.join(work, "swan-0")
    shutil.copy(os.path.join(work, "target", "release", "swan"), base)
    ran = subprocess.run([os.path.join(here, "scripts", "port-pattern.sh")], env=dict(os.environ, SWAN_NEW=base),
                         capture_output=True, encoding="utf-8", errors="replace")
    last = (ran.stdout.strip().splitlines() or [""])[-1]
    if ran.returncode != 0 or not last.startswith("the same:"):
        print(f"the judge does not pass the unbroken program (port-pattern.sh exit {ran.returncode}), so it proves nothing:")
        print("    " + "\n    ".join((ran.stdout + ran.stderr).strip().splitlines()[-8:]))
        return 2
    print(f"the unbroken program: {last}")
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
        ran = subprocess.run([os.path.join(here, "scripts", "port-pattern.sh")],
                             env=dict(os.environ, SWAN_NEW=program), capture_output=True, encoding="utf-8", errors="replace")
        return n, what, ran.returncode, ran.stdout

    missed = 0
    # One judge a core: each runs hundreds of comparisons.
    with ThreadPoolExecutor(max(1, min(len(built), os.cpu_count() or 4))) as pool:
        for n, what, code, said in pool.map(judge, built):
            caught = [line for line in said.splitlines() if line.startswith("DIFFERENT (")]
            steps = list(dict.fromkeys(line[len("DIFFERENT ("):].rstrip(")") for line in caught))
            if code == 2:
                missed += 1
                print(f"break {n} NOT JUDGED ({what}): the judge could not compare (port-pattern.sh exit 2)")
                print("    " + "\n    ".join(said.splitlines()[-4:]))
            elif code == 1 and caught:
                print(f"break {n} caught ({what}) by: {'; '.join(steps)[:260]}")
            else:
                missed += 1
                print(f"break {n} NOT CAUGHT ({what}): port-pattern.sh exit {code}")
                print("    " + "\n    ".join(said.splitlines()[-6:]))
    print(f"{len(built) - missed} of {len(BREAKS)} breaks caught" + (f", {unfit} did not fit or build" if unfit else ""))
    return 0 if missed == 0 and unfit == 0 else 1


if __name__ == "__main__":
    main()
