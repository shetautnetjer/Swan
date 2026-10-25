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

extern fn swan_realpath(path: const u8[:], out: u8[>..]&) -> bool;

fn abs_path(p: const u8[:]) -> u8[>..] {
    var o: u8[>..] = [];
    if !swan_realpath(p, o) { abort(str("swan: no such path: ", p)); }
    return o;
}

// What a repo holds, found by walking it.
struct Langs {
    ts: bool, js: bool, py: bool, rs: bool,
    tsconfig: bool, cargo: bool,
    venv: u8[..2048],           // a virtualenv inside the repo, if any
}

let SKIP_DIRS = ["node_modules", ".git", "target", ".venv", "venv", "__pycache__", ".tox",
                 ".mypy_cache", ".pytest_cache", ".swan"];

fn detect(repo: const u8[:]) -> Langs {
    var l = Langs { ts: false, js: false, py: false, rs: false,
                    tsconfig: file_exists(str(repo, "/tsconfig.json")),
                    cargo: file_exists(str(repo, "/Cargo.toml")), .. };
    for v in [".venv", "venv"] {
        if l.venv.len == 0 && file_exists(str(repo, "/", v, "/pyvenv.cfg")) { format(l.venv, repo, "/", v); }
    }
    // Breadth-first over directories; `dirs` only grows, `next` walks it.
    var dirs: u8[>..] = [];
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
            } else if ends_with(name, ".ts") || ends_with(name, ".tsx") || ends_with(name, ".mts") || ends_with(name, ".cts") {
                l.ts = true;
            } else if ends_with(name, ".js") || ends_with(name, ".jsx") || ends_with(name, ".mjs") || ends_with(name, ".cjs") {
                l.js = true;
            } else if ends_with(name, ".py") {
                l.py = true;
            } else if ends_with(name, ".rs") {
                l.rs = true;
            }
        };
    }
    return l;
}

// The environment children get: a repo virtualenv first on PATH, and room
// for scip-python and pyright on big repos.
fn child_env(l: const Langs&, extra: const u8[:]) -> u8[>..] {
    var vars: u8[>..] = [];
    var path: u8[>..] = [];
    if l.venv.len > 0 { format(path, l.venv, "/bin:"); }
    env("PATH", path);
    var e: u8[>..] = [];
    format(e, "PATH=", path);
    arg(vars, e);
    if l.venv.len > 0 {
        e.clear();
        format(e, "VIRTUAL_ENV=", l.venv);
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

fn map_main(repo_arg: const u8[:], out_arg: const u8[:], report: u8[>..]&) -> bool {
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
           if l.py { " python" } else { "" }, if l.rs || l.cargo { " rust" } else { "" },
           if l.venv.len > 0 { str(" (venv ", l.venv, ")") } else { str("") }, "\n");
    // Edits after this moment make answers stale (src/fresh.goose).
    write_file(str(out, "/scip-started"), "");
    var scips: u8[>..] = [];      // NUL-separated index files, for the flattener
    var ok = true;

    if l.tsconfig || l.ts || l.js {
        let target = str(out, "/index-typescript.scip");
        delete_file(target);
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
        var o: u8[>..] = [];
        if run_step("scip-typescript", a, repo, child_env(l, ""), 3600000, o) == 0 { arg(scips, target); }
        else { ok = false; }
    }

    if l.py {
        let target = str(out, "/index-python.scip");
        delete_file(target);
        let python = python_of(l);
        var a: u8[>..] = [];
        arg(a, str(bin, "scip-python"));
        arg(a, "index");
        arg(a, ".");
        arg(a, "--quiet");
        arg(a, "--project-name");
        let slash = rfind(repo, "/");
        arg(a, repo[slash + 1..]);
        arg(a, "--project-version");
        arg(a, "0");
        arg(a, "--output");
        arg(a, target);
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
            arg(a, "--environment");
            arg(a, env_file);
        }
        o.clear();
        if run_step("scip-python", a, repo, child_env(l, ""), 3600000, o) == 0 { arg(scips, target); }
        else { ok = false; }
    }

    if l.cargo {
        let target = str(out, "/index-rust.scip");
        delete_file(target);
        var a: u8[>..] = [];
        arg(a, str(home, "/.tools/rust-analyzer/rust-analyzer"));
        arg(a, "scip");
        arg(a, ".");
        arg(a, "--output");
        arg(a, target);
        var o: u8[>..] = [];
        let extra = env_entry("CARGO_TARGET_DIR", str(out, "/cargo-target"));
        if run_step("rust-analyzer scip", a, repo, child_env(l, extra), 3600000, o) == 0 { arg(scips, target); }
        else { ok = false; }
    }

    guard scips.len > 0 else { format(report, "no language found to index in ", repo); return false; }
    var f: u8[>..] = [];
    arg(f, "bun");
    arg(f, str(home, "/tools/scip-flatten.ts"));
    arg(f, "--root");
    arg(f, repo);
    let parts = split(scips[..scips.len - 1], 0);
    arg(f, parts[0]);
    arg(f, out);
    for k in 1..parts.len { arg(f, parts[k]); }
    var o: u8[>..] = [];
    guard run_step("flatten", f, home, "", 600000, o) == 0 else { format(report, "flatten failed"); return false; }
    let db = str(out, "/swan.db");
    index_main(out, db, repo, file_exists(db), report);
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
fn parse_cargo(text: const u8[:], repo: const u8[:], rows: u8[>..]&) -> i64 {
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
                    put_row(rows, relative_to(repo, file), ls - 1, cs - 1, le - 1, ce - 1, level, "cargo",
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
        run_step("tsc", a, repo, child_env(l, ""), 1800000, o);   // exit 2 when it finds errors
        format(ran, " tsc:", parse_tsc(o, rows));
    }
    if l.cargo {
        var a: u8[>..] = [];
        arg(a, "cargo");
        arg(a, "check");
        arg(a, "--workspace");
        arg(a, "--all-targets");
        arg(a, "--message-format=json");
        arg(a, "--quiet");
        var o: u8[>..] = [];
        let extra = env_entry("CARGO_TARGET_DIR", str(out, "/cargo-target"));
        run_step("cargo check", a, repo, child_env(l, extra), 3600000, o);
        format(ran, " cargo:", parse_cargo(o, repo, rows));
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
        run_step("pyright", a, repo, child_env(l, ""), 3600000, o);   // exit 1 when it finds errors
        format(ran, " pyright:", parse_pyright(o, repo, rows));
    }
    guard ran.len > 0 else { format(report, "no checker for the languages in ", repo); return false; }
    write_file(str(out, "/diagnostics.tsv"), rows);
    format(report, "checked", ran, "\n");
    diagnostics_main(out, db, report);
    return true;
}
