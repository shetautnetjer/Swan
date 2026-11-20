#!/usr/bin/env python3
"""Proves stage 2's judge can fail (AGENTS.md rule 4: a check never seen
failing may be testing nothing).

Builds copies of the Rust program, each broken in one place on purpose, and
runs scripts/port-plan.sh against each. Every copy must be caught.

    scripts/port-prove-plan.py

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
    ("gradle.rs", "a module's build.gradle wins over build.gradle.kts",
     'let kotlin = sys::read_file(&[dir, b"/build.gradle.kts"].concat(), &mut b);',
     'let kotlin = !sys::read_file(&[dir, b"/build.gradle"].concat(), &mut b) && sys::read_file(&[dir, b"/build.gradle.kts"].concat(), &mut b);'),
    ("gradle.rs", 'com.android.test gets unit tests',
     'if ANDROID_PLUGINS[k as usize] != b"com.android.test" {',
     'if true {'),
    ("gradle.rs", '"id:version" in a catalog is not read',
     ' || find(s, &[q, p, b":"].concat()) >= 0',
     ''),
    ("gradle.rs", 'a catalog entry "id:version" keeps its version',
     'id.extend_from_slice(if colon >= 0 { &value[1..1 + colon as usize] } else { &value[1..end] });',
     'id.extend_from_slice(&value[1..end]);'),
    ("gradle.rs", 'a catalog key that only holds "id" counts',
     'if !(p - 2 == 0 || !is_ident(value[p - 3])) {',
     'if false {'),
    ("gradle.rs", 'buildSrc is not read',
     'if sys::is_dir(&[repo, b"/buildSrc"].concat()) {',
     'if false {'),
    ("gradle.rs", 'an includeBuild in a comment counts',
     'let text = strip_gradle_comments(&s, kotlin);\n    let mut p = 0;\n    while p < text.len() {\n        let a = find(&text[p..], b"includeBuild");',
     'let text = s.clone();\n    let mut p = 0;\n    while p < text.len() {\n        let a = find(&text[p..], b"includeBuild");'),
    ("gradle.rs", 'a longer word ending in includeBuild counts',
     'let word = p + a == 0 || !is_ident(text[p + a - 1]);',
     'let word = true;'),
    ("gradle.rs", 'an includeBuild leaving the repo is read',
     ' || find(name, b"..") >= 0 || name[0] == b\'/\';',
     " || name[0] == b'/';"),
    ("gradle.rs", "a precompiled plugin's package is not part of its id",
     'if id.is_empty() && starts_with(t, b"package ") {',
     'if false {'),
    ("gradle.rs", 'a Groovy precompiled plugin is not one',
     'let script = ends_with(name, b".gradle.kts") || ends_with(name, b".gradle");',
     'let script = ends_with(name, b".gradle.kts");'),
    ("gradle.rs", 'a script outside src/main is a plugin',
     '&& (find(full, b"/src/main/kotlin/") >= 0 || find(full, b"/src/main/groovy/") >= 0)',
     ''),
    ("gradle.rs", 'a class keeps its package',
     'let cls = if dot >= 0 { &qualified[dot as usize + 1..] } else { qualified };',
     'let cls = qualified; let _ = dot;'),
    ("gradle.rs", "an id without '=' (Groovy id 'x') is not read",
     '                if k < to && text[k] == b\'=\' {\n                    k += 1;\n                }\n                while k < to && (text[k] == b\' \' || text[k] == b\'\\t\') {\n                    k += 1;\n                }\n                if k < to && (text[k] == b\'"\' || text[k] == b\'\\\'\') {',
     '                if !(k < to && text[k] == b\'=\') {\n                    continue;\n                }\n                k += 1;\n                while k < to && (text[k] == b\' \' || text[k] == b\'\\t\') {\n                    k += 1;\n                }\n                if k < to && (text[k] == b\'"\' || text[k] == b\'\\\'\') {'),
    ("gradle.rs", '.asProvider is not taken off a catalog id',
     'for tail in [&b".get"[..], b".asProvider"] {',
     'for tail in [&b".get"[..]] {'),
    ("gradle.rs", 'a class in a .groovy file is not found',
     'for ext in [&b".kt"[..], b".groovy", b".java"] {',
     'for ext in [&b".kt"[..], b".java"] {'),
    ("gradle.rs", 'a class in a .java file is not found',
     'for ext in [&b".kt"[..], b".groovy", b".java"] {',
     'for ext in [&b".kt"[..], b".groovy"] {'),
    ("gradle.rs", 'one pass only, so a chain of three is not followed',
     '                more = true;\n            }\n        }\n    }\n    known',
     '                more = false;\n            }\n        }\n    }\n    known'),
    ("gradle.rs", 'a module naming a convention id in quotes is not read',
     '        if k < 0 {\n            k = convention_plugin_in(line, conventions);\n        }',
     '        let _ = conventions;'),
    ("gradle.rs", "the catalog's aliases for convention plugins not added",
     '        if !k.is_empty() {\n            push_pair(&mut aliases, &e[..tab as usize], &k);\n        }',
     '        let _ = k;'),
    ("gradle.rs", "a convention plugin's own Android plugin taken as com.android.application",
     '                push_int(&mut known, k);',
     '                push_int(&mut known, 0);'),
    ("gradle.rs", "a registration's id read from the start of the file",
     '            let mut from = at;\n            let mut depth = 0;',
     '            let mut from = 0;\n            let mut depth = 0;'),
    ("gradle.rs", 'settings.gradle wins over settings.gradle.kts',
     '    let kotlin = sys::read_file(&[repo, b"/settings.gradle.kts"].concat(), &mut s);\n    if !(kotlin || sys::read_file(&[repo, b"/settings.gradle"].concat(), &mut s)) {\n        return out;\n    }\n    let text = strip_gradle_comments(&s, kotlin);\n    let mut open = false;',
     '    let kotlin = !sys::read_file(&[repo, b"/settings.gradle"].concat(), &mut s) && sys::read_file(&[repo, b"/settings.gradle.kts"].concat(), &mut s);\n    if !(kotlin || sys::read_file(&[repo, b"/settings.gradle"].concat(), &mut s)) {\n        return out;\n    }\n    let text = strip_gradle_comments(&s, kotlin);\n    let mut open = false;'),
    ("gradle.rs", "'_' in an Android plugin's catalog key is kept",
     "trim(&line[..eq as usize])].concat();\n                for c in name.iter_mut() {\n                    if *c == b'-' || *c == b'_' {",
     "trim(&line[..eq as usize])].concat();\n                for c in name.iter_mut() {\n                    if *c == b'-' {"),
    ("gradle.rs", "'_' in a convention plugin's catalog key is kept",
     "trim(&line[..eq])].concat();\n                for c in name.iter_mut() {\n                    if *c == b'-' || *c == b'_' {",
     "trim(&line[..eq])].concat();\n                for c in name.iter_mut() {\n                    if *c == b'-' {"),
    ("pyplan.rs", 'a piece may hold 63 files, not 64',
     'const PY_PIECE_FILES: i64 = 64;',
     'const PY_PIECE_FILES: i64 = 63;'),
    ("pyplan.rs", 'a split may make 39 groups, not 40',
     'const PY_PIECE_GROUPS: usize = 40;',
     'const PY_PIECE_GROUPS: usize = 39;'),
    ("pyplan.rs", 'a relative import does not need the repo',
     'if !m.is_empty() && m[0] == b\'.\' {\n                f(b".");',
     'if false {\n                f(b".");'),
    ("pyplan.rs", 'only the first name of an import line is read',
     "for part in l[7..].split(|&c| c == b',') {",
     "for part in l[7..].split(|&c| c == b',').take(1) {"),
    ("pyplan.rs", "a module's name keeps its .py",
     'let stem = if ends_with(&p[at..], b".py") { &p[at..p.len() - 3] } else { &p[at..] };',
     'let stem = &p[at..];'),
    ("pyplan.rs", "a folder is not one of the repo's names",
     'own.insert(hash(&p[at..at + sl]));',
     'let _ = sl;'),
    ("pyplan.rs", 'one in ten importing the repo is too many',
     'needs_repo * 10 <= loose',
     'needs_repo * 10 < loose'),
    ("pyplan.rs", 'a group is over the limits by its file count only',
     'if (files > PY_PIECE_FILES || bytes > limit) && files > pick_files {',
     'if files > PY_PIECE_FILES && files > pick_files { let _ = bytes;'),
    ("pyplan.rs", 'the last of the biggest groups is split first',
     '&& files > pick_files {',
     '&& files >= pick_files {'),
    ("pyplan.rs", 'a name that ends at the prefix does not stop the split',
     'if nm.len() == plen {\n                    ends_here = true;\n                } else if',
     'if false {\n                    ends_here = true;\n                } else if nm.len() > plen &&'),
    ("pyplan.rs", 'no limit on how many groups a split makes',
     'if ends_here || kids < 2 || g_rep.len() - 1 + kids > PY_PIECE_GROUPS {',
     'if ends_here || kids < 2 {'),
    ("pyplan.rs", "a split group's prefix is not lengthened",
     '            if !g_done[g] {\n                lengthen(g, &g_rep, &mut g_len);',
     '            if false {\n                lengthen(g, &g_rep, &mut g_len);'),
    ("pyplan.rs", '"." can be a piece',
     'if pre.is_empty() || pre == b"." || pre == b".." {',
     'if pre.is_empty() {'),
    ("pyplan.rs", 'pieces in reverse name order',
     'order.sort_by(|&a, &b| prefix(a).cmp(prefix(b)));',
     'order.sort_by(|&a, &b| prefix(b).cmp(prefix(a)));'),
    ("pyplan.rs", 'an empty file counts as nothing',
     'sizes.push(sys::file_size(full).max(1));',
     'sizes.push(sys::file_size(full));'),
    ("pyplan.rs", 'one run only below k files, not 2k',
     'if k <= 1 || (sizes.len() as i64) < 2 * k {',
     'if k <= 1 || (sizes.len() as i64) < k {'),
    ("pyplan.rs", 'a folder exactly at the limit is split',
     'if size_under(&dir) <= limit && !dir.is_empty() {',
     'if size_under(&dir) < limit && !dir.is_empty() {'),
    ("pyplan.rs", 'a folder holds the files of a longer name beside it',
     "dir.is_empty() || (starts_with(p, dir) && p.len() > dir.len() && p[dir.len()] == b'/')",
     'dir.is_empty() || (starts_with(p, dir) && p.len() > dir.len())'),
    ("pyplan.rs", 'a subfolder is queued once per file',
     'if subs.insert(sub) {',
     'if subs.insert(sub) || true {'),
    ("pyplan.rs", 'a folder of many loose files is never split by prefix',
     'if loose > PY_PIECE_FILES && plan_prefix_pieces(repo, &dir, &paths, &sizes, limit, &mut plan) {',
     'if false && plan_prefix_pieces(repo, &dir, &paths, &sizes, limit, &mut plan) {'),
    ("gradle.rs", 'a convention id counts anywhere it is in quotes',
     'fn gradle_applies_at(s: &[u8], q: usize) -> bool {\n',
     'fn gradle_applies_at(s: &[u8], q: usize) -> bool {\n    if q < usize::MAX {\n        return true;\n    }\n'),
    ("gradle.rs", 'any name before = or : applies a plugin',
     'return gradle_word_before(s, i) == b"plugin";',
     'return true;'),
    ("gradle.rs", 'apply("x") does not apply a plugin',
     'w == b"id" || (paren && w == b"apply")',
     'w == b"id"'),
    ("gradle.rs", "id 'x' without parentheses does not apply a plugin",
     'w == b"id" || (paren && w == b"apply")',
     '(paren && w == b"id") || (paren && w == b"apply")'),
    ("gradle.rs", "only a convention id's first place on a line is looked at",
     '                p = at + 1;',
     '                p = s.len();'),
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
    ran = subprocess.run([os.path.join(here, "scripts", "port-plan.sh")], env=dict(os.environ, SWAN_NEW=base),
                         capture_output=True, encoding="utf-8", errors="replace")
    last = (ran.stdout.strip().splitlines() or [""])[-1]
    if ran.returncode != 0 or not last.startswith("the same:"):
        print(f"the judge does not pass the unbroken program (port-plan.sh exit {ran.returncode}), so it proves nothing:")
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
        ran = subprocess.run([os.path.join(here, "scripts", "port-plan.sh")],
                             env=dict(os.environ, SWAN_NEW=program), capture_output=True, encoding="utf-8", errors="replace")
        return n, what, ran.returncode, ran.stdout

    missed = 0
    # One judge a core: each runs hundreds of comparisons.
    with ThreadPoolExecutor(max(1, min(len(built), os.cpu_count() or 4))) as pool:
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
