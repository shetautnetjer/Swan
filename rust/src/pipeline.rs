// The map: what `swan map` runs, in what order, and what it keeps.
//
// Carried over from src/pipeline.goose so far: `swan trust`, and `swan map`
// to where its jobs are run: what git ignores, what the repo holds, its
// survey, an older or a clean map, the content stamps, and every job
// planned (TypeScript's chunks and layers, Python's pieces, the cargo
// projects, Java, C#, C and CUDA, the language servers, the syntax index),
// with what waits for trust. A repo with nothing to run is mapped to its
// end. Any other map stops there, with what it would have said so far and
// exit 70. The walk at the head of that file is in walk.rs.

use std::collections::{HashMap, HashSet};

use crate::change::{code_hash, cosmetic_lang, index_lines, line_of_path, shift_cosmetic};
use crate::db::Db;
use crate::edit::mark_edited;
use crate::fresh::scip_time_of;
use crate::gradle::gradle_scip_tasks;
use crate::gsort::goose_sort;
use crate::index::{index_main_locked, SCHEMA_VERSION};
use crate::modules::map_entries;
use crate::pypatch::{ensure_scip_python_patch, ensure_scip_python_site_patch, pypatch_count};
use crate::pyplan::{piece_target, plan_python};
use crate::query::meta_value;
use crate::run::{run_step, swan_home};
use crate::rustproj::{add_toolchain_env, cargo_inside, cargo_manifest_dirs, rust_analyzer_config, rust_projects, rust_std_source, rust_toolchain_dir, rust_toolchain_override, rust_unmapped, RUST_PROJECT_LIMIT};
use crate::seal::{sandbox_on, seal_argv, sealed_run, sealed_step};
use crate::stamp::prestamp;
use crate::survey::{survey_ignored, survey_paths, survey_python_envs, survey_report, survey_run};
use crate::sys;
use crate::treesitter;
use crate::tspatch::ensure_scip_typescript_patch;
use crate::tsproj::ts_other_projects;
use crate::util::{contains_line, die, ends_with, find, hash, hash_combine, json_string, parse_int, push_int, rfind, split, starts_with, trim, Dict};
use crate::walk::Walk;

// What a repo holds, found by walking it.
#[derive(Default)]
pub(crate) struct Langs {
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
    maven: bool,
    gradle: bool,
    pub(crate) venv: Vec<u8>, // a virtualenv inside the repo, if any
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

pub(crate) fn detect(walk: &Walk, repo: &[u8]) -> Langs {
    let mut l = Langs {
        tsconfig: sys::file_exists(&[repo, b"/tsconfig.json"].concat()),
        cargo: sys::file_exists(&[repo, b"/Cargo.toml"].concat()),
        maven: sys::file_exists(&[repo, b"/pom.xml"].concat()),
        gradle: sys::file_exists(&[repo, b"/build.gradle"].concat())
            || sys::file_exists(&[repo, b"/build.gradle.kts"].concat())
            || sys::file_exists(&[repo, b"/settings.gradle"].concat())
            || sys::file_exists(&[repo, b"/settings.gradle.kts"].concat()),
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

// The CUDA toolkit: $CUDA_PATH, /usr/local/cuda, or the headers-only one
// scripts/fetch-tools.sh assembles in .tools/cuda-sdk from NVIDIA's pip
// wheels (enough to index; nvcc itself is not needed).
fn cuda_path(home: &[u8]) -> Vec<u8> {
    let p = sys::env(b"CUDA_PATH");
    if !p.is_empty() {
        return p;
    }
    if sys::is_dir(b"/usr/local/cuda/include") {
        return b"/usr/local/cuda".to_vec();
    }
    [home, b"/.tools/cuda-sdk"].concat()
}

// A compile_commands.json for repos without one, outside the repo: every C,
// C++ and CUDA source, with the repo root on the include path. CUDA is
// compiled host-side by clang's CUDA mode against cuda_path.
fn write_compdb(walk: &Walk, repo: &[u8], home: &[u8], path: &[u8]) {
    let cuda = cuda_path(home);
    let mut j: Vec<u8> = vec![b'['];
    let mut n = 0;
    walk.each_file(repo, |full, name| {
        let is_cu = ends_with(name, b".cu");
        if is_cu || is_c_source(name) {
            if n > 0 {
                j.push(b',');
            }
            n += 1;
            j.extend_from_slice(b"{\"directory\":");
            json_string(&mut j, repo);
            j.extend_from_slice(b",\"file\":");
            json_string(&mut j, full);
            j.extend_from_slice(b",\"arguments\":[");
            if is_cu {
                j.extend_from_slice(b"\"clang++\",\"-x\",\"cuda\",");
                json_string(&mut j, &[&b"--cuda-path="[..], &cuda].concat());
                j.extend_from_slice(b",\"--cuda-gpu-arch=sm_80\",\"--cuda-host-only\",\"-nocudalib\",\"-std=c++17\",");
            } else if ends_with(name, b".c") {
                j.extend_from_slice(b"\"clang\",\"-std=c11\",");
            } else {
                j.extend_from_slice(b"\"clang++\",\"-std=c++17\",");
            }
            json_string(&mut j, &[b"-I", repo].concat());
            j.extend_from_slice(b",\"-c\",");
            json_string(&mut j, full);
            j.extend_from_slice(b"]}");
        }
    });
    j.extend_from_slice(b"]\n");
    sys::write_file(path, &j);
}

// The scip-java scripts/fetch-tools.sh installs, by version, so a new pin
// is a new file and never an old binary kept. Keep the two in step.
const SCIP_JAVA: &[u8] = b"v0.14.1";

// Whether the repo's root holds a solution or project file for scip-dotnet.
fn has_dotnet_project(repo: &[u8]) -> bool {
    match sys::list_dir(repo) {
        Some(names) => names.iter().any(|n| ends_with(n, b".sln") || ends_with(n, b".slnx") || ends_with(n, b".csproj")),
        None => false,
    }
}

// Swan's .NET SDK and its homes, so nothing lands in ~/.dotnet or ~/.nuget.
fn dotnet_env(home: &[u8]) -> Vec<Vec<u8>> {
    let t = [home, b"/.tools"].concat();
    vec![
        [&b"DOTNET_ROOT="[..], &t, b"/dotnet"].concat(),
        [&b"DOTNET_CLI_HOME="[..], &t, b"/dotnet-home"].concat(),
        [&b"NUGET_PACKAGES="[..], &t, b"/nuget"].concat(),
        b"DOTNET_CLI_TELEMETRY_OPTOUT=1".to_vec(),
        b"DOTNET_NOLOGO=1".to_vec(),
    ]
}

// What a job is to run, as the Goose program holds it: each word and a NUL
// after it. A fingerprint that takes in the words takes them in this way.
fn packed(argv: &[Vec<u8>]) -> Vec<u8> {
    let mut p: Vec<u8> = Vec::new();
    for a in argv {
        p.extend_from_slice(a);
        p.push(0);
    }
    p
}

pub(crate) fn untrusted_note(skipped: &[u8], repo: &[u8]) -> Vec<u8> {
    [&b"not run:"[..], skipped, b" (each runs the repo's own build files, which can run any code); if you trust this repo: swan trust ", repo].concat()
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
pub(crate) fn child_env(l: &Langs, extra: &[&[u8]], first: &[u8]) -> Vec<Vec<u8>> {
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

pub(crate) fn python_of(l: &Langs) -> Vec<u8> {
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

pub(crate) fn build_trusted(repo: &[u8]) -> bool {
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

// Clean publication must not treat a successful but malformed flattener as a
// complete replacement. Match bin/swan-flatten's row contract before the
// existing permissive native reader runs. Empty files/lines are valid, and the
// historical five-column symbol row remains valid (the sixth is optional docs).
fn clean_row_number(field: &[u8]) -> bool {
    !field.is_empty() && field.iter().all(|c| c.is_ascii_digit()) && parse_int(field).is_some_and(|v| v >= 0)
}

fn clean_row_valid(name: &[u8], line: &[u8]) -> bool {
    let f = split(line, b'\t');
    if name == b"symbols.tsv" {
        return (f.len() == 5 || f.len() == 6) && !f[0].is_empty() && clean_row_number(f[2]);
    }
    if name == b"relationships.tsv" {
        if !(f.len() == 4 && f.iter().all(|x| !x.is_empty())) {
            return false;
        }
        return split(f[3], b',').iter().all(|&flag| flag == b"impl" || flag == b"ref" || flag == b"type" || flag == b"def");
    }
    let expected = if name == b"extents.tsv" { 6 } else { 7 };
    if !(f.len() == expected && !f[0].is_empty() && !f[1].is_empty()) {
        return false;
    }
    if !(2..6).all(|i| clean_row_number(f[i])) {
        return false;
    }
    let at = |i: usize| parse_int(f[i]).unwrap_or(0);
    if !(at(4) > at(2) || (at(4) == at(2) && at(5) >= at(3))) {
        return false;
    }
    name == b"extents.tsv" || f[6] == b"def" || f[6] == b"ref" || f[6] == b"imp" || f[6] == b"name"
}

fn clean_rows_valid(out: &[u8], report: &mut Vec<u8>) -> bool {
    for name in [&b"symbols.tsv"[..], b"extents.tsv", b"relationships.tsv", b"occurrences.tsv"] {
        let mut rows: Vec<u8> = Vec::new();
        if !sys::read_file(&[out, b"/", name].concat(), &mut rows) {
            report.extend_from_slice(&[b"clean rebuild cannot read flattened output: ", name, b"; previous database retained"].concat());
            return false;
        }
        for (row, line) in rows.split(|&c| c == b'\n').enumerate() {
            if !line.is_empty() && !clean_row_valid(name, line) {
                report.extend_from_slice(&[b"clean rebuild malformed flattened output: ", name, b" row "].concat());
                push_int(report, row as i64 + 1);
                report.extend_from_slice(b"; previous database retained");
                return false;
            }
        }
    }
    true
}

static MAP_HELD: std::sync::Mutex<Vec<u8>> = std::sync::Mutex::new(Vec::new());

// Build-running indexers the last map_main held back for `swan trust`,
// reported as use_repo's `skipped` field.
pub fn map_held_indexers() -> Vec<u8> {
    MAP_HELD.lock().unwrap_or_else(|e| e.into_inner()).clone()
}

pub fn map_main(repo_arg: &[u8], out_arg: &[u8], report: &mut Vec<u8>, clean: bool) -> bool {
    MAP_HELD.lock().unwrap_or_else(|e| e.into_inner()).clear();
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

// The syntax index's job: `swan syntax-index` (src/syntax.rs, this binary
// itself) over the repo but for the files in skip, and its fingerprint.
fn syntax_plan(walk: &Walk, stamps: &mut Stamps, repo: &[u8], out: &[u8], swan_bin: &[u8], skip: &HashSet<Vec<u8>>) -> (Vec<Vec<u8>>, u64) {
    let mut a: Vec<Vec<u8>> = vec![swan_bin.to_vec(), b"syntax-index".to_vec(), repo.to_vec(), [out, b"/index-syntax.scip"].concat()];
    let mut listed: Vec<&Vec<u8>> = skip.iter().collect();
    listed.sort();
    let listed: Vec<u8> = listed.iter().flat_map(|f| f.iter().copied().chain([b'\n'])).collect();
    let mut skip_word: Vec<u8> = Vec::new();
    let list = [out, b"/syntax-skip.txt"].concat();
    sys::delete_file(&list);
    if !listed.is_empty() {
        sys::write_file(&list, &listed);
        a.push(b"--skip-files".to_vec());
        a.push(list);
        skip_word = format!("\tskip {}", hash(&listed)).into_bytes();
    }
    let mut fp = hash(&[&b"syntax-goose-1\t"[..], swan_bin, b"\t", sys::file_size(swan_bin).to_string().as_bytes(), &skip_word].concat());
    walk.each_file(repo, |full, name| {
        if syntax_file(full, name) && !skip.contains(&full[repo.len() + 1..]) {
            fp = hash_combine(fp, hash_combine(hash(full), stamps.stamp(full)));
        }
    });
    (a, fp)
}

// The public wrapper holds the writer lock for every shared output: cached
// indexer files, flattened rows, schema replacement and final database update.
fn map_main_locked(repo: &[u8], out: &[u8], report: &mut Vec<u8>, clean: bool) -> bool {
    let t_start = std::time::Instant::now();
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

    // The indexers that wait for `swan trust`. The report names them where
    // the languages are done, still to be carried.
    let mut skipped: Vec<u8> = Vec::new();

    // Rust: one rust-analyzer run for each cargo project (src/rustproj.rs),
    // the repo root's first. `rust_dirs` is every folder with a Cargo.toml.
    let rust_dirs = cargo_manifest_dirs(&walk, repo);
    let mut rust_over: Vec<u8> = Vec::new();
    let rust_plan = rust_projects(repo, &rust_dirs, &mut rust_over);
    let mut rust_indexed = false;
    if !rust_plan.is_empty() && !trusted && !sandbox_on() {
        skipped.extend_from_slice(b" rust-analyzer scip (Rust: cargo build scripts, proc macros)");
        // This map drops them; after trust they are rebuilt, not reused.
        if let Some(had) = sys::list_dir(out) {
            for nm in had {
                if starts_with(&nm, b"index-rust") && ends_with(&nm, b".scip") {
                    sys::delete_file(&[out, b"/", &nm[..]].concat());
                }
            }
        }
    } else if !rust_plan.is_empty() {
        rust_indexed = true;
        // Any Rust file or cargo file anywhere in the repo: a project's index
        // also holds what it resolved in the crates it depends on by path.
        let rust_files = lang_fingerprint(&walk, repo, &[b".rs", b"Cargo.toml", b"Cargo.lock", b"rust-toolchain.toml", b"rust-toolchain"], &[], |f| stamps.stamp(f));
        // What each folder with a rust-toolchain file means for the run, asked
        // (and said on stderr) once: "folder \x01 library source \x01 toolchain".
        let mut rust_toolchains: Vec<u8> = Vec::new();
        for dir in rust_plan.split(|&c| c == b'\n') {
            if dir.is_empty() {
                continue;
            }
            let at_root = dir == b".";
            let target = if at_root { [out, b"/index-rust.scip"].concat() } else { [out, b"/index-rust-", hash(dir).to_string().as_bytes(), b".scip"].concat() };
            let label = if at_root { b"rust-analyzer scip".to_vec() } else { [b"rust project ", dir].concat() };
            let base: &[u8] = if at_root { b"" } else { dir };
            let mut a: Vec<Vec<u8>> = vec![[&home[..], b"/.tools/rust-analyzer/rust-analyzer"].concat(), b"scip".to_vec(), dir.to_vec(), b"--output".to_vec(), target.clone()];
            // The settings, in a file named by what they say: projects that
            // agree share it.
            let tc_dir = rust_toolchain_dir(repo, dir);
            let mut std_src: Vec<u8> = Vec::new();
            let mut tc: Vec<u8> = Vec::new();
            let mut asked = false;
            for line in rust_toolchains.split(|&c| c == b'\n') {
                let f = split(line, 1);
                if f.len() == 3 && f[0] == &tc_dir[..] {
                    asked = true;
                    std_src.extend_from_slice(f[1]);
                    tc.extend_from_slice(f[2]);
                }
            }
            if !asked {
                std_src.extend_from_slice(&rust_std_source(&tc_dir));
                tc.extend_from_slice(&rust_toolchain_override(&tc_dir));
                rust_toolchains.extend_from_slice(&tc_dir);
                rust_toolchains.push(1);
                rust_toolchains.extend_from_slice(&std_src);
                rust_toolchains.push(1);
                rust_toolchains.extend_from_slice(&tc);
                rust_toolchains.push(b'\n');
            }
            let settings = rust_analyzer_config(&std_src);
            let cfg = [out, b"/rust-analyzer-", hash(&settings).to_string().as_bytes(), b".json"].concat();
            sys::write_file(&cfg, &settings);
            a.push(b"--config-path".to_vec());
            a.push(cfg);
            // Build scripts and proc macros run inside the seal. Untrusted repos
            // run offline against the crates already cached in Cargo's home;
            // a missing crate leaves those uses unresolved, never unsealed.
            let mut renv: Vec<Vec<u8>> = Vec::new();
            renv.push([&b"CARGO_TARGET_DIR="[..], out, b"/cargo-target"].concat());
            add_toolchain_env(&mut renv, b"RUSTUP_HOME", b".rustup");
            add_toolchain_env(&mut renv, b"CARGO_HOME", b".cargo");
            if !trusted {
                renv.push(b"CARGO_NET_OFFLINE=true".to_vec());
            }
            // A run that fails then ends on its reason (cargo's own error),
            // which the report quotes, not on forty lines of stack.
            renv.push(b"RUST_BACKTRACE=0".to_vec());
            if !tc.is_empty() {
                renv.push([&b"RUSTUP_TOOLCHAIN="[..], &tc].concat());
            }
            // A project inside another one (a fuzz crate, an excluded tool) is
            // one the map can do without; a project with none above it is the
            // repo's own code, and its failure is the map's.
            let mut inside = false;
            for d in rust_dirs.split(|&c| c == b'\n') {
                if !d.is_empty() && cargo_inside(dir, d) {
                    inside = true;
                }
            }
            let renv: Vec<&[u8]> = renv.iter().map(|e| &e[..]).collect();
            jobs.add_lang(report, &label, &target, a, child_env(&l, &renv, b""), hash_combine(rust_files, hash(&settings)), false, base, inside);
        }
        if !rust_over.is_empty() {
            report.extend_from_slice(b"rust: ");
            push_int(report, count_lines(&rust_over));
            report.extend_from_slice(b" more cargo projects not mapped (");
            push_int(report, RUST_PROJECT_LIMIT as i64);
            report.extend_from_slice(b" at most in one map), starting with ");
            report.extend_from_slice(&rust_over[..find(&rust_over, b"\n") as usize]);
            report.push(b'\n');
        }
    }

    // scip-java indexes Java, and Kotlin built with Gradle (its compiler
    // plugin follows the current Kotlin, 2.4 as of scip-java 0.14.1).
    if (l.java || (l.kt && l.gradle)) && (l.maven || l.gradle) && !trusted {
        skipped.extend_from_slice(if l.gradle { &b" scip-java (Gradle)"[..] } else { b" scip-java (Maven)" });
        sys::delete_file(&[out, b"/index-java.scip"].concat());
    } else if l.java || (l.kt && l.gradle) {
        let target = [out, b"/index-java.scip"].concat();
        let mut a: Vec<Vec<u8>> = vec![
            [&home[..], b"/.tools/scip-java/", SCIP_JAVA, b"/scip-java"].concat(),
            b"index".to_vec(),
            [&b"--output="[..], &target].concat(),
            [&b"--targetroot="[..], out, b"/java-targetroot"].concat(),
        ];
        if !l.maven && !l.gradle {
            // No build tool: scip-java compiles the sources itself from a config
            // of our own, outside the repo. Without one, dependencies are unknown.
            let cfg = [out, b"/scip-java.json"].concat();
            sys::write_file(&cfg, b"{\"dependencies\":[],\"jvm\":\"21\"}\n");
            a.push([&b"--scip-config="[..], &cfg].concat());
        }
        let mut genv: Vec<Vec<u8>> = Vec::new();
        if l.gradle {
            // The build runs with Swan's Gradle home and, for Android, Swan's
            // SDK. scip-java's init script cannot run with the configuration
            // cache or isolated projects, which newer builds turn on. The
            // tasks are gradle_scip_tasks's: on Android, the (unqualified)
            // Kotlin compiles instead of scipPrintDependencies, which AGP 9
            // breaks (so no package versions for callees there). Note the `clean`
            // first: the repo's build/ output is rebuilt.
            for w in [&b"--"[..], b"-Dorg.gradle.configuration-cache=false", b"-Dorg.gradle.isolated-projects=false", b"-Dorg.gradle.jvmargs=-Xmx3g", b"-Dkotlin.daemon.jvmargs=-Xmx3g"] {
                a.push(w.to_vec());
            }
            for t in gradle_scip_tasks(&walk, repo).split(|&c| c == b'\n') {
                if !t.is_empty() {
                    a.push(t.to_vec());
                }
            }
            genv.push([&b"GRADLE_USER_HOME="[..], &home, b"/.tools/gradle-home"].concat());
            let sdk = [&home[..], b"/.tools/android-sdk"].concat();
            if sys::file_exists(&[&sdk[..], b"/licenses/android-sdk-license"].concat()) {
                genv.push([&b"ANDROID_HOME="[..], &sdk].concat());
                genv.push([&b"ANDROID_SDK_ROOT="[..], &sdk].concat());
            }
        }
        let genv: Vec<&[u8]> = genv.iter().map(|e| &e[..]).collect();
        let java_files = lang_fingerprint(
            &walk,
            repo,
            &[b".java", b".kt", b".kts", b".gradle"],
            &[b"pom.xml", b"build.gradle", b"build.gradle.kts", b"settings.gradle", b"settings.gradle.kts", b"gradle/libs.versions.toml"],
            |f| stamps.stamp(f),
        );
        let fp = hash_combine(java_files, hash(&packed(&a)));
        jobs.add_lang(report, b"scip-java", &target, a, child_env(&l, &genv, b""), fp, false, b"", false);
    }

    // C# (Unity, Godot C#, .NET): scip-dotnet over the solution or project at
    // the repo's root, with Swan's .NET SDK. It runs `dotnet restore`, which
    // writes the repo's obj/ folders, as a build would.
    let scip_dotnet = [&home[..], b"/.tools/dotnet-tools/scip-dotnet"].concat();
    let cs_map = find(&l.other, b"csharp") >= 0 && sys::file_exists(&scip_dotnet) && has_dotnet_project(repo);
    if cs_map && !trusted {
        skipped.extend_from_slice(b" scip-dotnet (C#: MSBuild through dotnet restore)");
        sys::delete_file(&[out, b"/index-csharp.scip"].concat());
    } else if cs_map {
        let target = [out, b"/index-csharp.scip"].concat();
        let a: Vec<Vec<u8>> = vec![scip_dotnet.clone(), b"index".to_vec(), b"--working-directory".to_vec(), repo.to_vec(), b"--output".to_vec(), target.clone()];
        let denv = dotnet_env(&home);
        let denv: Vec<&[u8]> = denv.iter().map(|e| &e[..]).collect();
        let fp = lang_fingerprint(&walk, repo, &[b".cs", b".csproj", b".sln", b".slnx", b".props", b".targets"], &[b"global.json", b"NuGet.config"], |f| stamps.stamp(f));
        jobs.add_lang(report, b"scip-dotnet", &target, a, child_env(&l, &denv, b""), fp, false, b"", false);
    }

    if l.c || l.cuda {
        let target = [out, b"/index-cxx.scip"].concat();
        let compdb = if sys::file_exists(&[repo, b"/compile_commands.json"].concat()) {
            [repo, b"/compile_commands.json"].concat()
        } else if sys::file_exists(&[repo, b"/build/compile_commands.json"].concat()) {
            [repo, b"/build/compile_commands.json"].concat()
        } else {
            let p = [out, b"/compile_commands.json"].concat();
            write_compdb(&walk, repo, &home, &p);
            p
        };
        let a: Vec<Vec<u8>> = vec![[&home[..], b"/.tools/scip-clang/scip-clang"].concat(), [&b"--compdb-path="[..], &compdb].concat(), [&b"--index-output-path="[..], &target].concat()];
        let fp = lang_fingerprint(
            &walk,
            repo,
            &[b".c", b".cc", b".cpp", b".cxx", b".h", b".hpp", b".hh", b".cu", b".cuh"],
            &[b"compile_commands.json", b"build/compile_commands.json"],
            |f| stamps.stamp(f),
        );
        jobs.add_lang(report, b"scip-clang", &target, a, child_env(&l, &[], b""), fp, false, b"", false);
    }

    if !skipped.is_empty() {
        report.extend_from_slice(&untrusted_note(&skipped, repo));
        report.push(b'\n');
    }

    // Languages with a language server and no SCIP indexer, when their entry
    // in tools/modules.json has "map_lsp" servers or says "map": "lsp":
    // `swan lsp-index` (this binary) asks the server for every definition and
    // its references, for the files the entry's "match" names. Left out, and
    // said, when the server is not here.
    let swan_bin = [&home[..], b"/bin/swan"].concat();
    // The files the lsp-index jobs map, repo-relative; and each job's place
    // in the list, its files, and whether the syntax index can map them
    // instead when its server fails.
    let mut covered: HashSet<Vec<u8>> = HashSet::new();
    let mut lsp_jobs: Vec<(usize, Vec<Vec<u8>>, bool)> = Vec::new();
    for (lang_name, entry) in map_entries(&home) {
        let lang = lang_name.as_bytes();
        let (mut all_files, mut by_syntax): (i64, i64) = (0, 0);
        walk.each_file(repo, |full, name| {
            if entry.holds(name) {
                all_files += 1;
                by_syntax += syntax_file(full, name) as i64;
            }
        });
        if all_files == 0 {
            continue;
        }
        if let Some(missing) = entry.missing(&home) {
            let then: &[u8] = if by_syntax > 0 { b"its files are mapped by name (syntax index)" } else { b"its files are not mapped" };
            report.extend_from_slice(&[lang, b": its language server is not here (", &missing[..], b"); ", then, b"\n"].concat());
            continue;
        }
        // Go modules below the top of the repo (from the survey): one run
        // per module, the server started in the module's own folder, as an
        // editor opens it. With a go.mod or a go.work at the top, or no
        // survey, one run over the repo.
        let mut folders: Vec<u8> = Vec::new();
        if lang == b"go" {
            let mods_at = survey_paths(&survey, b"go", &survey_skip);
            if !mods_at.is_empty() && !contains_line(&mods_at, b".") && !sys::file_exists(&[repo, b"/go.work"].concat()) {
                folders.extend_from_slice(&mods_at);
            }
        }
        if folders.is_empty() {
            folders.extend_from_slice(b".\n");
        }
        let per_folder = folders != b".\n";
        let mut in_folders: i64 = 0;
        // What the job runs: the map servers as written, and the size of
        // each file they need (a server fetched again maps again).
        let servers = [entry.map_text().as_bytes(), b"\t", &entry.needs_identity(&home)[..]].concat();
        for within in folders.split(|&c| c == b'\n') {
            if within.is_empty() {
                continue;
            }
            let whole = within == b".";
            let target = if whole {
                [out, b"/index-lsp-", lang, b".scip"].concat()
            } else {
                [out, b"/index-lsp-", lang, b"-", (hash(within) % 1000000).to_string().as_bytes(), b".scip"].concat()
            };
            let mut a: Vec<Vec<u8>> = vec![swan_bin.clone(), b"lsp-index".to_vec(), repo.to_vec(), out.to_vec(), lang.to_vec(), target.clone()];
            if !whole {
                a.push(b"--within".to_vec());
                a.push(within.to_vec());
            }
            let mut fp = hash(&[b"lsp-index-3\t", lang, b"\t", within, b"\t", &swan_bin[..], b"\t", sys::file_size(&swan_bin).to_string().as_bytes(), b"\t", &servers[..]].concat());
            let under = [repo, b"/", within, b"/"].concat();
            let mut files: Vec<Vec<u8>> = Vec::new();
            walk.each_file(repo, |full, name| {
                if entry.holds(name) && (whole || starts_with(full, &under)) {
                    fp = hash_combine(fp, hash_combine(hash(full), stamps.stamp(full)));
                    files.push(full[repo.len() + 1..].to_vec());
                }
            });
            in_folders += files.len() as i64;
            covered.extend(files.iter().cloned());
            lsp_jobs.push((jobs.list.len(), files, by_syntax > 0));
            let label = if whole { [b"lsp-index ", lang].concat() } else { [b"lsp-index ", lang, b" ", within].concat() };
            // With a by-name fallback the map goes on when the server fails.
            jobs.add_lang(report, &label, &target, a, child_env(&l, &[], b""), fp, false, b"", by_syntax > 0);
        }
        if per_folder {
            report.extend_from_slice(lang);
            report.extend_from_slice(b": ");
            push_int(report, count_lines(&folders));
            report.extend_from_slice(b" modules below the top of the repo, each mapped from its own folder");
            if all_files > in_folders {
                report.extend_from_slice(b"; ");
                push_int(report, all_files - in_folders);
                report.extend_from_slice(&[b" ", lang, b" files outside every module are left to the syntax index"].concat());
            }
            report.push(b'\n');
        }
    }
    // No compiler, no repo code run: a syntax-level map (definitions,
    // bodies, references by name) for the languages above, but for the
    // files a language server maps in this run: their rows would only
    // repeat, by name, what the server resolved.
    let mut syntax_at: Option<usize> = None;
    if l.syn {
        let (a, fp) = syntax_plan(&walk, &mut stamps, repo, out, &swan_bin, &covered);
        syntax_at = Some(jobs.list.len());
        jobs.add_lang(report, b"syntax-index", &[out, b"/index-syntax.scip"].concat(), a, child_env(&l, &[], b""), fp, false, b"", false);
    }
    {
        let mut held = MAP_HELD.lock().unwrap_or_else(|e| e.into_inner());
        held.clear();
        held.extend_from_slice(trim(&skipped));
    }
    if jobs.list.is_empty() && (l.kt || !l.other.is_empty() || !skipped.is_empty()) {
        // Nothing to index, but the code can still be searched by structure
        // and checked live: an empty map records the repo for search_pattern
        // and the rest.
        for t in [&b"symbols.tsv"[..], b"extents.tsv", b"relationships.tsv", b"occurrences.tsv"] {
            sys::write_file(&[out, b"/", t].concat(), b"");
        }
        index_main_locked(out, &[out, b"/swan.db"].concat(), repo, false, report);
        if l.kt || !l.other.is_empty() {
            report.extend_from_slice(&[&b"\n"[..], if l.kt { &b"kotlin "[..] } else { b"" }, &l.other, b": no SCIP indexer ran for these; search_pattern and rewrite_pattern work on them, and live diagnostics where their server is set up"].concat());
        }
        report.extend_from_slice(b"\nswan map: ");
        push_int(report, t_start.elapsed().as_millis() as i64);
        report.extend_from_slice(b" ms in all");
        return true;
    }
    if jobs.list.is_empty() {
        report.extend_from_slice(&[b"no language found to index in ", repo].concat());
        return false;
    }

    // Run them, at most jobs_limit() at a time.
    let limit = jobs_limit();
    let n_jobs = jobs.list.len();
    let mut pids: Vec<i64> = vec![0; n_jobs];
    let mut codes: Vec<i32> = vec![0; n_jobs];
    let mut began: Vec<std::time::Instant> = vec![t_start; n_jobs];
    let mut took: Vec<i64> = vec![0; n_jobs]; // ms
    let mut running: i64 = 0;
    fn wait_one(pids: &[i64], codes: &mut [i32], began: &[std::time::Instant], took: &mut [i64], running: &mut i64) {
        let Some((pid, code)) = sys::wait_any() else {
            *running = 0;
            return;
        };
        for k in 0..pids.len() {
            if pids[k] == pid && codes[k] == -999 {
                codes[k] = code;
                took[k] = began[k].elapsed().as_millis() as i64;
                *running -= 1;
            }
        }
    }
    if clean {
        // A successful indexer must produce this run's file, not leave an old
        // target behind. Reuse metadata was invalidated before planning.
        for job in &jobs.list {
            if job.argv.is_empty() {
                report.extend_from_slice(b"clean rebuild unexpectedly planned cached output");
                return false;
            }
            if !(!sys::file_exists(&job.target) || sys::delete_file(&job.target)) {
                report.extend_from_slice(&[b"cannot remove prior indexer output: ", &job.target[..]].concat());
                return false;
            }
        }
    }
    // Start order: an indexer that runs once for its whole language
    // (rust-analyzer, scip-java, scip-clang, ...) before the indexers split
    // into many pieces. One long job queued behind dozens of short pieces
    // would start only when they are nearly done and then be the whole
    // wait (monty: rust-analyzer's 12 s began 11 s in). The report keeps
    // the jobs' own order.
    fn tool_of(label: &[u8]) -> &[u8] {
        match label.iter().position(|&c| c == b' ') {
            Some(sp) if sp > 0 => &label[..sp],
            _ => label,
        }
    }
    let mut order: Vec<usize> = Vec::new();
    for pass in 0..2 {
        for i in 0..n_jobs {
            let same = jobs.list.iter().filter(|o| tool_of(&o.label) == tool_of(&jobs.list[i].label)).count();
            if (same == 1) == (pass == 0) {
                order.push(i);
            }
        }
    }
    for &idx in &order {
        let job = &jobs.list[idx];
        if job.argv.is_empty() {
            continue; // reused from the last map: nothing to run
        }
        while running >= limit {
            wait_one(&pids, &mut codes, &began, &mut took, &mut running);
        }
        let inner: Vec<&[u8]> = job.argv.iter().map(|a| &a[..]).collect();
        let launch: Vec<Vec<u8>> = if sandbox_on() { seal_argv(&inner, repo, out, trusted) } else { job.argv.clone() };
        let launch: Vec<&[u8]> = launch.iter().map(|a| &a[..]).collect();
        let env: Vec<&[u8]> = job.env.iter().map(|e| &e[..]).collect();
        let log = [out, b"/log-", idx.to_string().as_bytes(), b".txt"].concat();
        codes[idx] = -999;
        began[idx] = std::time::Instant::now();
        match sys::spawn_job(&launch, repo, &env, &log) {
            Ok(pid) => {
                pids[idx] = pid;
                running += 1;
            }
            // Not started: the code its child would have ended with.
            Err(code) => codes[idx] = code,
        }
    }
    while running > 0 {
        wait_one(&pids, &mut codes, &began, &mut took, &mut running);
    }
    // A language server that failed leaves its files without rows: the
    // syntax index runs again, now mapping them too, by name.
    let fell: Vec<&(usize, Vec<Vec<u8>>, bool)> =
        lsp_jobs.iter().filter(|(i, _, _)| !jobs.list[*i].argv.is_empty() && (codes[*i] != 0 || !sys::file_exists(&jobs.list[*i].target))).collect();
    if let (Some(si), true) = (syntax_at, fell.iter().any(|(_, _, by_name)| *by_name)) {
        let mut skip = covered.clone();
        for (_, files, _) in &fell {
            for f in files {
                skip.remove(f);
            }
        }
        let (argv, fp) = syntax_plan(&walk, &mut stamps, repo, out, &swan_bin, &skip);
        let target = jobs.list[si].target.clone();
        // Its manifest line is for what it is run with now.
        let mut manifest: Vec<u8> = Vec::new();
        for line in jobs.index_manifest.split(|&c| c == b'\n').filter(|l| !l.is_empty()) {
            if starts_with(line, b"syntax-index\t") {
                manifest.extend_from_slice(&[&b"syntax-index\t"[..], fp.to_string().as_bytes(), b"\t", &target[..]].concat());
            } else {
                manifest.extend_from_slice(line);
            }
            manifest.push(b'\n');
        }
        jobs.index_manifest = manifest;
        let job = &mut jobs.list[si];
        job.argv = argv;
        job.label = b"syntax-index".to_vec();
        let inner: Vec<&[u8]> = job.argv.iter().map(|a| &a[..]).collect();
        let launch: Vec<Vec<u8>> = if sandbox_on() { seal_argv(&inner, repo, out, trusted) } else { job.argv.clone() };
        let launch: Vec<&[u8]> = launch.iter().map(|a| &a[..]).collect();
        let env: Vec<&[u8]> = job.env.iter().map(|e| &e[..]).collect();
        let log = [out, b"/log-", si.to_string().as_bytes(), b".txt"].concat();
        let before = took[si];
        codes[si] = -999;
        began[si] = std::time::Instant::now();
        match sys::spawn_job(&launch, repo, &env, &log) {
            Ok(pid) => {
                pids[si] = pid;
                running = 1;
                while running > 0 {
                    wait_one(&pids, &mut codes, &began, &mut took, &mut running);
                }
            }
            Err(code) => codes[si] = code,
        }
        took[si] += before;
    }
    for (i, _, by_name) in &fell {
        let then: &[u8] = if *by_name && syntax_at.is_some() { b"its files are mapped by name (syntax index) in this map" } else { b"its files are not mapped" };
        report.extend_from_slice(&[&jobs.list[*i].label[..], b": the language server failed; ", then, b"\n"].concat());
    }

    let mut scips: Vec<Vec<u8>> = Vec::new(); // the index files, for the flattener
    let mut failed: Vec<u8> = Vec::new(); // their index files, one per line
    let mut fresh_scips: Vec<u8> = Vec::new(); // the index files this map's indexers wrote, one per line
    let mut ok = true;
    for (idx, job) in jobs.list.iter().enumerate() {
        let code = codes[idx];
        if !job.label.is_empty() {
            report.extend_from_slice(&job.label);
            report.extend_from_slice(b": ");
            push_int(report, took[idx]);
            report.extend_from_slice(b" ms");
        }
        // What a language server answered, as swan lsp-index counts it.
        if code == 0 && starts_with(&job.label, b"lsp-index ") {
            let mut log: Vec<u8> = Vec::new();
            sys::read_file(&[out, b"/log-", idx.to_string().as_bytes(), b".txt"].concat(), &mut log);
            if let Some(line) = log.split(|&c| c == b'\n').rev().find(|l| starts_with(l, b"lsp-index ")) {
                let from = find(line, b": ").max(0) as usize + 2;
                let to = rfind(line, b", ").max(from as i64) as usize;
                report.extend_from_slice(&[b" (", &line[from.min(to)..to], b")"].concat());
            }
        }
        if code == 0 && sys::file_exists(&job.target) {
            if !job.label.is_empty() {
                fresh_scips.extend_from_slice(&job.target);
                fresh_scips.push(b'\n');
            }
            if !job.base.is_empty() {
                scips.push([&job.target[..], b"=", &job.base[..]].concat());
            } else {
                scips.push(job.target.clone());
            }
        } else {
            if !job.optional {
                ok = false;
            }
            failed.extend_from_slice(&job.target);
            failed.push(b'\n');
            let mut log: Vec<u8> = Vec::new();
            sys::read_file(&[out, b"/log-", idx.to_string().as_bytes(), b".txt"].concat(), &mut log);
            if job.optional {
                report.extend_from_slice(b" not mapped, the map goes on without it");
            }
            report.extend_from_slice(b" (exit ");
            push_int(report, code as i64);
            report.extend_from_slice(b") ");
            report.extend_from_slice(if log.len() > 400 { &log[log.len() - 400..] } else { &log[..] });
        }
        if !job.label.is_empty() {
            report.push(b'\n');
        }
    }
    if clean && !ok {
        report.extend_from_slice(b"clean rebuild failed; previous database retained and reuse metadata invalidated");
        return false;
    }
    // A Python piece whose run failed is not reusable: its old index file
    // no longer matches the fingerprint recorded for it before the run. Nor
    // are TypeScript layers on top of a chunk run that failed: forgetting
    // the shared inputs' fingerprint makes the next map rerun the chunks.
    if find(&failed, b"/index-typescript-") >= 0 {
        sys::delete_file(&[out, b"/typescript-shared.txt"].concat());
    }
    if !failed.is_empty() {
        let mut pieces_kept: Vec<u8> = Vec::new();
        let mut prev_pieces: Vec<u8> = Vec::new();
        sys::read_file(&[out, b"/python-pieces.tsv"].concat(), &mut prev_pieces);
        for line in prev_pieces.split(|&c| c == b'\n') {
            let f = split(line, b'\t');
            if f.len() == 3 && !contains_line(&failed, f[2]) {
                pieces_kept.extend_from_slice(line);
                pieces_kept.push(b'\n');
            }
        }
        if !prev_pieces.is_empty() {
            sys::write_file(&[out, b"/python-pieces.tsv"].concat(), &pieces_kept);
        }
    }
    if scips.is_empty() {
        report.extend_from_slice(b"every indexer failed");
        return false;
    }
    // Remember what each index was made from, failures excepted, and drop
    // index files no job produced or reused.
    let mut kept_index: Vec<u8> = Vec::new();
    for line in jobs.index_manifest.split(|&c| c == b'\n') {
        let f = split(line, b'\t');
        if f.len() == 3 && find(&failed, f[2]) < 0 {
            kept_index.extend_from_slice(line);
            kept_index.push(b'\n');
        }
    }
    cache.write(b"index-manifest.tsv", &kept_index);
    if let Some(listing) = sys::list_dir(out) {
        // Named by a job: anywhere in what it is, writes or is given.
        let named = |p: &[u8]| -> bool {
            jobs.list.iter().any(|j| {
                find(&j.label, p) >= 0 || find(&j.target, p) >= 0 || find(&j.base, p) >= 0 || j.argv.iter().any(|a| find(a, p) >= 0) || j.env.iter().any(|e| find(e, p) >= 0)
            })
        };
        for nm in &listing {
            if starts_with(nm, b"index-") && ends_with(nm, b".scip") && !named(&[out, b"/", &nm[..]].concat()) {
                sys::delete_file(&[out, b"/", &nm[..]].concat());
            }
        }
    }
    let db = [out, b"/swan.db"].concat();
    // Said at the end of every map that indexed Rust: the crates the
    // finished map has no rows for (src/rustproj.rs).
    let rust_gaps = |report: &mut Vec<u8>| {
        if !rust_indexed {
            return;
        }
        let gaps = rust_unmapped(&walk, repo, &db, &rust_dirs);
        if !gaps.is_empty() {
            report.extend_from_slice(&[b"\nrust: no rows for these crates: ", &gaps[..], b" (in no cargo project that was mapped, or their project's run failed)"].concat());
        }
    };
    // Which text each file's rows came from after this map, from the
    // flattener's documents.tsv ("path\t1" when this map's indexers wrote
    // its rows, "\t0" when they were kept from before).
    let mut idx_new: Vec<u8> = Vec::new();
    let note_indexed = |docs: &[u8], idx_new: &mut Vec<u8>| {
        for line in docs.split(|&c| c == b'\n') {
            let f = split(line, b'\t');
            if f.len() != 2 {
                continue;
            }
            let key = hash(f[0]);
            if !stamps.code_memo.contains(&key) {
                continue;
            }
            if f[1] == b"1" {
                if let (Some(&then), Some(&s)) = (stamps.mtime_memo.get(&key), stamps.stamp_memo.get(&key)) {
                    idx_new.extend_from_slice(f[0]);
                    // Changed while the indexers ran: which text they read is unknown.
                    if sys::mtime_ns(&[repo, b"/", f[0]].concat()) == then {
                        idx_new.push(b'\t');
                        idx_new.extend_from_slice(&stamps.raw_text_of(key));
                        idx_new.push(b'\t');
                    } else {
                        idx_new.extend_from_slice(b"\t?\t");
                    }
                    push_int(idx_new, s as i64);
                    idx_new.push(b'\n');
                }
            } else {
                let p = line_of_path(&idx_prev, &idx_at, f[0]);
                if !p.is_empty() {
                    idx_new.extend_from_slice(p);
                    idx_new.push(b'\n');
                }
            }
        }
    };
    // For the flattener: the indexed text of each file whose rows may be kept
    // from before and whose text has changed since ("path\ttext file").
    let kept_texts = || -> Vec<u8> {
        let mut t: Vec<u8> = Vec::new();
        for line in idx_prev.split(|&c| c == b'\n') {
            let f = split(line, b'\t');
            if !(f.len() == 3 && stamps.have_text(f[1])) {
                continue;
            }
            let key = hash(f[0]);
            if !(stamps.code_memo.contains(&key) && stamps.raw_text_of(key) != f[1]) {
                continue;
            }
            t.extend_from_slice(&[f[0], b"\t", &texts_dir[..], b"/t", f[1], b".txt\n"].concat());
        }
        t
    };
    // Once the map is written: moves the rows of each file edited only in
    // comments or layout since its rows were made, to match its text, and
    // saves the records above. `rewritten`: every row was just written from
    // indexer output, so the rows match the indexed texts.
    let finish_cosmetic = |rewritten: bool, idx_new: &[u8], report: &mut Vec<u8>| {
        let Ok(h) = Db::open_existing(&db) else {
            return;
        };
        let mut basis_new: Vec<u8> = Vec::new();
        let mut unknown: HashSet<u64> = HashSet::new();
        let mut moved = 0;
        for line in idx_new.split(|&c| c == b'\n') {
            let f = split(line, b'\t');
            if f.len() != 3 {
                continue;
            }
            let key = hash(f[0]);
            if !stamps.code_memo.contains(&key) {
                continue;
            }
            let full = [repo, b"/", f[0]].concat();
            let raw = stamps.raw_text_of(key);
            let basis: Vec<u8> = if rewritten { f[1].to_vec() } else { rows_basis(f[0], key, &full, f[1]) };
            if basis.is_empty() || basis == raw {
                continue; // the rows already match the text
            }
            let mut old: Vec<u8> = Vec::new();
            let mut cur: Vec<u8> = Vec::new();
            if !(sys::read_file(&full, &mut cur) && (hash(&cur) as i64).to_string().as_bytes() == &raw[..]) {
                continue; // changed again since: stale for now
            }
            if basis != b"?" && sys::read_file(&[&texts_dir[..], b"/t", &basis[..], b".txt"].concat(), &mut old) && shift_cosmetic(&h, f[0], cosmetic_lang(f[0]), &old, &cur) {
                mark_edited(&h, f[0], &full);
                basis_new.extend_from_slice(&[f[0], b"\t", &raw[..], b"\t", sys::mtime_ns(&full).to_string().as_bytes(), b"\n"].concat());
                moved += 1;
            } else {
                unknown.insert(key);
            }
        }
        drop(h);
        if moved > 0 {
            report.extend_from_slice(b"\ncosmetic edits: rows moved to match ");
            push_int(report, moved);
            report.extend_from_slice(b" file(s), no indexer run");
        }
        if !unknown.is_empty() {
            report.extend_from_slice(b"\ncosmetic edits: ");
            push_int(report, unknown.len() as i64);
            report.extend_from_slice(b" file(s) could not be matched; they are reindexed next map");
        }
        // A file whose rows could not be moved is marked unknown: the next map reindexes it.
        let mut idx_out: Vec<u8> = Vec::new();
        for line in idx_new.split(|&c| c == b'\n') {
            let f = split(line, b'\t');
            if f.len() != 3 {
                continue;
            }
            if unknown.contains(&hash(f[0])) {
                idx_out.extend_from_slice(&[f[0], b"\t?\t", f[2], b"\n"].concat());
            } else {
                idx_out.extend_from_slice(line);
                idx_out.push(b'\n');
            }
        }
        if !rewritten {
            let mut updated: HashSet<u64> = HashSet::new();
            for line in basis_new.split(|&c| c == b'\n') {
                let t = find(line, b"\t");
                if t > 0 {
                    updated.insert(hash(&line[..t as usize]));
                }
            }
            for line in basis_prev.split(|&c| c == b'\n') {
                let t = find(line, b"\t");
                if t > 0 && !updated.contains(&hash(&line[..t as usize])) && edited_at.contains_key(&hash(&line[..t as usize])) {
                    basis_new.extend_from_slice(line);
                    basis_new.push(b'\n');
                }
            }
        }
        sys::write_file(&[out, b"/indexed-texts.tsv"].concat(), &idx_out);
        sys::write_file(&[out, b"/row-basis.tsv"].concat(), &basis_new);
        // Kept texts no record names go.
        let mut keep: HashSet<u64> = HashSet::new();
        let mut keep_raw = |r: &[u8]| {
            if !r.is_empty() && r != b"?" {
                keep.insert(hash(&[b"t", r, b".txt"].concat()));
            }
        };
        for line in idx_out.split(|&c| c == b'\n') {
            let f = split(line, b'\t');
            if f.len() == 3 {
                keep_raw(f[1]);
            }
        }
        for line in basis_new.split(|&c| c == b'\n') {
            let f = split(line, b'\t');
            if f.len() == 3 {
                keep_raw(f[1]);
            }
        }
        for &key in &stamps.code_memo {
            keep_raw(&stamps.raw_text_of(key));
        }
        if let Some(names) = sys::list_dir(&texts_dir) {
            for nm in &names {
                if !nm.is_empty() && !keep.contains(&hash(nm)) {
                    sys::delete_file(&[&texts_dir[..], b"/", &nm[..]].concat());
                }
            }
        }
    };
    let said_in_all = |report: &mut Vec<u8>| {
        report.extend_from_slice(b"\nswan map: ");
        push_int(report, t_start.elapsed().as_millis() as i64);
        report.extend_from_slice(b" ms in all");
    };

    sys::write_file(&[out, b"/content-stamps.tsv"].concat(), &stamps.lines);
    let have_rows = sys::file_exists(&db) && sys::file_exists(&[out, b"/occurrences.tsv"].concat());
    if !clean && jobs.reused_all && have_rows {
        // No indexer ran, but files edited only in comments or layout still
        // need their rows moved.
        idx_new.extend_from_slice(&idx_prev);
        finish_cosmetic(false, &idx_new, report);
        // Every file's text is the text its rows were built from: the map is
        // current as of this run, so its reference time moves up to it.
        // Without this a file that was edited and put back (or just
        // touched) stayed "stale" through every later refresh, and edits to
        // it were refused with "refresh first" (found 2026-11-17).
        if n_cosmetic == 0 {
            if let Ok(h) = Db::open_existing(&db) {
                if let Ok(up) = h.prepare(b"UPDATE meta SET value = ?1 WHERE key = 'scip_time'") {
                    up.bind_text(1, scip_time_of(out).to_string().as_bytes());
                    let _ = up.step();
                }
            }
        }
        report.extend_from_slice(if n_cosmetic > 0 { &b"\nno code changed since the last map"[..] } else { b"nothing changed since the last map" });
        rust_gaps(report);
        said_in_all(report);
        return ok;
    }
    // Only failed indexers ran (rea's scip-java fails every map): the index
    // files are the ones the map's rows were flattened from, so flattening
    // them again would write the same rows. flattened-inputs.txt is written
    // after the rows are in the database, and removed before a flatten.
    let scips_packed = packed(&scips);
    let flat_marker = [out, b"/flattened-inputs.txt"].concat();
    let mut flat_prev: Vec<u8> = Vec::new();
    if !clean && fresh_scips.is_empty() && have_rows && sys::read_file(&flat_marker, &mut flat_prev) && flat_prev == scips_packed {
        idx_new.extend_from_slice(&idx_prev);
        finish_cosmetic(false, &idx_new, report);
        report.extend_from_slice(b"\nflatten: skipped (only failed indexers ran; rows as last flattened)");
        rust_gaps(report);
        said_in_all(report);
        report.extend_from_slice(b", up to ");
        push_int(report, limit);
        report.extend_from_slice(b" indexers at once");
        if !ok {
            report.extend_from_slice(b"\n(some indexers failed; see above)");
        }
        return ok;
    }
    sys::delete_file(&flat_marker);

    // The flattener reads some files' text itself (import statements, C
    // bodies, Rust macros): for rows kept from before, the text they were
    // indexed from.
    sys::write_file(&[out, b"/fresh-indexes.txt"].concat(), &fresh_scips);
    sys::write_file(&[out, b"/kept-texts.tsv"].concat(), &kept_texts());
    sys::delete_file(&[out, b"/documents.tsv"].concat());
    // bin/swan-flatten (native/swan-flatten, Rust) flattens the SCIP
    // indexes into rows, a core per index file. It is the only flattener.
    let native_flat = [&home[..], b"/bin/swan-flatten"].concat();
    if !sys::file_exists(&native_flat) {
        report.extend_from_slice(&[b"swan-flatten is missing at ", &native_flat[..], b": rebuild with scripts/build.sh (needs cargo) or reinstall Swan\n"].concat());
        return false;
    }
    let mut fl: Vec<Vec<u8>> = vec![
        native_flat,
        b"--fresh".to_vec(),
        [out, b"/fresh-indexes.txt"].concat(),
        b"--texts".to_vec(),
        [out, b"/kept-texts.tsv"].concat(),
        b"--root".to_vec(),
        repo.to_vec(),
    ];
    // Whatever an indexer found by itself in a folder git ignores is left out.
    if sys::file_size(&[out, b"/git-ignored-all.txt"].concat()) > 0 {
        fl.push(b"--ignored".to_vec());
        fl.push([out, b"/git-ignored-all.txt"].concat());
    }
    fl.push(scips[0].clone());
    fl.push(out.to_vec());
    fl.extend(scips[1..].iter().cloned());
    const ROWS: [&[u8]; 4] = [b"symbols.tsv", b"extents.tsv", b"relationships.tsv", b"occurrences.tsv"];
    if clean {
        for name in ROWS {
            let path = [out, b"/", name].concat();
            if !(!sys::file_exists(&path) || sys::delete_file(&path)) {
                report.extend_from_slice(&[b"cannot remove prior flattened output: ", &path[..]].concat());
                return false;
            }
        }
    }
    let t_flat = std::time::Instant::now();
    {
        let fl: Vec<&[u8]> = fl.iter().map(|a| &a[..]).collect();
        let env = child_env(&l, &[], b"");
        let env: Vec<&[u8]> = env.iter().map(|e| &e[..]).collect();
        let mut o: Vec<u8> = Vec::new();
        if run_step(b"flatten", &fl, &home, &env, 600000, &mut o) != 0 {
            report.extend_from_slice(b"flatten failed");
            return false;
        }
    }
    report.extend_from_slice(b"flatten: ");
    push_int(report, t_flat.elapsed().as_millis() as i64);
    report.extend_from_slice(b" ms\n");
    if clean {
        for name in ROWS {
            if !sys::file_exists(&[out, b"/", name].concat()) {
                report.extend_from_slice(&[b"clean rebuild missing flattened output: ", name, b"; previous database retained"].concat());
                return false;
            }
        }
        if !clean_rows_valid(out, report) {
            return false;
        }
    }
    index_main_locked(out, &db, repo, !clean && sys::file_exists(&db), report);
    sys::write_file(&flat_marker, &scips_packed);
    let mut docs: Vec<u8> = Vec::new();
    sys::read_file(&[out, b"/documents.tsv"].concat(), &mut docs);
    note_indexed(&docs, &mut idx_new);
    finish_cosmetic(true, &idx_new, report);
    if clean {
        for (name, contents) in &cache.pending {
            if !sys::write_file(&[out, b"/", &name[..]].concat(), contents) {
                report.extend_from_slice(&[b"\nwarning: fresh database published but cache could not be saved: ", &name[..]].concat());
            }
        }
    }
    rust_gaps(report);
    said_in_all(report);
    report.extend_from_slice(b", up to ");
    push_int(report, limit);
    report.extend_from_slice(b" indexers at once");
    if !ok {
        report.extend_from_slice(b"\n(some indexers failed; see above)");
    }
    ok
}
