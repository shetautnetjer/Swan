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
import treesitter;
import .writer;
import .pypatch;

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
    syn: bool,                  // Go, shell, Make, Ruby or Lua: `swan syntax-index` maps them
    other: u8[..256],           // languages with no indexer here, only search and live errors: "lua glsl ..."
    tsconfig: bool, cargo: bool, maven: bool, gradle: bool,
    venv: u8[..2048],           // a virtualenv inside the repo, if any
}

let SKIP_DIRS = ["node_modules", ".git", "target", ".venv", "venv", "__pycache__", ".tox",
                 ".mypy_cache", ".pytest_cache", ".swan", "build", ".gradle", "obj"];

extern fn swan_is_symlink(path: const u8[:]) -> bool;

// F(path, name) for each file under repo, breadth-first, skipping folders
// that hold dependencies, caches or build output. A symlinked folder is not
// entered: it could lead out of the repo or loop back into it (a link to "."
// listed one file 41 times), and a target inside the repo is walked under
// its own path anyway.
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
                if !contains(SKIP_DIRS, name) && !swan_is_symlink(full) { dirs.append(full); dirs.push('\n'); }
            } else {
                F(full[..], name);
            }
        };
    }
}

// Files `swan syntax-index` (src/syntax.goose) covers: Go, shell, Make, Ruby and Lua by name,
// and scripts with no extension in a bin/ or scripts/ folder (it reads their
// #! line itself).
fn syntax_file(full: const u8[:], name: const u8[:]) -> bool {
    for e in [".go", ".sh", ".bash", ".zsh", ".ksh", ".rb", ".lua", ".mk"] { if ends_with(name, e) { return true; } }
    if name == "Makefile" || name == "makefile" || name == "GNUmakefile" || name == "Rakefile" { return true; }
    return find(name, ".") < 0 && (find(full, "/bin/") >= 0 || find(full, "/scripts/") >= 0);
}

fn detect(repo: const u8[:]) -> Langs {
    var l = Langs { ts: false, js: false, py: false, rs: false, java: false, c: false, cuda: false, kt: false, syn: false,
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
        if syntax_file(full, name) { l.syn = true; }
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
        } else if treesitter::language_of_path(name).len > 0 {
            // Any other language with a grammar here (Lua, the shaders,
            // GDScript, C#, PHP): no SCIP indexer runs for these (yet); they
            // are searched by structure and checked by their language servers.
            let lang = treesitter::language_of_path(name);
            let indexed = contains(["typescript", "tsx", "javascript", "python", "rust", "java", "kotlin", "c", "cpp", "cuda"], lang);
            if !indexed && find(l.other, lang) < 0 && l.other.len + lang.len + 1 < 256 {
                if l.other.len > 0 { l.other.push(' '); }
                l.other.append(lang);
            }
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

// The scip-java scripts/fetch-tools.sh installs, by version, so a new pin
// is a new file and never an old binary kept. Keep the two in step.
let SCIP_JAVA = "v0.14.1";

// Whether the repo's root holds a solution or project file for scip-dotnet.
fn has_dotnet_project(repo: const u8[:]) -> bool {
    var names: u8[>..] = [];
    guard list_dir(repo, names) else { return false; }
    var yes = false;
    each_split(names, '\n') { n => if ends_with(n, ".sln") || ends_with(n, ".slnx") || ends_with(n, ".csproj") { yes = true; } };
    return yes;
}

// Swan's .NET SDK and its homes, so nothing lands in ~/.dotnet or ~/.nuget.
fn dotnet_env(home: const u8[:]) -> u8[>..] {
    var e: u8[>..] = [];
    let t = str(home, "/.tools");
    e.append(env_entry("DOTNET_ROOT", str(t, "/dotnet")));
    e.append(env_entry("DOTNET_CLI_HOME", str(t, "/dotnet-home")));
    e.append(env_entry("NUGET_PACKAGES", str(t, "/nuget")));
    e.append(env_entry("DOTNET_CLI_TELEMETRY_OPTOUT", "1"));
    e.append(env_entry("DOTNET_NOLOGO", "1"));
    return e;
}

// The environment children get: a repo virtualenv first on PATH, and room
// for scip-python and pyright on big repos.
fn child_env(l: const Langs&, extra: const u8[:]) -> u8[>..] {
    var vars: u8[>..] = [];
    var path: u8[>..] = [];
    if l.venv.len > 0 { format(path, l.venv, "/bin:"); }
    // Package-local Node/Bun, when installed. Trust-gated virtualenvs retain
    // their existing precedence; the runtime directory belongs to Swan.
    format(path, swan_home(), "/.tools/runtime/bin:");
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
    // scip-dotnet runs `dotnet restore` by name.
    if find(l.other, "csharp") >= 0 { format(path, swan_home(), "/.tools/dotnet:"); }
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

// Some indexers and checkers run the repo's own build files: cargo's build
// scripts and proc macros, Maven and Gradle, MSBuild through `dotnet
// restore`. A repo can run any code that way, so they wait until a person
// says the repo is trusted: `swan trust <repo>` adds the repo's
// path to Swan's own data/trusted-repos, which no repo can ship (a record
// inside the map folder could, when that folder sits in the checkout).
// SWAN_TRUST_BUILD=1 trusts every repo, for tests and CI. Nothing in the
// MCP server writes it.
fn trust_file() -> u8[>..] { return str(swan_home(), "/data/trusted-repos"); }

fn build_trusted(repo: const u8[:], out: const u8[:]) -> bool {
    var all: u8[>..] = [];
    if env("SWAN_TRUST_BUILD", all) && all == "1" { return true; }
    var saved: u8[>..] = [];
    guard read_file(trust_file(), saved) else { return false; }
    return contains_line(saved, repo);
}

fn trust_main(repo_arg: const u8[:], report: u8[>..]&) -> bool {
    let repo = abs_path(repo_arg);
    let tf = trust_file();
    var mk: u8[>..] = [];
    arg(mk, "mkdir");
    arg(mk, "-p");
    arg(mk, str(swan_home(), "/data"));
    var ignored: u8[>..] = [];
    run_step("mkdir", mk, "", "", 10000, ignored);
    var saved: u8[>..] = [];
    read_file(tf, saved);
    if !contains_line(saved, repo) {
        if saved.len > 0 && saved[saved.len - 1] != '\n' { saved.push('\n'); }
        format(saved, repo, "\n");
        guard write_file(tf, saved) else { format(report, "could not write ", tf); return false; }
    }
    format(report, "trusted ", repo, ": swan map, swan check and live answers may now run its build files (Cargo, Maven, Gradle, MSBuild)");
    return true;
}

fn untrusted_note(skipped: const u8[:], repo: const u8[:]) -> u8[>..] {
    return str("not run:", skipped, " (each runs the repo's own build files, which can run any code); ",
               "if you trust this repo: swan trust ", repo);
}

var map_held: u8[..1024];      // build-running indexers the last map_main left out for `swan trust`

// The same list the map report carries as "not run: ..."; "" when the last
// map held nothing back. swan serve reports it as use_repo's `skipped`.
fn map_held_indexers() -> const u8[:] { return trim(map_held[..]); }

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

// The repo's src folder when it holds Python packages or modules (the "src
// layout"), as a PYTHONPATH value; empty otherwise.
fn python_src_roots(repo: const u8[:]) -> u8[>..] {
    let src = str(repo, "/src");
    var names: u8[>..] = [];
    var found = false;
    if list_dir(src, names) {
        each_split(names, '\n') { nm =>
            if nm.len > 0 && (ends_with(nm, ".py") || file_exists(str(src, "/", nm, "/__init__.py"))) { found = true; }
        };
    }
    return if found { src } else { str("") };
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

// Most files in a prefix piece, and most prefix pieces from one folder.
let PY_PIECE_FILES: i64 = 64;
let PY_PIECE_GROUPS: i64 = 40;

// Splits a TypeScript project into k chunks of similar size for parallel
// scip-typescript runs. The files are tsc's own roots (`tsc --listFilesOnly`
// kept to the `--showConfig` file list, so the project's include and
// exclude hold), less node_modules and declaration files, which every chunk
// gets. Packed largest first, each into the lightest chunk. Returns one
// line per chunk, files separated by tabs, and the declaration files as
// `decls`; nothing when one run will do. k may be 1: one chunk of every
// file, which lets a later edit be indexed as a layer over it.
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
    guard k >= 1 && sizes.len >= 4 * k else { return plan; }
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

// tsc's root files, from `tsc --showConfig`. --listFilesOnly lists every
// file in the program, the roots and all they import, wherever those are
// (rea's scripts/*.mts, outside its tsconfig's include); scip-typescript
// indexes only the roots, so a chunk of anything more would map files a
// whole run leaves out. Returns the listing's lines that are roots, or
// nothing when the config's file list cannot be read (TypeScript then runs
// whole, as before).
fn ts_root_listing(listing: const u8[:], show: const u8[:], cfg_dir: const u8[:]) -> u8[>..] {
    var kept: u8[>..] = [];
    let at = find(show, "\"files\": [");
    guard at >= 0 else { return kept; }
    var all: u8[>..] = [];
    var done = false;
    var bad = false;
    var first = true;
    each_split(show[at..], '\n') { line =>
        guard !done && !bad;
        if first { first = false; } else {
            var t = trim(line);
            if starts_with(t, "]") { done = true; } else {
                if ends_with(t, ",") { t = t[..t.len - 1]; }
                if t.len < 3 || t[0] != '"' || t[t.len - 1] != '"' || find(t, "\\") >= 0 { bad = true; } else {
                    let rel = t[1..t.len - 1];
                    let p = if rel[0] == '/' { str(rel) } else if starts_with(rel, "./") { str(cfg_dir, "/", rel[2..]) } else { str(cfg_dir, "/", rel) };
                    if !swan_realpath(p, all) { all.append(p); }
                    all.push('\n');
                }
            }
        }
    };
    guard done && !bad && all.len > 0 else { return kept; }
    // In the config's order, not the listing's (the order tsc reached
    // files): scip-typescript numbers anonymous types in the order it
    // meets them, so one chunk in another order names them differently
    // from a whole run.
    var real: u8[>..] = [];
    var lines: u8[>..] = [];
    each_split(listing, '\n') { raw =>
        let f = trim(raw);
        guard f.len > 0;
        if !swan_realpath(f, real) { real.append(f); }
        real.push('\n');
        format(lines, f, "\n");
    };
    let reals = split(real, '\n');
    let given = split(lines, '\n');
    var listed = dictionary<const u8[:], i64> {};
    for r, i in reals { if r.len > 0 && i < given.len { listed.insert(r, i); } }
    each_split(all, '\n') { r =>
        guard r.len > 0;
        let at = listed.get(r);
        guard at;
        let i: i64 = at;
        format(kept, given[i], "\n");
    };
    return kept;
}

// "path\tstamp" for every .py file, in walk order (list_dir sorts). S(path)
// is the file's content stamp (map_main's `stamp`, src/change.goose).
fn py_stamps<S>(repo: const u8[:]) -> u8[>..] {
    var s: u8[>..] = [];
    each_file(repo) { full, name =>
        if ends_with(name, ".py") { format(s, full[repo.len + 1..], "\t", S(full) as! i64, "\n"); }
    };
    return s;
}

// One fingerprint for every file with these endings (and the named build
// files at the root): a whole-language index is reused while it is
// unchanged. S(path) is a file's content stamp.
fn lang_fingerprint<S>(repo: const u8[:], endings: const u8[:][:], roots: const u8[:][:]) -> u64 {
    var h: u64 = 0;
    each_file(repo) { full, name =>
        var hit = false;
        for e in endings { if ends_with(name, e) { hit = true; } }
        if hit { h = hash_combine(h, hash_combine(hash(full), S(full))); }
    };
    for r in roots {
        let p = str(repo, "/", r);
        if file_exists(p) { h = hash_combine(h, hash_combine(hash(p[..]), S(p[..]))); }
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
    // A prefix piece ("dir/ab*") holds every path that starts with dir/ab.
    if piece.len > 0 && piece[piece.len - 1] == '*' { return starts_with(path, piece[..piece.len - 1]); }
    return piece.len == 0 || path == piece || (starts_with(path, piece) && path.len > piece.len && path[piece.len] == '/');
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
    let db = sqlite::open_existing(db_path, err);
    if db == 0 { abort(str("swan: cannot read dependency map: ", err)); }
    let st = prepare_or_die(db, """
        SELECT DISTINCT o.file FROM occurrences o JOIN symbols s ON s.id = o.symbol_id
        WHERE s.def_file = ?1 AND o.file != ?1 AND o.is_def = 0
        """);
    each_split(changed, '\n') { f =>
        guard f.len > 0;
        sqlite::bind_text(st, 1, f);
        while step_checked(st, err) == 1 { sqlite::col_text(st, 0, dirty); dirty.push('\n'); }
        sqlite::reset(st);
    };
    sqlite::finalize(st);
    sqlite::close(db);
    return dirty;
}

// Clean publication must not treat a successful but malformed flattener as a
// complete replacement. Match bin/swan-flatten's row contract before the
// existing permissive native reader runs. Empty files/lines are valid, and the
// historical five-column symbol row remains valid (the sixth is optional docs).
fn clean_row_number(field: const u8[:]) -> bool {
    guard field.len > 0 else { return false; }
    for c in field { if c < '0' || c > '9' { return false; } }
    let value, ok = parse_int(field);
    return ok && value >= 0;
}

fn clean_row_valid(name: const u8[:], line: const u8[:]) -> bool {
    let f = split(line, '\t');
    if name == "symbols.tsv" {
        return (f.len == 5 || f.len == 6) && f[0].len > 0 && clean_row_number(f[2]);
    }
    if name == "relationships.tsv" {
        guard f.len == 4 && f[0].len > 0 && f[1].len > 0 && f[2].len > 0 && f[3].len > 0 else { return false; }
        for flag in split(f[3], ',') {
            if flag != "impl" && flag != "ref" && flag != "type" && flag != "def" { return false; }
        }
        return true;
    }
    let expected = if name == "extents.tsv" { 6 } else { 7 };
    guard f.len == expected && f[0].len > 0 && f[1].len > 0 else { return false; }
    for i in 2..6 { if !clean_row_number(f[i]) { return false; } }
    let sl = field_int(f[2]); let sc = field_int(f[3]);
    let el = field_int(f[4]); let ec = field_int(f[5]);
    guard el > sl || (el == sl && ec >= sc) else { return false; }
    return name == "extents.tsv" || f[6] == "def" || f[6] == "ref" || f[6] == "imp" || f[6] == "name";
}

fn clean_rows_valid(out: const u8[:], report: u8[>..]&) -> bool {
    for name in ["symbols.tsv", "extents.tsv", "relationships.tsv", "occurrences.tsv"] {
        var rows: u8[>..] = [];
        guard read_file(str(out, "/", name), rows) else {
            format(report, "clean rebuild cannot read flattened output: ", name, "; previous database retained"); return false;
        }
        var row = 0;
        var valid = true;
        each_split(rows, '\n') { line =>
            row++;
            if valid && line.len > 0 && !clean_row_valid(name, line) {
                format(report, "clean rebuild malformed flattened output: ", name, " row ", row, "; previous database retained");
                valid = false;
            }
        };
        if !valid { return false; }
    }
    return true;
}

// ---- Stamping on several cores -------------------------------------------

fn map_main(repo_arg: const u8[:], out_arg: const u8[:], report: u8[>..]&, clean: bool = false) -> bool {
    map_held.clear();
    let repo = abs_path(repo_arg);
    var mk: u8[>..] = [];
    arg(mk, "mkdir");
    arg(mk, "-p");
    arg(mk, out_arg);
    var ignored: u8[>..] = [];
    run_step("mkdir", mk, "", "", 10000, ignored);
    let out = abs_path(out_arg);
    let writer = swan_writer_lock(str(out, "/swan.db"), report);
    guard writer != 0 else { return false; }
    let ok = map_main_locked(repo, out, report, clean);
    if ok { swan_writer_complete(writer); } else { swan_writer_unlock(writer); }
    return ok;
}

// The public wrapper holds the writer lock for every shared output: cached
// indexer files, flattened rows, schema replacement and final database update.
fn map_main_locked(repo: const u8[:], out: const u8[:], report: u8[>..]&, clean: bool = false) -> bool {
    let t_start = clock();
    let home = swan_home();
    let bin = str(home, "/tools/node_modules/.bin/");
    var l = detect(repo);
    let trusted = build_trusted(repo, out);
    // A virtualenv inside the repo is the repo's own code (its python, its pip, its PATH):
    // use it only once the repo is trusted, like any other build-running step.
    if !trusted { l.venv.clear(); }
    var skipped: u8[>..] = [];     // indexers that wait for `swan trust`
    format(report, "languages:", if l.ts { " typescript" } else { "" }, if l.js { " javascript" } else { "" },
           if l.java { " java" } else { "" }, if l.c { " c/c++" } else { "" }, if l.cuda { " cuda" } else { "" },
           if l.py { " python" } else { "" }, if l.rs || l.cargo { " rust" } else { "" }, if l.kt { " kotlin" } else { "" }, if l.syn { " go/shell/make/ruby/lua (syntax only)" } else { "" }, if l.other.len > 0 { str(" ", l.other) } else { str("") },
           if l.venv.len > 0 { str(" (venv ", l.venv, ")") } else { str("") }, "\n");
    // A map from an older Swan is rebuilt from scratch, indexers included:
    // reusing their output would skip what the new schema needs.
    let old_db = str(out, "/swan.db");
    if clean && file_exists(old_db) {
        // Refuse a wrong or unverifiable target before invalidating anything.
        // A damaged map can instead be rebuilt in a new private directory.
        var e: u8[>..] = [];
        var recorded: u8[>..] = [];
        let h = sqlite::open_existing(old_db, e);
        guard h != 0 else { format(report, "cannot verify clean map target: ", e); return false; }
        let st = sqlite::prepare(h, "SELECT value FROM meta WHERE key = 'root'", e);
        if st != 0 {
            if sqlite::step(st, e) == 1 { sqlite::col_text(st, 0, recorded); }
            sqlite::finalize(st);
        }
        sqlite::close(h);
        guard recorded == repo else {
            format(report, "clean rebuild requires the exact recorded repo root; requested ", repo,
                   ", recorded ", if recorded.len > 0 { recorded[..] } else { "(unreadable)" });
            return false;
        }
    }
    if !clean && file_exists(old_db) {
        var e: u8[>..] = [];
        let h = sqlite::open_existing(old_db, e);
        if h == 0 { abort(str("swan: cannot inspect map schema: ", e)); }
        var v: u8[>..] = [];
        meta_value(h, "schema_version", v);
        sqlite::close(h);
        if v != str(SCHEMA_VERSION) {
            format(report, "map schema ", if v.len > 0 { v[..] } else { "?" }, " is older than ", SCHEMA_VERSION, ": rebuilding\n");
            for f in ["/swan.db", "/index-manifest.tsv", "/python-pieces.tsv", "/python-files.tsv"] { delete_file(str(out, f)); }
        }
    }
    // Invalidate reuse metadata under the same stable writer lock. Never remove
    // the database or its lock: readers keep their snapshot until atomic publish.
    // Defer replacement metadata until publication, so failure/interruption
    // cannot make a later ordinary map trust unfinished indexer output.
    var pending_cache: u8[>..] = [];
    fn cache_write(name: const u8[:], contents: const u8[:]) {
        if clean { arg(pending_cache, name); arg(pending_cache, contents); }
        else { write_file(str(out, "/", name), contents); }
    }
    if clean {
        for name in ["index-manifest.tsv", "tsc-files.txt", "tsc-program.txt", "typescript-chunks.txt",
                     "typescript-shared.txt", "typescript-files.tsv", "typescript-layers.txt",
                     "python-files.tsv", "python-pieces.tsv"] {
            let path = str(out, "/", name);
            guard !file_exists(path) || delete_file(path) else {
                format(report, "cannot invalidate clean rebuild cache: ", path); return false;
            }
        }
        report.append("clean rebuild: cached indexer output and merge layers will not be reused; previous database retained until publication\n");
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
    // when its index was made. `force` runs it anyway, with the fingerprint
    // recorded as usual (a file whose indexed text is unknown, see below).
    fn add_lang_job(label: const u8[:], target: const u8[:], a: const u8[:], e: const u8[:], fp: u64, force: bool = false) {
        let fps = str(fp);
        var hit = false;
        each_split(prev_index, '\n') { line =>
            let f = split(line, '\t');
            if f.len == 3 && f[0] == label && f[1] == fps && f[2] == target && file_exists(target) { hit = true; }
        };
        format(index_manifest, label, "\t", fps, "\t", target, "\n");
        if hit && !force {
            format(report, label, ": reused (no changes)\n");
            add_job("", target, "", "", "");
        } else {
            add_job(label, target, a, e, "");
        }
    }

    // Content stamps (src/change.goose): what a file holds, not when it was
    // saved. content-stamps.tsv keeps one line per file stamped, "path\tsize\t
    // mtime\tstamp\traw\tc|b" (c: stamped by its code alone, b: by its bytes),
    // so a file whose size and mtime are what the last map saw is not read
    // again. The text of each file stamped by its code is kept in texts/, by
    // its raw hash, to move its rows after a cosmetic edit.
    let texts_dir = str(out, "/texts");
    make_dir(texts_dir);
    var stamp_prev: u8[>..] = [];
    if !clean { read_file(str(out, "/content-stamps.tsv"), stamp_prev); }
    var stamp_at = dictionary<u64, i64> {};
    index_lines(stamp_prev, stamp_at);
    var stamp_lines: u8[>..] = [];
    var stamp_memo = dictionary<u64, u64> {};      // by the hash of the path
    var raw_memo = dictionary<u64, u64> {};
    var mtime_memo = dictionary<u64, i64> {};
    var code_memo = dictionary<u64, bool> {};      // the files stamped by their code
    // Stamps worked out ahead on several cores (prestamp), in the same
    // format as content-stamps.tsv and checked the same way.
    var stamp_pre: u8[>..] = [];
    var stamp_pre_at = dictionary<u64, i64> {};
    fn stamp(full: const u8[:]) -> u64 {
        guard full.len > repo.len + 1 && starts_with(full, repo) && full[repo.len] == '/' else { return hash(full); }
        let rel = full[repo.len + 1..];
        let key = hash(rel);
        let m = stamp_memo.get(key);
        if m { return m; }
        let size = swan_file_size(full);
        let mt = swan_mtime_ns(full);
        var st: u64 = 0;
        var raw: u64 = 0;
        var by_code = false;
        var known = false;
        let line = line_of_path(stamp_prev, stamp_at, rel);
        if line.len > 0 {
            let f = split(line, '\t');
            if f.len == 6 && f[1] == str(size) && f[2] == str(mt) {
                let a, ok1 = parse_int(f[3]);
                let b, ok2 = parse_int(f[4]);
                if ok1 && ok2 { st = a as! u64; raw = b as! u64; by_code = f[5] == "c"; known = true; }
            }
        }
        if !known && stamp_pre.len > 0 {
            let pl = line_of_path(stamp_pre, stamp_pre_at, rel);
            if pl.len > 0 {
                let f = split(pl, '\t');
                if f.len == 6 && f[1] == str(size) && f[2] == str(mt) {
                    let a, ok1 = parse_int(f[3]);
                    let b, ok2 = parse_int(f[4]);
                    if ok1 && ok2 { st = a as! u64; raw = b as! u64; by_code = f[5] == "c"; known = true; }
                }
            }
        }
        if !known {
            var text: u8[>..] = [];
            read_file(full, text);
            raw = hash(text[..]);
            st = raw;
            let lang = cosmetic_lang(rel);
            if lang.len > 0 {
                let h, ok = code_hash(lang, text[..]);
                if ok {
                    st = h;
                    by_code = true;
                    let keep = str(texts_dir, "/t", raw as! i64, ".txt");
                    if !file_exists(keep) { write_file(keep, text[..]); }
                }
            }
        }
        format(stamp_lines, rel, "\t", size, "\t", mt, "\t", st as! i64, "\t", raw as! i64, "\t", if by_code { "c" } else { "b" }, "\n");
        stamp_memo.insert(key, st);
        raw_memo.insert(key, raw);
        mtime_memo.insert(key, mt);
        if by_code { code_memo.insert(key, true); }
        return st;
    }
    fn raw_text_of(key: u64) -> u8[>..] {
        var s: u8[>..] = [];
        let r = raw_memo.get(key);
        if r { format(s, r as! i64); }
        return s;
    }

    // Cosmetic edits. indexed-texts.tsv says, for each file stamped by its
    // code, which text its rows were indexed from: "path\traw\tstamp", raw
    // "?" when Swan cannot tell. row-basis.tsv lists the files whose rows
    // Swan moved since the map was last written from indexer output:
    // "path\traw\tmtime", the text the rows now match and the mtime recorded
    // with it. A file whose rows could not be moved to match its text is
    // reindexed (`forced`), whatever its stamp says.
    var idx_prev: u8[>..] = [];
    var basis_prev: u8[>..] = [];
    if !clean {
        read_file(str(out, "/indexed-texts.tsv"), idx_prev);
        read_file(str(out, "/row-basis.tsv"), basis_prev);
    }
    var idx_at = dictionary<u64, i64> {};
    var basis_at = dictionary<u64, i64> {};
    index_lines(idx_prev, idx_at);
    index_lines(basis_prev, basis_at);
    var edited_at = dictionary<u64, i64> {};       // files.edited_mtime, where set
    if !clean && file_exists(old_db) {
        var e: u8[>..] = [];
        let h = sqlite::open_existing(old_db, e);
        if h != 0 {
            let st = sqlite::prepare(h, "SELECT file, edited_mtime FROM files WHERE edited_mtime IS NOT NULL", e);
            if st != 0 {
                while sqlite::step(st, e) == 1 {
                    var f: u8[>..] = [];
                    sqlite::col_text(st, 0, f);
                    edited_at.insert(hash(f[..]), sqlite::col_int(st, 1));
                }
                sqlite::finalize(st);
            }
            sqlite::close(h);
        }
    }
    fn have_text(raw: const u8[:]) -> bool { raw.len > 0 && raw != "?" && file_exists(str(texts_dir, "/t", raw, ".txt")) }
    // The text the map's rows for a file match while no rows are rewritten
    // from indexer output: "" when that is its current text, "?" unknown.
    fn rows_basis(rel: const u8[:], key: u64, full: const u8[:], idx_raw: const u8[:]) -> u8[>..] {
        let et = edited_at.get(key);
        guard et else { return str(idx_raw); }
        let t: i64 = et;
        let b = line_of_path(basis_prev, basis_at, rel);
        if b.len > 0 {
            let f = split(b, '\t');
            if f.len == 3 && f[2] == str(t) { return str(f[1]); }
        }
        if t == swan_mtime_ns(full) { return str(""); }
        return str("?");
    }
    var forced: u8[>..] = [];        // paths, one per line
    var force_ts = false;
    var n_cosmetic = 0;
    prestamp(repo, out, texts_dir, stamp_prev, stamp_at, stamp_pre, report);
    index_lines(stamp_pre, stamp_pre_at);
    each_file(repo) { full, name =>
        guard cosmetic_lang(name).len > 0;
        let st = stamp(full);
        let rel = full[repo.len + 1..];
        let key = hash(rel);
        guard code_memo.contains(key);
        let raw = raw_text_of(key);
        let line = line_of_path(idx_prev, idx_at, rel);
        guard line.len > 0;          // new since the last map: indexed anyway
        let f = split(line, '\t');
        guard f.len == 3;
        var why = f[1] == "?";
        if !why && f[2] == str(st as! i64) {     // its code is as indexed: no indexer would run for it
            if f[1] != raw && !have_text(f[1]) { why = true; }
            let b = rows_basis(rel, key, full, f[1]);
            if b.len > 0 && b != raw && !have_text(b) { why = true; }
            if !why && f[1] != raw { n_cosmetic++; }
        }
        if why {
            format(forced, rel, "\n");
            if cosmetic_lang(name) != "python" { force_ts = true; }
        }
    };
    if n_cosmetic > 0 { format(report, "cosmetic edits: ", n_cosmetic, " file(s) changed only in comments or layout; no indexer runs for them\n"); }
    if forced.len > 0 { format(report, "reindexing ", count_lines(forced), " file(s) whose indexed text is unknown\n"); }

    // Which text each file's rows came from after this map, from the
    // flattener's documents.tsv ("path\t1" when this map's indexers wrote
    // its rows, "\t0" when they were kept from before).
    var idx_new: u8[>..] = [];
    fn note_indexed(docs: const u8[:]) {
        each_split(docs, '\n') { line =>
            let f = split(line, '\t');
            guard f.len == 2;
            let key = hash(f[0]);
            guard code_memo.contains(key);
            if f[1] == "1" {
                let mt = mtime_memo.get(key);
                let st = stamp_memo.get(key);
                if mt && st {
                    let then: i64 = mt;
                    let s: u64 = st;
                    // Changed while the indexers ran: which text they read is unknown.
                    if swan_mtime_ns(str(repo, "/", f[0])) == then { format(idx_new, f[0], "\t", raw_text_of(key), "\t", s as! i64, "\n"); }
                    else { format(idx_new, f[0], "\t?\t", s as! i64, "\n"); }
                }
            } else {
                let p = line_of_path(idx_prev, idx_at, f[0]);
                if p.len > 0 { idx_new.append(p); idx_new.push('\n'); }
            }
        };
    }
    // For the flattener: the indexed text of each file whose rows may be kept
    // from before and whose text has changed since ("path\ttext file").
    fn kept_texts() -> u8[>..] {
        var t: u8[>..] = [];
        each_split(idx_prev, '\n') { line =>
            let f = split(line, '\t');
            guard f.len == 3 && have_text(f[1]);
            let key = hash(f[0]);
            guard code_memo.contains(key) && raw_text_of(key) != f[1];
            format(t, f[0], "\t", texts_dir, "/t", f[1], ".txt\n");
        };
        return t;
    }
    // Once the map is written: moves the rows of each file edited only in
    // comments or layout since its rows were made, to match its text, and
    // saves the records above. `rewritten`: every row was just written from
    // indexer output, so the rows match the indexed texts.
    fn finish_cosmetic(rewritten: bool) {
        var err: u8[>..] = [];
        let db = sqlite::open_existing(str(out, "/swan.db"), err);
        guard db != 0 else { return; }
        var basis_new: u8[>..] = [];
        var unknown = dictionary<u64, bool> {};
        var moved = 0;
        each_split(idx_new, '\n') { line =>
            let f = split(line, '\t');
            guard f.len == 3;
            let key = hash(f[0]);
            guard code_memo.contains(key);
            let full = str(repo, "/", f[0]);
            let raw = raw_text_of(key);
            let basis: u8[>..] = if rewritten { str(f[1]) } else { rows_basis(f[0], key, full[..], f[1]) };
            guard basis.len > 0 && basis != raw;       // the rows already match the text
            var old: u8[>..] = [];
            var cur: u8[>..] = [];
            guard read_file(full, cur) && str(hash(cur[..]) as! i64) == raw;   // changed again since: stale for now
            if basis != "?" && read_file(str(texts_dir, "/t", basis, ".txt"), old) &&
               shift_cosmetic(db, f[0], cosmetic_lang(f[0]), old[..], cur[..]) {
                mark_edited(db, f[0], full[..]);
                format(basis_new, f[0], "\t", raw, "\t", swan_mtime_ns(full), "\n");
                moved++;
            } else {
                unknown.insert(key, true);
            }
        };
        sqlite::close(db);
        if moved > 0 { format(report, "\ncosmetic edits: rows moved to match ", moved, " file(s), no indexer run"); }
        if unknown.count > 0 { format(report, "\ncosmetic edits: ", unknown.count, " file(s) could not be matched; they are reindexed next map"); }
        // A file whose rows could not be moved is marked unknown: the next map reindexes it.
        var idx_out: u8[>..] = [];
        each_split(idx_new, '\n') { line =>
            let f = split(line, '\t');
            guard f.len == 3;
            if unknown.contains(hash(f[0])) { format(idx_out, f[0], "\t?\t", f[2], "\n"); } else { format(idx_out, line, "\n"); }
        };
        if !rewritten {
            var updated = dictionary<u64, bool> {};
            each_split(basis_new, '\n') { line => let t = find(line, "\t"); if t > 0 { updated.insert(hash(line[..t]), true); } };
            each_split(basis_prev, '\n') { line =>
                let t = find(line, "\t");
                if t > 0 && !updated.contains(hash(line[..t])) && edited_at.contains(hash(line[..t])) { format(basis_new, line, "\n"); }
            };
        }
        write_file(str(out, "/indexed-texts.tsv"), idx_out);
        write_file(str(out, "/row-basis.tsv"), basis_new);
        // Kept texts no record names go.
        var keep = dictionary<u64, bool> {};
        fn keep_raw(r: const u8[:]) { if r.len > 0 && r != "?" { keep.insert(hash(str("t", r, ".txt")), true); } }
        each_split(idx_out, '\n') { line => let f = split(line, '\t'); if f.len == 3 { keep_raw(f[1]); } };
        each_split(basis_new, '\n') { line => let f = split(line, '\t'); if f.len == 3 { keep_raw(f[1]); } };
        code_memo.each() { key, yes => keep_raw(raw_text_of(key)); };
        var names: u8[>..] = [];
        if list_dir(texts_dir, names) {
            each_split(names, '\n') { nm => if nm.len > 0 && !keep.contains(hash(nm)) { delete_file(str(texts_dir, "/", nm)); } };
        }
    }

    // A repo's tsconfig that tsc cannot read (it extends a shared config
    // from an npm package that is not installed, such as
    // "@sindresorhus/tsconfig", or names a missing file) failed the whole
    // TypeScript index. Swan's own config is used instead, and says so.
    if l.tsconfig {
        var probe: u8[>..] = [];
        arg(probe, str(bin, "tsc"));
        arg(probe, "-p");
        arg(probe, str(repo, "/tsconfig.json"));
        arg(probe, "--showConfig");
        var po: u8[>..] = [];
        var pe: u8[>..] = [];
        if sealed_run(probe, repo, out, trusted, child_env(l, ""), 60000, po, pe) != 0 {
            let first = find(po, "\n");
            format(report, "typescript: the repo's tsconfig.json cannot be read (",
                   trim(if first > 0 { po[..first] } else { po }), "); indexing with Swan's own config\n");
            l.tsconfig = false;
            if !l.ts && !l.js { l.ts = true; }
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
        let ts_fp = lang_fingerprint(repo, [".ts", ".tsx", ".mts", ".cts", ".js", ".jsx", ".mjs", ".cjs"], ["tsconfig.json", "package.json"]) { f => stamp(f) };
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
        var ts_count: i64 = 0;
        each_file(repo) { full, name =>
            for e in [".ts", ".tsx", ".mts", ".cts", ".js", ".jsx", ".mjs", ".cjs"] {
                if ends_with(name, e) { names_key = hash_combine(names_key, hash(full)); ts_count++; }
            }
        };
        // With no slots to split into, a big project still runs as one
        // chunk (all of tsc's files, the same index the whole-language run
        // makes), so that a code edit can be indexed as a layer of just the
        // changed files and their users instead of the whole project again.
        // $SWAN_TS_LAYER_MIN files or more (default 200); small projects
        // index in a few seconds anyway.
        var layer_min: i64 = 200;
        var lm: u8[>..] = [];
        if env("SWAN_TS_LAYER_MIN", lm) { let n, ok = parse_int(lm); if ok && n > 0 { layer_min = n; } }
        let plan_k = if ts_k >= 2 { ts_k } else if ts_count >= layer_min { 1 } else { 0 };
        for r in ["tsconfig.json", "package.json"] {
            let pth = str(repo, "/", r);
            if file_exists(pth) { names_key = hash_combine(names_key, hash_combine(hash(pth[..]), stamp(pth[..]))); }
        }
        var listing: u8[>..] = [];
        var cached: u8[>..] = [];
        read_file(str(out, "/tsc-files.txt"), cached);
        // "roots": the kept list holds tsc's root files only (ts_root_listing);
        // a list kept by an earlier Swan, of every program file, is not used.
        let key_line = str(names_key, " roots\n");
        var listed = false;
        // Every file tsc compiles, the roots and what they import, kept
        // beside the roots (tsc-program.txt): see `shared` below.
        var program: u8[>..] = [];
        if plan_k >= 1 && starts_with(cached, key_line) {
            var kept_program: u8[>..] = [];
            read_file(str(out, "/tsc-program.txt"), kept_program);
            if starts_with(kept_program, key_line) {
                listing.append(cached[key_line.len..]);
                program.append(kept_program[key_line.len..]);
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
            let code = sealed_step("tsc --listFilesOnly", la, repo, out, trusted, child_env(l, ""), 600000, listing);
            if code == 0 || ((code == 1 || code == 2) && contains_line_prefix(listing, str(repo, "/"))) {
                var sa: u8[>..] = [];
                arg(sa, str(bin, "tsc"));
                arg(sa, "-p");
                arg(sa, base);
                arg(sa, "--showConfig");
                var show: u8[>..] = [];
                if sealed_step("tsc --showConfig", sa, repo, out, trusted, child_env(l, ""), 600000, show) == 0 {
                    let cfg_dir: u8[>..] = if l.tsconfig { str(repo) } else { str(out, "/tsproject") };
                    let roots = ts_root_listing(listing, show, cfg_dir);
                    program.append(listing);
                    listing.clear();
                    listing.append(roots);
                    listed = roots.len > 0;
                }
                if listed {
                    cache_write("tsc-files.txt", str(key_line, listing));
                    cache_write("tsc-program.txt", str(key_line, program));
                }
            }
        }
        var decls: u8[>..] = [];
        var refs: u8[>..] = [];
        var chunks: u8[>..] = if listed { plan_ts(repo, listing, plan_k, decls, refs) } else { str("") };
        // Keep the last map's chunks while the set of files is the same, so
        // that an edit reruns only the chunks it touches (sizes moving files
        // between chunks would rerun them all).
        var same_plan = false;
        if chunks.len > 0 {
            var prev_plan: u8[>..] = [];
            read_file(str(out, "/typescript-chunks.txt"), prev_plan);
            if prev_plan.len > 0 && same_file_set(prev_plan, chunks) { chunks.clear(); chunks.append(prev_plan); same_plan = true; }
            cache_write("typescript-chunks.txt", chunks);
        }
        if chunks.len == 0 {
            add_lang_job("scip-typescript", target, a, child_env(l, ""), ts_fp, force_ts);
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
                if file_exists(pth) { shared = hash_combine(shared, hash_combine(hash(r), stamp(pth[..]))); }
            }
            shared = hash_combine(shared, hash(base));
            each_split(decls, '\n') { f =>
                if f.len > repo.len {
                    let st = str(f[repo.len + 1..], "\t", stamp(f) as! i64);
                    shared = hash_combine(shared, hash(st));
                    format(stamps, st, "\n");
                }
            };
            // Repo files tsc compiles that are not roots (what the roots
            // import from outside the include) are not indexed, but an edit
            // to one can change how the roots resolve, so they count as
            // shared inputs: an edit to one reruns every chunk.
            var root_set = dictionary<const u8[:], bool> {};
            each_split(listing, '\n') { f => let t = trim(f); if t.len > 0 { root_set.insert(t, true); } };
            each_split(program, '\n') { raw =>
                let f = trim(raw);
                if f.len > repo.len && starts_with(f, repo) && f[repo.len] == '/' &&
                   find(f, "/node_modules/") < 0 && !root_set.contains(f) {
                    shared = hash_combine(shared, hash(str(f[repo.len + 1..], "\t", stamp(f) as! i64)));
                }
            };
            each_split(chunks, '\n') { chunk => each_split(chunk, '\t') { f =>
                if f.len > repo.len { format(stamps, f[repo.len + 1..], "\t", stamp(f) as! i64, "\n"); }
            }; };
            // Layers index changed files against the last map's view of
            // everything else, so they are only used while the shared inputs
            // (config, package.json, declarations, imported non-roots) are
            // what they were.
            var prev_shared: u8[>..] = [];
            read_file(str(out, "/typescript-shared.txt"), prev_shared);
            let same_shared = prev_shared == str(shared);
            cache_write("typescript-shared.txt", str(shared));
            var prev_stamps: u8[>..] = [];
            read_file(str(out, "/typescript-files.tsv"), prev_stamps);
            var dirty = dependents_of_changes(out, stamps, prev_stamps);
            dirty.append(forced);
            cache_write("typescript-files.tsv", stamps);
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
                cache_write("typescript-layers.txt", layers);
            } else {
                cache_write("typescript-layers.txt", "");
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
                        fp = hash_combine(fp, hash_combine(hash(rel), stamp(f)));
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
        // Swan's copy of scip-python gets its reachability memo first
        // (src/pypatch.goose): without it one long script of try/except
        // blocks can hold a map for minutes.
        ensure_scip_python_patch(home, swan_file_size(str(home, "/tools/node_modules/@sourcegraph/scip-python/dist/pyright-internal.js")), report);
        let python = python_of(l);
        var env_args: u8[>..] = [];
        var probe: u8[>..] = [];
        arg(probe, python);
        arg(probe, "-m");
        arg(probe, "pip");
        arg(probe, "--version");
        var o: u8[>..] = [];
        var e: u8[>..] = [];
        // Sealed: run with the repo as working directory, `python -m pip`
        // and `python -c` would import a repo file named pip.py or json.py.
        if sealed_run(probe, repo, out, trusted, child_env(l, ""), 30000, o, e) != 0 {
            var p: u8[>..] = [];
            arg(p, python);
            arg(p, "-c");
            arg(p, PY_ENV_SNIPPET);
            var listing: u8[>..] = [];
            let env_file = str(out, "/python-env.json");
            if sealed_step("python packages (importlib.metadata)", p, repo, out, trusted, child_env(l, ""), 60000, listing) == 0 {
                write_file(env_file, listing);
            } else {
                write_file(env_file, "[]");
            }
            arg(env_args, "--environment");
            arg(env_args, env_file);
        }
        let slash = rfind(repo, "/");
        let pieces = plan_python(repo, min(jobs_limit(), 6));
        let stamps = py_stamps(repo) { f => stamp(f) };
        // A src layout (src/<package>/__init__.py) is importable only once
        // the package is installed, which Swan never does, so tests and
        // scripts that `import <package>` resolved to nothing. Putting src on
        // PYTHONPATH lets scip-python find it, and names the package's
        // modules as their importers do (`click.core`, not `src.click.core`).
        let py_path = python_src_roots(repo);
        let py_env: u8[>..] = if py_path.len > 0 { env_entry("PYTHONPATH", py_path) } else { str("") };
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
            if piece.len > 0 { arg(a, "--target-only"); arg(a, piece_target(piece)); }
            a.append(env_args);
            let label: u8[>..] = if piece.len > 0 { str("scip-python ", piece) } else { str("scip-python") };
            add_job(label, target, a, child_env(l, py_env), piece);
        }

        // Reuse: a piece whose files are unchanged since the last map, and
        // none of whose files use a symbol defined in a changed file, keeps
        // its last index. Each file is stamped by its content (`stamp`).
        var prev_stamps: u8[>..] = [];
        read_file(str(out, "/python-files.tsv"), prev_stamps);
        var prev_manifest: u8[>..] = [];
        read_file(str(out, "/python-pieces.tsv"), prev_manifest);
        var dirty = dependents_of_changes(out, stamps, prev_stamps);
        dirty.append(forced);
        cache_write("python-files.tsv", stamps);
        var manifest: u8[>..] = [];
        var reused = 0;
        each_split(pieces[..pieces.len - 1], '\n') { piece =>
            // The search path changes symbol names, so it is part of the key.
            let fp = if py_path.len > 0 { str(piece_fingerprint(stamps, piece), "-", hash(py_path)) }
                     else { str(piece_fingerprint(stamps, piece)) };
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
        cache_write("python-pieces.tsv", manifest);
        if reused > 0 { format(report, "python: ", reused, " pieces reused\n"); }
        // Index files of pieces no longer in the plan go.
        var old2: u8[>..] = [];
        if list_dir(out, old2) {
            each_split(old2, '\n') { nm =>
                if starts_with(nm, "index-python-") && find(manifest, str(out, "/", nm)) < 0 { delete_file(str(out, "/", nm)); }
            };
        }
    }

    if l.cargo && !trusted && !sandbox_on() {
        skipped.append(" rust-analyzer scip (Rust: cargo build scripts, proc macros)");
        delete_file(str(out, "/index-rust.scip"));   // this map drops it; after trust it is rebuilt, not reused
    } else if l.cargo {
        let target = str(out, "/index-rust.scip");
        var a: u8[>..] = [];
        arg(a, str(home, "/.tools/rust-analyzer/rust-analyzer"));
        arg(a, "scip");
        arg(a, ".");
        arg(a, "--output");
        arg(a, target);
        // Build scripts and proc macros run inside the seal. Untrusted repos
        // run offline against the crates already cached in Cargo's home;
        // a missing crate leaves those uses unresolved, never unsealed.
        var renv: u8[>..] = [];
        renv.append(env_entry("CARGO_TARGET_DIR", str(out, "/cargo-target")));
        add_toolchain_env(renv, "RUSTUP_HOME", ".rustup");
        add_toolchain_env(renv, "CARGO_HOME", ".cargo");
        if !trusted { renv.append(env_entry("CARGO_NET_OFFLINE", "true")); }
        let tc = rust_toolchain_override(repo);
        if tc.len > 0 { renv.append(env_entry("RUSTUP_TOOLCHAIN", tc)); }
        add_lang_job("rust-analyzer scip", target, a, child_env(l, renv),
                     lang_fingerprint(repo, [".rs"], ["Cargo.toml", "Cargo.lock", "rust-toolchain.toml", "rust-toolchain"]) { f => stamp(f) });
    }

    // scip-java indexes Java, and Kotlin built with Gradle (its compiler
    // plugin follows the current Kotlin, 2.4 as of scip-java 0.14.1).
    if (l.java || (l.kt && l.gradle)) && (l.maven || l.gradle) && !trusted {
        skipped.append(if l.gradle { " scip-java (Gradle)" } else { " scip-java (Maven)" });
        delete_file(str(out, "/index-java.scip"));
    } else if l.java || (l.kt && l.gradle) {
        let target = str(out, "/index-java.scip");
        var a: u8[>..] = [];
        arg(a, str(home, "/.tools/scip-java/", SCIP_JAVA, "/scip-java"));
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
            // cache or isolated projects, which newer builds turn on. The
            // tasks are gradle_scip_tasks's: on Android, the (unqualified)
            // Kotlin compiles instead of scipPrintDependencies, which AGP 9
            // breaks (so no package versions for callees there). Note the `clean`
            // first: the repo's build/ output is rebuilt.
            arg(a, "--");
            arg(a, "-Dorg.gradle.configuration-cache=false");
            arg(a, "-Dorg.gradle.isolated-projects=false");
            arg(a, "-Dorg.gradle.jvmargs=-Xmx3g");
            arg(a, "-Dkotlin.daemon.jvmargs=-Xmx3g");
            each_split(gradle_scip_tasks(repo), '\n') { t => if t.len > 0 { arg(a, t); } };
            genv.append(env_entry("GRADLE_USER_HOME", str(home, "/.tools/gradle-home")));
            let sdk = str(home, "/.tools/android-sdk");
            if file_exists(str(sdk, "/licenses/android-sdk-license")) {
                genv.append(env_entry("ANDROID_HOME", sdk));
                genv.append(env_entry("ANDROID_SDK_ROOT", sdk));
            }
        }
        add_lang_job("scip-java", target, a, child_env(l, genv),
                     hash_combine(lang_fingerprint(repo, [".java", ".kt", ".kts", ".gradle"],
                                      ["pom.xml", "build.gradle", "build.gradle.kts", "settings.gradle",
                                       "settings.gradle.kts", "gradle/libs.versions.toml"]) { f => stamp(f) }, hash(a)));
    }

    // C# (Unity, Godot C#, .NET): scip-dotnet over the solution or project at
    // the repo's root, with Swan's .NET SDK. It runs `dotnet restore`, which
    // writes the repo's obj/ folders, as a build would.
    let scip_dotnet = str(home, "/.tools/dotnet-tools/scip-dotnet");
    let cs_map = find(l.other, "csharp") >= 0 && file_exists(scip_dotnet) && has_dotnet_project(repo);
    if cs_map && !trusted {
        skipped.append(" scip-dotnet (C#: MSBuild through dotnet restore)");
        delete_file(str(out, "/index-csharp.scip"));
    } else if cs_map {
        let target = str(out, "/index-csharp.scip");
        var a: u8[>..] = [];
        arg(a, scip_dotnet);
        arg(a, "index");
        arg(a, "--working-directory");
        arg(a, repo);
        arg(a, "--output");
        arg(a, target);
        add_lang_job("scip-dotnet", target, a, child_env(l, dotnet_env(home)),
                     lang_fingerprint(repo, [".cs", ".csproj", ".sln", ".slnx", ".props", ".targets"], ["global.json", "NuGet.config"]) { f => stamp(f) });
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
                                      ["compile_commands.json", "build/compile_commands.json"]) { f => stamp(f) });
    }

    if skipped.len > 0 { format(report, untrusted_note(skipped, repo), "\n"); }
    if l.syn {
        // No compiler, no repo code run: a syntax-level map (definitions,
        // bodies, references by name) for the languages above.
        let target = str(out, "/index-syntax.scip");
        var a: u8[>..] = [];
        // `swan syntax-index` (src/syntax.goose), this binary itself: no Bun.
        let swan_bin = str(home, "/bin/swan");
        arg(a, swan_bin);
        arg(a, "syntax-index");
        arg(a, repo);
        arg(a, target);
        var fp: u64 = hash(str("syntax-goose-1\t", swan_bin, "\t", swan_file_size(swan_bin)));
        each_file(repo) { full, name =>
            if syntax_file(full, name) { fp = hash_combine(fp, hash_combine(hash(full), stamp(full))); }
        };
        add_lang_job("syntax-index", target, a, child_env(l, ""), fp);
    }
    map_held.append(trim(skipped[..]));
    if jobs.len == 0 && (l.kt || l.other.len > 0 || skipped.len > 0) {
        // Nothing to index, but the code can still be searched by structure
        // and checked live: an empty map records the repo for search_pattern
        // and the rest.
        for t in ["symbols.tsv", "extents.tsv", "relationships.tsv", "occurrences.tsv"] { write_file(str(out, "/", t), ""); }
        index_main_locked(out, str(out, "/swan.db"), repo, false, report);
        if l.kt || l.other.len > 0 {
            format(report, "\n", if l.kt { "kotlin " } else { "" }, l.other,
                   ": no SCIP indexer ran for these; search_pattern and rewrite_pattern work on them, and live diagnostics where their server is set up");
        }
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
    if clean {
        // A successful indexer must produce this run's file, not leave an old
        // target behind. Reuse metadata was invalidated before planning.
        for job in all_jobs {
            let f = split(job, 1);
            guard f[2].len > 0 else { report.append("clean rebuild unexpectedly planned cached output"); return false; }
            guard !file_exists(f[1]) || delete_file(f[1]) else {
                format(report, "cannot remove prior indexer output: ", f[1]); return false;
            }
        }
    }
    // Start order: an indexer that runs once for its whole language
    // (rust-analyzer, scip-java, scip-clang, ...) before the indexers split
    // into many pieces. One long job queued behind dozens of short pieces
    // would start only when they are nearly done and then be the whole
    // wait (monty: rust-analyzer's 12 s began 11 s in). The report keeps
    // the jobs' own order.
    var order: i64[>..] = [];
    fn tool_of(job: const u8[:]) -> const u8[:] {
        let label = job[..max(0, find(job, "\x01"))];
        let sp = find(label, " ");
        return if sp > 0 { label[..sp] } else { label };
    }
    for pass in 2 {
        for i in all_jobs.len {
            var same = 0;
            for other in all_jobs { if tool_of(other) == tool_of(all_jobs[i]) { same++; } }
            if (same == 1) == (pass == 0) { order.push(i); }
        }
    }
    for i in all_jobs.len { pids.push(0); codes.push(0); began.push(0.0); took.push(0.0); }
    for idx in order {
        let f = split(all_jobs[idx], 1);
        if f[2].len == 0 {
            // reused from the last map: nothing to run
        } else {
            while running >= limit { wait_one(); }
            var launch: u8[>..] = [];
            if sandbox_on() { launch = seal_argv(f[2], repo, out, trusted); } else { launch.append(f[2]); }
            pids[idx] = swan_spawn(launch[..], repo, f[3], str(out, "/log-", idx, ".txt"));
            codes[idx] = -999;
            began[idx] = clock();
            if pids[idx] > 0 { running++; } else { codes[idx] = -1; }
        }
    }
    while running > 0 { wait_one(); }

    var scips: u8[>..] = [];      // NUL-separated index files, for the flattener
    var failed: u8[>..] = [];     // their index files, one per line
    var fresh_scips: u8[>..] = [];  // the index files this map's indexers wrote, one per line
    var ok = true;
    var idx = 0;
    each_split(jobs[..jobs.len - 1], 2) { job =>
        let f = split(job, 1);
        let code = codes[idx];
        if f[0].len > 0 { format(report, f[0], ": ", (took[idx] * 1000.0) as i64, " ms"); }
        if code == 0 && file_exists(f[1]) {
            if f[0].len > 0 { format(fresh_scips, f[1], "\n"); }
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
    if clean && !ok {
        report.append("clean rebuild failed; previous database retained and reuse metadata invalidated");
        return false;
    }
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
    cache_write("index-manifest.tsv", kept_index);
    var listing: u8[>..] = [];
    if list_dir(out, listing) {
        each_split(listing, '\n') { nm =>
            if starts_with(nm, "index-") && ends_with(nm, ".scip") && find(jobs, str(out, "/", nm)) < 0 {
                delete_file(str(out, "/", nm));
            }
        };
    }
    let db = str(out, "/swan.db");
    write_file(str(out, "/content-stamps.tsv"), stamp_lines);
    if !clean && reused_all && file_exists(db) && file_exists(str(out, "/occurrences.tsv")) {
        // No indexer ran, but files edited only in comments or layout still
        // need their rows moved.
        idx_new.append(idx_prev);
        finish_cosmetic(false);
        // Every file's text is the text its rows were built from: the map is
        // current as of this run, so its reference time moves up to it.
        // Without this a file that was edited and put back (or just
        // touched) stayed "stale" through every later refresh, and edits to
        // it were refused with "refresh first" (found 2026-11-17).
        if n_cosmetic == 0 {
            var derr: u8[>..] = [];
            let h = sqlite::open_existing(db, derr);
            if h != 0 {
                let up = sqlite::prepare(h, "UPDATE meta SET value = ?1 WHERE key = 'scip_time'", derr);
                if up != 0 {
                    sqlite::bind_text(up, 1, str(scip_time_of(out)));
                    sqlite::step(up, derr);
                    sqlite::finalize(up);
                }
                sqlite::close(h);
            }
        }
        format(report, if n_cosmetic > 0 { "\nno code changed since the last map" } else { "nothing changed since the last map" },
               "\nswan map: ", ((clock() - t_start) * 1000.0) as i64, " ms in all");
        return ok;
    }
    // Only failed indexers ran (rea's scip-java fails every map): the index
    // files are the ones the map's rows were flattened from, so flattening
    // them again would write the same rows. flattened-inputs.txt is written
    // after the rows are in the database, and removed before a flatten.
    let flat_marker = str(out, "/flattened-inputs.txt");
    var flat_prev: u8[>..] = [];
    if !clean && fresh_scips.len == 0 && file_exists(db) && file_exists(str(out, "/occurrences.tsv")) &&
       read_file(flat_marker, flat_prev) && flat_prev == scips {
        idx_new.append(idx_prev);
        finish_cosmetic(false);
        format(report, "\nflatten: skipped (only failed indexers ran; rows as last flattened)",
               "\nswan map: ", ((clock() - t_start) * 1000.0) as i64, " ms in all, up to ", limit, " indexers at once");
        if !ok { report.append("\n(some indexers failed; see above)"); }
        return ok;
    }
    delete_file(flat_marker);

    // The flattener reads some files' text itself (import statements, C
    // bodies, Rust macros): for rows kept from before, the text they were
    // indexed from.
    write_file(str(out, "/fresh-indexes.txt"), fresh_scips);
    write_file(str(out, "/kept-texts.tsv"), kept_texts());
    delete_file(str(out, "/documents.tsv"));
    // bin/swan-flatten (native/swan-flatten, Rust) flattens the SCIP
    // indexes into rows, a core per index file. It is the only flattener.
    var fl: u8[>..] = [];
    let native_flat = str(home, "/bin/swan-flatten");
    guard file_exists(native_flat) else {
        format(report, "swan-flatten is missing at ", native_flat, ": rebuild with scripts/build.sh (needs cargo) or reinstall Swan\n");
        return false;
    }
    arg(fl, native_flat);
    arg(fl, "--fresh");
    arg(fl, str(out, "/fresh-indexes.txt"));
    arg(fl, "--texts");
    arg(fl, str(out, "/kept-texts.tsv"));
    arg(fl, "--root");
    arg(fl, repo);
    let parts = split(scips[..scips.len - 1], 0);
    arg(fl, parts[0]);
    arg(fl, out);
    for k in 1..parts.len { arg(fl, parts[k]); }
    var o: u8[>..] = [];
    if clean {
        for name in ["symbols.tsv", "extents.tsv", "relationships.tsv", "occurrences.tsv"] {
            let path = str(out, "/", name);
            guard !file_exists(path) || delete_file(path) else {
                format(report, "cannot remove prior flattened output: ", path); return false;
            }
        }
    }
    let t_flat = clock();
    guard run_step("flatten", fl, home, child_env(l, ""), 600000, o) == 0 else { format(report, "flatten failed"); return false; }
    format(report, "flatten: ", ((clock() - t_flat) * 1000.0) as i64, " ms\n");
    if clean {
        for name in ["symbols.tsv", "extents.tsv", "relationships.tsv", "occurrences.tsv"] {
            guard file_exists(str(out, "/", name)) else {
                format(report, "clean rebuild missing flattened output: ", name, "; previous database retained"); return false;
            }
        }
        guard clean_rows_valid(out, report) else { return false; }
    }
    index_main_locked(out, db, repo, !clean && file_exists(db), report);
    write_file(flat_marker, scips);
    var docs: u8[>..] = [];
    read_file(str(out, "/documents.tsv"), docs);
    note_indexed(docs);
    finish_cosmetic(true);
    if clean && pending_cache.len > 0 {
        let entries = split(pending_cache[..pending_cache.len - 1], 0);
        for i in entries.len / 2 {
            if !write_file(str(out, "/", entries[i * 2]), entries[i * 2 + 1]) {
                format(report, "\nwarning: fresh database published but cache could not be saved: ", entries[i * 2]);
            }
        }
    }
    format(report, "\nswan map: ", ((clock() - t_start) * 1000.0) as i64, " ms in all, up to ", limit, " indexers at once");
    if !ok { report.append("\n(some indexers failed; see above)"); }
    return ok;
}
