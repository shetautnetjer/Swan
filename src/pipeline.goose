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

// Gradle plugins that make a module an Android one.
let ANDROID_PLUGINS = ["com.android.application", "com.android.library", "com.android.test",
                       "com.android.dynamic-feature"];

// Which Android plugin id s names in quotes ("id" or 'id', or "id:version"
// in a version catalog): its index in ANDROID_PLUGINS, or -1.
fn android_plugin_in(s: const u8[:]) -> i64 {
    for p, k in ANDROID_PLUGINS {
        for q in ["\"", "'"] {
            if find(s, str(q, p, q)) >= 0 || find(s, str(q, p, ":")) >= 0 { return k; }
        }
    }
    return -1;
}

// The plugin aliases in gradle/libs.versions.toml that name an Android
// plugin, as build files write them ("libs.plugins.android.application"),
// each with its ANDROID_PLUGINS index: "alias\tindex" lines. Gradle's
// accessors turn '-' and '_' in a key into '.'. Other catalogs are not read.
fn android_catalog_aliases(repo: const u8[:]) -> u8[>..] {
    var out: u8[>..] = [];
    var toml: u8[>..] = [];
    guard read_file(str(repo, "/gradle/libs.versions.toml"), toml) else { return out; }
    var plugins = false;
    each_split(toml, '\n') { raw =>
        let line = trim(raw);
        if starts_with(line, "[") {
            plugins = starts_with(line, "[plugins]");
        } else if plugins && !starts_with(line, "#") {
            let eq = find(line, "=");
            let k = if eq > 0 { android_plugin_in(line[eq + 1..]) } else { -1 };
            if k >= 0 {
                var name: u8[>..] = str("libs.plugins.", trim(line[..eq]));
                for i in 0..name.len { if name[i] == '-' || name[i] == '_' { name[i] = '.'; } }
                format(out, name, "\t", k, "\n");
            }
        }
    };
    return out;
}

// Slashy strings occur where an expression may start; a slash after a value
// is division instead. The detector does not evaluate arbitrary Groovy code.
fn groovy_slashy_start(s: const u8[:], at: i64) -> bool {
    var i = at;
    while i > 0 && (s[i - 1] == ' ' || s[i - 1] == '\t' || s[i - 1] == '\n' || s[i - 1] == '\r') { i--; }
    if i == 0 { return true; }
    let c = s[i - 1];
    if c == '=' || c == '(' || c == '[' || c == '{' || c == ',' || c == ':' || c == '~' || c == '?' { return true; }
    if c == '+' || c == '-' {
        // After postfix ++ or -- the slash is division, not a new string.
        return i < 2 || s[i - 2] != c;
    }
    if c == '*' || c == '%' || c == '&' || c == '|' || c == '^' || c == '!' || c == '<' || c == '>' { return true; }
    let end = i;
    while i > 0 && is_ident(s[i - 1]) { i--; }
    let word = s[i..end];
    return word == "return" || word == "case" || word == "throw" || word == "assert";
}

// A build file without its comments: /* ... */ (its newlines kept, so lines
// stay lines) and // to the end of the line, neither inside a quoted string.
// Kotlin and Groovy triple-quoted strings can contain newlines and comments.
fn strip_gradle_comments(s: const u8[:], kotlin: bool) -> u8[>..] {
    var out: u8[>..] = [];
    var q: u8 = 0;
    var triple = false;
    var slashy = false;
    var dollar_slashy = false;
    var i = 0;
    while i < s.len {
        let c = s[i];
        if dollar_slashy {
            out.push(c);
            if c == '$' && i + 1 < s.len && (s[i + 1] == '$' || s[i + 1] == '/') {
                out.push(s[i + 1]); i++;
            } else if c == '/' && i + 1 < s.len && s[i + 1] == '$' {
                out.push('$'); i++; dollar_slashy = false;
            }
        } else if slashy {
            out.push(c);
            if c == '\\' && i + 1 < s.len && s[i + 1] == '/' { out.push('/'); i++; }
            else if c == '/' { slashy = false; }
        } else if q != 0 {
            out.push(c);
            if c == '\\' && (!triple || !kotlin) && i + 1 < s.len { out.push(s[i + 1]); i++; }
            else if triple && c == q && i + 2 < s.len && s[i + 1] == q && s[i + 2] == q {
                out.push(q); out.push(q); i += 2; q = 0; triple = false;
            } else if !triple && (c == q || c == '\n') { q = 0; }
        } else if c == '/' && i + 1 < s.len && s[i + 1] == '*' {
            i += 2;
            var depth = 1;
            while i < s.len && depth > 0 {
                if s[i] == '/' && i + 1 < s.len && s[i + 1] == '*' && kotlin { depth++; i += 2; continue; }
                if s[i] == '*' && i + 1 < s.len && s[i + 1] == '/' { depth--; i += 2; continue; }
                if s[i] == '\n' { out.push('\n'); }
                i++;
            }
            continue;
        } else if c == '/' && i + 1 < s.len && s[i + 1] == '/' {
            while i < s.len && s[i] != '\n' { i++; }
            continue;
        } else if !kotlin && c == '$' && i + 1 < s.len && s[i + 1] == '/' {
            out.push(c); out.push('/'); i++; dollar_slashy = true;
        } else if !kotlin && c == '/' && groovy_slashy_start(out, out.len) {
            out.push(c); slashy = true;
        } else {
            out.push(c);
            if c == '"' || c == '\'' {
                q = c;
                if i + 2 < s.len && s[i + 1] == c && s[i + 2] == c {
                    triple = true; out.push(c); out.push(c); i += 2;
                }
            }
        }
        i++;
    }
    return out;
}

// Mask reaction calls, including multiline argument lists, but keep the
// surrounding code and newlines. A plugin applied in a callback still counts.
fn strip_gradle_reactions(s: const u8[:], kotlin: bool) -> u8[>..] {
    var out: u8[>..] = [];
    var q: u8 = 0;
    var triple = false;
    var depth = 0;
    var i = 0;
    while i < s.len {
        let c = s[i];
        if depth == 0 && q == 0 && (i == 0 || !is_ident(s[i - 1])) {
            var n = 0;
            for name in ["withId", "hasPlugin", "withPlugin"] {
                if starts_with(s[i..], name) { n = name.len; }
            }
            if n > 0 {
                var j = i + n;
                while j < s.len && (s[j] == ' ' || s[j] == '\t' || s[j] == '\n' || s[j] == '\r') { j++; }
                if j < s.len && s[j] == '(' {
                    while i <= j { out.push(if s[i] == '\n' { '\n' } else { ' ' }); i++; }
                    depth = 1;
                    continue;
                }
            }
        }
        if q != 0 {
            out.push(if depth > 0 && c != '\n' { ' ' } else { c });
            if c == '\\' && (!triple || !kotlin) && i + 1 < s.len {
                i++; out.push(if depth > 0 && s[i] != '\n' { ' ' } else { s[i] });
            } else if triple && c == q && i + 2 < s.len && s[i + 1] == q && s[i + 2] == q {
                out.push(if depth > 0 { ' ' } else { q }); out.push(if depth > 0 { ' ' } else { q });
                i += 2; q = 0; triple = false;
            } else if !triple && (c == q || c == '\n') { q = 0; }
        } else {
            if c == '"' || c == '\'' {
                q = c;
                if i + 2 < s.len && s[i + 1] == c && s[i + 2] == c { triple = true; }
            } else if depth > 0 && c == '(' { depth++; }
            else if depth > 0 && c == ')' { depth--; out.push(' '); i++; continue; }
            out.push(if depth > 0 && c != '\n' { ' ' } else { c });
            if triple && q == c && i + 2 < s.len && s[i + 1] == c && s[i + 2] == c {
                out.push(if depth > 0 { ' ' } else { c }); out.push(if depth > 0 { ' ' } else { c }); i += 2;
            }
        }
        i++;
    }
    return out;
}

// Whether a plugin entry is only declared, with `apply false` / `.apply(false)`
// on its own line or on the chained lines after it (`.version(...)`).
fn gradle_apply_false(lines: const u8[:][:], at: i64) -> bool {
    var j = at;
    while j < lines.len {
        let line = trim(lines[j]);
        guard j == at || starts_with(line, ".") || starts_with(line, "apply ") || starts_with(line, "version ") else { return false; }
        if find(line, "apply false") >= 0 || find(line, "apply(false)") >= 0 { return true; }
        j++;
    }
    return false;
}

// The Android plugin a build file applies (its ANDROID_PLUGINS index), or
// -1: by id in a plugins {} block, `id("...")`, `id '...'` or `apply
// plugin:`, or by `alias(libs.plugins....)` from the version catalog.
// Comments are skipped. An entry with `apply false`, on its line or the
// chained lines after it, only declares the plugin (a root build file does
// that for its modules), and `plugins.withId(...)`, `hasPlugin(...)` and
// `withPlugin(...)` only react to it.
fn android_plugin_of(build: const u8[:], aliases: const u8[:], kotlin: bool) -> i64 {
    var k = -1;
    let text = strip_gradle_reactions(strip_gradle_comments(build, kotlin), kotlin);
    let lines = split(text, '\n');
    for raw, at in lines {
        let line = trim(raw);
        guard k < 0 else { continue; }
        guard !gradle_apply_false(lines, at) else { continue; }
        k = android_plugin_in(line);
        let al = find(line, "alias");
        if k < 0 && al >= 0 {
            var i = al + 5;
            while i < line.len && (line[i] == '(' || line[i] == ' ') { i++; }
            let start = i;
            while i < line.len && (is_ident(line[i]) || line[i] == '.') { i++; }
            let name = line[start..i];
            each_split(aliases, '\n') { a =>
                let tab = find(a, "\t");
                if tab > 0 && a[..tab] == name {
                    let n, ok = parse_int(a[tab + 1..]);
                    if ok { k = n; }
                }
            };
        }
    }
    return k;
}

// The modules settings.gradle(.kts) includes, as Gradle paths (":app",
// ":core:data"), one per line: every quoted name in an `include(...)` or
// Groovy `include '...', '...'`, which may run over several lines; names
// with ".." or "/" are skipped. Modules moved elsewhere with projectDir are
// looked for at their default place.
fn gradle_includes(repo: const u8[:]) -> u8[>..] {
    var out: u8[>..] = [];
    var s: u8[>..] = [];
    let kotlin = read_file(str(repo, "/settings.gradle.kts"), s);
    guard kotlin || read_file(str(repo, "/settings.gradle"), s) else { return out; }
    let text = strip_gradle_comments(s, kotlin);
    var open = false;
    var depth = 0;
    var triple: u8 = 0;
    var slashy = false;
    var dollar_slashy = false;
    var offset = 0;
    each_split(text, '\n') { raw =>
        let line = trim(raw);
        let line_start = offset;
        offset += raw.len + 1;
        let in_string = triple != 0 || slashy || dollar_slashy;
        var q: u8 = 0;
        var i = 0;
        while i < raw.len {
            let c = raw[i];
            if dollar_slashy {
                if c == '$' && i + 1 < raw.len && (raw[i + 1] == '$' || raw[i + 1] == '/') { i += 2; continue; }
                if c == '/' && i + 1 < raw.len && raw[i + 1] == '$' { dollar_slashy = false; i += 2; continue; }
                i++; continue;
            }
            if slashy {
                if c == '\\' && i + 1 < raw.len && raw[i + 1] == '/' { i += 2; continue; }
                if c == '/' { slashy = false; }
                i++; continue;
            }
            if c == '\\' && (q != 0 || (triple != 0 && !kotlin)) && i + 1 < raw.len { i += 2; continue; }
            if triple != 0 {
                if c == triple && i + 2 < raw.len && raw[i + 1] == c && raw[i + 2] == c { triple = 0; i += 3; continue; }
            } else if q != 0 {
                if c == q { q = 0; }
            } else if !kotlin && c == '$' && i + 1 < raw.len && raw[i + 1] == '/' {
                dollar_slashy = true; i += 2; continue;
            } else if !kotlin && c == '/' && groovy_slashy_start(text, line_start + i) {
                slashy = true;
            } else if c == '"' || c == '\'' {
                if i + 2 < raw.len && raw[i + 1] == c && raw[i + 2] == c { triple = c; i += 3; continue; }
                q = c;
            }
            i++;
        }
        guard !in_string;
        let starts = starts_with(line, "include") && line.len > 7 && (line[7] == '(' || line[7] == ' ' || line[7] == '\t');
        guard open || starts;
        var q: u8 = 0;
        var from = 0;
        for c, i in line {
            if q != 0 {
                if c == q {
                    let name = line[from..i];
                    let path: u8[>..] = if starts_with(name, ":") { str(name) } else { str(":", name) };
                    // A name with ".." or "/" is no Gradle path; it would
                    // send the build-file lookup outside the module tree.
                    let bad = find(name, "..") >= 0 || find(name, "/") >= 0;
                    if name.len > 0 && !bad && !contains_line(out, path) { format(out, path, "\n"); }
                    q = 0;
                }
            } else if c == '"' || c == '\'' {
                q = c;
                from = i + 1;
            } else if c == '(' {
                depth++;
            } else if c == ')' {
                depth--;
            }
        }
        open = depth > 0 || ends_with(line, ",");
    };
    return out;
}

// The Gradle tasks scip-java runs, one per line. Its own scipPrintDependencies
// (the dependency versions behind callees in packages) and scipCompileAll
// (the compiles) do for a plain JVM build. On an Android build (AGP 9, with
// its built-in Kotlin) scipPrintDependencies dies of a
// ConcurrentModificationException (WriteDependencies walks the project's
// configurations while AGP adds some), and scipCompileAll alone has no
// actions there; so when any module looks Android, it goes, and the Kotlin
// compiles are named instead: compileDebugKotlin and compileDebugUnitTestKotlin,
// unqualified. Gradle runs an unqualified task in every project that has it
// and fails only if none does, so a wrong guess about which module is
// Android costs nothing, and a module without a debug variant or without
// Kotlin is just passed over. compileDebugUnitTestKotlin is left out when
// every Android module found is com.android.test (all instrumented tests,
// no unit tests). The variant is taken to be debug: nothing short of running
// Gradle says which variants a module has, and a repo where no module has
// compileDebugKotlin (only flavored variants) fails the run.
// `clean` first: the compiles must run for scip-java to see them.
fn gradle_scip_tasks(repo: const u8[:]) -> u8[>..] {
    let aliases = android_catalog_aliases(repo);
    var android = false;
    var unit = false;
    fn module(dir: const u8[:]) {
        var b: u8[>..] = [];
        let kotlin = read_file(str(dir, "/build.gradle.kts"), b);
        guard kotlin || read_file(str(dir, "/build.gradle"), b) else { return; }
        let k = android_plugin_of(b, aliases, kotlin);
        guard k >= 0 else { return; }
        android = true;
        if ANDROID_PLUGINS[k] != "com.android.test" { unit = true; }
    }
    module(repo);
    each_split(gradle_includes(repo), '\n') { path =>
        guard path.len > 1;
        var dir: u8[>..] = str(repo, "/", path[1..]);
        for i in (repo.len + 1)..dir.len { if dir[i] == ':' { dir[i] = '/'; } }
        module(dir);
    };
    var tasks: u8[>..] = [];
    tasks.append("clean\n");
    if android {
        tasks.append("compileDebugKotlin\n");
        if unit { tasks.append("compileDebugUnitTestKotlin\n"); }
    } else {
        tasks.append("scipPrintDependencies\n");
    }
    tasks.append("scipCompileAll\n");
    return tasks;
}

// The environment children get: a repo virtualenv first on PATH, and room
// for scip-python and pyright on big repos.
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

// One more environment entry, for child_env's `extra`.
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

// Sealed by default. SWAN_SANDBOX=0 turns the seal off (indexers run the old
// way); anything else, including unset, means on.
fn sandbox_on() -> bool {
    var v: u8[>..] = [];
    if env("SWAN_SANDBOX", v) && v == "0" { return false; }
    return true;
}

// Wrap a child's argv so it runs sealed via <swan_home>/bin/eggshell:
//   eggshell <repo> <out> [--allow-net --rw <dir>...] -- <inner argv...>
// Every repo is sealed: no host writes except the map dir, no host sockets.
// Trust only loosens the seal: a trusted repo gets the network and the
// writable directories its build tools need (the repo itself for obj/ and
// build/, Cargo's home, Swan's Gradle and .NET caches); it never runs
// unsealed. The runner refuses (exit 3) if the kernel cannot seal, which
// surfaces as a failed step rather than an unconfined run.
fn seal_argv(inner: const u8[:], repo: const u8[:], out: const u8[:], trusted: bool) -> u8[>..] {
    var a: u8[>..] = [];
    arg(a, str(swan_home(), "/bin/eggshell"));
    arg(a, repo);
    arg(a, out);
    if trusted {
        arg(a, "--allow-net");
        let t = str(swan_home(), "/.tools");
        arg(a, "--rw"); arg(a, repo);
        arg(a, "--rw"); arg(a, toolchain_home("CARGO_HOME", ".cargo"));
        arg(a, "--rw"); arg(a, str(t, "/gradle-home"));
        arg(a, "--rw"); arg(a, str(t, "/dotnet-home"));
        arg(a, "--rw"); arg(a, str(t, "/nuget"));
    }
    arg(a, "--");
    a.append(inner);
    return a;
}

// $VAR if set, else $HOME/<sub>: where rustup and Cargo keep toolchains and
// crates. Sealed children get a scratch HOME, so these are passed explicitly.
fn toolchain_home(name: const u8[:], sub: const u8[:]) -> u8[>..] {
    var v: u8[>..] = [];
    if env(name, v) && v.len > 0 { return v; }
    var h: u8[>..] = [];
    env("HOME", h);
    return str(h, "/", sub);
}

// Passes $VAR to a sealed child when this machine keeps that folder where
// toolchain_home says: $VAR is set, or $HOME/<sub> is there. Otherwise the
// variable is left alone. A machine with rustup installed for everyone has
// no ~/.rustup: its `cargo` is a small script that sets RUSTUP_HOME itself
// when nothing else did, and naming ~/.rustup made rustup try to create it
// inside the seal ("could not create home directory ... Read-only file
// system"), so every Rust map there failed (found 2026-11-17 in a clean
// Ubuntu microVM).
fn add_toolchain_env(renv: u8[>..]&, name: const u8[:], sub: const u8[:]) {
    var v: u8[>..] = [];
    let p = toolchain_home(name, sub);
    if (env(name, v) && v.len > 0) || is_dir(p) { renv.append(env_entry(name, p)); }
}

// Run one step of the map sealed when the sandbox is on (see seal_argv).
fn sealed_run(argv: const u8[:], repo: const u8[:], out: const u8[:], trusted: bool, env: const u8[:],
              timeout_ms: i64, o: u8[>..]&, e: u8[>..]&) -> i32 {
    if !sandbox_on() { return swan_run(argv, repo, env, timeout_ms, o, e); }
    return swan_run(seal_argv(argv, repo, out, trusted)[..], repo, env, timeout_ms, o, e);
}

fn sealed_step(label: const u8[:], argv: const u8[:], repo: const u8[:], out: const u8[:], trusted: bool,
               env: const u8[:], timeout_ms: i64, o: u8[>..]&) -> i32 {
    if !sandbox_on() { return run_step(label, argv, repo, env, timeout_ms, o); }
    return run_step(label, seal_argv(argv, repo, out, trusted)[..], repo, env, timeout_ms, o);
}

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

// The first segments of the modules a Python file imports: F(segment), or
// F(".") for a relative import. Line by line, which is enough to tell a
// script that stands alone from one that needs the repo's own packages.
fn py_imports<F>(text: const u8[:]) {
    each_split(text, '\n') { raw =>
        let l = trim(raw);
        if starts_with(l, "from ") {
            let m = trim(l[5..]);
            if m.len > 0 && m[0] == '.' { F("."); }
            else {
                var e = 0;
                while e < m.len && (is_alnum(m[e]) || m[e] == '_') { e++; }
                if e > 0 { F(m[..e]); }
            }
        } else if starts_with(l, "import ") {
            each_split(l[7..], ',') { part =>
                let m = trim(part);
                var e = 0;
                while e < m.len && (is_alnum(m[e]) || m[e] == '_') { e++; }
                if e > 0 { F(m[..e]); }
            };
        }
    };
}

fn is_alnum(c: u8) -> bool { (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') }

// What scip-python is told for a piece: a prefix piece ("dir/ab*": every
// path starting with dir/ab) loses its star; a folder or file piece is its
// own path.
fn piece_target(piece: const u8[:]) -> const u8[:] {
    return if piece.len > 0 && piece[piece.len - 1] == '*' { piece[..piece.len - 1] } else { piece };
}

// Splits everything directly in `dir` (its files, and its subfolders whole)
// into prefix pieces, appended to plan as "dir/prefix*". False, with plan
// untouched, when the folder's files do not stand alone (more than one in
// ten imports a name that is a folder or module of this repo, or imports
// relatively) or no clean split exists; the caller then keeps the folder
// whole.
fn plan_prefix_pieces(repo: const u8[:], dir: const u8[:], paths: const u8[:][:], sizes: const i64[:], limit: i64,
                      plan: u8[>..]&) -> bool {
    // This repo's own importable names: every folder on a .py file's path,
    // and every module's file name.
    var own = dictionary<u64, bool> {};
    for p in paths {
        var at = 0;
        while at < p.len {
            let sl = find(p[at..], "/");
            if sl < 0 {
                let stem = if ends_with(p[at..], ".py") { p[at..p.len - 3] } else { p[at..] };
                own.insert(hash(stem), true);
                break;
            }
            own.insert(hash(p[at..at + sl]), true);
            at = at + sl + 1;
        }
    }
    // The folder's children: a name, how many .py files and bytes it holds.
    var names: u8[>..] = [];
    var e_off: i64[>..] = [];
    var e_len: i64[>..] = [];
    var e_files: i64[>..] = [];
    var e_bytes: i64[>..] = [];
    var at_name = dictionary<u64, i64> {};
    var loose = 0;
    var needs_repo = 0;
    for p, i in paths {
        let inside = dir.len == 0 || (starts_with(p, dir) && p.len > dir.len && p[dir.len] == '/');
        if inside {
            let rest = if dir.len == 0 { p } else { p[dir.len + 1..] };
            let slash = find(rest, "/");
            let name = if slash < 0 { rest } else { rest[..slash] };
            let known = at_name.get(hash(name));
            if known {
                let k: i64 = known;
                e_files[k] += 1;
                e_bytes[k] += sizes[i];
            } else {
                at_name.insert(hash(name), e_off.len);
                e_off.push(names.len);
                e_len.push(name.len);
                e_files.push(1);
                e_bytes.push(sizes[i]);
                names.append(name);
            }
            if slash < 0 {
                loose++;
                var text: u8[>..] = [];
                var full: u8[>..] = [];
                format(full, repo, "/", p);
                if read_file(full, text) {
                    var uses = false;
                    py_imports(text) { seg => if seg == "." || own.contains(hash(seg)) { uses = true; } };
                    if uses { needs_repo++; }
                }
            }
        }
    }
    guard loose > 0 && needs_repo * 10 <= loose else { return false; }

    // Groups of children sharing a name prefix: (one member, prefix length).
    // The biggest group over the limits is split by its next byte, until none
    // is over, or it cannot be (a name ends where the prefix does), or there
    // would be too many groups.
    var g_rep: i64[>..] = [];
    var g_len: i64[>..] = [];
    var g_done: i64[>..] = [];
    g_rep.push(0); g_len.push(0); g_done.push(0);
    fn name_of(k: i64) -> const u8[:] { names[e_off[k]..e_off[k] + e_len[k]] }
    fn in_group(k: i64, g: i64) -> bool { starts_with(name_of(k), name_of(g_rep[g])[..g_len[g]]) }
    // Lengthens a group's prefix to all that its members share.
    fn lengthen(g: i64) {
        var l = -1;
        let first = name_of(g_rep[g]);
        for k in e_off.len {
            if in_group(k, g) {
                let nm = name_of(k);
                var c = 0;
                while c < nm.len && c < first.len && nm[c] == first[c] { c++; }
                if l < 0 || c < l { l = c; }
            }
        }
        if l > g_len[g] { g_len[g] = l; }
    }
    lengthen(0);
    while true {
        var pick = -1;
        var pick_files = 0;
        for g in g_rep.len {
            if g_done[g] == 0 {
                var files = 0;
                var bytes = 0;
                for k in e_off.len { if in_group(k, g) { files += e_files[k]; bytes += e_bytes[k]; } }
                if (files > PY_PIECE_FILES || bytes > limit) && files > pick_files { pick = g; pick_files = files; }
            }
        }
        if pick < 0 { break; }
        // Its members by their next byte; a name that ends here stops the split.
        var next_seen: bool[256] = [false; 256];
        var kids = 0;
        var ends_here = false;
        for k in e_off.len {
            if in_group(k, pick) {
                let nm = name_of(k);
                if nm.len == g_len[pick] { ends_here = true; }
                else if !next_seen[nm[g_len[pick]]] { next_seen[nm[g_len[pick]]] = true; kids++; }
            }
        }
        if ends_here || kids < 2 || g_rep.len - 1 + kids > PY_PIECE_GROUPS { g_done[pick] = 1; continue; }
        let plen = g_len[pick];
        var first_kid = true;
        for b in 256 {
            if next_seen[b] {
                var rep = -1;
                for k in e_off.len {
                    if rep < 0 && in_group(k, pick) && name_of(k).len > plen && name_of(k)[plen] == (b as! u8) { rep = k; }
                }
                // The first child takes the parent's slot (after the scan above, which still reads it).
                if first_kid { first_kid = false; g_rep.push(rep); g_len.push(plen + 1); g_done.push(0); }
                else { g_rep.push(rep); g_len.push(plen + 1); g_done.push(0); }
            }
        }
        // Drop the parent: move the last group into its slot.
        let last = g_rep.len - 1;
        g_rep[pick] = g_rep[last]; g_len[pick] = g_len[last]; g_done[pick] = g_done[last];
        g_rep.pop(); g_len.pop(); g_done.pop();
        for g in g_rep.len { if g_done[g] == 0 { lengthen(g); } }
    }
    // One group left means nothing was split; "." and ".." cannot be told to
    // scip-python as a prefix (it would resolve them to the folder).
    guard g_rep.len > 1 else { return false; }
    for g in g_rep.len {
        let pre = name_of(g_rep[g])[..g_len[g]];
        if pre.len == 0 || pre == "." || pre == ".." { return false; }
    }
    // In name order, so the plan is the same every time.
    var order: i64[>..] = [];
    for g in g_rep.len { order.push(g); }
    sort(order) { a, b => bytes_before(name_of(g_rep[a])[..g_len[a]], name_of(g_rep[b])[..g_len[b]]) };
    for g in order {
        if dir.len > 0 { format(plan, dir, "/"); }
        format(plan, name_of(g_rep[g])[..g_len[g]], "*\n");
    }
    return true;
}

fn bytes_before(a: const u8[:], b: const u8[:]) -> bool {
    let n = min(a.len, b.len);
    for i in n { if a[i] != b[i] { return a[i] < b[i]; } }
    return a.len < b.len;
}

// Splits a repo's Python into pieces for parallel scip-python runs
// (--target-only), about k of similar size. A folder bigger than its share
// is split into its subfolders; a few .py files directly in it become
// pieces of their own; many of them stay together as the folder, unless
// they stand alone, when they are split by filename prefix
// (plan_prefix_pieces). Returns the pieces, relative to repo, one per line:
// a folder or file path, or "path/prefix*"; a single empty line means "the
// whole repo in one run".
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
        // scip-python takes one path per run, and every run analyses the
        // whole program again. A folder with more loose .py files than
        // there are pieces (a flat tests/ of hundreds of files) would become
        // one run per file: hundreds of whole-program runs. Index such a
        // folder in one run instead; at the root, index everything in one.
        var loose = 0;
        for p in paths {
            let inside = dir.len == 0 || (starts_with(p, dir) && p.len > dir.len && p[dir.len] == '/');
            if inside && find(if dir.len == 0 { p } else { p[dir.len + 1..] }, "/") < 0 { loose++; }
        }
        if loose > k {
            // Unless its files stand alone. scip-python's --target-only keeps
            // every path that starts with the text it is given, so a folder
            // of scripts that import nothing of the repo's own (a test corpus
            // of standalone cases) is split by filename prefix, a few dozen
            // files to a run, on every core: each run then loads almost
            // nothing besides its own files. Files that import the repo's
            // packages stay together, since every run would load those again.
            if loose > PY_PIECE_FILES && plan_prefix_pieces(repo, dir, paths, sizes, limit, plan) { continue; }
            if dir.len == 0 { plan.clear(); plan.push('\n'); return plan; }
            plan.append(dir); plan.push('\n');
            continue;
        }
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

// Whether content-stamps.tsv already holds this file's stamp (same size and
// mtime), so map_main's `stamp` would not read it.
fn stamp_known(prev: const u8[:], prev_at: dictionary<u64, i64>&, rel: const u8[:], full: const u8[:]) -> bool {
    let line = line_of_path(prev, prev_at, rel);
    guard line.len > 0 else { return false; }
    let f = split(line, '\t');
    return f.len == 6 && f[1] == str(swan_file_size(full)) && f[2] == str(swan_mtime_ns(full));
}

// How many stamp workers to start: $SWAN_STAMP_JOBS, else every core, at
// most 32. 1 stamps in this process, as before.
fn stamp_jobs() -> i64 {
    var v: u8[>..] = [];
    if env("SWAN_STAMP_JOBS", v) {
        let n, ok = parse_int(v);
        if ok && n > 0 { return n; }
    }
    return max(1, min(32, swan_cpu_count() as i64));
}

// A first map parses every TypeScript, JavaScript and Python file to stamp
// its code (src/change.goose), one after another: 6.6 s on rea. This stamps
// the files content-stamps.tsv does not already hold in `swan stamp-worker`
// processes, one per core, and leaves their lines in `pre`. The workers run
// the same code (stamp_file), so a stamp is the same whichever process made
// it; a worker that fails leaves its files to be stamped here.
fn prestamp(repo: const u8[:], out: const u8[:], texts_dir: const u8[:], prev: const u8[:], prev_at: dictionary<u64, i64>&,
            pre: u8[>..]&, report: u8[>..]&) {
    let k_max = stamp_jobs();
    guard k_max > 1 else { return; }
    var todo: u8[>..] = [];        // relative paths, one per line
    var n = 0;
    each_file(repo) { full, name =>
        guard cosmetic_lang(name).len > 0;
        let rel = full[repo.len + 1..];
        guard !stamp_known(prev, prev_at, rel, full);
        format(todo, rel, "\n");
        n++;
    };
    // Below a few hundred files starting processes costs more than it saves.
    var min_files: i64 = 256;
    var mv: u8[>..] = [];
    if env("SWAN_STAMP_MIN", mv) {
        let m, ok = parse_int(mv);
        if ok && m > 0 { min_files = m; }
    }
    guard n >= min_files else { return; }
    let k = max(1, min(k_max, n / max(1, min(64, min_files))));
    var mode: u8[>..] = [];
    if env("SWAN_STAMP_MODE", mode) && mode == "threads" {
        prestamp_threads(repo, texts_dir, todo, n, k, pre, report);
        return;
    }
    var exe: u8[>..] = [];
    guard swan_exe_path(exe) else { return; }
    let t0 = clock();
    var started = 0;
    var pids: i64[>..] = [];
    for w in k {
        let list = str(out, "/prestamp-", w, ".txt");
        delete_file(str(out, "/prestamp-", w, ".tsv"));
        var mine: u8[>..] = [];    // every k-th file, so big and small files spread evenly
        var i = 0;
        each_split(todo, '\n') { rel =>
            guard rel.len > 0;
            if i % k == w { format(mine, rel, "\n"); }
            i++;
        };
        guard write_file(list, mine) else { pids.push(0); continue; }
        var a: u8[>..] = [];
        arg(a, exe);
        arg(a, "stamp-worker");
        arg(a, repo);
        arg(a, list);
        arg(a, str(out, "/prestamp-", w, ".tsv"));
        arg(a, texts_dir);
        let pid = swan_spawn(a[..], repo, "", str(out, "/prestamp-log-", w, ".txt"));
        pids.push(pid);
        if pid > 0 { started++; }
    }
    var codes: i32[>..] = [];
    for w in k { codes.push(-1); }
    while started > 0 {
        var code: i32 = 0;
        let pid = swan_wait_any(code);
        guard pid > 0 else { started = 0; continue; }
        for p, w in pids { if p == pid { codes[w] = code; started--; } }
    }
    var used = 0;
    for w in k {
        let part = str(out, "/prestamp-", w, ".tsv");
        if codes[w] == 0 {
            var t: u8[>..] = [];
            if read_file(part, t) { pre.append(t); used++; }
        }
        delete_file(part);
        delete_file(str(out, "/prestamp-", w, ".txt"));
        delete_file(str(out, "/prestamp-log-", w, ".txt"));
    }
    format(report, "stamps: ", n, " files on ", used, " of ", k, " workers in ", ((clock() - t0) * 1000.0) as i64, " ms\n");
}

// The same work on Goose threads instead of processes: the files go into a
// queue, k workers take them and send each stamp line back. Goose threads
// share no memory, so a job and a line are copied through the queue.
struct StampJob { spec: u8[] }      // repo \x01 texts dir \x01 relative path; empty: stop
struct StampDone { line: u8[] }

thread_fn stamp_thread() {
    loop {
        let job = qget<StampJob>();
        guard job.spec.len > 0 else { break; }
        let f = split(job.spec, 1);
        var line: u8[>..] = [];
        stamp_line(f[0], f[2], f[1], line);
        qput(StampDone { line: copy(line) });
    }
}

fn prestamp_threads(repo: const u8[:], texts_dir: const u8[:], todo: const u8[:], n: i64, k_want: i64,
                    pre: u8[>..]&, report: u8[>..]&) {
    let t0 = clock();
    let k = max(1, min(k_want, hardware_threads()));
    var queued = 0;
    each_split(todo, '\n') { rel =>
        guard rel.len > 0;
        var spec: u8[>..] = [];
        spec.append(repo); spec.push(1); spec.append(texts_dir); spec.push(1); spec.append(rel);
        qput(StampJob { spec: copy(spec) });
        queued++;
    };
    for i in k { qput(StampJob { spec: [] }); }
    var ids: i64[>..] = [];
    for i in k { ids.push(thread_spawn(stamp_thread)); }
    for d in queued {
        let r = qget<StampDone>();
        pre.append(r.line);
    }
    for id in ids { thread_wait(id); }
    format(report, "stamps: ", n, " files on ", k, " threads in ", ((clock() - t0) * 1000.0) as i64, " ms\n");
}

// One file's stamp line, as map_main's `stamp` writes it to
// content-stamps.tsv: "path\tsize\tmtime\tstamp\traw\tc|b". Keeps the text
// of a file stamped by its code in texts_dir.
fn stamp_line(repo: const u8[:], rel: const u8[:], texts_dir: const u8[:], line: u8[>..]&) {
    let full = str(repo, "/", rel);
    let size = swan_file_size(full);
    let mt = swan_mtime_ns(full);
    var text: u8[>..] = [];
    read_file(full, text);
    let raw = hash(text[..]);
    var st = raw;
    var by_code = false;
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
    format(line, rel, "\t", size, "\t", mt, "\t", st as! i64, "\t", raw as! i64, "\t", if by_code { "c" } else { "b" }, "\n");
}

// swan stamp-bench <repo> <out-dir>: the stamping a first map does, alone,
// timed, its lines written to <out-dir>/stamps.tsv. SWAN_STAMP_JOBS=1 stamps
// in this process, file after file; otherwise prestamp runs with
// SWAN_STAMP_MODE (processes, the default, or threads).
fn stamp_bench_main(repo_arg: const u8[:], out_arg: const u8[:]) -> bool {
    let repo = abs_path(repo_arg);
    make_dir(out_arg);
    let out = abs_path(out_arg);
    let texts = str(out, "/texts");
    make_dir(texts);
    var prev: u8[>..] = [];
    var prev_at = dictionary<u64, i64> {};
    var pre: u8[>..] = [];
    var report: u8[>..] = [];
    let t0 = clock();
    if stamp_jobs() == 1 {
        var n = 0;
        each_file(repo) { full, name =>
            guard cosmetic_lang(name).len > 0;
            stamp_line(repo, full[repo.len + 1..], texts, pre);
            n++;
        };
        format(report, "stamps: ", n, " files in this process\n");
    } else {
        prestamp(repo, out, texts, prev, prev_at, pre, report);
        // prestamp stamps nothing below SWAN_STAMP_MIN files, and leaves a
        // failed worker's files out: stamp them all here then, so stamps.tsv
        // always holds every eligible file.
        var n_all = 0;
        each_file(repo) { full, name =>
            guard cosmetic_lang(name).len > 0;
            n_all++;
        };
        let got = count_lines(pre);
        if got != n_all {
            format(report, "stamps: workers stamped ", got, " of ", n_all, " files; stamped them all in this process\n");
            pre.clear();
            each_file(repo) { full, name =>
                guard cosmetic_lang(name).len > 0;
                stamp_line(repo, full[repo.len + 1..], texts, pre);
            };
        }
    }
    format(report, "stamp-bench: ", ((clock() - t0) * 1000.0) as i64, " ms");
    print(report);
    return write_file(str(out, "/stamps.tsv"), pre);
}

// swan stamp-worker <repo> <list> <out.tsv> <texts-dir>: a stamp line for
// each relative path in list.
fn stamp_worker_main(repo: const u8[:], list: const u8[:], out_path: const u8[:], texts_dir: const u8[:]) -> bool {
    var names: u8[>..] = [];
    guard read_file(list, names) else { return false; }
    var lines: u8[>..] = [];
    each_split(names, '\n') { rel =>
        guard rel.len > 0;
        stamp_line(repo, rel, texts_dir, lines);
    };
    return write_file(out_path, lines);
}

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
        add_lang_job("rust-analyzer scip", target, a, child_env(l, renv),
                     lang_fingerprint(repo, [".rs"], ["Cargo.toml", "Cargo.lock"]) { f => stamp(f) });
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
    var l = detect(repo);
    var rows: u8[>..] = [];
    var ran: u8[>..] = [];
    let trusted = build_trusted(repo, out);
    if !trusted { l.venv.clear(); }     // the repo's virtualenv is its own code (see map_main)
    var skipped: u8[>..] = [];
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
    if l.cargo && !trusted {
        skipped.append(" cargo check and clippy (Rust build scripts, proc macros)");
    } else if l.cargo {
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
    if skipped.len > 0 {
        format(report, untrusted_note(skipped, repo), "\n");
        // Rust went unchecked: its saved diagnostics stay as they were.
        var prev: u8[>..] = [];
        read_file(str(out, "/diagnostics.tsv"), prev);
        each_split(prev, '\n') { line =>
            let f = split(line, '\t');
            if f.len > 6 && (f[6] == "cargo" || f[6] == "clippy") { format(rows, line, "\n"); }
        };
    }
    guard ran.len > 0 else { format(report, "no checker for the languages in ", repo); return false; }
    write_file(str(out, "/diagnostics.tsv"), rows);
    format(report, "checked", ran, "\n");
    diagnostics_main(out, db, report);
    return true;
}
