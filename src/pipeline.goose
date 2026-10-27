// Swan running the whole pipeline itself, so one binary maps and checks a
// repo and AYA can ask for either through MCP:
//   swan map <repo> <out-dir>     every SCIP indexer the repo needs, the
//                                 flattener, then index (or refresh)
//   swan check <repo> <out-dir>   each language's checker (tsc, cargo
//                                 check, pyright), loaded as diagnostics
// The repo is only read. Generated configs, build output and the map go
// in out-dir.

import std;
import os;
import json;
import dictionary;
import sqlite;

extern fn swan_realpath(path: const u8[:], out: u8[>..]&) -> bool;

fn abs_path(p: const u8[:]) -> u8[>..] {
    var o: u8[>..] = [];
    if !swan_realpath(p, o) { abort(str("swan: no such path: ", p)); }
    return o;
}

// What a repo holds, found by walking it.
struct Langs {
    ts: bool, js: bool, py: bool, rs: bool, java: bool, c: bool, cuda: bool,
    kt: bool,                   // Kotlin: tree-sitter only for now, no SCIP indexer runs
    tsconfig: bool, cargo: bool, maven: bool, gradle: bool,
    venv: u8[..2048],           // a virtualenv inside the repo, if any
}

let SKIP_DIRS = ["node_modules", ".git", "target", ".venv", "venv", "__pycache__", ".tox",
                 ".mypy_cache", ".pytest_cache", ".swan", "build", ".gradle"];

// F(path, name) for each file under repo, breadth-first, skipping folders
// that hold dependencies, caches or build output.
fn each_file<F>(repo: const u8[:]) {
    var dirs: u8[>..] = [];     // only grows; `next` walks it
    dirs.append(repo);
    dirs.push('\n');
    var next = 0;
    var seen = 0;
    while next < dirs.len && seen < 200000 {
        let end = next + find(dirs[next..], "\n");
        var dir: u8[>..] = [];
        dir.append(dirs[next..end]);
        next = end + 1;
        var names: u8[>..] = [];
        guard list_dir(dir, names) else { continue; }
        each_split(names, '\n') { name =>
            guard name.len > 0;
            seen++;
            var full: u8[>..] = [];
            format(full, dir, "/", name);
            if is_dir(full) {
                if !contains(SKIP_DIRS, name) { dirs.append(full); dirs.push('\n'); }
            } else {
                F(full[..], name);
            }
        };
    }
}

fn detect(repo: const u8[:]) -> Langs {
    var l = Langs { ts: false, js: false, py: false, rs: false, java: false, c: false, cuda: false, kt: false,
                    tsconfig: file_exists(str(repo, "/tsconfig.json")),
                    cargo: file_exists(str(repo, "/Cargo.toml")),
                    maven: file_exists(str(repo, "/pom.xml")),
                    gradle: file_exists(str(repo, "/build.gradle")) || file_exists(str(repo, "/build.gradle.kts")) ||
                            file_exists(str(repo, "/settings.gradle")) || file_exists(str(repo, "/settings.gradle.kts")),
                    .. };
    for v in [".venv", "venv"] {
        if l.venv.len == 0 && file_exists(str(repo, "/", v, "/pyvenv.cfg")) { format(l.venv, repo, "/", v); }
    }
    each_file(repo) { full, name =>
        if ends_with(name, ".ts") || ends_with(name, ".tsx") || ends_with(name, ".mts") || ends_with(name, ".cts") {
            l.ts = true;
        } else if ends_with(name, ".js") || ends_with(name, ".jsx") || ends_with(name, ".mjs") || ends_with(name, ".cjs") {
            l.js = true;
        } else if ends_with(name, ".py") {
            l.py = true;
        } else if ends_with(name, ".rs") {
            l.rs = true;
        } else if ends_with(name, ".java") {
            l.java = true;
        } else if ends_with(name, ".kt") || ends_with(name, ".kts") {
            l.kt = true;
        } else if ends_with(name, ".cu") || ends_with(name, ".cuh") {
            l.cuda = true;
        } else if is_c_source(name) || ends_with(name, ".h") || ends_with(name, ".hpp") || ends_with(name, ".hh") {
            l.c = true;
        }
    };
    return l;
}

fn is_c_source(name: const u8[:]) -> bool {
    ends_with(name, ".c") || ends_with(name, ".cc") || ends_with(name, ".cpp") || ends_with(name, ".cxx")
}

// The CUDA toolkit: $CUDA_PATH, /usr/local/cuda, or the headers-only one
// scripts/fetch-tools.sh assembles in .tools/cuda-sdk from NVIDIA's pip
// wheels (enough to index; nvcc itself is not needed).
fn cuda_path(home: const u8[:]) -> u8[>..] {
    var p: u8[>..] = [];
    if env("CUDA_PATH", p) && p.len > 0 { return p; }
    p.clear();
    if is_dir("/usr/local/cuda/include") { p.append("/usr/local/cuda"); return p; }
    format(p, home, "/.tools/cuda-sdk");
    return p;
}

// A compile_commands.json for repos without one, outside the repo: every C,
// C++ and CUDA source, with the repo root on the include path. CUDA is
// compiled host-side by clang's CUDA mode against cuda_path.
fn write_compdb(repo: const u8[:], home: const u8[:], path: const u8[:]) -> i64 {
    let cuda = cuda_path(home);
    var j: u8[>..] = [];
    j.push('[');
    var n = 0;
    each_file(repo) { full, name =>
        let is_cu = ends_with(name, ".cu");
        if is_cu || is_c_source(name) {
            if n > 0 { j.push(','); }
            n++;
            j.append("{\"directory\":");
            json::format_string(j, repo);
            j.append(",\"file\":");
            json::format_string(j, full);
            j.append(",\"arguments\":[");
            if is_cu {
                j.append("\"clang++\",\"-x\",\"cuda\",");
                json::format_string(j, str("--cuda-path=", cuda));
                j.append(",\"--cuda-gpu-arch=sm_80\",\"--cuda-host-only\",\"-nocudalib\",\"-std=c++17\",");
            } else if ends_with(name, ".c") {
                j.append("\"clang\",\"-std=c11\",");
            } else {
                j.append("\"clang++\",\"-std=c++17\",");
            }
            json::format_string(j, str("-I", repo));
            j.append(",\"-c\",");
            json::format_string(j, full);
            j.append("]}");
        }
    };
    j.append("]\n");
    write_file(path, j);
    return n;
}

// The JDK: $JAVA_HOME, else the one scripts/fetch-tools.sh puts in .tools/jdk.
fn java_home(home: const u8[:]) -> u8[>..] {
    var jh: u8[>..] = [];
    if env("JAVA_HOME", jh) && jh.len > 0 { return jh; }
    jh.clear();
    var names: u8[>..] = [];
    let dir = str(home, "/.tools/jdk");
    if list_dir(dir, names) {
        each_split(names, '\n') { name =>
            if jh.len == 0 && starts_with(name, "jdk-") { format(jh, dir, "/", name); }
        };
    }
    return jh;
}

// The environment children get: a repo virtualenv first on PATH, and room
// for scip-python and pyright on big repos.
fn child_env(l: const Langs&, extra: const u8[:]) -> u8[>..] {
    var vars: u8[>..] = [];
    var path: u8[>..] = [];
    if l.venv.len > 0 { format(path, l.venv, "/bin:"); }
    var jh: u8[>..] = [];
    if l.java || l.kt {
        jh = java_home(swan_home());
        if jh.len > 0 { format(path, jh, "/bin:"); }
    }
    var p0: u8[>..] = [];
    env("PATH", p0);
    if (l.c || l.cuda) && !has_clang(p0) {
        // scip-clang asks `clang++` only where clang's builtin headers are;
        // .tools/llvm has those headers and a stand-in that answers.
        format(path, swan_home(), "/.tools/llvm/bin:");
    }
    path.append(p0);
    var e: u8[>..] = [];
    format(e, "PATH=", path);
    arg(vars, e);
    if l.venv.len > 0 {
        e.clear();
        format(e, "VIRTUAL_ENV=", l.venv);
        arg(vars, e);
    }
    if jh.len > 0 {
        e.clear();
        format(e, "JAVA_HOME=", jh);
        arg(vars, e);
    }
    var heap: u8[>..] = [];
    if !env("SWAN_NODE_HEAP_MB", heap) { heap.append("16000"); }
    e.clear();
    format(e, "NODE_OPTIONS=--max-old-space-size=", heap);
    arg(vars, e);
    vars.append(extra);
    return vars;
}

fn has_clang(path: const u8[:]) -> bool {
    var found = false;
    each_split(path, ':') { d => if !found && file_exists(str(d, "/clang++")) { found = true; } };
    return found;
}

// One more environment entry, for child_env's `extra`.
fn env_entry(k: const u8[:], v: const u8[:]) -> u8[>..] {
    var e: u8[>..] = [];
    format(e, k, "=", v);
    e.push(0);
    return e;
}

fn python_of(l: const Langs&) -> u8[>..] {
    var p: u8[>..] = [];
    if l.venv.len > 0 { format(p, l.venv, "/bin/python"); } else { p.append("python3"); }
    return p;
}

// scip-python asks pip which packages are installed, to name outside symbols
// by package and version. Without pip the same list comes from Python's own
// importlib.metadata, written where --environment can read it.
let PY_ENV_SNIPPET = "import json, importlib.metadata as m\nseen = set()\nout = []\nfor d in m.distributions():\n    n = d.metadata['Name']\n    if not n or n.lower() in seen: continue\n    seen.add(n.lower())\n    out.append({'name': n, 'version': d.version, 'files': [str(f) for f in (d.files or []) if str(f).endswith(('.py', '.pyi'))]})\nprint(json.dumps(out))\n";

extern fn swan_spawn(argv: const u8[:], cwd: const u8[:], env: const u8[:], log: const u8[:]) -> i64;
extern fn swan_wait_any(code: i32&) -> i64;
extern fn swan_file_size(path: const u8[:]) -> i64;
extern fn swan_cpu_count() -> i32;

// How many indexers run at once: $SWAN_JOBS, else half the cores, at most 8
// (scip-python can take several GB each).
fn jobs_limit() -> i64 {
    var v: u8[>..] = [];
    if env("SWAN_JOBS", v) {
        let n, ok = parse_int(v);
        if ok && n > 0 { return n; }
    }
    // Half the cores, at most 8, and no more than the free memory holds at
    // about 3 GB a job (scip-python reached 10 GB on a big repo), so a big
    // map pushes the desktop into swap less.
    var by_mem: i64 = 8;
    var info: u8[>..] = [];
    if read_file("/proc/meminfo", info) {
        each_split(info, '\n') { l =>
            if starts_with(l, "MemAvailable:") {
                let kb, ok = parse_int(trim(trim(l[13..])[..find(trim(l[13..]), " ")]));
                if ok { by_mem = kb / (3 * 1024 * 1024); }
            }
        };
    }
    return max(1, min(min(8, (swan_cpu_count() / 2) as i64), by_mem));
}

// Splits a repo's Python into about k pieces of similar size for parallel
// scip-python runs (--target-only). A folder bigger than its share is split
// into its subfolders, and the .py files directly in it become pieces of
// their own. Returns the pieces, relative to repo, one per line; a single
// empty line means "the whole repo in one run".
fn plan_python(repo: const u8[:], k: i64) -> u8[>..] {
    var files: u8[>..] = [];        // "relative path\n" for every .py
    var sizes: i64[>..] = [];
    each_file(repo) { full, name =>
        if ends_with(name, ".py") {
            files.append(full[repo.len + 1..]);
            files.push('\n');
            sizes.push(max(swan_file_size(full), 1));
        }
    };
    var plan: u8[>..] = [];
    var total = 0;
    for z in sizes { total += z; }
    if k <= 1 || sizes.len < 2 * k { plan.push('\n'); return plan; }
    let paths = split(files[..files.len - 1], '\n');
    let limit = total / k;
    // A directory's size: every .py under it.
    fn size_under(dir: const u8[:]) -> i64 {
        var t = 0;
        for p, i in paths {
            if dir.len == 0 || (starts_with(p, dir) && p.len > dir.len && p[dir.len] == '/') { t += sizes[i]; }
        }
        return t;
    }
    // Subdirectories of dir that hold .py files, and .py files directly in it.
    var queue: u8[>..] = [];
    queue.push('\n');               // the root, as an empty line
    var next = 0;
    while next < queue.len {
        let e = next + find(queue[next..], "\n");
        var dir: u8[>..] = [];
        dir.append(queue[next..e]);
        next = e + 1;
        if size_under(dir) <= limit && dir.len > 0 { plan.append(dir); plan.push('\n'); continue; }
        var subs = dictionary<const u8[:], bool> {};
        for p in paths {
            let inside = dir.len == 0 || (starts_with(p, dir) && p.len > dir.len && p[dir.len] == '/');
            if inside {
                let rest = if dir.len == 0 { p } else { p[dir.len + 1..] };
                let slash = find(rest, "/");
                if slash < 0 {
                    plan.append(p);
                    plan.push('\n');
                } else {
                    let sub = p[..(if dir.len == 0 { 0 } else { dir.len + 1 }) + slash];
                    if !subs.contains(sub) {
                        subs.insert(sub, true);
                        queue.append(sub);
                        queue.push('\n');
                    }
                }
            }
        }
    }
    return plan;
}

// Splits a TypeScript project into k chunks of similar size for parallel
// scip-typescript runs. The files are the ones tsc itself would compile
// (`tsc --listFilesOnly`, so the project's include and exclude hold), less
// node_modules and declaration files, which every chunk gets. Packed
// largest first, each into the lightest chunk. Returns one line per chunk,
// files separated by tabs, and the declaration files as `decls`; nothing
// when one run will do.
fn plan_ts(repo: const u8[:], listing: const u8[:], k: i64, decls: u8[>..]&, refs: u8[>..]&) -> u8[>..] {
    var files: u8[>..] = [];
    var sizes: i64[>..] = [];
    each_split(listing, '\n') { raw =>
        let f = trim(raw);
        if f.len > repo.len && starts_with(f, repo) && f[repo.len] == '/' && find(f, "/node_modules/") < 0 {
            if ends_with(f, ".d.ts") { decls.append(f); decls.push('\n'); }
            else {
                files.append(f); files.push('\n'); sizes.push(max(swan_file_size(f), 1));
                // A file with `/// <reference types=...>` brings ambient types
                // (bun-types' "bun:test", say) to whatever is compiled with it,
                // so every chunk gets it, as it gets the .d.ts files.
                var head: u8[>..] = [];
                if read_file(f, head) && find(head[..min(head.len, 4096)], "/// <reference") >= 0 { refs.append(f); refs.push('\n'); }
            }
        }
    };
    var plan: u8[>..] = [];
    guard k > 1 && sizes.len >= 4 * k else { return plan; }
    let paths = split(files[..files.len - 1], '\n');
    var order: i64[>..] = [];
    for z, i in sizes { order.push(i); }
    sort(order) { a, b => sizes[a] > sizes[b] };
    var load: i64[>..] = [];
    var owner: i64[>..] = [];
    for i in k { load.push(0); }
    for i in paths.len { owner.push(0); }
    for u in order {
        var best = 0;
        for c in k { if load[c] < load[best] { best = c; } }
        load[best] += sizes[u];
        owner[u] = best;
    }
    for c in k {
        var first = true;
        for u in paths.len {
            if owner[u] == c {
                if !first { plan.push('\t'); }
                plan.append(paths[u]);
                first = false;
            }
        }
        if !first { plan.push('\n'); }
    }
    return plan;
}

// "path\tsize\tmtime" for every .py file, in walk order (list_dir sorts).
fn py_stamps(repo: const u8[:]) -> u8[>..] {
    var s: u8[>..] = [];
    each_file(repo) { full, name =>
        if ends_with(name, ".py") {
            format(s, full[repo.len + 1..], "\t", swan_file_size(full), "\t", swan_mtime_ns(full), "\n");
        }
    };
    return s;
}

// One fingerprint for every file with these endings (and the named build
// files at the root): a whole-language index is reused while it is unchanged.
fn lang_fingerprint(repo: const u8[:], endings: const u8[:][:], roots: const u8[:][:]) -> u64 {
    var h: u64 = 0;
    each_file(repo) { full, name =>
        var hit = false;
        for e in endings { if ends_with(name, e) { hit = true; } }
        if hit { h = hash_combine(h, hash(str(full, "\t", swan_file_size(full), "\t", swan_mtime_ns(full)))); }
    };
    for r in roots {
        let p = str(repo, "/", r);
        if file_exists(p) { h = hash_combine(h, hash(str(p, "\t", swan_file_size(p), "\t", swan_mtime_ns(p)))); }
    }
    return h;
}

// Whether two chunk plans (lines of tab-separated files) hold the same files.
fn same_file_set(a: const u8[:], b: const u8[:]) -> bool {
    var x: u8[>..] = [];
    var y: u8[>..] = [];
    each_split(a, '\n') { l => each_split(l, '\t') { f => if f.len > 0 { format(x, f, "\n"); } }; };
    each_split(b, '\n') { l => each_split(l, '\t') { f => if f.len > 0 { format(y, f, "\n"); } }; };
    var xs = split(x, '\n');
    var ys = split(y, '\n');
    guard xs.len == ys.len else { return false; }
    sort(xs) { p, q => compare(p, q) < 0 };
    sort(ys) { p, q => compare(p, q) < 0 };
    for v, i in xs { if v != ys[i] { return false; } }
    return true;
}

fn contains_line_prefix(lines: const u8[:], p: const u8[:]) -> bool {
    var yes = false;
    each_split(lines, '\n') { l => if !yes && starts_with(l, p) { yes = true; } };
    return yes;
}

fn contains_line(lines: const u8[:], s: const u8[:]) -> bool {
    var yes = false;
    each_split(lines, '\n') { l => if !yes && l == s { yes = true; } };
    return yes;
}

fn count_lines(s: const u8[:]) -> i64 {
    var n = 0;
    for c in s { if c == '\n' { n++; } }
    return n;
}

fn in_piece(path: const u8[:], piece: const u8[:]) -> bool {
    piece.len == 0 || path == piece || (starts_with(path, piece) && path.len > piece.len && path[piece.len] == '/')
}

// A piece's fingerprint: the stamps of the files in it.
fn piece_fingerprint(stamps: const u8[:], piece: const u8[:]) -> u64 {
    var h: u64 = 0;
    each_split(stamps, '\n') { line =>
        let tab = find(line, "\t");
        if tab > 0 && in_piece(line[..tab], piece) { h = hash_combine(h, hash(line)); }
    };
    return h;
}

fn piece_has(files: const u8[:], piece: const u8[:]) -> bool {
    var yes = false;
    each_split(files, '\n') { f => if f.len > 0 && in_piece(f, piece) { yes = true; } };
    return yes;
}

// Files to treat as changed: those whose stamp changed, and, from the last
// map, the files that use a symbol defined in one of those. A piece holding
// any of them is indexed again. One line per file.
fn dependents_of_changes(out: const u8[:], stamps: const u8[:], prev: const u8[:]) -> u8[>..] {
    var dirty: u8[>..] = [];
    guard prev.len > 0 else { return dirty; }
    var before = dictionary<const u8[:], const u8[:]> {};
    each_split(prev, '\n') { line => let tab = find(line, "\t"); if tab > 0 { before.insert(line[..tab], line); } };
    var changed: u8[>..] = [];
    var seen = dictionary<const u8[:], bool> {};
    each_split(stamps, '\n') { line =>
        let tab = find(line, "\t");
        if tab > 0 {
            seen.insert(line[..tab], true);
            let old = before.get(line[..tab]);
            if !old || old != line { changed.append(line[..tab]); changed.push('\n'); }
        }
    };
    before.each() { path, line => if !seen.contains(path) { changed.append(path); changed.push('\n'); } };
    dirty.append(changed);
    let db_path = str(out, "/swan.db");
    guard changed.len > 0 && file_exists(db_path) else { return dirty; }
    var err: u8[>..] = [];
    let db = sqlite::open(db_path, err);
    guard db != 0 else { return dirty; }
    let st = prepare_or_die(db, """
        SELECT DISTINCT o.file FROM occurrences o JOIN symbols s ON s.id = o.symbol_id
        WHERE s.def_file = ?1 AND o.file != ?1 AND o.is_def = 0
        """);
    each_split(changed, '\n') { f =>
        guard f.len > 0;
        sqlite::bind_text(st, 1, f);
        while sqlite::step(st, err) == 1 { sqlite::col_text(st, 0, dirty); dirty.push('\n'); }
        sqlite::reset(st);
    };
    sqlite::finalize(st);
    sqlite::close(db);
    return dirty;
}

fn map_main(repo_arg: const u8[:], out_arg: const u8[:], report: u8[>..]&) -> bool {
    let t_start = clock();
    let repo = abs_path(repo_arg);
    var mk: u8[>..] = [];
    arg(mk, "mkdir");
    arg(mk, "-p");
    arg(mk, out_arg);
    var ignored: u8[>..] = [];
    run_step("mkdir", mk, "", "", 10000, ignored);
    let out = abs_path(out_arg);
    let home = swan_home();
    let bin = str(home, "/tools/node_modules/.bin/");
    let l = detect(repo);
    format(report, "languages:", if l.ts { " typescript" } else { "" }, if l.js { " javascript" } else { "" },
           if l.java { " java" } else { "" }, if l.c { " c/c++" } else { "" }, if l.cuda { " cuda" } else { "" },
           if l.py { " python" } else { "" }, if l.rs || l.cargo { " rust" } else { "" }, if l.kt { " kotlin" } else { "" },
           if l.venv.len > 0 { str(" (venv ", l.venv, ")") } else { str("") }, "\n");
    // A map from an older Swan is rebuilt from scratch, indexers included:
    // reusing their output would skip what the new schema needs.
    let old_db = str(out, "/swan.db");
    if file_exists(old_db) {
        var e: u8[>..] = [];
        let h = sqlite::open(old_db, e);
        var v: u8[>..] = [];
        if h != 0 { meta_value(h, "schema_version", v); sqlite::close(h); }
        if v != str(SCHEMA_VERSION) {
            format(report, "map schema ", if v.len > 0 { v[..] } else { "?" }, " is older than ", SCHEMA_VERSION, ": rebuilding\n");
            for f in ["/swan.db", "/index-manifest.tsv", "/python-pieces.tsv", "/python-files.tsv"] { delete_file(str(out, f)); }
        }
    }
    // Edits after this moment make answers stale (src/fresh.goose).
    write_file(str(out, "/scip-started"), "");

    // The jobs, each "label \x01 index file \x01 argv \x01 env \x01 base",
    // separated by \x02. base is the folder the job's document paths are
    // relative to, when that is not the repo (scip-python --target-only).
    var jobs: u8[>..] = [];
    var prev_index: u8[>..] = [];
    read_file(str(out, "/index-manifest.tsv"), prev_index);
    var index_manifest: u8[>..] = [];
    var reused_all = true;
    fn add_job(label: const u8[:], target: const u8[:], a: const u8[:], e: const u8[:], base: const u8[:]) {
        if label.len > 0 { reused_all = false; }
        jobs.append(label); jobs.push(1);
        jobs.append(target); jobs.push(1);
        jobs.append(a); jobs.push(1);
        jobs.append(e); jobs.push(1);
        jobs.append(base); jobs.push(2);
    }
    // A whole-language job, unless its files have the fingerprint they had
    // when its index was made.
    fn add_lang_job(label: const u8[:], target: const u8[:], a: const u8[:], e: const u8[:], fp: u64) {
        let fps = str(fp);
        var hit = false;
        each_split(prev_index, '\n') { line =>
            let f = split(line, '\t');
            if f.len == 3 && f[0] == label && f[1] == fps && f[2] == target && file_exists(target) { hit = true; }
        };
        format(index_manifest, label, "\t", fps, "\t", target, "\n");
        if hit {
            format(report, label, ": reused (no changes)\n");
            add_job("", target, "", "", "");
        } else {
            add_job(label, target, a, e, "");
        }
    }

    if l.tsconfig || l.ts || l.js {
        let target = str(out, "/index-typescript.scip");
        var a: u8[>..] = [];
        arg(a, str(bin, "scip-typescript"));
        arg(a, "index");
        arg(a, "--output");
        arg(a, target);
        if !l.tsconfig {
            // A tsconfig of our own, outside the repo; allowJs takes in .js/.mjs/.cjs.
            let dir = str(out, "/tsproject");
            make_dir(dir);
            var cfg: u8[>..] = [];
            cfg.append("{\"compilerOptions\":{\"allowJs\":true,\"checkJs\":false,\"noEmit\":true,");
            cfg.append("\"module\":\"esnext\",\"moduleResolution\":\"bundler\",\"target\":\"es2022\"},\"include\":[");
            json::format_string(cfg, str(repo, "/**/*"));
            cfg.append("],\"exclude\":[");
            json::format_string(cfg, str(repo, "/**/node_modules"));
            cfg.append("]}\n");
            write_file(str(dir, "/tsconfig.json"), cfg);
            arg(a, "--cwd");
            arg(a, repo);
            arg(a, dir);
        }
        let ts_fp = lang_fingerprint(repo, [".ts", ".tsx", ".mts", ".cts", ".js", ".jsx", ".mjs", ".cjs"], ["tsconfig.json", "package.json"]);
        // What tsc would compile, to split it.
        let base: u8[>..] = if l.tsconfig { str(repo, "/tsconfig.json") } else { str(out, "/tsproject/tsconfig.json") };
        var la: u8[>..] = [];
        arg(la, str(bin, "tsc"));
        arg(la, "-p");
        arg(la, base);
        arg(la, "--listFilesOnly");
        // Split only into the slots other languages leave free: chunks cost
        // more work in all (each loads the shared code), so they pay only
        // when TypeScript is the long pole.
        let others = (if l.py { count_lines(plan_python(repo, min(jobs_limit(), 6))) } else { 0 }) +
                     (if l.cargo { 1 } else { 0 }) + (if l.java { 1 } else { 0 }) + (if l.c || l.cuda { 1 } else { 0 });
        let ts_k = jobs_limit() - others;
        // tsc's list changes only when files come or go or the config
        // changes, so it is kept with a key of those and asked again only then.
        var names_key: u64 = 0;
        each_file(repo) { full, name =>
            for e in [".ts", ".tsx", ".mts", ".cts", ".js", ".jsx", ".mjs", ".cjs"] {
                if ends_with(name, e) { names_key = hash_combine(names_key, hash(full)); }
            }
        };
        for r in ["tsconfig.json", "package.json"] {
            let pth = str(repo, "/", r);
            if file_exists(pth) { names_key = hash_combine(names_key, hash(str(pth, "\t", swan_file_size(pth), "\t", swan_mtime_ns(pth)))); }
        }
        var listing: u8[>..] = [];
        var cached: u8[>..] = [];
        read_file(str(out, "/tsc-files.txt"), cached);
        let key_line = str(names_key, "\n");
        var listed = false;
        if ts_k >= 2 && starts_with(cached, key_line) {
            listing.append(cached[key_line.len..]);
            listed = true;
        } else if ts_k >= 2 && run_step("tsc --listFilesOnly", la, repo, child_env(l, ""), 600000, listing) == 0 {
            listed = true;
            write_file(str(out, "/tsc-files.txt"), str(key_line, listing));
        }
        var decls: u8[>..] = [];
        var refs: u8[>..] = [];
        var chunks: u8[>..] = if listed { plan_ts(repo, listing, ts_k, decls, refs) } else { str("") };
        // Keep the last map's chunks while the set of files is the same, so
        // that an edit reruns only the chunks it touches (sizes moving files
        // between chunks would rerun them all).
        var same_plan = false;
        if chunks.len > 0 {
            var prev_plan: u8[>..] = [];
            read_file(str(out, "/typescript-chunks.txt"), prev_plan);
            if prev_plan.len > 0 && same_file_set(prev_plan, chunks) { chunks.clear(); chunks.append(prev_plan); same_plan = true; }
            write_file(str(out, "/typescript-chunks.txt"), chunks);
        }
        if chunks.len == 0 {
            add_lang_job("scip-typescript", target, a, child_env(l, ""), ts_fp);
        } else {
            // Each chunk extends the project's tsconfig (or Swan's own) with its
            // own include list, plus every .d.ts, since declarations such as
            // module augmentations shape how the chunk's code resolves.
            //
            // Reuse, as for Python pieces: a chunk whose files, the shared
            // declarations and the config are unchanged, and none of whose
            // files use a symbol defined in a changed file (by the last map),
            // keeps its last index.
            var stamps: u8[>..] = [];
            var shared: u64 = 0;
            for r in ["tsconfig.json", "package.json"] {
                let pth = str(repo, "/", r);
                if file_exists(pth) { shared = hash_combine(shared, hash(str(r, "\t", swan_file_size(pth), "\t", swan_mtime_ns(pth)))); }
            }
            shared = hash_combine(shared, hash(base));
            each_split(decls, '\n') { f =>
                if f.len > repo.len {
                    let st = str(f[repo.len + 1..], "\t", swan_file_size(f), "\t", swan_mtime_ns(f));
                    shared = hash_combine(shared, hash(st));
                    format(stamps, st, "\n");
                }
            };
            each_split(chunks, '\n') { chunk => each_split(chunk, '\t') { f =>
                if f.len > repo.len { format(stamps, f[repo.len + 1..], "\t", swan_file_size(f), "\t", swan_mtime_ns(f), "\n"); }
            }; };
            // Layers index changed files against the last map's view of
            // everything else, so they are only used while the shared inputs
            // (config, package.json, declarations) are what they were.
            var prev_shared: u8[>..] = [];
            read_file(str(out, "/typescript-shared.txt"), prev_shared);
            let same_shared = prev_shared == str(shared);
            write_file(str(out, "/typescript-shared.txt"), str(shared));
            var prev_stamps: u8[>..] = [];
            read_file(str(out, "/typescript-files.tsv"), prev_stamps);
            let dirty = dependents_of_changes(out, stamps, prev_stamps);
            write_file(str(out, "/typescript-files.tsv"), stamps);
            // A small edit: rather than rerun whole chunks (each loads the
            // shared code, about 7 s on AEON), index just the changed files
            // and their users as a run of their own, a layer. Layers are
            // listed newest first, before the chunks, and the flattener keeps
            // the first rows it sees for a file, so the newest wins. Earlier
            // layers are kept as they are. When the layers cover more than a
            // quarter of the files, or there are more than 6, the chunks run
            // again and the layers go.
            var prev_layers: u8[>..] = [];       // "id\tfile,file,..." per line, newest first
            read_file(str(out, "/typescript-layers.txt"), prev_layers);
            var nfiles = count_lines(stamps);
            var fresh: u8[>..] = [];             // this map's changed files and their users
            each_split(dirty, '\n') { rel =>
                if rel.len > 0 && !contains_line(fresh, rel) && !ends_with(rel, ".d.ts") &&
                   contains_line_prefix(stamps, str(rel, "\t")) { format(fresh, rel, "\n"); }
            };
            var covered: u8[>..] = [];
            each_split(fresh, '\n') { f => if f.len > 0 { format(covered, f, "\n"); } };
            var next_id: i64 = 0;
            var nlayers = 0;
            each_split(prev_layers, '\n') { line =>
                let tab = find(line, "\t");
                if tab > 0 {
                    nlayers++;
                    let id, ok = parse_int(line[..tab]);
                    if ok && id >= next_id { next_id = id + 1; }
                    each_split(line[tab + 1..], ',') { f => if f.len > 0 && !contains_line(covered, f) { format(covered, f, "\n"); } };
                }
            };
            var chunk_files_present = true;
            for c in count_lines(chunks) { if !file_exists(str(out, "/index-typescript-", c, ".scip")) { chunk_files_present = false; } }
            var layers_present = true;
            each_split(prev_layers, '\n') { line =>
                let tab = find(line, "\t");
                if tab > 0 && !file_exists(str(out, "/index-typescript-layer-", line[..tab], ".scip")) { layers_present = false; }
            };
            let use_delta = same_plan && same_shared && chunk_files_present && layers_present && covered.len > 0 &&
                            count_lines(covered) * 4 <= nfiles && nlayers + (if fresh.len > 0 { 1 } else { 0 }) <= 6;
            if use_delta {
                var layers: u8[>..] = [];
                if fresh.len > 0 {
                    let dir = str(out, "/tsproject-layer");
                    make_dir(dir);
                    var cfg: u8[>..] = [];
                    cfg.append("{\"extends\":");
                    json::format_string(cfg, base);
                    cfg.append(",\"include\":[],\"files\":[");
                    var first = true;
                    each_split(fresh, '\n') { f => if f.len > 0 { if !first { cfg.push(','); } json::format_string(cfg, str(repo, "/", f)); first = false; } };
                    each_split(decls, '\n') { f => if f.len > 0 { cfg.push(','); json::format_string(cfg, f); } };
                    each_split(refs, '\n') { f => if f.len > 0 && !contains_line(fresh, f[repo.len + 1..]) { cfg.push(','); json::format_string(cfg, f); } };
                    cfg.append("]}\n");
                    write_file(str(dir, "/tsconfig.json"), cfg);
                    let t = str(out, "/index-typescript-layer-", next_id, ".scip");
                    var da: u8[>..] = [];
                    arg(da, str(bin, "scip-typescript"));
                    arg(da, "index");
                    arg(da, "--output");
                    arg(da, t);
                    arg(da, "--cwd");
                    arg(da, repo);
                    arg(da, dir);
                    add_job(str("scip-typescript changed files (", count_lines(fresh), ")"), t, da, child_env(l, ""), "");
                    format(layers, next_id, "\t");
                    var firstf = true;
                    each_split(fresh, '\n') { f => if f.len > 0 { if !firstf { layers.push(','); } layers.append(f); firstf = false; } };
                    layers.push('\n');
                }
                each_split(prev_layers, '\n') { line =>
                    let tab = find(line, "\t");
                    if tab > 0 {
                        add_job("", str(out, "/index-typescript-layer-", line[..tab], ".scip"), "", "", "");
                        format(layers, line, "\n");
                    }
                };
                write_file(str(out, "/typescript-layers.txt"), layers);
            } else {
                write_file(str(out, "/typescript-layers.txt"), "");
            }
            var n = 0;
            each_split(chunks[..chunks.len - 1], '\n') { chunk =>
                let dir = str(out, "/tsproject-", n);
                make_dir(dir);
                var cfg: u8[>..] = [];
                cfg.append("{\"extends\":");
                json::format_string(cfg, base);
                // "files" overrides the base's include: exactly this chunk, plus
                // the project's own declaration files.
                cfg.append(",\"include\":[],\"files\":[");
                var first = true;
                each_split(chunk, '\t') { f => if !first { cfg.push(','); } json::format_string(cfg, f); first = false; };
                each_split(decls, '\n') { f => if f.len > 0 { cfg.push(','); json::format_string(cfg, f); } };
                each_split(refs, '\n') { f => if f.len > 0 && find(chunk, f) < 0 { cfg.push(','); json::format_string(cfg, f); } };
                cfg.append("]}\n");
                write_file(str(dir, "/tsconfig.json"), cfg);
                let t = str(out, "/index-typescript-", n, ".scip");
                var ca: u8[>..] = [];
                arg(ca, str(bin, "scip-typescript"));
                arg(ca, "index");
                arg(ca, "--output");
                arg(ca, t);
                arg(ca, "--cwd");
                arg(ca, repo);
                arg(ca, dir);
                var fp = shared;
                var touched = false;
                each_split(chunk, '\t') { f =>
                    if f.len > repo.len {
                        let rel = f[repo.len + 1..];
                        fp = hash_combine(fp, hash(str(rel, "\t", swan_file_size(f), "\t", swan_mtime_ns(f))));
                        if !touched && contains_line(dirty, rel) { touched = true; }
                    }
                };
                // A chunk a changed file's users fall in counts as changed.
                if touched { fp = hash_combine(fp, hash(str(clock()))); }
                if use_delta {
                    // Kept as it is; the changed-files run covers what moved. Its
                    // manifest line can never match, so a later full run redoes it.
                    format(index_manifest, "scip-typescript ", n, "/", count_lines(chunks), "\tstale\t", t, "\n");
                    add_job("", t, "", "", "");
                } else {
                    add_lang_job(str("scip-typescript ", n, "/", count_lines(chunks)), t, ca, child_env(l, ""), fp);
                }
                n++;
            };
        }
    }

    if l.py {
        let python = python_of(l);
        var env_args: u8[>..] = [];
        var probe: u8[>..] = [];
        arg(probe, python);
        arg(probe, "-m");
        arg(probe, "pip");
        arg(probe, "--version");
        var o: u8[>..] = [];
        var e: u8[>..] = [];
        if swan_run(probe, repo, child_env(l, ""), 30000, o, e) != 0 {
            var p: u8[>..] = [];
            arg(p, python);
            arg(p, "-c");
            arg(p, PY_ENV_SNIPPET);
            var listing: u8[>..] = [];
            let env_file = str(out, "/python-env.json");
            if run_step("python packages (importlib.metadata)", p, repo, child_env(l, ""), 60000, listing) == 0 {
                write_file(env_file, listing);
            } else {
                write_file(env_file, "[]");
            }
            arg(env_args, "--environment");
            arg(env_args, env_file);
        }
        let slash = rfind(repo, "/");
        let pieces = plan_python(repo, min(jobs_limit(), 6));
        let stamps = py_stamps(repo);
        fn add_python_job(piece: const u8[:], target: const u8[:]) {
            var a: u8[>..] = [];
            arg(a, str(bin, "scip-python"));
            arg(a, "index");
            arg(a, ".");
            arg(a, "--quiet");
            arg(a, "--project-name");
            arg(a, repo[slash + 1..]);
            arg(a, "--project-version");
            arg(a, "0");
            arg(a, "--output");
            arg(a, target);
            if piece.len > 0 { arg(a, "--target-only"); arg(a, piece); }
            a.append(env_args);
            let label: u8[>..] = if piece.len > 0 { str("scip-python ", piece) } else { str("scip-python") };
            add_job(label, target, a, child_env(l, ""), piece);
        }

        // Reuse: a piece whose files are unchanged since the last map, and
        // none of whose files use a symbol defined in a changed file, keeps
        // its last index. Each file is stamped by size and mtime.
        var prev_stamps: u8[>..] = [];
        read_file(str(out, "/python-files.tsv"), prev_stamps);
        var prev_manifest: u8[>..] = [];
        read_file(str(out, "/python-pieces.tsv"), prev_manifest);
        var dirty = dependents_of_changes(out, stamps, prev_stamps);
        write_file(str(out, "/python-files.tsv"), stamps);
        var manifest: u8[>..] = [];
        var reused = 0;
        each_split(pieces[..pieces.len - 1], '\n') { piece =>
            let fp = str(piece_fingerprint(stamps, piece));
            let target = str(out, "/index-python-", hash(piece), ".scip");
            var hit = false;
            each_split(prev_manifest, '\n') { line =>
                let f = split(line, '\t');
                if f.len == 3 && f[0] == piece && f[1] == fp && file_exists(f[2]) { hit = true; }
            };
            if hit && !piece_has(dirty, piece) {
                reused++;
                add_job("", target, "", "", piece);      // already done: no argv
            } else {
                add_python_job(piece, target);
            }
            format(manifest, piece, "\t", fp, "\t", target, "\n");
        };
        write_file(str(out, "/python-pieces.tsv"), manifest);
        if reused > 0 { format(report, "python: ", reused, " pieces reused\n"); }
        // Index files of pieces no longer in the plan go.
        var old2: u8[>..] = [];
        if list_dir(out, old2) {
            each_split(old2, '\n') { nm =>
                if starts_with(nm, "index-python-") && find(manifest, str(out, "/", nm)) < 0 { delete_file(str(out, "/", nm)); }
            };
        }
    }

    if l.cargo {
        let target = str(out, "/index-rust.scip");
        var a: u8[>..] = [];
        arg(a, str(home, "/.tools/rust-analyzer/rust-analyzer"));
        arg(a, "scip");
        arg(a, ".");
        arg(a, "--output");
        arg(a, target);
        add_lang_job("rust-analyzer scip", target, a, child_env(l, env_entry("CARGO_TARGET_DIR", str(out, "/cargo-target"))),
                     lang_fingerprint(repo, [".rs"], ["Cargo.toml", "Cargo.lock"]));
    }

    // scip-java indexes Java, and Kotlin built with Gradle (its compiler
    // plugin follows the current Kotlin, 2.4 as of scip-java 0.13.2).
    if l.java || (l.kt && l.gradle) {
        let target = str(out, "/index-java.scip");
        var a: u8[>..] = [];
        arg(a, str(home, "/.tools/scip-java/scip-java"));
        arg(a, "index");
        arg(a, str("--output=", target));
        arg(a, str("--targetroot=", out, "/java-targetroot"));
        if !l.maven && !l.gradle {
            // No build tool: scip-java compiles the sources itself from a config
            // of our own, outside the repo. Without one, dependencies are unknown.
            let cfg = str(out, "/scip-java.json");
            write_file(cfg, "{\"dependencies\":[],\"jvm\":\"21\"}\n");
            arg(a, str("--scip-config=", cfg));
        }
        var genv: u8[>..] = [];
        if l.gradle {
            // The build runs with Swan's Gradle home and, for Android, Swan's
            // SDK. scip-java's init script cannot run with the configuration
            // cache or isolated projects, which newer builds turn on. Note
            // its `clean`: the repo's build/ output is rebuilt.
            arg(a, "--");
            arg(a, "-Dorg.gradle.configuration-cache=false");
            arg(a, "-Dorg.gradle.isolated-projects=false");
            arg(a, "-Dorg.gradle.jvmargs=-Xmx3g");
            arg(a, "-Dkotlin.daemon.jvmargs=-Xmx3g");
            for t in ["clean", "scipPrintDependencies", "scipCompileAll"] { arg(a, t); }
            genv.append(env_entry("GRADLE_USER_HOME", str(home, "/.tools/gradle-home")));
            let sdk = str(home, "/.tools/android-sdk");
            if file_exists(str(sdk, "/licenses/android-sdk-license")) {
                genv.append(env_entry("ANDROID_HOME", sdk));
                genv.append(env_entry("ANDROID_SDK_ROOT", sdk));
            }
        }
        add_lang_job("scip-java", target, a, child_env(l, genv),
                     lang_fingerprint(repo, [".java", ".kt", ".kts"], ["pom.xml", "build.gradle", "build.gradle.kts",
                                                                       "settings.gradle", "settings.gradle.kts"]));
    }

    if l.c || l.cuda {
        let target = str(out, "/index-cxx.scip");
        var compdb: u8[>..] = [];
        if file_exists(str(repo, "/compile_commands.json")) { format(compdb, repo, "/compile_commands.json"); }
        else if file_exists(str(repo, "/build/compile_commands.json")) { format(compdb, repo, "/build/compile_commands.json"); }
        else {
            format(compdb, out, "/compile_commands.json");
            write_compdb(repo, home, compdb);
        }
        var a: u8[>..] = [];
        arg(a, str(home, "/.tools/scip-clang/scip-clang"));
        arg(a, str("--compdb-path=", compdb));
        arg(a, str("--index-output-path=", target));
        add_lang_job("scip-clang", target, a, child_env(l, ""),
                     lang_fingerprint(repo, [".c", ".cc", ".cpp", ".cxx", ".h", ".hpp", ".hh", ".cu", ".cuh"],
                                      ["compile_commands.json", "build/compile_commands.json"]));
    }

    if jobs.len == 0 && l.kt {
        // Nothing to index, but Kotlin can still be searched by structure:
        // an empty map records the repo for search_pattern and the rest.
        for t in ["symbols.tsv", "extents.tsv", "relationships.tsv", "occurrences.tsv"] { write_file(str(out, "/", t), ""); }
        index_main(out, str(out, "/swan.db"), repo, false, report);
        format(report, "\nkotlin: no SCIP indexer runs yet; search_pattern and rewrite_pattern work on .kt files");
        format(report, "\nswan map: ", ((clock() - t_start) * 1000.0) as i64, " ms in all");
        return true;
    }
    guard jobs.len > 0 else { format(report, "no language found to index in ", repo); return false; }

    // Run them, at most jobs_limit() at a time.
    let limit = jobs_limit();
    var pids: i64[>..] = [];
    var codes: i64[>..] = [];
    var began: f64[>..] = [];
    var took: f64[>..] = [];
    var running = 0;
    fn wait_one() {
        var code: i32 = 0;
        let pid = swan_wait_any(code);
        guard pid > 0 else { running = 0; return; }
        for q, k in pids {
            if q == pid && codes[k] == -999 { codes[k] = code; took[k] = clock() - began[k]; running--; }
        }
    }
    let all_jobs = split(jobs[..jobs.len - 1], 2);
    var order: i64[>..] = [];
    for i in all_jobs.len { order.push(i); }
    for i in all_jobs.len { pids.push(0); codes.push(0); began.push(0.0); took.push(0.0); }
    for idx in order {
        let f = split(all_jobs[idx], 1);
        if f[2].len == 0 {
            // reused from the last map: nothing to run
        } else {
            while running >= limit { wait_one(); }
            pids[idx] = swan_spawn(f[2], repo, f[3], str(out, "/log-", idx, ".txt"));
            codes[idx] = -999;
            began[idx] = clock();
            if pids[idx] > 0 { running++; } else { codes[idx] = -1; }
        }
    }
    while running > 0 { wait_one(); }

    var scips: u8[>..] = [];      // NUL-separated index files, for the flattener
    var failed: u8[>..] = [];     // their index files, one per line
    var ok = true;
    var idx = 0;
    each_split(jobs[..jobs.len - 1], 2) { job =>
        let f = split(job, 1);
        let code = codes[idx];
        if f[0].len > 0 { format(report, f[0], ": ", (took[idx] * 1000.0) as i64, " ms"); }
        if code == 0 && file_exists(f[1]) {
            if f[4].len > 0 { arg(scips, str(f[1], "=", f[4])); } else { arg(scips, f[1]); }
        } else {
            ok = false;
            failed.append(f[1]);
            failed.push('\n');
            var log: u8[>..] = [];
            read_file(str(out, "/log-", idx, ".txt"), log);
            format(report, " (exit ", code, ") ", if log.len > 400 { log[log.len - 400..] } else { log[..] });
        }
        if f[0].len > 0 { report.push('\n'); }
        idx++;
    };
    // A Python piece whose run failed is not reusable: its old index file
    // no longer matches the fingerprint recorded for it before the run. Nor
    // are TypeScript layers on top of a chunk run that failed: forgetting
    // the shared inputs' fingerprint makes the next map rerun the chunks.
    if find(failed, "/index-typescript-") >= 0 { delete_file(str(out, "/typescript-shared.txt")); }
    if failed.len > 0 {
        var pieces_kept: u8[>..] = [];
        var prev_pieces: u8[>..] = [];
        read_file(str(out, "/python-pieces.tsv"), prev_pieces);
        each_split(prev_pieces, '\n') { line =>
            let f = split(line, '\t');
            if f.len == 3 && !contains_line(failed, f[2]) { pieces_kept.append(line); pieces_kept.push('\n'); }
        };
        if prev_pieces.len > 0 { write_file(str(out, "/python-pieces.tsv"), pieces_kept); }
    }
    guard scips.len > 0 else { format(report, "every indexer failed"); return false; }
    // Remember what each index was made from, failures excepted, and drop
    // index files no job produced or reused.
    var kept_index: u8[>..] = [];
    each_split(index_manifest, '\n') { line =>
        let f = split(line, '\t');
        if f.len == 3 && find(failed, f[2]) < 0 { kept_index.append(line); kept_index.push('\n'); }
    };
    write_file(str(out, "/index-manifest.tsv"), kept_index);
    var listing: u8[>..] = [];
    if list_dir(out, listing) {
        each_split(listing, '\n') { nm =>
            if starts_with(nm, "index-") && ends_with(nm, ".scip") && find(jobs, str(out, "/", nm)) < 0 {
                delete_file(str(out, "/", nm));
            }
        };
    }
    let db = str(out, "/swan.db");
    if reused_all && file_exists(db) && file_exists(str(out, "/occurrences.tsv")) {
        format(report, "nothing changed since the last map\nswan map: ", ((clock() - t_start) * 1000.0) as i64, " ms in all");
        return ok;
    }

    var fl: u8[>..] = [];
    arg(fl, "bun");
    arg(fl, str(home, "/tools/scip-flatten.ts"));
    arg(fl, "--root");
    arg(fl, repo);
    let parts = split(scips[..scips.len - 1], 0);
    arg(fl, parts[0]);
    arg(fl, out);
    for k in 1..parts.len { arg(fl, parts[k]); }
    var o: u8[>..] = [];
    let t_flat = clock();
    guard run_step("flatten", fl, home, "", 600000, o) == 0 else { format(report, "flatten failed"); return false; }
    format(report, "flatten: ", ((clock() - t_flat) * 1000.0) as i64, " ms\n");
    index_main(out, db, repo, file_exists(db), report);
    format(report, "\nswan map: ", ((clock() - t_start) * 1000.0) as i64, " ms in all, up to ", limit, " indexers at once");
    if !ok { report.append("\n(some indexers failed; see above)"); }
    return ok;
}

// ---- Checkers -----------------------------------------------------------

// A TSV field: tabs and newlines folded to spaces.
fn put_field(row: u8[>..]&, s: const u8[:]) {
    for c in s { row.push(if c == '\t' || c == '\n' || c == '\r' { ' ' } else { c }); }
}

fn put_row(rows: u8[>..]&, file: const u8[:], l: i64, c: i64, el: i64, ec: i64, sev: const u8[:],
           source: const u8[:], code: const u8[:], msg: const u8[:]) {
    put_field(rows, file);
    format(rows, "\t", l, "\t", c, "\t", el, "\t", ec, "\t");
    put_field(rows, sev);
    rows.push('\t');
    put_field(rows, source);
    rows.push('\t');
    put_field(rows, code);
    rows.push('\t');
    put_field(rows, if msg.len > 500 { msg[..500] } else { msg });
    rows.push('\n');
}

fn relative_to(repo: const u8[:], file: const u8[:]) -> const u8[:] {
    if starts_with(file, repo) && file.len > repo.len && file[repo.len] == '/' { return file[repo.len + 1..]; }
    return file;
}

// tsc --pretty false: `file(line,col): error TS2554: message`
fn parse_tsc(text: const u8[:], rows: u8[>..]&) -> i64 {
    var n = 0;
    each_split(text, '\n') { line =>
        let lp = find(line, "(");
        let rp = find(line, "): ");
        guard lp > 0 && rp > lp;
        let coords = split(line[lp + 1..rp], ',');
        guard coords.len == 2;
        let ln, ok1 = parse_int(coords[0]);
        let cn, ok2 = parse_int(coords[1]);
        guard ok1 && ok2;
        let rest = line[rp + 3..];
        let sp = find(rest, " ");
        let colon = find(rest, ": ");
        guard sp > 0 && colon > sp;
        let sev = rest[..sp];
        put_row(rows, line[..lp], ln - 1, cn - 1, ln - 1, cn - 1, if sev == "message" { "info" } else { sev },
                "tsc", rest[sp + 1..colon], rest[colon + 2..]);
        n++;
    };
    return n;
}

// cargo check --message-format=json: one JSON object per line.
fn parse_cargo(text: const u8[:], repo: const u8[:], rows: u8[>..]&, source: const u8[:] = "cargo") -> i64 {
    var n = 0;
    each_split(text, '\n') { line =>
        guard line.len > 0 && line[0] == '{';
        var doc: json::Node[>..] = [];
        var decoded: u8[>..] = [];
        let root, perr = json::parse(line, doc, decoded);
        guard root;
        let reason, r_ok = json::as_string(json::member(root, "reason"));
        guard r_ok && reason == "compiler-message";
        let msg = json::member(root, "message");
        let level, l_ok = json::as_string(json::member(msg, "level"));
        guard l_ok && (level == "error" || level == "warning");
        let text_, t_ok = json::as_string(json::member(msg, "message"));
        let code, c_ok = json::as_string(json::member(json::member(msg, "code"), "code"));
        let spans = json::member(msg, "spans");
        guard spans;
        json::each(spans) { sp =>
            let primary, p_ok = json::as_bool(json::member(sp, "is_primary"));
            if p_ok && primary {
                let file, f_ok = json::as_string(json::member(sp, "file_name"));
                let ls, a1 = json::as_i64(json::member(sp, "line_start"));
                let cs, a2 = json::as_i64(json::member(sp, "column_start"));
                let le, a3 = json::as_i64(json::member(sp, "line_end"));
                let ce, a4 = json::as_i64(json::member(sp, "column_end"));
                if f_ok && a1 && a2 && a3 && a4 && (!starts_with(file, "/") || starts_with(file, repo)) {
                    put_row(rows, relative_to(repo, file), ls - 1, cs - 1, le - 1, ce - 1, level, source,
                            if c_ok { code } else { "" }, if t_ok { text_ } else { "" });
                    n++;
                }
            }
        };
        assert(perr.len >= 0);
    };
    return n;
}

// pyright --outputjson: generalDiagnostics with absolute paths.
fn parse_pyright(text: const u8[:], repo: const u8[:], rows: u8[>..]&) -> i64 {
    var doc: json::Node[>..] = [];
    var decoded: u8[>..] = [];
    let start = find(text, "{");
    guard start >= 0 else { return 0; }
    let root, perr = json::parse(text[start..], doc, decoded);
    guard root else { write_stderr(str("pyright output: ", perr, "\n")); return 0; }
    let list = json::member(root, "generalDiagnostics");
    guard list else { return 0; }
    var n = 0;
    json::each(list) { d =>
        let file, f_ok = json::as_string(json::member(d, "file"));
        let sev, s_ok = json::as_string(json::member(d, "severity"));
        let msg, m_ok = json::as_string(json::member(d, "message"));
        let rule, r_ok = json::as_string(json::member(d, "rule"));
        let range = json::member(d, "range");
        let ls, a1 = json::as_i64(json::member(json::member(range, "start"), "line"));
        let cs, a2 = json::as_i64(json::member(json::member(range, "start"), "character"));
        let le, a3 = json::as_i64(json::member(json::member(range, "end"), "line"));
        let ce, a4 = json::as_i64(json::member(json::member(range, "end"), "character"));
        if f_ok && s_ok && a1 && a2 && a3 && a4 {
            put_row(rows, relative_to(repo, file), ls, cs, le, ce,
                    if sev == "information" { "info" } else { sev }, "pyright",
                    if r_ok { rule } else { "" }, if m_ok { msg } else { "" });
            n++;
        }
    };
    return n;
}

// javac: `path:line: error: message`, then the source line, then a caret
// under the column.
fn parse_javac(text: const u8[:], repo: const u8[:], rows: u8[>..]&) -> i64 {
    let lines = split(text, '\n');
    var n = 0;
    for line, i in lines {
        let j = find(line, ".java:");
        guard j > 0 else { continue; }
        let rest = line[j + 6..];
        let colon = find(rest, ": ");
        guard colon > 0 else { continue; }
        let ln, ok = parse_int(rest[..colon]);
        guard ok else { continue; }
        let tail = rest[colon + 2..];
        let sev_end = find(tail, ": ");
        guard sev_end > 0 else { continue; }
        let sev = tail[..sev_end];
        guard sev == "error" || sev == "warning" else { continue; }
        var col = 0;
        if i + 2 < lines.len {
            let caret = find(lines[i + 2], "^");
            if caret >= 0 { col = caret; }
        }
        put_row(rows, relative_to(repo, line[..j + 5]), ln - 1, col, ln - 1, col, sev, "javac", "",
                tail[sev_end + 2..]);
        n++;
    }
    return n;
}

// clang: `path:line:col: error: message` (it prints each diagnostic once per
// compilation side, host and device, so repeats are dropped).
fn parse_clang(text: const u8[:], repo: const u8[:], rows: u8[>..]&) -> i64 {
    var n = 0;
    var seen = dictionary<const u8[:], bool> {};
    each_split(text, '\n') { line =>
        guard starts_with(line, "/") && !seen.contains(line);
        let parts = split(line, ':');
        guard parts.len >= 5;
        let ln, ok1 = parse_int(parts[1]);
        let cn, ok2 = parse_int(parts[2]);
        guard ok1 && ok2;
        let sev = trim(parts[3]);
        guard sev == "error" || sev == "warning" || sev == "fatal error";
        seen.insert(line, true);
        let msg_at = find(line, str(parts[3], ":")) + parts[3].len + 1;
        put_row(rows, relative_to(repo, parts[0]), ln - 1, cn - 1, ln - 1, cn - 1,
                if sev == "warning" { "warning" } else { "error" }, "clang", "", trim(line[msg_at..]));
        n++;
    };
    return n;
}

fn check_main(repo_arg: const u8[:], out_arg: const u8[:], report: u8[>..]&) -> bool {
    let repo = abs_path(repo_arg);
    let out = abs_path(out_arg);
    let db = str(out, "/swan.db");
    guard file_exists(db) else { format(report, "no map at ", db, "; run swan map first"); return false; }
    let home = swan_home();
    let bin = str(home, "/tools/node_modules/.bin/");
    let l = detect(repo);
    var rows: u8[>..] = [];
    var ran: u8[>..] = [];
    // Checkers that never got to check: not started (126, 127), timed out
    // (-2), killed, or failed with nothing to show for it (a checker that
    // found errors says which). Cargo says itself whether the build ran to
    // its end ("build-finished"); one that stopped early (a dependency that
    // will not resolve, a build script that failed) checked only part of
    // the code, whatever it printed. Their silence is not a clean bill, so
    // the diagnostics already saved are kept rather than replaced by a
    // partial set.
    var not_run: u8[>..] = [];
    fn cargo_finished(output: const u8[:]) -> bool { return find(output, "\"reason\":\"build-finished\"") >= 0; }
    fn checked(name: const u8[:], code: i64, found: i64, finished: bool = true) -> bool {
        let broke = code < 0 || code == 126 || code == 127 || code >= 128 || (code != 0 && !finished);
        guard broke || (code != 0 && found == 0) else { return true; }
        format(not_run, " ", name, if code == -2 { str(" (timed out)") }
                                    else if broke { str(" (exit ", code, ")") }
                                    else { str(" (exit ", code, " and no findings)") });
        return false;
    }

    // Only with the repo's own tsconfig: the one Swan generates to index a
    // repo without one has no say over how strict its code means to be.
    if l.tsconfig {
        var a: u8[>..] = [];
        arg(a, str(bin, "tsc"));
        arg(a, "--noEmit");
        arg(a, "--pretty");
        arg(a, "false");
        arg(a, "-p");
        arg(a, repo);
        var o: u8[>..] = [];
        let code = run_step("tsc", a, repo, child_env(l, ""), 1800000, o);   // exit 2 when it finds errors
        let n = parse_tsc(o, rows);
        if checked("tsc", code, n) { format(ran, " tsc:", n); }
    }
    if l.cargo {
        var a: u8[>..] = [];
        arg(a, "cargo");
        arg(a, "check");
        arg(a, "--workspace");
        arg(a, "--all-targets");
        arg(a, "--message-format=json");
        arg(a, "--keep-going");     // every crate it can check, not just up to the first that fails
        arg(a, "--quiet");
        var o: u8[>..] = [];
        let extra = env_entry("CARGO_TARGET_DIR", str(out, "/cargo-target"));
        let code = run_step("cargo check", a, repo, child_env(l, extra), 3600000, o);
        let n = parse_cargo(o, repo, rows);
        if checked("cargo", code, n, cargo_finished(o)) { format(ran, " cargo:", n); }
    }
    if l.py {
        // pyright run from the repo root reads the repo's own settings
        // (pyrightconfig.json, pyproject.toml) if it has any; --pythonpath points it
        // at the repo's interpreter, so installed packages resolve.
        var py: u8[>..] = [];
        if l.venv.len > 0 { format(py, l.venv, "/bin/python"); }
        else {
            var which: u8[>..] = [];
            arg(which, "python3");
            arg(which, "-c");
            arg(which, "import sys; print(sys.executable, end='')");
            var e: u8[>..] = [];
            swan_run(which, repo, child_env(l, ""), 30000, py, e);
        }
        var a: u8[>..] = [];
        arg(a, str(bin, "pyright"));
        arg(a, "--outputjson");
        arg(a, "--pythonpath");
        arg(a, py);
        var o: u8[>..] = [];
        let code = run_step("pyright", a, repo, child_env(l, ""), 3600000, o);   // exit 1 when it finds errors
        let n = parse_pyright(o, repo, rows);
        if checked("pyright", code, n) { format(ran, " pyright:", n); }
    }
    if l.java && !l.maven && !l.gradle {
        // javac over every source, output thrown away in out-dir.
        var files: u8[>..] = [];
        each_file(repo) { full, name => if ends_with(name, ".java") { files.append(full); files.push('\n'); } };
        write_file(str(out, "/javac-files.txt"), files);
        var a: u8[>..] = [];
        let jh = java_home(home);
        let javac: u8[>..] = if jh.len > 0 { str(jh, "/bin/javac") } else { str("javac") };
        arg(a, javac);
        arg(a, "-d");
        arg(a, str(out, "/javac-classes"));
        arg(a, "-encoding");
        arg(a, "UTF-8");
        arg(a, "-proc:none");
        arg(a, "-Xmaxerrs");
        arg(a, "100000");
        arg(a, str("@", out, "/javac-files.txt"));
        var o: u8[>..] = [];
        var e: u8[>..] = [];
        let t0 = clock();
        let code = swan_run(a, repo, child_env(l, ""), 1800000, o, e);   // javac reports on stderr
        write_stderr(str("javac: ", ((clock() - t0) * 1000.0) as i64, " ms\n"));
        let n = parse_javac(e, repo, rows);
        if checked("javac", code, n) { format(ran, " javac:", n); }
    } else if l.java {
        format(ran, " javac: skipped (Maven/Gradle repo; its build tool is not run yet)");
    }
    if l.c || l.cuda {
        // No nvcc needed: clang's own frontend, as scip-clang runs it, reports
        // the errors (CUDA in host mode), from the same compile commands.
        var compdb: u8[>..] = [];
        if file_exists(str(repo, "/compile_commands.json")) { format(compdb, repo, "/compile_commands.json"); }
        else if file_exists(str(repo, "/build/compile_commands.json")) { format(compdb, repo, "/build/compile_commands.json"); }
        else {
            format(compdb, out, "/compile_commands.json");
            write_compdb(repo, home, compdb);
        }
        var a: u8[>..] = [];
        arg(a, str(home, "/.tools/scip-clang/scip-clang"));
        arg(a, "--show-compiler-diagnostics");
        arg(a, str("--compdb-path=", compdb));
        arg(a, str("--index-output-path=", out, "/check-cxx.scip"));
        var o: u8[>..] = [];
        var e: u8[>..] = [];
        let t0 = clock();
        let code = swan_run(a, repo, child_env(l, ""), 3600000, o, e);
        write_stderr(str("clang (via scip-clang): ", ((clock() - t0) * 1000.0) as i64, " ms\n"));
        let n = parse_clang(e, repo, rows);
        if checked("clang", code, n) { format(ran, " clang:", n); }
    }
    // Linters, from tools/modules.json.
    let mc = mod_ctx(repo, out, home, l);
    each_split(module_langs(l), '\n') { lang =>
        guard lang.len > 0;
        var o: u8[>..] = [];
        var src: u8[>..] = [];
        var par: u8[>..] = [];
        let code = run_module(home, lang, "lint", mc, child_env(l, ""), "", o, src, par);
        if code != -100 {
            let n = if par == "github" { parse_github(o, repo, src, rows) }
                    else if par == "cargo" { parse_cargo(o, repo, rows, src) } else { 0 };
            if checked(lang, code, n, par != "cargo" || cargo_finished(o)) { format(ran, " ", src, ":", n); }
        }
    };
    guard not_run.len == 0 else {
        format(report, "could not check:", not_run, "; the saved diagnostics are unchanged", if ran.len > 0 { str(" (ran", ran, ")") } else { str("") });
        return false;
    }
    guard ran.len > 0 else { format(report, "no checker for the languages in ", repo); return false; }
    write_file(str(out, "/diagnostics.tsv"), rows);
    format(report, "checked", ran, "\n");
    diagnostics_main(out, db, report);
    return true;
}
