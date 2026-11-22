#!/usr/bin/env python3
"""Proves stage 4's judge for `swan map` can fail, for the part of the map
that is carried (AGENTS.md rule 4: a check never seen failing may be testing
nothing).

Builds copies of the Rust program, each broken in one place on purpose, and
runs scripts/port-map.sh against each, after the unbroken program passes
it. Every copy must be caught.

    scripts/port-prove-map.py            every break
    scripts/port-prove-map.py 3 9        only these (as numbered in a run)
    scripts/port-prove-map.py --fit      whether each break still fits the source; builds nothing

The tree is not touched: the copies are made and built in a temporary
folder. The judge keeps what the Goose program said of each case, so only
the first run of it maps anything with the Goose program.

Exit 0: every break was caught. 1: one was not (the judge has a hole), or a
break no longer fits the source (mend BREAKS below, then run again). 2: the
judge does not pass the unbroken program, so no break proves anything.

Not among the breaks, because the carried part of a map cannot show them:
- what trust adds to the seal (the network, folders to write in): the
  survey is never run trusted, and git's answer is the same with it;
- the room for 255 bytes of other languages' names, and for 65,000 bytes
  of ignored folders;
- the map's lock held by another writer.
"""
import os
import shutil
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor

WALKED = "let walked = !dir.split(|&c| c == b'/').any(|seg| seg.is_empty() || seg[0] == b'.' || SKIP_DIRS.contains(&seg));"
SAID = "    let said: [(bool, &[u8]); 9] = [\n"
KINDS = '    for kind in [&b"node"[..], b"python", b"rust", b"go", b"java", b"deno"] {'
OLDER = '            for f in [&b"/swan.db"[..], b"/index-manifest.tsv", b"/python-pieces.tsv", b"/python-files.tsv"] {'
USAGE = '        if find(&text, b"spread-wings index <repo>") >= 0 || find(&e, b"spread-wings index <repo>") >= 0 {'
ANSWER = "    if !(code == 0 && !text.is_empty() && text[0] == b'{') {"
IN = "!d.is_empty() && (path == d || (path.len() > d.len() && starts_with(path, d) && path[d.len()] == b'/'))"

# (file in rust/src, what is broken, the text as it is, the text broken)
BREAKS = [
    # What git ignores.
    ('walk.rs', 'git is asked without --directory',
     '            argv.push(b"--directory");\n',
     ''),
    ('walk.rs', "git is asked without the repo's own ignore files",
     'b"--others", b"--ignored", b"--exclude-standard"];',
     'b"--others", b"--ignored", b"--exclude-from=/dev/null"];'),
    ('walk.rs', 'an ignored file is taken for a folder',
     "                    if !(entry.len() > 1 && entry[entry.len() - 1] == b'/') {\n                        continue;\n                    }",
     '                    if entry.len() < 2 {\n                        continue;\n                    }'),
    ('walk.rs', 'a hidden ignored folder is listed as one a walk would reach', WALKED,
     "let walked = !dir.split(|&c| c == b'/').any(|seg| seg.is_empty() || SKIP_DIRS.contains(&seg));"),
    ('walk.rs', 'an ignored node_modules is listed as one a walk would reach', WALKED,
     "let walked = !dir.split(|&c| c == b'/').any(|seg| seg.is_empty() || seg[0] == b'.');"),
    ('walk.rs', 'the list of every ignored folder is left empty',
     "                    all.extend_from_slice(dir);\n                    all.push(b'\\n');\n",
     ''),
    ('walk.rs', 'the folders git ignores are walked all the same',
     '        self.set(repo, &list);\n',
     ''),
    ('walk.rs', '"this folder" for several and "these folders" for one',
     'if n == 1 { b"this folder" } else { b"these folders" }',
     'if n != 1 { b"this folder" } else { b"these folders" }'),
    ('walk.rs', 'seven ignored folders are named, not six',
     '.filter(|d| !d.is_empty()).take(6) {',
     '.filter(|d| !d.is_empty()).take(7) {'),
    ('walk.rs', 'how many more folders there are is one too many',
     '                push_int(said, n as i64 - 6);',
     '                push_int(said, n as i64 - 5);'),
    ('walk.rs', 'no "and N more"',
     '            if n > 6 {\n                said.extend_from_slice(b" and ");',
     '            if n > 600 {\n                said.extend_from_slice(b" and ");'),
    ('walk.rs', '.git as a file is no repository',
     '        if sys::is_dir(&[repo, b"/.git"].concat()) || sys::file_exists(&[repo, b"/.git"].concat()) {',
     '        if sys::is_dir(&[repo, b"/.git"].concat()) {'),
    # Which languages a repo holds.
    ('pipeline.rs', 'TypeScript is not seen', '            l.ts = true;', '            l.ts = false;'),
    ('pipeline.rs', 'JavaScript is not seen', '            l.js = true;', '            l.js = false;'),
    ('pipeline.rs', 'Python is not seen', '            l.py = true;', '            l.py = false;'),
    ('pipeline.rs', 'Rust files are not seen', '            l.rs = true;', '            l.rs = false;'),
    ('pipeline.rs', 'Java is not seen', '            l.java = true;', '            l.java = false;'),
    ('pipeline.rs', 'Kotlin is not seen', '            l.kt = true;', '            l.kt = false;'),
    ('pipeline.rs', 'CUDA is not seen', '            l.cuda = true;', '            l.cuda = false;'),
    ('pipeline.rs', 'C is not seen', '            l.c = true;', '            l.c = false;'),
    ('pipeline.rs', 'the syntax-level languages are not seen', '            l.syn = true;', '            l.syn = false;'),
    ('pipeline.rs', 'a Cargo.toml with no Rust file beside it is not Rust',
     '        (l.rs || l.cargo, b" rust"),',
     '        (l.rs, b" rust"),'),
    ('pipeline.rs', 'a script with no ending in scripts/ is not seen',
     '    find(name, b".") < 0 && (find(full, b"/bin/") >= 0 || find(full, b"/scripts/") >= 0)',
     '    find(name, b".") < 0 && find(full, b"/bin/") >= 0'),
    ('pipeline.rs', 'any file in scripts/ is a script',
     '    find(name, b".") < 0 && (find(full, b"/bin/") >= 0 || find(full, b"/scripts/") >= 0)',
     '    find(full, b"/bin/") >= 0 || find(full, b"/scripts/") >= 0'),
    ('pipeline.rs', 'Go is not named once Goose is',
     '            if find(&[b" ", &l.other[..], b" "].concat(), b" go ") < 0 {',
     '            if find(&l.other, b"go") < 0 {'),
    ('pipeline.rs', 'Goose is named for each of its files',
     '            if find(&l.other, b"goose") < 0 {',
     '            if true || find(&l.other, b"goose") < 0 {'),
    ('pipeline.rs', 'another language is named for each of its files',
     '            if !lang.is_empty() && !indexed && find(&l.other, lang) < 0 {',
     '            if !lang.is_empty() && !indexed {'),
    ('pipeline.rs', 'a language with an indexer is named among the others',
     '            if !lang.is_empty() && !indexed && find(&l.other, lang) < 0 {',
     '            if !lang.is_empty() && find(&l.other, lang) < 0 {'),
    ('pipeline.rs', 'Java and C are said the other way round', SAID + '        (l.ts, b" typescript"),\n        (l.js, b" javascript"),\n        (l.java, b" java"),\n        (l.c, b" c/c++"),',
     SAID + '        (l.ts, b" typescript"),\n        (l.js, b" javascript"),\n        (l.c, b" c/c++"),\n        (l.java, b" java"),'),
    # A virtualenv, and trust.
    ('pipeline.rs', 'venv is looked for before .venv',
     '    for v in [&b".venv"[..], b"venv"] {',
     '    for v in [&b"venv"[..], b".venv"] {'),
    ('pipeline.rs', 'a virtualenv is named for a repo that is not trusted',
     '    if !trusted {\n        l.venv.clear();\n    }',
     '    let _ = trusted;'),
    ('pipeline.rs', 'any SWAN_TRUST_BUILD trusts',
     '    if sys::env(b"SWAN_TRUST_BUILD") == b"1" {',
     '    if !sys::env(b"SWAN_TRUST_BUILD").is_empty() {'),
    ('pipeline.rs', "Swan's own list of trusted repos is not read",
     '    contains_line(&saved, repo)\n}',
     '    let _ = (saved, repo);\n    false\n}'),
    ('pipeline.rs', 'a repo is trusted when a longer name is listed',
     '    contains_line(&saved, repo)\n}',
     '    saved.windows(repo.len()).any(|w| w == repo)\n}'),
    # The report's first lines.
    ('pipeline.rs', 'what git ignores is not said',
     '    report.extend_from_slice(&ignored_said);\n',
     ''),
    ('pipeline.rs', 'a survey that failed is not said',
     '    if !survey.is_empty() {\n        survey_report(&survey, &survey_skip, report);',
     '    if true || !survey.is_empty() {\n        survey_report(&survey, &survey_skip, report);'),
    ('pipeline.rs', 'other words for a survey that failed',
     'b"projects: not surveyed ("',
     'b"projects: no survey ("'),
    # An older map, a clean one.
    ('pipeline.rs', "a clean map does not check the repo it was made of",
     '    if clean && sys::file_exists(&old_db) {',
     '    if false && clean && sys::file_exists(&old_db) {'),
    ('pipeline.rs', "a clean map reads the map's version for its repo",
     "SELECT value FROM meta WHERE key = 'root'",
     "SELECT value FROM meta WHERE key = 'schema_version'"),
    ('pipeline.rs', 'other words for a map that names no repo',
     '&b"(unreadable)"[..]',
     '&b"(none)"[..]'),
    ('pipeline.rs', 'an older map is not seen as one',
     '    if !clean && sys::file_exists(&old_db) {',
     '    if false && !clean && sys::file_exists(&old_db) {'),
    ('pipeline.rs', 'other words for a map with no version',
     '&b"?"[..]',
     '&b"none"[..]'),
    ('pipeline.rs', "an older map's Python files list is kept", OLDER,
     OLDER.replace('b"/python-files.tsv"', 'b"/python-pieces.tsv"')),
    ('pipeline.rs', "an older map's Python pieces are kept", OLDER,
     OLDER.replace('b"/python-pieces.tsv", ', 'b"/python-files.tsv", ')),
    ('pipeline.rs', "a clean map keeps the Python pieces",
     '            b"python-files.tsv",\n            b"python-pieces.tsv",\n        ] {',
     '            b"python-files.tsv",\n            b"python-files.tsv",\n        ] {'),
    ('pipeline.rs', 'a clean map does not say it is one',
     '        report.extend_from_slice(b"clean rebuild: cached indexer output',
     '        let _ = (b"clean rebuild: cached indexer output'),
    ('pipeline.rs', 'no mark of when the map began',
     '    sys::write_file(&[out, b"/scip-started"].concat(), b"");\n',
     ''),
    ('pipeline.rs', 'the map folder is made without -p',
     '    run_step(b"mkdir", &[b"mkdir", b"-p", out_arg], b"", &[], 10000, &mut ignored);',
     '    run_step(b"mkdir", &[b"mkdir", out_arg], b"", &[], 10000, &mut ignored);'),
    ('main.rs', '--clean is not passed on',
     '        let ok = pipeline::map_main(&a[2], &a[3], &mut report, n == 5);',
     '        let ok = pipeline::map_main(&a[2], &a[3], &mut report, false);'),
    ('main.rs', 'another exit code when a map is refused',
     '        let ok = pipeline::map_main(&a[2], &a[3], &mut report, n == 5);\n        print(&report);\n        if !ok {\n            exit(1);',
     '        let ok = pipeline::map_main(&a[2], &a[3], &mut report, n == 5);\n        print(&report);\n        if !ok {\n            exit(3);'),
    # The survey.
    ('survey.rs', 'spread-wings is asked another word',
     '&[&bin, b"survey", repo]',
     '&[&bin, b"surveys", repo]'),
    ('survey.rs', 'an answer that is no JSON object is kept', ANSWER,
     '    if !(code == 0 && !text.is_empty()) {'),
    ('survey.rs', 'an answer from a survey that failed is kept', ANSWER,
     "    if !(!text.is_empty() && text[0] == b'{') {"),
    ('survey.rs', 'usage on standard output is not seen as an older spread-wings', USAGE,
     '        if find(&e, b"spread-wings index <repo>") >= 0 {'),
    ('survey.rs', 'usage on standard error is not seen as an older spread-wings', USAGE,
     '        if find(&text, b"spread-wings index <repo>") >= 0 {'),
    ('survey.rs', 'the last 100 bytes of what went wrong, not 200',
     '            let tail = if e.len() > 200 { &e[e.len() - 200..] } else { &e[..] };',
     '            let tail = if e.len() > 100 { &e[e.len() - 100..] } else { &e[..] };'),
    ('survey.rs', 'what went wrong keeps its line end',
     '            why.extend_from_slice(trim(tail));',
     '            why.extend_from_slice(tail);'),
    ('survey.rs', 'the survey is not kept',
     '    sys::write_file(&[&dir[..], b"/survey.json"].concat(), &text);\n',
     ''),
    ('survey.rs', 'only the ignored folders a walk would reach count',
     'b"/git-ignored-all.txt"',
     'b"/git-ignored.txt"'),
    ('survey.rs', 'a project whose folder only starts as an ignored one is left out', IN,
     "!d.is_empty() && (path == d || (path.len() > d.len() && starts_with(path, d)))"),
    ('survey.rs', 'a project that is an ignored folder itself is counted', IN,
     "!d.is_empty() && (path.len() > d.len() && starts_with(path, d) && path[d.len()] == b'/')"),
    ('survey.rs', 'the kinds are said in another order', KINDS,
     '    for kind in [&b"node"[..], b"rust", b"python", b"go", b"java", b"deno"] {'),
    ('survey.rs', 'a package manager is named once by the start of its name',
     '                        if !m.is_empty() && find(&[&managers[..], b" "].concat(), &[b" ", m, b" "].concat()) < 0 {',
     '                        if !m.is_empty() && find(&managers, m) < 0 {'),
    ('survey.rs', 'a package manager with no name is named',
     '                        if !m.is_empty() && find(&[&managers[..], b" "].concat(), &[b" ", m, b" "].concat()) < 0 {',
     '                        if find(&[&managers[..], b" "].concat(), &[b" ", m, b" "].concat()) < 0 {'),
    ('survey.rs', 'no projects is still said',
     '    if total == 0 {\n        return;\n    }',
     '    let _ = total;'),
    ('survey.rs', 'a node project that does not say is counted as not installed',
     ') == Some(false) {',
     ') != Some(true) {'),
    ('survey.rs', 'node projects are said to lack packages when none does',
     '    if bare > 0 {',
     '    if bare >= 0 && node > 0 {'),
    # Where spread-wings is.
    ('wings.rs', 'a SWAN_SPREAD_WINGS that is not there is used',
     '        if sys::file_exists(&v) {\n            return v;\n        }',
     '        if !v.is_empty() {\n            return v;\n        }'),
    ('wings.rs', 'an empty SWAN_SPREAD_WINGS is taken as set',
     '    if !v.is_empty() {\n        if sys::file_exists(&v) {',
     '    if std::env::var_os("SWAN_SPREAD_WINGS").is_some() {\n        if sys::file_exists(&v) {'),
    ('wings.rs', "spread-wings is looked for under another name in Swan's own bin",
     'b"/bin/spread-wings"',
     'b"/bin/spreadwings"'),
    # The seal.
    ('seal.rs', 'always sealed',
     '    sys::env(b"SWAN_SANDBOX") != b"0"',
     '    sys::env(b"SWAN_SANDBOX") != b"no"'),
    ('seal.rs', 'sealed only when asked',
     '    sys::env(b"SWAN_SANDBOX") != b"0"',
     '    sys::env(b"SWAN_SANDBOX") == b"1"'),
    ('seal.rs', 'the seal is looked for under another name',
     'b"/bin/eggshell"',
     'b"/bin/egg-shell"'),
    ('seal.rs', 'the seal is told the map folder is the repo',
     'vec![[&home[..], b"/bin/eggshell"].concat(), repo.to_vec(), out.to_vec()];',
     'vec![[&home[..], b"/bin/eggshell"].concat(), out.to_vec(), repo.to_vec()];'),
]

JUDGE = "port-map.sh"


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
