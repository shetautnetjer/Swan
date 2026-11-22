// The map: what `swan map` runs, in what order, and what it keeps.
//
// Carried over from src/pipeline.goose so far: `swan trust`, and `swan map`
// to the end of Python (what git ignores, what the repo holds, its survey,
// an older or a clean map, the content stamps, TypeScript's chunks and
// layers, Python's pieces), planned and not run. The walk at the head of
// that file is in walk.rs. A map stops where the carrying has got to, with
// what it would have said so far and exit 70.

use std::collections::{HashMap, HashSet};

use crate::change::{code_hash, cosmetic_lang, index_lines, line_of_path};
use crate::db::Db;
use crate::gsort::goose_sort;
use crate::index::SCHEMA_VERSION;
use crate::pypatch::{ensure_scip_python_patch, ensure_scip_python_site_patch, pypatch_count};
use crate::pyplan::{piece_target, plan_python};
use crate::query::meta_value;
use crate::run::{run_step, swan_home};
use crate::seal::{sealed_run, sealed_step};
use crate::stamp::prestamp;
use crate::survey::{survey_ignored, survey_python_envs, survey_report, survey_run};
use crate::sys;
use crate::treesitter;
use crate::tspatch::ensure_scip_typescript_patch;
use crate::tsproj::ts_other_projects;
use crate::util::{contains_line, die, ends_with, find, hash, hash_combine, json_string, parse_int, print, push_int, rfind, split, starts_with, trim, Dict};
use crate::walk::Walk;

// What a repo holds, found by walking it.
#[derive(Default)]
struct Langs {
    ts: bool,
    js: bool,
    py: bool,
    rs: bool,
    java: bool,
    c: bool,
    cuda: bool,
    kt: bool,       // Kotlin: tree-sitter only for now, no SCIP indexer runs
    syn: bool,      // Go, shell, Make, Ruby or Lua: `swan syntax-index` maps them
    other: Vec<u8>, // languages with no indexer here, only search and live errors: "lua glsl ..."
    tsconfig: bool,
    cargo: bool,
    venv: Vec<u8>, // a virtualenv inside the repo, if any
}

// Files `swan syntax-index` (src/syntax.rs) covers: Go, shell, Make, Ruby and Lua by name,
// and scripts with no extension in a bin/ or scripts/ folder (it reads their
// #! line itself).
fn syntax_file(full: &[u8], name: &[u8]) -> bool {
    for e in [&b".go"[..], b".sh", b".bash", b".zsh", b".ksh", b".rb", b".lua", b".mk"] {
        if ends_with(name, e) {
            return true;
        }
    }
    if name == b"Makefile" || name == b"makefile" || name == b"GNUmakefile" || name == b"Rakefile" {
        return true;
    }
    find(name, b".") < 0 && (find(full, b"/bin/") >= 0 || find(full, b"/scripts/") >= 0)
}

fn is_c_source(name: &[u8]) -> bool {
    ends_with(name, b".c") || ends_with(name, b".cc") || ends_with(name, b".cpp") || ends_with(name, b".cxx")
}

// One more name in `other`, which holds at most 255 bytes.
fn other_add(other: &mut Vec<u8>, lang: &[u8], room: usize) {
    if other.len() + room < 256 {
        if !other.is_empty() {
            other.push(b' ');
        }
        other.extend_from_slice(lang);
    }
}

fn detect(walk: &Walk, repo: &[u8]) -> Langs {
    let mut l = Langs {
        tsconfig: sys::file_exists(&[repo, b"/tsconfig.json"].concat()),
        cargo: sys::file_exists(&[repo, b"/Cargo.toml"].concat()),
        ..Default::default()
    };
    for v in [&b".venv"[..], b"venv"] {
        if l.venv.is_empty() && sys::file_exists(&[repo, b"/", v, b"/pyvenv.cfg"].concat()) {
            l.venv = [repo, b"/", v].concat();
        }
    }
    walk.each_file(repo, |full, name| {
        if syntax_file(full, name) {
            l.syn = true;
        }
        if ends_with(name, b".ts") || ends_with(name, b".tsx") || ends_with(name, b".mts") || ends_with(name, b".cts") {
            l.ts = true;
        } else if ends_with(name, b".js") || ends_with(name, b".jsx") || ends_with(name, b".mjs") || ends_with(name, b".cjs") {
            l.js = true;
        } else if ends_with(name, b".py") {
            l.py = true;
        } else if ends_with(name, b".rs") {
            l.rs = true;
        } else if ends_with(name, b".java") {
            l.java = true;
        } else if ends_with(name, b".kt") || ends_with(name, b".kts") {
            l.kt = true;
        } else if ends_with(name, b".cu") || ends_with(name, b".cuh") {
            l.cuda = true;
        } else if is_c_source(name) || ends_with(name, b".h") || ends_with(name, b".hpp") || ends_with(name, b".hh") {
            l.c = true;
        } else if ends_with(name, b".go") {
            // Mapped through gopls when it is installed (tools/modules.json
            // "map": "lsp"); by syntax otherwise (syntax_file above).
            if find(&[b" ", &l.other[..], b" "].concat(), b" go ") < 0 {
                other_add(&mut l.other, b"go", 3);
            }
        } else if ends_with(name, b".goose") {
            // No grammar and no SCIP indexer: mapped through its language
            // server (tools/modules.json "map": "lsp").
            if find(&l.other, b"goose") < 0 {
                other_add(&mut l.other, b"goose", 6);
            }
        } else {
            // Any other language with a grammar here (Lua, the shaders,
            // GDScript, C#, PHP): no SCIP indexer runs for these (yet); they
            // are searched by structure and checked by their language servers.
            let lang = treesitter::language_of_path(name);
            let indexed = [&b"typescript"[..], b"tsx", b"javascript", b"python", b"rust", b"java", b"kotlin", b"c", b"cpp", b"cuda"].contains(&lang);
            if !lang.is_empty() && !indexed && find(&l.other, lang) < 0 {
                other_add(&mut l.other, lang, lang.len() + 1);
            }
        }
    });
    l
}

// A JDK for the indexers: $JAVA_HOME, else the one Swan fetched.
fn java_home(home: &[u8]) -> Vec<u8> {
    let jh = sys::env(b"JAVA_HOME");
    if !jh.is_empty() {
        return jh;
    }
    let dir = [home, b"/.tools/jdk"].concat();
    if let Some(names) = sys::list_dir(&dir) {
        for name in names {
            if starts_with(&name, b"jdk-") {
                return [&dir[..], b"/", &name[..]].concat();
            }
        }
    }
    Vec::new()
}

fn has_clang(path: &[u8]) -> bool {
    path.split(|&c| c == b':').any(|d| sys::file_exists(&[d, b"/clang++"].concat()))
}

// The environment children get: a repo virtualenv first on PATH, and room
// for scip-python and pyright on big repos.
fn child_env(l: &Langs, extra: &[&[u8]], first: &[u8]) -> Vec<Vec<u8>> {
    let home = swan_home();
    let mut vars: Vec<Vec<u8>> = Vec::new();
    let mut path: Vec<u8> = Vec::new();
    if !first.is_empty() {
        path.extend_from_slice(first);
        path.push(b':');
    }
    if !l.venv.is_empty() {
        path.extend_from_slice(&l.venv);
        path.extend_from_slice(b"/bin:");
    }
    // Package-local Node/Bun, when installed. Trust-gated virtualenvs retain
    // their existing precedence; the runtime directory belongs to Swan.
    path.extend_from_slice(&home);
    path.extend_from_slice(b"/.tools/runtime/bin:");
    let mut jh: Vec<u8> = Vec::new();
    if l.java || l.kt {
        jh = java_home(&home);
        if !jh.is_empty() {
            path.extend_from_slice(&jh);
            path.extend_from_slice(b"/bin:");
        }
    }
    let p0 = sys::env(b"PATH");
    if (l.c || l.cuda) && !has_clang(&p0) {
        // scip-clang asks `clang++` only where clang's builtin headers are;
        // .tools/llvm has those headers and a stand-in that answers.
        path.extend_from_slice(&home);
        path.extend_from_slice(b"/.tools/llvm/bin:");
    }
    // scip-dotnet runs `dotnet restore` by name.
    if find(&l.other, b"csharp") >= 0 {
        path.extend_from_slice(&home);
        path.extend_from_slice(b"/.tools/dotnet:");
    }
    path.extend_from_slice(&p0);
    vars.push([&b"PATH="[..], &path].concat());
    if !l.venv.is_empty() {
        vars.push([&b"VIRTUAL_ENV="[..], &l.venv].concat());
    }
    if !jh.is_empty() {
        vars.push([&b"JAVA_HOME="[..], &jh].concat());
    }
    let heap = sys::env_set(b"SWAN_NODE_HEAP_MB").unwrap_or_else(|| b"16000".to_vec());
    vars.push([&b"NODE_OPTIONS=--max-old-space-size="[..], &heap].concat());
    for e in extra {
        vars.push(e.to_vec());
    }
    vars
}

// How many indexers run at once: $SWAN_JOBS, else half the cores, at most 8
// (scip-python can take several GB each).
fn jobs_limit() -> i64 {
    if let Some(n) = parse_int(&sys::env(b"SWAN_JOBS")) {
        if n > 0 {
            return n;
        }
    }
    // Half the cores, at most 8, and no more than the free memory holds at
    // about 3 GB a job (scip-python reached 10 GB on a big repo), so a big
    // map pushes the desktop into swap less.
    let mut by_mem: i64 = 8;
    let mut info: Vec<u8> = Vec::new();
    if sys::read_file(b"/proc/meminfo", &mut info) {
        for line in info.split(|&c| c == b'\n') {
            if starts_with(line, b"MemAvailable:") {
                let rest = trim(&line[13..]);
                // The kernel always writes "<n> kB"; a line without the
                // space stops the Goose program, and is passed over here.
                let space = find(rest, b" ");
                if space >= 0 {
                    if let Some(kb) = parse_int(trim(&rest[..space as usize])) {
                        by_mem = kb / (3 * 1024 * 1024);
                    }
                }
            }
        }
    }
    1.max(8.min(sys::cpu_count() / 2).min(by_mem))
}

// tsc's root files, from `tsc --showConfig`. --listFilesOnly lists every
// file in the program, the roots and all they import, wherever those are
// (rea's scripts/*.mts, outside its tsconfig's include); scip-typescript
// indexes only the roots, so a chunk of anything more would map files a
// whole run leaves out. Returns the listing's lines that are roots, or
// nothing when the config's file list cannot be read (TypeScript then runs
// whole, as before).
fn ts_root_listing(listing: &[u8], show: &[u8], cfg_dir: &[u8]) -> Vec<u8> {
    let mut kept: Vec<u8> = Vec::new();
    let at = find(show, b"\"files\": [");
    if at < 0 {
        return kept;
    }
    let mut all: Vec<u8> = Vec::new();
    let mut done = false;
    let mut bad = false;
    for (n, line) in show[at as usize..].split(|&c| c == b'\n').enumerate() {
        if done || bad {
            break;
        }
        if n == 0 {
            continue;
        }
        let mut t = trim(line);
        if starts_with(t, b"]") {
            done = true;
            continue;
        }
        if ends_with(t, b",") {
            t = &t[..t.len() - 1];
        }
        if t.len() < 3 || t[0] != b'"' || t[t.len() - 1] != b'"' || find(t, b"\\") >= 0 {
            bad = true;
            continue;
        }
        let rel = &t[1..t.len() - 1];
        let p = if rel[0] == b'/' {
            rel.to_vec()
        } else if starts_with(rel, b"./") {
            [cfg_dir, b"/", &rel[2..]].concat()
        } else {
            [cfg_dir, b"/", rel].concat()
        };
        all.extend_from_slice(&sys::realpath(&p).unwrap_or(p));
        all.push(b'\n');
    }
    if !(done && !bad && !all.is_empty()) {
        return kept;
    }
    // In the config's order, not the listing's (the order tsc reached
    // files): scip-typescript numbers anonymous types in the order it
    // meets them, so one chunk in another order names them differently
    // from a whole run.
    let mut given: Vec<&[u8]> = Vec::new();
    let mut listed: HashMap<Vec<u8>, usize> = HashMap::new();
    for raw in listing.split(|&c| c == b'\n') {
        let f = trim(raw);
        if f.is_empty() {
            continue;
        }
        // One real path listed twice is found under its later line.
        let real = sys::realpath(f).unwrap_or_else(|| f.to_vec());
        if !real.is_empty() {
            listed.insert(real, given.len());
        }
        given.push(f);
    }
    for r in all.split(|&c| c == b'\n') {
        if r.is_empty() {
            continue;
        }
        if let Some(&i) = listed.get(r) {
            kept.extend_from_slice(given[i]);
            kept.push(b'\n');
        }
    }
    kept
}

// One fingerprint for every file with these endings (and the named build
// files at the root): a whole-language index is reused while it is
// unchanged. `stamp` gives a file's content stamp.
fn lang_fingerprint(walk: &Walk, repo: &[u8], endings: &[&[u8]], roots: &[&[u8]], mut stamp: impl FnMut(&[u8]) -> u64) -> u64 {
    let mut h: u64 = 0;
    walk.each_file(repo, |full, name| {
        if endings.iter().any(|e| ends_with(name, e)) {
            h = hash_combine(h, hash_combine(hash(full), stamp(full)));
        }
    });
    for r in roots {
        let p = [repo, b"/", r].concat();
        if sys::file_exists(&p) {
            h = hash_combine(h, hash_combine(hash(&p), stamp(&p)));
        }
    }
    h
}

fn contains_line_prefix(lines: &[u8], p: &[u8]) -> bool {
    lines.split(|&c| c == b'\n').any(|l| starts_with(l, p))
}

fn count_lines(s: &[u8]) -> i64 {
    s.iter().filter(|&&c| c == b'\n').count() as i64
}

// What a map keeps to use again (tsc's lists, the chunks, the fingerprints).
// A clean map holds them back until its rows are published, so that one
// that fails or is stopped leaves nothing a later map would trust.
// Splits a TypeScript project into k chunks of similar size for parallel
// scip-typescript runs. The files are tsc's own roots (`tsc --listFilesOnly`
// kept to the `--showConfig` file list, so the project's include and
// exclude hold), less node_modules and declaration files, which every chunk
// gets. Packed largest first, each into the lightest chunk. Returns one
// line per chunk, files separated by tabs, and the declaration files as
// `decls`; nothing when one run will do. k may be 1: one chunk of every
// file, which lets a later edit be indexed as a layer over it.
fn plan_ts(repo: &[u8], listing: &[u8], k_asked: i64, decls: &mut Vec<u8>, refs: &mut Vec<u8>, always: bool) -> Vec<u8> {
    let mut files: Vec<u8> = Vec::new();
    let mut sizes: Vec<i64> = Vec::new();
    for raw in listing.split(|&c| c == b'\n') {
        let f = trim(raw);
        if f.len() > repo.len() && starts_with(f, repo) && f[repo.len()] == b'/' && find(f, b"/node_modules/") < 0 {
            if ends_with(f, b".d.ts") {
                decls.extend_from_slice(f);
                decls.push(b'\n');
            } else {
                files.extend_from_slice(f);
                files.push(b'\n');
                sizes.push(sys::file_size(f).max(1));
                // A file with `/// <reference types=...>` brings ambient types
                // (bun-types' "bun:test", say) to whatever is compiled with it,
                // so every chunk gets it, as it gets the .d.ts files.
                let mut head: Vec<u8> = Vec::new();
                if sys::read_file(f, &mut head) && find(&head[..head.len().min(4096)], b"/// <reference") >= 0 {
                    refs.extend_from_slice(f);
                    refs.push(b'\n');
                }
            }
        }
    }
    let mut plan: Vec<u8> = Vec::new();
    // `always`: a plan however few the files (one project of several, which
    // cannot be left to a whole run under another project's config).
    let count = sizes.len() as i64;
    let k = if always { k_asked.min(count / 4).max(1) } else { k_asked };
    if !(count > 0 && k >= 1 && (always || count >= 4 * k)) {
        return plan;
    }
    let k = k as usize;
    let paths = split(&files[..files.len() - 1], b'\n');
    // Largest first, files of one size in the order Goose's sort leaves them.
    let mut order: Vec<usize> = (0..sizes.len()).collect();
    goose_sort(&mut order, &|a, b| sizes[a] > sizes[b]);
    let mut load: Vec<i64> = vec![0; k];
    let mut owner: Vec<usize> = vec![0; paths.len()];
    for &u in &order {
        let mut best = 0;
        for c in 0..k {
            if load[c] < load[best] {
                best = c;
            }
        }
        load[best] += sizes[u];
        owner[u] = best;
    }
    for c in 0..k {
        let mut first = true;
        for u in 0..paths.len() {
            if owner[u] == c {
                if !first {
                    plan.push(b'\t');
                }
                plan.extend_from_slice(paths[u]);
                first = false;
            }
        }
        if !first {
            plan.push(b'\n');
        }
    }
    plan
}

// Whether two chunk plans (lines of tab-separated files) hold the same files.
fn same_file_set(a: &[u8], b: &[u8]) -> bool {
    let files = |plan: &'_ [u8]| -> Vec<Vec<u8>> {
        let mut found: Vec<Vec<u8>> = Vec::new();
        for l in plan.split(|&c| c == b'\n') {
            for f in l.split(|&c| c == b'\t') {
                if !f.is_empty() {
                    found.push(f.to_vec());
                }
            }
        }
        // Bytes in order, as Goose's compare: equal names are the same name,
        // so any sort gives this order.
        found.sort();
        found
    };
    files(a) == files(b)
}

// Files to treat as changed: those whose stamp changed, and, from the last
// map, the files that use a symbol defined in one of those. A piece holding
// any of them is indexed again. One line per file.
fn dependents_of_changes(out: &[u8], stamps: &[u8], prev: &[u8]) -> Vec<u8> {
    let mut dirty: Vec<u8> = Vec::new();
    if prev.is_empty() {
        return dirty;
    }
    // The last map's line for each path, and the paths in the order a Goose
    // dictionary gives them back (the files gone since then are added in it).
    let mut before: HashMap<&[u8], &[u8]> = HashMap::new();
    let mut before_order: Dict<bool> = Dict::new();
    for line in prev.split(|&c| c == b'\n') {
        let tab = find(line, b"\t");
        if tab > 0 {
            before.insert(&line[..tab as usize], line);
            before_order.entry(&line[..tab as usize], true);
        }
    }
    let mut changed: Vec<u8> = Vec::new();
    let mut seen: HashSet<&[u8]> = HashSet::new();
    for line in stamps.split(|&c| c == b'\n') {
        let tab = find(line, b"\t");
        if tab > 0 {
            let path = &line[..tab as usize];
            seen.insert(path);
            if before.get(path) != Some(&line) {
                changed.extend_from_slice(path);
                changed.push(b'\n');
            }
        }
    }
    for (path, _) in before_order.each() {
        if !seen.contains(path) {
            changed.extend_from_slice(path);
            changed.push(b'\n');
        }
    }
    dirty.extend_from_slice(&changed);
    let db_path = [out, b"/swan.db"].concat();
    if !(!changed.is_empty() && sys::file_exists(&db_path)) {
        return dirty;
    }
    let db = match Db::open_existing(&db_path) {
        Ok(db) => db,
        Err(e) => die(&[b"swan: cannot read dependency map: ", &e[..]].concat()),
    };
    // The text as Goose's literal holds it, with no line end after its last
    // line: it is part of what is said when it cannot be prepared.
    let st = db.prepare_or_die(
        b"SELECT DISTINCT o.file FROM occurrences o JOIN symbols s ON s.id = o.symbol_id
WHERE s.def_file = ?1 AND o.file != ?1 AND o.is_def = 0",
    );
    for f in changed.split(|&c| c == b'\n') {
        if f.is_empty() {
            continue;
        }
        st.bind_text(1, f);
        while st.step_checked() {
            dirty.extend_from_slice(&st.col_text(0));
            dirty.push(b'\n');
        }
        st.reset();
    }
    dirty
}

fn python_of(l: &Langs) -> Vec<u8> {
    if !l.venv.is_empty() {
        [&l.venv[..], b"/bin/python"].concat()
    } else {
        b"python3".to_vec()
    }
}

// The repo's src folder when it holds Python packages or modules (the "src
// layout"), as a PYTHONPATH value; empty otherwise.
fn python_src_roots(repo: &[u8]) -> Vec<u8> {
    let src = [repo, b"/src"].concat();
    let mut found = false;
    if let Some(names) = sys::list_dir(&src) {
        for nm in names {
            if !nm.is_empty() && (ends_with(&nm, b".py") || sys::file_exists(&[&src[..], b"/", &nm[..], b"/__init__.py"].concat())) {
                found = true;
            }
        }
    }
    if found {
        src
    } else {
        Vec::new()
    }
}

// scip-python asks pip which packages are installed, to name outside symbols
// by package and version. Without pip the same list comes from Python's own
// importlib.metadata, written where --environment can read it.
#[rustfmt::skip]
const PY_ENV_SNIPPET: &[u8] = b"import json, importlib.metadata as m\nseen = set()\nout = []\nfor d in m.distributions():\n    n = d.metadata['Name']\n    if not n or n.lower() in seen: continue\n    seen.add(n.lower())\n    out.append({'name': n, 'version': d.version, 'files': [str(f) for f in (d.files or []) if str(f).endswith(('.py', '.pyi'))]})\nprint(json.dumps(out))\n";

// The same list for virtualenvs that are read and not run: each argument is
// a site-packages folder, and importlib.metadata reads the *.dist-info
// folders there (METADATA and RECORD). No package is imported.
#[rustfmt::skip]
const PY_VENV_SNIPPET: &[u8] = b"import json, sys, importlib.metadata as m\nseen = set()\nout = []\nfor d in m.distributions(path=sys.argv[1:]):\n    n = d.metadata['Name']\n    if not n or n.lower() in seen: continue\n    seen.add(n.lower())\n    out.append({'name': n, 'version': d.version, 'files': [str(f) for f in (d.files or []) if str(f).endswith(('.py', '.pyi'))]})\nprint(json.dumps(out))\n";

// A stand-in for the Python interpreter, first on PATH for scip-python when
// a project's own virtualenv is used. scip-python's pyright asks `python3
// -c <script>` two things: where packages are (sys.path) and which Python
// this is (sys.version_info). The virtualenv's own interpreter is the
// repo's to run, not Swan's, and inside the seal it is usually not even
// there (bin/python is a link out of the repo). The stand-in runs the
// script in the machine's python3 with those two answers set from the
// virtualenv: $SWAN_PY_SITE, its site-packages folders, and
// $SWAN_PY_VERSION, the Python its pyvenv.cfg names. So the packages the
// project installed are found and nothing in the virtualenv is run.
// $PYTHONPATH is passed on as python3 itself would (Swan sets it for src
// layouts). scip-python 0.6.8 asks only the first question; the version
// reaches it through Swan's fix in src/pypatch.rs. The texts are the Goose
// program's, its file's name included.
#[rustfmt::skip]
const PY_STANDIN_SH: &[u8] = b"#!/bin/sh\n# Swan's stand-in for python3 (src/pipeline.goose): the next python3 on PATH runs standin.py.\n# PATH goes on without this folder: a version manager's shim looks python3 up again.\nself=${SWAN_PY_STANDIN:-$(dirname \"$0\")}\nrest=\nIFS=:\nfor d in $PATH; do\n    [ \"$d\" = \"$self\" ] || rest=${rest:+$rest:}$d\ndone\nPATH=$rest\nexec python3 -I \"$self/standin.py\" \"$@\"\n";
#[rustfmt::skip]
const PY_STANDIN_PY: &[u8] = b"# Swan's stand-in for the Python interpreter (src/pipeline.goose).\n# Runs the script it is given with sys.path and sys.version_info set from a\n# virtualenv that is read and not run. Answers nothing but `-c <script>`.\nimport os, sys\nargs = sys.argv[1:]\nwhile args and args[0].startswith('-') and args[0] not in ('-c', '-m'):\n    args.pop(0)\nif len(args) < 2 or args[0] != '-c':\n    sys.exit(2)\nfolders = lambda name: [p for p in os.environ.get(name, '').split(os.pathsep) if p]\nown = [p for p in sys.path if p and 'site-packages' not in p and 'dist-packages' not in p]\nsys.path[:] = folders('PYTHONPATH') + own + folders('SWAN_PY_SITE')\nn = [int(x) for x in os.environ.get('SWAN_PY_VERSION', '').split('.')[:3] if x.isdigit()]\nif len(n) >= 2:\n    sys.version_info = (n[0], n[1], n[2] if len(n) > 2 else 0, 'final', 0)\nsys.argv = ['-c'] + args[2:]\nexec(compile(args[1], '<string>', 'exec'), {'__name__': '__main__'})\n";

// Writes text to path, unless the file already holds it.
fn write_unless_same(path: &[u8], text: &[u8]) {
    let mut have: Vec<u8> = Vec::new();
    if !sys::read_file(path, &mut have) || have != text {
        sys::write_file(path, text);
    }
}

// Writes the stand-in into <out>/py-standin (python3, python, standin.py)
// and returns that folder, or "" when it could not be made runnable.
fn py_standin_dir(out: &[u8]) -> Vec<u8> {
    let d = [out, b"/py-standin"].concat();
    sys::make_dir(&d);
    let python3 = [&d[..], b"/python3"].concat();
    let python = [&d[..], b"/python"].concat();
    write_unless_same(&python3, PY_STANDIN_SH);
    write_unless_same(&python, PY_STANDIN_SH);
    write_unless_same(&[&d[..], b"/standin.py"].concat(), PY_STANDIN_PY);
    let mut o: Vec<u8> = Vec::new();
    let mut e: Vec<u8> = Vec::new();
    if sys::run(&[b"chmod", b"755", &python3, &python], &d, &[], 10000, &mut o, &mut e) == 0 {
        d
    } else {
        Vec::new()
    }
}

// The Python a virtualenv was made with, as its pyvenv.cfg says ("version"
// or "version_info"); "" when it says neither.
fn pyvenv_version(venv: &[u8]) -> Vec<u8> {
    let mut v: Vec<u8> = Vec::new();
    let mut cfg: Vec<u8> = Vec::new();
    if !sys::read_file(&[venv, b"/pyvenv.cfg"].concat(), &mut cfg) {
        return v;
    }
    for l in cfg.split(|&c| c == b'\n') {
        let eq = find(l, b"=");
        if v.is_empty() && eq > 0 {
            let key = trim(&l[..eq as usize]);
            if key == b"version" || key == b"version_info" {
                v.extend_from_slice(trim(&l[eq as usize + 1..]));
            }
        }
    }
    v
}

// The site-packages folders of a virtualenv (<venv>/lib/python*/site-packages),
// appended to dirs with ':' between.
fn py_site_dirs(venv: &[u8], dirs: &mut Vec<u8>) {
    let Some(names) = sys::list_dir(&[venv, b"/lib"].concat()) else {
        return;
    };
    for nm in names {
        let d = [venv, b"/lib/", &nm[..], b"/site-packages"].concat();
        if starts_with(&nm, b"python") && sys::is_dir(&d) {
            if !dirs.is_empty() {
                dirs.push(b':');
            }
            dirs.extend_from_slice(&d);
        }
    }
}

fn in_piece(path: &[u8], piece: &[u8]) -> bool {
    // A prefix piece ("dir/ab*") holds every path that starts with dir/ab.
    if !piece.is_empty() && piece[piece.len() - 1] == b'*' {
        return starts_with(path, &piece[..piece.len() - 1]);
    }
    piece.is_empty() || path == piece || (starts_with(path, piece) && path.len() > piece.len() && path[piece.len()] == b'/')
}

// A piece's fingerprint: the stamps of the files in it.
fn piece_fingerprint(stamps: &[u8], piece: &[u8]) -> u64 {
    let mut h: u64 = 0;
    for line in stamps.split(|&c| c == b'\n') {
        let tab = find(line, b"\t");
        if tab > 0 && in_piece(&line[..tab as usize], piece) {
            h = hash_combine(h, hash(line));
        }
    }
    h
}

fn piece_has(files: &[u8], piece: &[u8]) -> bool {
    files.split(|&c| c == b'\n').any(|f| !f.is_empty() && in_piece(f, piece))
}

/// One indexer run of a map, or an index kept from the last map (no label
/// and nothing to run).
#[allow(dead_code)] // read where the jobs are run, still to be carried
struct Job {
    label: Vec<u8>,
    target: Vec<u8>,
    argv: Vec<Vec<u8>>,
    env: Vec<Vec<u8>>,
    /// The folder the job's document paths are relative to, when that is not
    /// the repo (scip-python --target-only, a cargo project in a subfolder).
    base: Vec<u8>,
    /// A job the map can do without: when it fails the report says so and
    /// the map is still made (a fuzz crate that does not resolve).
    optional: bool,
}

/// The jobs of a map, and what says which of their indexes can be kept.
struct Jobs {
    list: Vec<Job>,
    /// index-manifest.tsv as the last map left it: "label \t fingerprint \t index file".
    prev_index: Vec<u8>,
    index_manifest: Vec<u8>,
    reused_all: bool,
}

impl Jobs {
    fn add(&mut self, label: &[u8], target: &[u8], argv: Vec<Vec<u8>>, env: Vec<Vec<u8>>, base: &[u8], optional: bool) {
        if !label.is_empty() {
            self.reused_all = false;
        }
        self.list.push(Job { label: label.to_vec(), target: target.to_vec(), argv, env, base: base.to_vec(), optional });
    }

    // A whole-language job, unless its files have the fingerprint they had
    // when its index was made. `force` runs it anyway, with the fingerprint
    // recorded as usual (a file whose indexed text is unknown).
    #[allow(clippy::too_many_arguments)]
    fn add_lang(&mut self, report: &mut Vec<u8>, label: &[u8], target: &[u8], argv: Vec<Vec<u8>>, env: Vec<Vec<u8>>, fp: u64, force: bool, base: &[u8], optional: bool) {
        let fps = fp.to_string();
        let mut hit = false;
        for line in self.prev_index.split(|&c| c == b'\n') {
            let f = split(line, b'\t');
            if f.len() == 3 && f[0] == label && f[1] == fps.as_bytes() && f[2] == target && sys::file_exists(target) {
                hit = true;
            }
        }
        self.index_manifest.extend_from_slice(&[label, b"\t", fps.as_bytes(), b"\t", target, b"\n"].concat());
        if hit && !force {
            report.extend_from_slice(&[label, b": reused (no changes)\n"].concat());
            self.add(b"", target, Vec::new(), Vec::new(), base, false);
        } else {
            self.add(label, target, argv, env, base, optional);
        }
    }
}

/// TypeScript's chunks, planned inside each project: no chunk holds files
/// of two configs.
struct TsPlan {
    decls: Vec<u8>,
    /// "config \t file": each project's declaration files,
    decl_of: Vec<u8>,
    /// and its files with a /// <reference>.
    ref_of: Vec<u8>,
    /// The configs that own files, the root's first.
    bases: Vec<u8>,
    /// Which of them a file of another's is under, as its place in `bases`.
    owner_at: HashMap<u64, i64>,
    chunks: Vec<u8>,
}

impl TsPlan {
    // One project's chunks: its share of the `plan_k` slots, by its part of
    // the `ts_total` files, when there are several projects.
    fn project(&mut self, repo: &[u8], cfg: &[u8], files: &[u8], plan_k: i64, ts_total: i64, ts_projects: bool) {
        if files.is_empty() {
            return;
        }
        let mut gd: Vec<u8> = Vec::new();
        let mut gr: Vec<u8> = Vec::new();
        let n = count_lines(files);
        let plan = plan_ts(repo, files, if ts_projects { plan_k * n / ts_total.max(1) } else { plan_k }, &mut gd, &mut gr, ts_projects);
        let at = count_lines(&self.bases);
        self.bases.extend_from_slice(cfg);
        self.bases.push(b'\n');
        if at > 0 {
            for f in files.split(|&c| c == b'\n') {
                if !f.is_empty() {
                    self.owner_at.insert(hash(f), at);
                }
            }
        }
        self.chunks.extend_from_slice(&plan);
        self.decls.extend_from_slice(&gd);
        for f in gd.split(|&c| c == b'\n') {
            if !f.is_empty() {
                self.decl_of.extend_from_slice(&[cfg, b"\t", f, b"\n"].concat());
            }
        }
        for f in gr.split(|&c| c == b'\n') {
            if !f.is_empty() {
                self.ref_of.extend_from_slice(&[cfg, b"\t", f, b"\n"].concat());
            }
        }
    }

    // Which config a file is under, as its place in `bases`.
    fn owner_index(&self, f: &[u8]) -> i64 {
        self.owner_at.get(&hash(f)).copied().unwrap_or(0)
    }
}

struct Cache {
    clean: bool,
    out: Vec<u8>,
    #[allow(dead_code)] // written out where a clean map publishes, still to be carried
    pending: Vec<(Vec<u8>, Vec<u8>)>,
}

impl Cache {
    fn write(&mut self, name: &[u8], contents: &[u8]) {
        if self.clean {
            self.pending.push((name.to_vec(), contents.to_vec()));
        } else {
            sys::write_file(&[&self.out[..], b"/", name].concat(), contents);
        }
    }
}

// Some indexers and checkers run the repo's own build files: cargo's build
// scripts and proc macros, Maven and Gradle, MSBuild through `dotnet
// restore`. A repo can run any code that way, so they wait until a person
// says the repo is trusted: `swan trust <repo>` adds the repo's
// path to Swan's own data/trusted-repos, which no repo can ship (a record
// inside the map folder could, when that folder sits in the checkout).
// SWAN_TRUST_BUILD=1 trusts every repo, for tests and CI. Nothing in the
// MCP server writes it.
fn trust_file() -> Vec<u8> {
    [&swan_home()[..], b"/data/trusted-repos"].concat()
}

fn build_trusted(repo: &[u8]) -> bool {
    if sys::env(b"SWAN_TRUST_BUILD") == b"1" {
        return true;
    }
    let mut saved: Vec<u8> = Vec::new();
    if !sys::read_file(&trust_file(), &mut saved) {
        return false;
    }
    contains_line(&saved, repo)
}

pub fn trust_main(repo_arg: &[u8], report: &mut Vec<u8>) -> bool {
    let repo = crate::abs_path(repo_arg);
    let tf = trust_file();
    let data = [&swan_home()[..], b"/data"].concat();
    let mut ignored: Vec<u8> = Vec::new();
    run_step(b"mkdir", &[b"mkdir", b"-p", &data], b"", &[], 10000, &mut ignored);
    let mut saved: Vec<u8> = Vec::new();
    sys::read_file(&tf, &mut saved);
    if !contains_line(&saved, &repo) {
        if !saved.is_empty() && saved[saved.len() - 1] != b'\n' {
            saved.push(b'\n');
        }
        saved.extend_from_slice(&repo);
        saved.push(b'\n');
        if !sys::write_file(&tf, &saved) {
            report.extend_from_slice(b"could not write ");
            report.extend_from_slice(&tf);
            return false;
        }
    }
    report.extend_from_slice(b"trusted ");
    report.extend_from_slice(&repo);
    report.extend_from_slice(b": swan map, swan check and live answers may now run its build files (Cargo, Maven, Gradle, MSBuild)");
    true
}

// Content stamps (src/change.rs): what a file holds, not when it was
// saved. content-stamps.tsv keeps one line per file stamped, "path\tsize\t
// mtime\tstamp\traw\tc|b" (c: stamped by its code alone, b: by its bytes),
// so a file whose size and mtime are what the last map saw is not read
// again. The text of each file stamped by its code is kept in texts/, by
// its raw hash, to move its rows after a cosmetic edit.
#[allow(dead_code)] // the lines and the times are read by the parts of the map still to be carried
struct Stamps {
    repo: Vec<u8>,
    texts_dir: Vec<u8>,
    prev: Vec<u8>, // content-stamps.tsv as the last map left it
    prev_at: HashMap<u64, usize>,
    lines: Vec<u8>,
    stamp_memo: HashMap<u64, u64>, // by the hash of the path
    raw_memo: HashMap<u64, u64>,
    mtime_memo: HashMap<u64, i64>,
    code_memo: HashSet<u64>, // the files stamped by their code
    // Stamps worked out ahead on several cores (prestamp), in the same
    // format as content-stamps.tsv and checked the same way.
    pre: Vec<u8>,
    pre_at: HashMap<u64, usize>,
}

impl Stamps {
    // What a stamp line says of a file, when its size and time are these.
    fn known(line: &[u8], size: i64, mt: i64) -> Option<(u64, u64, bool)> {
        if line.is_empty() {
            return None;
        }
        let f = split(line, b'\t');
        if f.len() == 6 && f[1] == size.to_string().as_bytes() && f[2] == mt.to_string().as_bytes() {
            if let (Some(a), Some(b)) = (parse_int(f[3]), parse_int(f[4])) {
                return Some((a as u64, b as u64, f[5] == b"c"));
            }
        }
        None
    }

    fn stamp(&mut self, full: &[u8]) -> u64 {
        let repo_len = self.repo.len();
        if !(full.len() > repo_len + 1 && starts_with(full, &self.repo) && full[repo_len] == b'/') {
            return hash(full);
        }
        let rel = &full[repo_len + 1..];
        let key = hash(rel);
        if let Some(&m) = self.stamp_memo.get(&key) {
            return m;
        }
        let size = sys::file_size(full);
        let mt = sys::mtime_ns(full);
        let mut found = Self::known(line_of_path(&self.prev, &self.prev_at, rel), size, mt);
        if found.is_none() && !self.pre.is_empty() {
            found = Self::known(line_of_path(&self.pre, &self.pre_at, rel), size, mt);
        }
        let (st, raw, by_code) = match found {
            Some(known) => known,
            None => {
                let mut text: Vec<u8> = Vec::new();
                sys::read_file(full, &mut text);
                let raw = hash(&text);
                let mut st = raw;
                let mut by_code = false;
                let lang = cosmetic_lang(rel);
                if !lang.is_empty() {
                    let (h, ok) = code_hash(lang, &text);
                    if ok {
                        st = h;
                        by_code = true;
                        let mut keep = [&self.texts_dir[..], b"/t"].concat();
                        push_int(&mut keep, raw as i64);
                        keep.extend_from_slice(b".txt");
                        if !sys::file_exists(&keep) {
                            sys::write_file(&keep, &text);
                        }
                    }
                }
                (st, raw, by_code)
            }
        };
        self.lines.extend_from_slice(rel);
        for v in [size, mt, st as i64, raw as i64] {
            self.lines.push(b'\t');
            push_int(&mut self.lines, v);
        }
        self.lines.extend_from_slice(if by_code { b"\tc\n" } else { b"\tb\n" });
        self.stamp_memo.insert(key, st);
        self.raw_memo.insert(key, raw);
        self.mtime_memo.insert(key, mt);
        if by_code {
            self.code_memo.insert(key);
        }
        st
    }

    fn raw_text_of(&self, key: u64) -> Vec<u8> {
        match self.raw_memo.get(&key) {
            Some(&r) => (r as i64).to_string().into_bytes(),
            None => Vec::new(),
        }
    }

    fn have_text(&self, raw: &[u8]) -> bool {
        !raw.is_empty() && raw != b"?" && sys::file_exists(&[&self.texts_dir[..], b"/t", raw, b".txt"].concat())
    }
}

pub fn map_main(repo_arg: &[u8], out_arg: &[u8], report: &mut Vec<u8>, clean: bool) -> bool {
    let repo = crate::abs_path(repo_arg);
    let mut ignored: Vec<u8> = Vec::new();
    run_step(b"mkdir", &[b"mkdir", b"-p", out_arg], b"", &[], 10000, &mut ignored);
    let out = crate::abs_path(out_arg);
    let writer = match sys::WriterLock::acquire(&[&out[..], b"/swan.db"].concat()) {
        Ok(w) => w,
        Err(e) => {
            report.extend_from_slice(&e);
            return false;
        }
    };
    let ok = map_main_locked(&repo, &out, report, clean);
    if ok {
        writer.complete();
    } else {
        writer.unlock();
    }
    ok
}

// The public wrapper holds the writer lock for every shared output: cached
// indexer files, flattened rows, schema replacement and final database update.
fn map_main_locked(repo: &[u8], out: &[u8], report: &mut Vec<u8>, clean: bool) -> bool {
    let home = swan_home();
    let bin = [&home[..], b"/tools/node_modules/.bin/"].concat();
    let trusted = build_trusted(repo);
    // Before any walk of the repo: the folders git ignores are left out.
    let mut walk = Walk::default();
    let mut ignored_said: Vec<u8> = Vec::new();
    walk.refresh(repo, out, trusted, &mut ignored_said);
    let mut l = detect(&walk, repo);
    // A virtualenv inside the repo is the repo's own code (its python, its pip, its PATH):
    // run it only once the repo is trusted, like any other build-running step.
    // Until then it is read and not run (the Python step below).
    let mut venv_read: Vec<u8> = Vec::new();
    if !trusted {
        venv_read = std::mem::take(&mut l.venv);
    }
    // The projects the repo holds (src/survey.rs): read by Spread-Wings,
    // nothing of the repo run.
    let mut survey_why: Vec<u8> = Vec::new();
    let survey = survey_run(repo, out, &mut survey_why);
    report.extend_from_slice(b"languages:");
    let said: [(bool, &[u8]); 9] = [
        (l.ts, b" typescript"),
        (l.js, b" javascript"),
        (l.java, b" java"),
        (l.c, b" c/c++"),
        (l.cuda, b" cuda"),
        (l.py, b" python"),
        (l.rs || l.cargo, b" rust"),
        (l.kt, b" kotlin"),
        (l.syn, b" go/shell/make/ruby/lua (syntax only)"),
    ];
    for (there, name) in said {
        if there {
            report.extend_from_slice(name);
        }
    }
    if !l.other.is_empty() {
        report.push(b' ');
        report.extend_from_slice(&l.other);
    }
    if !l.venv.is_empty() {
        report.extend_from_slice(&[b" (venv ", &l.venv[..], b")"].concat());
    }
    report.push(b'\n');
    report.extend_from_slice(&ignored_said);
    let survey_skip = survey_ignored(out);
    if !survey.is_empty() {
        survey_report(&survey, &survey_skip, report);
    } else {
        report.extend_from_slice(&[b"projects: not surveyed (", &survey_why[..], b"): the map assumes what it did before, one Go project at the top\n"].concat());
    }
    // A map from an older Swan is rebuilt from scratch, indexers included:
    // reusing their output would skip what the new schema needs.
    let old_db = [out, b"/swan.db"].concat();
    if clean && sys::file_exists(&old_db) {
        // Refuse a wrong or unverifiable target before invalidating anything.
        // A damaged map can instead be rebuilt in a new private directory.
        let h = match Db::open_existing(&old_db) {
            Ok(h) => h,
            Err(e) => {
                report.extend_from_slice(&[b"cannot verify clean map target: ", &e[..]].concat());
                return false;
            }
        };
        let mut recorded: Vec<u8> = Vec::new();
        if let Ok(st) = h.prepare(b"SELECT value FROM meta WHERE key = 'root'") {
            if st.step().unwrap_or(false) {
                recorded = st.col_text(0);
            }
        }
        drop(h);
        if recorded != repo {
            report.extend_from_slice(&[&b"clean rebuild requires the exact recorded repo root; requested "[..], repo, b", recorded ", if !recorded.is_empty() { &recorded[..] } else { &b"(unreadable)"[..] }].concat());
            return false;
        }
    }
    if !clean && sys::file_exists(&old_db) {
        let h = match Db::open_existing(&old_db) {
            Ok(h) => h,
            Err(e) => crate::util::die(&[b"swan: cannot inspect map schema: ", &e[..]].concat()),
        };
        let v = meta_value(&h, b"schema_version");
        drop(h);
        if v != SCHEMA_VERSION.to_string().as_bytes() {
            report.extend_from_slice(&[&b"map schema "[..], if !v.is_empty() { &v[..] } else { &b"?"[..] }, b" is older than "].concat());
            push_int(report, SCHEMA_VERSION);
            report.extend_from_slice(b": rebuilding\n");
            for f in [&b"/swan.db"[..], b"/index-manifest.tsv", b"/python-pieces.tsv", b"/python-files.tsv"] {
                sys::delete_file(&[out, f].concat());
            }
        }
    }
    // Invalidate reuse metadata under the same stable writer lock. Never remove
    // the database or its lock: readers keep their snapshot until atomic publish.
    // Defer replacement metadata until publication, so failure/interruption
    // cannot make a later ordinary map trust unfinished indexer output.
    let mut cache = Cache { clean, out: out.to_vec(), pending: Vec::new() };
    if clean {
        for name in [
            &b"index-manifest.tsv"[..],
            b"tsc-files.txt",
            b"tsc-program.txt",
            b"tsc-projects.txt",
            b"typescript-chunks.txt",
            b"typescript-shared.txt",
            b"typescript-files.tsv",
            b"typescript-layers.txt",
            b"python-files.tsv",
            b"python-pieces.tsv",
        ] {
            let path = [out, b"/", name].concat();
            if !(!sys::file_exists(&path) || sys::delete_file(&path)) {
                report.extend_from_slice(&[b"cannot invalidate clean rebuild cache: ", &path[..]].concat());
                return false;
            }
        }
        report.extend_from_slice(b"clean rebuild: cached indexer output and merge layers will not be reused; previous database retained until publication\n");
    }
    // Edits after this moment make answers stale (src/fresh.rs).
    sys::write_file(&[out, b"/scip-started"].concat(), b"");

    // The jobs. An index is kept while its fingerprint in the last map's
    // index-manifest.tsv is the one worked out now.
    let mut jobs = Jobs { list: Vec::new(), prev_index: Vec::new(), index_manifest: Vec::new(), reused_all: true };
    sys::read_file(&[out, b"/index-manifest.tsv"].concat(), &mut jobs.prev_index);

    let texts_dir = [out, b"/texts"].concat();
    sys::make_dir(&texts_dir);
    let mut stamps = Stamps {
        repo: repo.to_vec(),
        texts_dir: texts_dir.clone(),
        prev: Vec::new(),
        prev_at: HashMap::new(),
        lines: Vec::new(),
        stamp_memo: HashMap::new(),
        raw_memo: HashMap::new(),
        mtime_memo: HashMap::new(),
        code_memo: HashSet::new(),
        pre: Vec::new(),
        pre_at: HashMap::new(),
    };
    if !clean {
        sys::read_file(&[out, b"/content-stamps.tsv"].concat(), &mut stamps.prev);
    }
    index_lines(&stamps.prev, &mut stamps.prev_at);

    // Cosmetic edits. indexed-texts.tsv says, for each file stamped by its
    // code, which text its rows were indexed from: "path\traw\tstamp", raw
    // "?" when Swan cannot tell. row-basis.tsv lists the files whose rows
    // Swan moved since the map was last written from indexer output:
    // "path\traw\tmtime", the text the rows now match and the mtime recorded
    // with it. A file whose rows could not be moved to match its text is
    // reindexed (`forced`), whatever its stamp says.
    let mut idx_prev: Vec<u8> = Vec::new();
    let mut basis_prev: Vec<u8> = Vec::new();
    if !clean {
        sys::read_file(&[out, b"/indexed-texts.tsv"].concat(), &mut idx_prev);
        sys::read_file(&[out, b"/row-basis.tsv"].concat(), &mut basis_prev);
    }
    let mut idx_at: HashMap<u64, usize> = HashMap::new();
    let mut basis_at: HashMap<u64, usize> = HashMap::new();
    index_lines(&idx_prev, &mut idx_at);
    index_lines(&basis_prev, &mut basis_at);
    let mut edited_at: HashMap<u64, i64> = HashMap::new(); // files.edited_mtime, where set
    if !clean && sys::file_exists(&old_db) {
        if let Ok(h) = Db::open_existing(&old_db) {
            if let Ok(st) = h.prepare(b"SELECT file, edited_mtime FROM files WHERE edited_mtime IS NOT NULL") {
                while st.step() == Ok(true) {
                    edited_at.insert(hash(&st.col_text(0)), st.col_int(1));
                }
            }
        }
    }
    // The text the map's rows for a file match while no rows are rewritten
    // from indexer output: "" when that is its current text, "?" unknown.
    let rows_basis = |rel: &[u8], key: u64, full: &[u8], idx_raw: &[u8]| -> Vec<u8> {
        let Some(&t) = edited_at.get(&key) else {
            return idx_raw.to_vec();
        };
        let b = line_of_path(&basis_prev, &basis_at, rel);
        if !b.is_empty() {
            let f = split(b, b'\t');
            if f.len() == 3 && f[2] == t.to_string().as_bytes() {
                return f[1].to_vec();
            }
        }
        if t == sys::mtime_ns(full) {
            return Vec::new();
        }
        b"?".to_vec()
    };
    let mut forced: Vec<u8> = Vec::new(); // paths, one per line
    let mut force_ts = false;
    let mut n_cosmetic = 0;
    prestamp(&walk, repo, out, &texts_dir, &stamps.prev, &stamps.prev_at, &mut stamps.pre, report);
    index_lines(&stamps.pre, &mut stamps.pre_at);
    walk.each_file(repo, |full, name| {
        if cosmetic_lang(name).is_empty() {
            return;
        }
        let st = stamps.stamp(full);
        let rel = &full[repo.len() + 1..];
        let key = hash(rel);
        if !stamps.code_memo.contains(&key) {
            return;
        }
        let raw = stamps.raw_text_of(key);
        let line = line_of_path(&idx_prev, &idx_at, rel);
        if line.is_empty() {
            return; // new since the last map: indexed anyway
        }
        let f = split(line, b'\t');
        if f.len() != 3 {
            return;
        }
        let mut why = f[1] == b"?";
        if !why && f[2] == (st as i64).to_string().as_bytes() {
            // its code is as indexed: no indexer would run for it
            if f[1] != raw && !stamps.have_text(f[1]) {
                why = true;
            }
            let b = rows_basis(rel, key, full, f[1]);
            if !b.is_empty() && b != raw && !stamps.have_text(&b) {
                why = true;
            }
            if !why && f[1] != raw {
                n_cosmetic += 1;
            }
        }
        if why {
            forced.extend_from_slice(rel);
            forced.push(b'\n');
            if cosmetic_lang(name) != b"python" {
                force_ts = true;
            }
        }
    });
    if n_cosmetic > 0 {
        report.extend_from_slice(b"cosmetic edits: ");
        push_int(report, n_cosmetic);
        report.extend_from_slice(b" file(s) changed only in comments or layout; no indexer runs for them\n");
    }
    if !forced.is_empty() {
        report.extend_from_slice(b"reindexing ");
        push_int(report, forced.iter().filter(|&&c| c == b'\n').count() as i64);
        report.extend_from_slice(b" file(s) whose indexed text is unknown\n");
    }

    // A repo's tsconfig that tsc cannot read (it extends a shared config
    // from an npm package that is not installed, such as
    // "@sindresorhus/tsconfig", or names a missing file) failed the whole
    // TypeScript index. Swan's own config is used instead, and says so.
    let tsc = [&bin[..], b"tsc"].concat();
    if l.tsconfig {
        let config = [repo, b"/tsconfig.json"].concat();
        let env = child_env(&l, &[], b"");
        let env: Vec<&[u8]> = env.iter().map(|e| &e[..]).collect();
        let mut po: Vec<u8> = Vec::new();
        let mut pe: Vec<u8> = Vec::new();
        if sealed_run(&[&tsc, b"-p", &config, b"--showConfig"], repo, out, trusted, &env, 60000, &mut po, &mut pe) != 0 {
            let first = find(&po, b"\n");
            report.extend_from_slice(b"typescript: the repo's tsconfig.json cannot be read (");
            report.extend_from_slice(trim(if first > 0 { &po[..first as usize] } else { &po }));
            report.extend_from_slice(b"); indexing with Swan's own config\n");
            l.tsconfig = false;
            if !l.ts && !l.js {
                l.ts = true;
            }
        }
    }
    if l.tsconfig || l.ts || l.js {
        let target = [out, b"/index-typescript.scip"].concat();
        let mut a: Vec<Vec<u8>> = vec![[&bin[..], b"scip-typescript"].concat(), b"index".to_vec(), b"--output".to_vec(), target.clone()];
        if !l.tsconfig {
            // A tsconfig of our own, outside the repo; allowJs takes in .js/.mjs/.cjs.
            let dir = [out, b"/tsproject"].concat();
            sys::make_dir(&dir);
            let mut cfg: Vec<u8> = Vec::new();
            cfg.extend_from_slice(b"{\"compilerOptions\":{\"allowJs\":true,\"checkJs\":false,\"noEmit\":true,");
            cfg.extend_from_slice(b"\"module\":\"esnext\",\"moduleResolution\":\"bundler\",\"target\":\"es2022\"},\"include\":[");
            json_string(&mut cfg, &[repo, b"/**/*"].concat());
            cfg.extend_from_slice(b"],\"exclude\":[");
            json_string(&mut cfg, &[repo, b"/**/node_modules"].concat());
            for d in walk.ignored().split(|&c| c == b'\n') {
                if !d.is_empty() {
                    cfg.push(b',');
                    json_string(&mut cfg, &[repo, b"/", d].concat());
                }
            }
            cfg.extend_from_slice(b"]}\n");
            sys::write_file(&[&dir[..], b"/tsconfig.json"].concat(), &cfg);
            a.push(b"--cwd".to_vec());
            a.push(repo.to_vec());
            a.push(dir);
        }
        // The indexer first (src/tspatch.rs): several processes may index
        // parts of one project only once it names the properties of object
        // literals by their place. What it is (its size) is part of every TypeScript
        // fingerprint, so the indexes are made again when it changes.
        let ts_stable = ensure_scip_typescript_patch(&home, report);
        let ts_indexer = hash(&[&b"scip-typescript\t"[..], sys::file_size(&[&home[..], b"/tools/node_modules/@sourcegraph/scip-typescript/dist/src/FileIndexer.js"].concat()).to_string().as_bytes()].concat());
        let ts_endings: [&[u8]; 8] = [b".ts", b".tsx", b".mts", b".cts", b".js", b".jsx", b".mjs", b".cjs"];
        let ts_fp = hash_combine(lang_fingerprint(&walk, repo, &ts_endings, &[b"tsconfig.json", b"package.json"], |f| stamps.stamp(f)), ts_indexer);
        // What tsc would compile, to split it.
        let base = if l.tsconfig { [repo, b"/tsconfig.json"].concat() } else { [out, b"/tsproject/tsconfig.json"].concat() };
        // Split only into the slots other languages leave free: chunks cost
        // more work in all (each loads the shared code), so they pay only
        // when TypeScript is the long pole.
        let others = (if l.py { count_lines(&plan_python(&walk, repo, jobs_limit().min(6))) } else { 0 })
            + (if l.cargo { 1 } else { 0 })
            + (if l.java { 1 } else { 0 })
            + (if l.c || l.cuda { 1 } else { 0 });
        let ts_k = jobs_limit() - others;
        // tsc's list changes only when files come or go or the config
        // changes, so it is kept with a key of those and asked again only then.
        let mut names_key: u64 = 0;
        let mut ts_count: i64 = 0;
        let mut ts_nested: Vec<u8> = Vec::new(); // every tsconfig.json below the repo's root, one per line
        walk.each_file(repo, |full, name| {
            for e in ts_endings {
                if ends_with(name, e) {
                    names_key = hash_combine(names_key, hash(full));
                    ts_count += 1;
                }
            }
            // Every other tsconfig counts too (src/tsproj.goose): which files
            // each owns is asked again when one changes.
            let at_root = full.len() == repo.len() + 1 + name.len();
            if starts_with(name, b"tsconfig") && ends_with(name, b".json") && !(at_root && name == b"tsconfig.json") {
                names_key = hash_combine(names_key, hash_combine(hash(full), stamps.stamp(full)));
                if name == b"tsconfig.json" {
                    ts_nested.extend_from_slice(full);
                    ts_nested.push(b'\n');
                }
            }
        });
        // More than one project is possible when a tsconfig.json lies below
        // the root or the root's own references others.
        let mut base_text: Vec<u8> = Vec::new();
        if l.tsconfig {
            sys::read_file(&base, &mut base_text);
        }
        let ts_multi = ts_stable && (!ts_nested.is_empty() || find(&base_text, b"\"references\"") >= 0);
        // With no slots to split into, a big project still runs as one
        // chunk (all of tsc's files, the same index the whole-language run
        // makes), so that a code edit can be indexed as a layer of just the
        // changed files and their users instead of the whole project again.
        // $SWAN_TS_LAYER_MIN files or more (default 200); small projects
        // index in a few seconds anyway.
        let mut layer_min: i64 = 200;
        if let Some(n) = parse_int(&sys::env(b"SWAN_TS_LAYER_MIN")) {
            if n > 0 {
                layer_min = n;
            }
        }
        let plan_k = if !ts_stable {
            0
        } else if ts_k >= 2 {
            ts_k
        } else if ts_count >= layer_min || ts_multi {
            1
        } else {
            0
        };
        for r in [&b"tsconfig.json"[..], b"package.json"] {
            let pth = [repo, b"/", r].concat();
            if sys::file_exists(&pth) {
                names_key = hash_combine(names_key, hash_combine(hash(&pth), stamps.stamp(&pth)));
            }
        }
        let mut listing: Vec<u8> = Vec::new();
        let mut cached: Vec<u8> = Vec::new();
        sys::read_file(&[out, b"/tsc-files.txt"].concat(), &mut cached);
        // "roots": the kept list holds tsc's root files only (ts_root_listing);
        // a list kept by an earlier Swan, of every program file, is not used.
        let key_line = format!("{names_key} roots\n").into_bytes();
        let mut listed = false;
        // Every file tsc compiles, the roots and what they import, kept
        // beside the roots (tsc-program.txt): see `shared` below.
        let mut program: Vec<u8> = Vec::new();
        if plan_k >= 1 && starts_with(&cached, &key_line) {
            let mut kept_program: Vec<u8> = Vec::new();
            sys::read_file(&[out, b"/tsc-program.txt"].concat(), &mut kept_program);
            if starts_with(&kept_program, &key_line) {
                listing.extend_from_slice(&cached[key_line.len()..]);
                program.extend_from_slice(&kept_program[key_line.len()..]);
                listed = true;
            }
        }
        if plan_k >= 1 && !listed {
            // tsc exits 1 when a type library is missing (a repo without its
            // node_modules: "Cannot find type definition file for 'node'")
            // yet still lists every file; scip-typescript indexes such a repo
            // the same way. Only tsc's own "errors reported" exits (1, 2)
            // count, not a timeout or a crash, which could cut the list
            // short, and a listing with none of the repo's files (a broken
            // config) is not used.
            let env = child_env(&l, &[], b"");
            let env: Vec<&[u8]> = env.iter().map(|e| &e[..]).collect();
            let code = sealed_step(b"tsc --listFilesOnly", &[&tsc, b"-p", &base, b"--listFilesOnly"], repo, out, trusted, &env, 600000, &mut listing);
            if code == 0 || ((code == 1 || code == 2) && contains_line_prefix(&listing, &[repo, b"/"].concat())) {
                let mut show: Vec<u8> = Vec::new();
                if sealed_step(b"tsc --showConfig", &[&tsc, b"-p", &base, b"--showConfig"], repo, out, trusted, &env, 600000, &mut show) == 0 {
                    let cfg_dir = if l.tsconfig { repo.to_vec() } else { [out, b"/tsproject"].concat() };
                    let roots = ts_root_listing(&listing, &show, &cfg_dir);
                    program.extend_from_slice(&listing);
                    listing = roots;
                    listed = !listing.is_empty();
                }
                if listed {
                    cache.write(b"tsc-files.txt", &[&key_line[..], &listing].concat());
                    cache.write(b"tsc-program.txt", &[&key_line[..], &program].concat());
                }
            }
        }
        // The other projects (src/tsproj.rs): "config \t file" for each
        // file a config other than the root's owns. Kept, like tsc's list,
        // until a file comes or goes or a tsconfig changes.
        let mut ts_others: Vec<u8> = Vec::new();
        if plan_k >= 1 && ts_multi {
            let mut kept_projects: Vec<u8> = Vec::new();
            sys::read_file(&[out, b"/tsc-projects.txt"].concat(), &mut kept_projects);
            if starts_with(&kept_projects, &key_line) {
                ts_others.extend_from_slice(&kept_projects[key_line.len()..]);
            } else {
                let env = child_env(&l, &[], b"");
                let env: Vec<&[u8]> = env.iter().map(|e| &e[..]).collect();
                let mut note: Vec<u8> = Vec::new();
                ts_others = ts_other_projects(repo, out, trusted, &tsc, &env, &base, &listing, &ts_nested, &mut note);
                report.extend_from_slice(&note);
                cache.write(b"tsc-projects.txt", &[&key_line[..], &ts_others].concat());
            }
            if !ts_others.is_empty() {
                // The root's own files are the ones no other config took.
                let mut taken: HashSet<u64> = HashSet::new();
                for line in ts_others.split(|&c| c == b'\n') {
                    let tab = find(line, b"\t");
                    if tab > 0 {
                        taken.insert(hash(&line[tab as usize + 1..]));
                    }
                }
                let mut mine: Vec<u8> = Vec::new();
                for raw in listing.split(|&c| c == b'\n') {
                    let f = trim(raw);
                    if !f.is_empty() {
                        let real = sys::realpath(f).unwrap_or_else(|| f.to_vec());
                        if !taken.contains(&hash(&real)) {
                            mine.extend_from_slice(f);
                            mine.push(b'\n');
                        }
                    }
                }
                listing = mine;
                listed = true;
            }
        }
        // The chunks, planned inside each project: no chunk holds files of
        // two configs.
        let mut plan = TsPlan { decls: Vec::new(), decl_of: Vec::new(), ref_of: Vec::new(), bases: Vec::new(), owner_at: HashMap::new(), chunks: Vec::new() };
        let ts_projects = !ts_others.is_empty();
        let ts_total = count_lines(&listing) + count_lines(&ts_others);
        if listed {
            let mut root_files: Vec<u8> = Vec::new();
            for raw in listing.split(|&c| c == b'\n') {
                let f = trim(raw);
                if !f.is_empty() {
                    root_files.extend_from_slice(f);
                    root_files.push(b'\n');
                }
            }
            if !root_files.is_empty() || !ts_projects {
                plan.project(repo, &base, if ts_projects { &root_files } else { &listing }, plan_k, ts_total, ts_projects);
            } else {
                plan.bases.extend_from_slice(&base);
                plan.bases.push(b'\n');
            }
            let mut group: Vec<u8> = Vec::new();
            let mut group_cfg: Vec<u8> = Vec::new();
            for line in ts_others.split(|&c| c == b'\n') {
                let tab = find(line, b"\t");
                if tab <= 0 {
                    continue;
                }
                let tab = tab as usize;
                if line[..tab] != group_cfg[..] {
                    plan.project(repo, &group_cfg, &group, plan_k, ts_total, ts_projects);
                    group.clear();
                    group_cfg.clear();
                    group_cfg.extend_from_slice(&line[..tab]);
                }
                group.extend_from_slice(&line[tab + 1..]);
                group.push(b'\n');
            }
            plan.project(repo, &group_cfg, &group, plan_k, ts_total, ts_projects);
        }
        // Keep the last map's chunks while the set of files is the same, so
        // that an edit reruns only the chunks it touches (sizes moving files
        // between chunks would rerun them all), and while each of them is
        // still one project's.
        let mut same_plan = false;
        if !plan.chunks.is_empty() {
            let mut prev_plan: Vec<u8> = Vec::new();
            sys::read_file(&[out, b"/typescript-chunks.txt"].concat(), &mut prev_plan);
            let mut one_project_each = true;
            for chunk in prev_plan.split(|&c| c == b'\n') {
                let mut first = -1;
                for f in chunk.split(|&c| c == b'\t') {
                    if !f.is_empty() {
                        let o = plan.owner_index(f);
                        if first < 0 {
                            first = o;
                        } else if o != first {
                            one_project_each = false;
                        }
                    }
                }
            }
            if !prev_plan.is_empty() && one_project_each && same_file_set(&prev_plan, &plan.chunks) {
                plan.chunks = prev_plan;
                same_plan = true;
            }
            cache.write(b"typescript-chunks.txt", &plan.chunks);
        }
        let plan = plan;
        let base_list = split(&plan.bases, b'\n');
        if plan.chunks.is_empty() {
            jobs.add_lang(report, b"scip-typescript", &target, a, child_env(&l, &[], b""), ts_fp, force_ts, b"", false);
        } else {
            // Each chunk extends the project's tsconfig (or Swan's own) with its
            // own include list, plus every .d.ts, since declarations such as
            // module augmentations shape how the chunk's code resolves.
            //
            // Reuse, as for Python pieces: a chunk whose files, the shared
            // declarations and the config are unchanged, and none of whose
            // files use a symbol defined in a changed file (by the last map),
            // keeps its last index.
            let signed = |v: u64| (v as i64).to_string().into_bytes();
            let mut ts_stamps: Vec<u8> = Vec::new();
            let mut shared: u64 = 0;
            for r in [&b"tsconfig.json"[..], b"package.json"] {
                let pth = [repo, b"/", r].concat();
                if sys::file_exists(&pth) {
                    shared = hash_combine(shared, hash_combine(hash(r), stamps.stamp(&pth)));
                }
            }
            shared = hash_combine(hash_combine(shared, hash(&base)), ts_indexer);
            for (i, b) in base_list.iter().enumerate() {
                if i > 0 && !b.is_empty() {
                    shared = hash_combine(shared, hash_combine(hash(b), stamps.stamp(b)));
                }
            }
            for f in plan.decls.split(|&c| c == b'\n') {
                if f.len() > repo.len() {
                    let st = [&f[repo.len() + 1..], b"\t", &signed(stamps.stamp(f))[..]].concat();
                    shared = hash_combine(shared, hash(&st));
                    ts_stamps.extend_from_slice(&st);
                    ts_stamps.push(b'\n');
                }
            }
            // Repo files tsc compiles that are not roots (what the roots
            // import from outside the include) are not indexed, but an edit
            // to one can change how the roots resolve, so they count as
            // shared inputs: an edit to one reruns every chunk.
            let mut root_set: HashSet<&[u8]> = HashSet::new();
            for f in listing.split(|&c| c == b'\n') {
                let f = trim(f);
                if !f.is_empty() {
                    root_set.insert(f);
                }
            }
            // A file another config owns is a root too, of its own project.
            for line in ts_others.split(|&c| c == b'\n') {
                let tab = find(line, b"\t");
                if tab > 0 {
                    root_set.insert(&line[tab as usize + 1..]);
                }
            }
            for raw in program.split(|&c| c == b'\n') {
                let f = trim(raw);
                if f.len() > repo.len() && starts_with(f, repo) && f[repo.len()] == b'/' && find(f, b"/node_modules/") < 0 && !root_set.contains(f) {
                    shared = hash_combine(shared, hash(&[&f[repo.len() + 1..], b"\t", &signed(stamps.stamp(f))[..]].concat()));
                }
            }
            for chunk in plan.chunks.split(|&c| c == b'\n') {
                for f in chunk.split(|&c| c == b'\t') {
                    if f.len() > repo.len() {
                        ts_stamps.extend_from_slice(&[&f[repo.len() + 1..], b"\t", &signed(stamps.stamp(f))[..], b"\n"].concat());
                    }
                }
            }
            // Layers index changed files against the last map's view of
            // everything else, so they are only used while the shared inputs
            // (config, package.json, declarations, imported non-roots) are
            // what they were.
            let mut prev_shared: Vec<u8> = Vec::new();
            sys::read_file(&[out, b"/typescript-shared.txt"].concat(), &mut prev_shared);
            let same_shared = prev_shared == shared.to_string().as_bytes();
            cache.write(b"typescript-shared.txt", shared.to_string().as_bytes());
            let mut prev_stamps: Vec<u8> = Vec::new();
            sys::read_file(&[out, b"/typescript-files.tsv"].concat(), &mut prev_stamps);
            let mut dirty = dependents_of_changes(out, &ts_stamps, &prev_stamps);
            dirty.extend_from_slice(&forced);
            cache.write(b"typescript-files.tsv", &ts_stamps);
            // A small edit: rather than rerun whole chunks (each loads the
            // shared code, about 7 s on AEON), index just the changed files
            // and their users as a run of their own, a layer. Layers are
            // listed newest first, before the chunks, and the flattener keeps
            // the first rows it sees for a file, so the newest wins. Earlier
            // layers are kept as they are. When the layers cover more than a
            // quarter of the files, or there are more than 6, the chunks run
            // again and the layers go.
            let mut prev_layers: Vec<u8> = Vec::new(); // "id\tfile,file,..." per line, newest first
            sys::read_file(&[out, b"/typescript-layers.txt"].concat(), &mut prev_layers);
            let nfiles = count_lines(&ts_stamps);
            let mut fresh: Vec<u8> = Vec::new(); // this map's changed files and their users
            for rel in dirty.split(|&c| c == b'\n') {
                if !rel.is_empty() && !contains_line(&fresh, rel) && !ends_with(rel, b".d.ts") && contains_line_prefix(&ts_stamps, &[rel, b"\t"].concat()) {
                    fresh.extend_from_slice(rel);
                    fresh.push(b'\n');
                }
            }
            let mut covered: Vec<u8> = Vec::new();
            for f in fresh.split(|&c| c == b'\n') {
                if !f.is_empty() {
                    covered.extend_from_slice(f);
                    covered.push(b'\n');
                }
            }
            let mut next_id: i64 = 0;
            let mut nlayers: i64 = 0;
            for line in prev_layers.split(|&c| c == b'\n') {
                let tab = find(line, b"\t");
                if tab > 0 {
                    let tab = tab as usize;
                    nlayers += 1;
                    if let Some(id) = parse_int(&line[..tab]) {
                        if id >= next_id {
                            next_id = id + 1;
                        }
                    }
                    for f in line[tab + 1..].split(|&c| c == b',') {
                        if !f.is_empty() && !contains_line(&covered, f) {
                            covered.extend_from_slice(f);
                            covered.push(b'\n');
                        }
                    }
                }
            }
            let n_chunks = count_lines(&plan.chunks);
            let mut chunk_files_present = true;
            for c in 0..n_chunks {
                if !sys::file_exists(&[out, b"/index-typescript-", c.to_string().as_bytes(), b".scip"].concat()) {
                    chunk_files_present = false;
                }
            }
            let mut layers_present = true;
            for line in prev_layers.split(|&c| c == b'\n') {
                let tab = find(line, b"\t");
                if tab > 0 && !sys::file_exists(&[out, b"/index-typescript-layer-", &line[..tab as usize], b".scip"].concat()) {
                    layers_present = false;
                }
            }
            // A layer for each config that owns changed files.
            let mut fresh_owners: Vec<u8> = Vec::new();
            for rel in fresh.split(|&c| c == b'\n') {
                if !rel.is_empty() {
                    let o = plan.owner_index(&[repo, b"/", rel].concat()).to_string();
                    if !contains_line(&fresh_owners, o.as_bytes()) {
                        fresh_owners.extend_from_slice(o.as_bytes());
                        fresh_owners.push(b'\n');
                    }
                }
            }
            let use_delta = same_plan
                && same_shared
                && chunk_files_present
                && layers_present
                && !covered.is_empty()
                && count_lines(&covered) * 4 <= nfiles
                && nlayers + count_lines(&fresh_owners) <= 6;
            let indexer = [&bin[..], b"scip-typescript"].concat();
            if use_delta {
                let mut layers: Vec<u8> = Vec::new();
                let mut layer_id = next_id;
                for os in fresh_owners.split(|&c| c == b'\n') {
                    if os.is_empty() {
                        continue;
                    }
                    let oi = parse_int(os).unwrap_or(0);
                    let cfg_path = base_list[oi as usize];
                    let dir = [out, b"/tsproject-layer-", layer_id.to_string().as_bytes()].concat();
                    sys::make_dir(&dir);
                    let mut cfg: Vec<u8> = Vec::new();
                    cfg.extend_from_slice(b"{\"extends\":");
                    json_string(&mut cfg, cfg_path);
                    cfg.extend_from_slice(b",\"include\":[],\"files\":[");
                    let mut first = true;
                    let mut mine: Vec<u8> = Vec::new();
                    let mut mine_n = 0;
                    for f in fresh.split(|&c| c == b'\n') {
                        if !f.is_empty() && plan.owner_index(&[repo, b"/", f].concat()) == oi {
                            if !first {
                                cfg.push(b',');
                                mine.push(b',');
                            }
                            json_string(&mut cfg, &[repo, b"/", f].concat());
                            mine.extend_from_slice(f);
                            mine_n += 1;
                            first = false;
                        }
                    }
                    for line in plan.decl_of.split(|&c| c == b'\n') {
                        let tab = find(line, b"\t");
                        if tab > 0 && &line[..tab as usize] == cfg_path {
                            cfg.push(b',');
                            json_string(&mut cfg, &line[tab as usize + 1..]);
                        }
                    }
                    for line in plan.ref_of.split(|&c| c == b'\n') {
                        let tab = find(line, b"\t");
                        if tab > 0 && &line[..tab as usize] == cfg_path && !contains_line(&fresh, &line[tab as usize + 1 + repo.len() + 1..]) {
                            cfg.push(b',');
                            json_string(&mut cfg, &line[tab as usize + 1..]);
                        }
                    }
                    cfg.extend_from_slice(b"]}\n");
                    sys::write_file(&[&dir[..], b"/tsconfig.json"].concat(), &cfg);
                    let t = [out, b"/index-typescript-layer-", layer_id.to_string().as_bytes(), b".scip"].concat();
                    let da: Vec<Vec<u8>> = vec![indexer.clone(), b"index".to_vec(), b"--output".to_vec(), t.clone(), b"--cwd".to_vec(), repo.to_vec(), dir];
                    jobs.add(format!("scip-typescript changed files ({mine_n})").as_bytes(), &t, da, child_env(&l, &[], b""), b"", false);
                    layers.extend_from_slice(&[layer_id.to_string().as_bytes(), b"\t", &mine[..], b"\n"].concat());
                    layer_id += 1;
                }
                for line in prev_layers.split(|&c| c == b'\n') {
                    let tab = find(line, b"\t");
                    if tab > 0 {
                        jobs.add(b"", &[out, b"/index-typescript-layer-", &line[..tab as usize], b".scip"].concat(), Vec::new(), Vec::new(), b"", false);
                        layers.extend_from_slice(line);
                        layers.push(b'\n');
                    }
                }
                cache.write(b"typescript-layers.txt", &layers);
            } else {
                cache.write(b"typescript-layers.txt", b"");
            }
            let mut n: i64 = 0;
            for chunk in plan.chunks[..plan.chunks.len() - 1].split(|&c| c == b'\n') {
                let dir = [out, b"/tsproject-", n.to_string().as_bytes()].concat();
                sys::make_dir(&dir);
                let mut cfg: Vec<u8> = Vec::new();
                // Under its own project's config.
                let tab0 = find(chunk, b"\t");
                let cfg_path = base_list[plan.owner_index(if tab0 > 0 { &chunk[..tab0 as usize] } else { chunk }) as usize];
                cfg.extend_from_slice(b"{\"extends\":");
                json_string(&mut cfg, cfg_path);
                // "files" overrides the base's include: exactly this chunk, plus
                // the project's own declaration files.
                cfg.extend_from_slice(b",\"include\":[],\"files\":[");
                let mut first = true;
                for f in chunk.split(|&c| c == b'\t') {
                    if !first {
                        cfg.push(b',');
                    }
                    json_string(&mut cfg, f);
                    first = false;
                }
                for line in plan.decl_of.split(|&c| c == b'\n') {
                    let tab = find(line, b"\t");
                    if tab > 0 && &line[..tab as usize] == cfg_path {
                        cfg.push(b',');
                        json_string(&mut cfg, &line[tab as usize + 1..]);
                    }
                }
                for line in plan.ref_of.split(|&c| c == b'\n') {
                    let tab = find(line, b"\t");
                    if tab > 0 && &line[..tab as usize] == cfg_path && find(chunk, &line[tab as usize + 1..]) < 0 {
                        cfg.push(b',');
                        json_string(&mut cfg, &line[tab as usize + 1..]);
                    }
                }
                cfg.extend_from_slice(b"]}\n");
                sys::write_file(&[&dir[..], b"/tsconfig.json"].concat(), &cfg);
                let t = [out, b"/index-typescript-", n.to_string().as_bytes(), b".scip"].concat();
                let ca: Vec<Vec<u8>> = vec![indexer.clone(), b"index".to_vec(), b"--output".to_vec(), t.clone(), b"--cwd".to_vec(), repo.to_vec(), dir];
                let mut fp = shared;
                let mut touched = false;
                for f in chunk.split(|&c| c == b'\t') {
                    if f.len() > repo.len() {
                        let rel = &f[repo.len() + 1..];
                        fp = hash_combine(fp, hash_combine(hash(rel), stamps.stamp(f)));
                        if !touched && contains_line(&dirty, rel) {
                            touched = true;
                        }
                    }
                }
                // A chunk a changed file's users fall in counts as changed:
                // the time is mixed in, so its fingerprint is no kept one.
                if touched {
                    fp = hash_combine(fp, hash(sys::time_ns().to_string().as_bytes()));
                }
                let label = format!("scip-typescript {n}/{n_chunks}").into_bytes();
                if use_delta {
                    // Kept as it is; the changed-files run covers what moved. Its
                    // manifest line can never match, so a later full run redoes it.
                    jobs.index_manifest.extend_from_slice(&[&label[..], b"\tstale\t", &t[..], b"\n"].concat());
                    jobs.add(b"", &t, Vec::new(), Vec::new(), b"", false);
                } else {
                    jobs.add_lang(report, &label, &t, ca, child_env(&l, &[], b""), fp, false, b"", false);
                }
                n += 1;
            }
        }
    }

    if l.py {
        // Swan's copy of scip-python gets its reachability memo first
        // (src/pypatch.rs): without it one long script of try/except
        // blocks can hold a map for minutes.
        let dist = [&home[..], b"/tools/node_modules/@sourcegraph/scip-python/dist"].concat();
        ensure_scip_python_patch(&home, sys::file_size(&[&dist[..], b"/pyright-internal.js"].concat()), report);
        ensure_scip_python_site_patch(&home, sys::file_size(&[&dist[..], b"/scip-python.js"].concat()), report);
        let python = python_of(&l);
        let mut env_args: Vec<Vec<u8>> = Vec::new();
        // The Python projects' own virtualenvs, where the survey found them
        // (not only at the top of the repo): read, not run. Their packages
        // are listed from their dist-info folders and found through a
        // stand-in interpreter (PY_STANDIN_SH), so this needs no trust. A
        // virtualenv at the top of a trusted repo is run as before (l.venv).
        let mut py_site: Vec<u8> = Vec::new(); // site-packages folders, ':' between
        let mut py_version: Vec<u8> = Vec::new(); // the first virtualenv's Python
        let mut py_venvs: Vec<u8> = Vec::new(); // the virtualenvs read, for the report
        let mut py_standin: Vec<u8> = Vec::new();
        let mut py_listing: Vec<u8> = Vec::new();
        if l.venv.is_empty() {
            // The one at the top that detect() found (a repo of scripts has
            // no manifest, so the survey names no project there), then the
            // survey's: "<virtualenv, relative to the repo>\t<its Python>".
            let mut found: Vec<u8> = Vec::new();
            if venv_read.len() > repo.len() + 1 {
                found.extend_from_slice(&[&venv_read[repo.len() + 1..], b"\t", &pyvenv_version(&venv_read)[..], b"\n"].concat());
            }
            let surveyed = survey_python_envs(&survey, &survey_skip);
            for line in surveyed.split(|&c| c == b'\n') {
                let f = split(line, b'\t');
                if f.len() == 3 && find(&found, &[f[1], b"\t"].concat()) != 0 && find(&found, &[b"\n", f[1], b"\t"].concat()) < 0 {
                    found.extend_from_slice(&[f[1], b"\t", f[2], b"\n"].concat());
                }
            }
            for line in found.split(|&c| c == b'\n') {
                let f = split(line, b'\t');
                if f.len() == 2 {
                    let had = py_site.len();
                    py_site_dirs(&[repo, b"/", f[0]].concat(), &mut py_site);
                    if py_site.len() > had {
                        if !py_venvs.is_empty() {
                            py_venvs.extend_from_slice(b", ");
                        }
                        py_venvs.extend_from_slice(f[0]);
                        if py_version.is_empty() {
                            py_version.extend_from_slice(f[1]);
                        }
                    }
                }
            }
        }
        if !py_site.is_empty() {
            py_standin = py_standin_dir(out);
        }
        // Otherwise, as before: is there a pip to ask? Sealed: run with the
        // repo as working directory, `python -m pip` and `python -c` would
        // import a repo file named pip.py or json.py.
        let env_file = [out, b"/python-env.json"].concat();
        let plain_env = child_env(&l, &[], b"");
        let plain_env: Vec<&[u8]> = plain_env.iter().map(|e| &e[..]).collect();
        let mut o: Vec<u8> = Vec::new();
        let mut e: Vec<u8> = Vec::new();
        if !py_standin.is_empty() {
            let mut p: Vec<&[u8]> = vec![b"python3", b"-I", b"-c", PY_VENV_SNIPPET];
            for d in py_site.split(|&c| c == b':') {
                p.push(d);
            }
            if sealed_step(b"python packages (read from the virtualenv)", &p, repo, out, trusted, &plain_env, 60000, &mut py_listing) != 0 {
                py_listing.clear();
                py_listing.extend_from_slice(b"[]");
            }
            sys::write_file(&env_file, &py_listing);
            env_args.push(b"--environment".to_vec());
            env_args.push(env_file.clone());
            let held = pypatch_count(&py_listing, b"{\"name\": ");
            report.extend_from_slice(b"python: ");
            push_int(report, held);
            report.extend_from_slice(if held == 1 { &b" package"[..] } else { b" packages" });
            if find(&py_venvs, b", ") < 0 {
                report.extend_from_slice(&[b" read from the project's own virtualenv (", &py_venvs[..]].concat());
                if !py_version.is_empty() {
                    report.extend_from_slice(&[b", Python ", &py_version[..]].concat());
                }
                report.extend_from_slice(b"); nothing in it was run\n");
            } else {
                // One environment for the whole repo: see STATUS.md, 2026-11-18.
                report.extend_from_slice(&[b" read from the projects' own virtualenvs (", &py_venvs[..], b"), a package two of them hold from the first"].concat());
                if !py_version.is_empty() {
                    report.extend_from_slice(&[b"; read as the first one's Python ", &py_version[..]].concat());
                }
                report.extend_from_slice(b"; nothing in them was run\n");
            }
        } else if sealed_run(&[&python, b"-m", b"pip", b"--version"], repo, out, trusted, &plain_env, 30000, &mut o, &mut e) != 0 {
            let mut listing: Vec<u8> = Vec::new();
            if sealed_step(b"python packages (importlib.metadata)", &[&python, b"-c", PY_ENV_SNIPPET], repo, out, trusted, &plain_env, 60000, &mut listing) == 0 {
                sys::write_file(&env_file, &listing);
            } else {
                sys::write_file(&env_file, b"[]");
            }
            env_args.push(b"--environment".to_vec());
            env_args.push(env_file.clone());
        }
        let slash = rfind(repo, b"/");
        let pieces = plan_python(&walk, repo, jobs_limit().min(6));
        // "<file, relative to the repo>\t<its content stamp>" for every .py.
        let mut py_stamps: Vec<u8> = Vec::new();
        walk.each_file(repo, |full, name| {
            if ends_with(name, b".py") {
                py_stamps.extend_from_slice(&[&full[repo.len() + 1..], b"\t", (stamps.stamp(full) as i64).to_string().as_bytes(), b"\n"].concat());
            }
        });
        // A src layout (src/<package>/__init__.py) is importable only once
        // the package is installed, which Swan never does, so tests and
        // scripts that `import <package>` resolved to nothing. Putting src on
        // PYTHONPATH lets scip-python find it, and names the package's
        // modules as their importers do (`click.core`, not `src.click.core`).
        let py_path = python_src_roots(repo);
        let mut py_env: Vec<Vec<u8>> = Vec::new();
        if !py_path.is_empty() {
            py_env.push([&b"PYTHONPATH="[..], &py_path].concat());
        }
        if !py_standin.is_empty() {
            py_env.push([&b"SWAN_PY_SITE="[..], &py_site].concat());
            py_env.push([&b"SWAN_PY_STANDIN="[..], &py_standin].concat());
        }
        // The Python the code is read as: the virtualenv's, run or read.
        if !l.venv.is_empty() {
            py_version = pyvenv_version(&l.venv);
        }
        if !py_version.is_empty() {
            py_env.push([&b"SWAN_PY_VERSION="[..], &py_version].concat());
        }
        let py_env: Vec<&[u8]> = py_env.iter().map(|e| &e[..]).collect();
        // What is installed, and which Python, change symbol names and
        // what resolves: both are part of each piece's key.
        let env_key: Vec<u8> = if !py_standin.is_empty() {
            let held = [&py_site[..], b"|", &py_version[..], b"|", hash(&py_listing).to_string().as_bytes()].concat();
            format!("-{}", hash(&held)).into_bytes()
        } else if !py_version.is_empty() {
            format!("-{}", hash(&py_version)).into_bytes()
        } else {
            Vec::new()
        };

        // Reuse: a piece whose files are unchanged since the last map, and
        // none of whose files use a symbol defined in a changed file, keeps
        // its last index. Each file is stamped by its content.
        let mut prev_stamps: Vec<u8> = Vec::new();
        sys::read_file(&[out, b"/python-files.tsv"].concat(), &mut prev_stamps);
        let mut prev_manifest: Vec<u8> = Vec::new();
        sys::read_file(&[out, b"/python-pieces.tsv"].concat(), &mut prev_manifest);
        let mut dirty = dependents_of_changes(out, &py_stamps, &prev_stamps);
        dirty.extend_from_slice(&forced);
        cache.write(b"python-files.tsv", &py_stamps);
        let mut manifest: Vec<u8> = Vec::new();
        let mut reused: i64 = 0;
        for piece in pieces[..pieces.len() - 1].split(|&c| c == b'\n') {
            // The search path changes symbol names, so it is part of the key.
            let fp0 = if !py_path.is_empty() {
                format!("{}-{}", piece_fingerprint(&py_stamps, piece), hash(&py_path))
            } else {
                piece_fingerprint(&py_stamps, piece).to_string()
            };
            // "-n2": names as Swan's second scip-python fix gives them
            // (src/pypatch.rs). A piece kept from before it would name
            // an outside class differently from a piece indexed now.
            let fp = [fp0.as_bytes(), &env_key[..], b"-n2"].concat();
            let target = [out, b"/index-python-", hash(piece).to_string().as_bytes(), b".scip"].concat();
            let mut hit = false;
            for line in prev_manifest.split(|&c| c == b'\n') {
                let f = split(line, b'\t');
                if f.len() == 3 && f[0] == piece && f[1] == &fp[..] && sys::file_exists(f[2]) {
                    hit = true;
                }
            }
            if hit && !piece_has(&dirty, piece) {
                reused += 1;
                jobs.add(b"", &target, Vec::new(), Vec::new(), piece, false); // already done: no argv
            } else {
                let mut a: Vec<Vec<u8>> = vec![
                    [&bin[..], b"scip-python"].concat(),
                    b"index".to_vec(),
                    b".".to_vec(),
                    b"--quiet".to_vec(),
                    b"--project-name".to_vec(),
                    repo[(slash + 1) as usize..].to_vec(),
                    b"--project-version".to_vec(),
                    b"0".to_vec(),
                    b"--output".to_vec(),
                    target.clone(),
                ];
                if !piece.is_empty() {
                    a.push(b"--target-only".to_vec());
                    a.push(piece_target(piece).to_vec());
                }
                a.extend(env_args.iter().cloned());
                let label = if !piece.is_empty() { [b"scip-python ", piece].concat() } else { b"scip-python".to_vec() };
                jobs.add(&label, &target, a, child_env(&l, &py_env, &py_standin), piece, false);
            }
            manifest.extend_from_slice(&[piece, b"\t", &fp[..], b"\t", &target[..], b"\n"].concat());
        }
        cache.write(b"python-pieces.tsv", &manifest);
        if reused > 0 {
            report.extend_from_slice(b"python: ");
            push_int(report, reused);
            report.extend_from_slice(b" pieces reused\n");
        }
        // Index files of pieces no longer in the plan go.
        if let Some(names) = sys::list_dir(out) {
            for nm in names {
                let path = [out, b"/", &nm[..]].concat();
                if starts_with(&nm, b"index-python-") && find(&manifest, &path) < 0 {
                    sys::delete_file(&path);
                }
            }
        }
    }

    // Carried this far (docs/rust-port.md, "Next"): what was said so far is
    // printed, and the jobs, the indexers and the rows they give are not run.
    // Read where the jobs are run and the map's records written, still to
    // be carried.
    let _ = (&jobs.list, &jobs.index_manifest, jobs.reused_all);
    print(report);
    crate::not_carried(b"map", 4);
}
