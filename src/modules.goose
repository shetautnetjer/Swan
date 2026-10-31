// Per-language tools that run after edits: linters, formatters and test
// runners. Which tool, with which arguments, and how its output is read all
// come from tools/modules.json, so a language or a tool is added there,
// not here. For each kind the first candidate whose conditions hold runs.

import std;
import os;
import json;
import sqlite;

// What the placeholders in modules.json stand for.
// compdb: the folder whose compile_commands.json built the map's C and C++
// (the repo's own, at its root or in build/, else the one swan map writes).
struct ModCtx { repo: u8[..2048], out: u8[..2048], home: u8[..2048], python: u8[..2048], compdb: u8[..2048],
                trusted: bool }   // the repo may run its own build files (see build_trusted)

fn mod_ctx(repo: const u8[:], out: const u8[:], home: const u8[:], l: const Langs&) -> ModCtx {
    var c = ModCtx { .. };
    format(c.repo, repo);
    format(c.out, out);
    format(c.home, home);
    format(c.python, python_of(l));
    if file_exists(str(repo, "/compile_commands.json")) { format(c.compdb, repo); }
    else if file_exists(str(repo, "/build/compile_commands.json")) { format(c.compdb, repo, "/build"); }
    else { format(c.compdb, out); }
    c.trusted = build_trusted(repo, out);
    return c;
}

fn expand(s: const u8[:], c: const ModCtx&, into: u8[>..]&) {
    var a: u8[>..] = [];
    format_replaced(a, s, "{repo}", c.repo);
    var b: u8[>..] = [];
    format_replaced(b, a, "{out}", c.out);
    a.clear();
    format_replaced(a, b, "{tools}", str(c.home, "/.tools"));
    b.clear();
    format_replaced(b, a, "{bin}", str(c.home, "/tools/node_modules/.bin"));
    a.clear();
    format_replaced(a, b, "{compdb}", c.compdb);
    format_replaced(into, a, "{python}", c.python);
}

// Builds a candidate's argv (NUL-separated) and environment entries, with
// {files} and {tests} expanding to one argument per line of `items`.
// False when it needs items and there are none.
fn build_cmd(cand: json::Node?, c: const ModCtx&, items: const u8[:], argv: u8[>..]&, env_out: u8[>..]&) -> bool {
    let cmd = json::member(cand, "cmd");
    guard cmd else { return false; }
    var ok = true;
    json::each(cmd) { part =>
        let s, is_s = json::as_string(part);
        if is_s {
            if s == "{files}" || s == "{tests}" {
                var any = false;
                each_split(items, '\n') { it => if it.len > 0 { arg(argv, it); any = true; } };
                if !any { ok = false; }
            } else {
                var e: u8[>..] = [];
                expand(s, c, e);
                arg(argv, e);
            }
        }
    };
    let env_list = json::member(cand, "env");
    if env_list {
        json::each(env_list) { kv =>
            let s, is_s = json::as_string(kv);
            if is_s { var e: u8[>..] = []; expand(s, c, e); arg(env_out, e); }
        };
    }
    return ok;
}

// Whether a candidate's conditions hold in this repo.
fn cand_applies(cand: json::Node?, c: const ModCtx&, env_base: const u8[:]) -> bool {
    var ok = !runs_repo_code(cand) || c.trusted;
    let files = json::member(cand, "when_file");
    if files {
        var found = false;
        json::each(files) { f =>
            let s, is_s = json::as_string(f);
            if is_s && file_exists(str(c.repo, "/", s)) { found = true; }
        };
        if !found { ok = false; }
    }
    let probe = json::member(cand, "when_cmd");
    if ok && probe {
        var argv: u8[>..] = [];
        json::each(probe) { part =>
            let s, is_s = json::as_string(part);
            if is_s { var e: u8[>..] = []; expand(s, c, e); arg(argv, e); }
        };
        var o: u8[>..] = [];
        var er: u8[>..] = [];
        if swan_run(argv, c.repo, env_base, 60000, o, er) != 0 { ok = false; }
    }
    return ok;
}

// A candidate marked "runs_repo_code" runs the repo's own build files
// (cargo's build scripts, Gradle, MSBuild), so it waits for `swan trust`.
fn runs_repo_code(cand: json::Node?) -> bool {
    let v, ok = json::as_bool(json::member(cand, "runs_repo_code"));
    return ok && v;
}

// Runs the first applicable candidate of `kind` for `lang`. Its stdout and
// stderr come back in `output`; `source` and `parser` name it. Returns the
// exit code, or -100 when no candidate applies.
fn run_module(home: const u8[:], lang: const u8[:], kind: const u8[:], c: const ModCtx&, env_base: const u8[:],
              items: const u8[:], output: u8[>..]&, source: u8[>..]&, parser: u8[>..]&) -> i32 {
    var text: u8[>..] = [];
    guard read_file(str(home, "/tools/modules.json"), text) else { output.append("tools/modules.json is missing"); return -100; }
    var doc: json::Node[>..] = [];
    var decoded: u8[>..] = [];
    let root, perr = json::parse(text, doc, decoded);
    guard root else { output.append(str("tools/modules.json: ", perr)); return -100; }
    let list = json::member(json::member(root, lang), kind);
    guard list else { return -100; }
    var code: i32 = -100;
    var done = false;
    json::each(list) { cand =>
        if !done && cand_applies(cand, c, env_base) {
            var argv: u8[>..] = [];
            var extra: u8[>..] = [];
            if build_cmd(cand, c, items, argv, extra) {
                done = true;
                let src, s_ok = json::as_string(json::member(cand, "source"));
                if s_ok { source.append(src); }
                let ps, p_ok = json::as_string(json::member(cand, "parser"));
                if p_ok { parser.append(ps); }
                var env_all: u8[>..] = [];
                env_all.append(env_base);
                env_all.append(extra);
                var err: u8[>..] = [];
                let t0 = clock();
                code = swan_run(argv, c.repo, env_all, 3600000, output, err);
                output.append(err);
                let label = str(lang, " ", kind, if source.len > 0 { str(" (", source, ")") } else { str("") });
                write_stderr(str(label, ": exit ", code, " after ", ((clock() - t0) * 1000.0) as i64, " ms\n"));
            }
        }
    };
    return code;
}

// GitHub Actions annotations, which ruff and biome both write:
// `::error title=…,file=…,line=…,col=…,endLine=…,endColumn=…::message`
fn parse_github(text: const u8[:], repo: const u8[:], source: const u8[:], rows: u8[>..]&) -> i64 {
    var n = 0;
    each_split(text, '\n') { line =>
        guard starts_with(line, "::");
        let sp = find(line, " ");
        let end = find(line[2..], "::");
        guard sp > 2 && end > sp;
        let sev = line[2..sp];
        let props = line[sp + 1..end + 2];
        let msg = line[end + 4..];
        var file = line[0..0];
        var ln = 1;
        var cn = 1;
        var title = line[0..0];
        each_split(props, ',') { kv =>
            let eq = find(kv, "=");
            if eq > 0 {
                let k = kv[..eq];
                let v = kv[eq + 1..];
                if k == "file" { file = v; }
                else if k == "line" { let x, ok = parse_int(v); if ok { ln = x; } }
                else if k == "col" { let x, ok = parse_int(v); if ok { cn = x; } }
                else if k == "title" { title = v; }
            }
        };
        guard file.len > 0;
        put_row(rows, relative_to(repo, file), ln - 1, cn - 1, ln - 1, cn - 1,
                if sev == "error" { "error" } else if sev == "warning" { "warning" } else { "info" },
                source, title, msg);
        n++;
    };
    return n;
}

// The languages the module table knows that this repo holds.
fn module_langs(l: const Langs&) -> u8[>..] {
    var s: u8[>..] = [];
    if l.py { s.append("python\n"); }
    if l.ts || l.js { s.append("typescript\n"); }
    if l.cargo { s.append("rust\n"); }
    return s;
}

fn lang_of_path(p: const u8[:]) -> const u8[:] {
    if ends_with(p, ".py") || ends_with(p, ".pyi") { return "python"; }
    if ends_with(p, ".rs") { return "rust"; }
    if ends_with(p, ".kt") || ends_with(p, ".kts") { return "kotlin"; }
    if ends_with(p, ".c") || ends_with(p, ".cc") || ends_with(p, ".cpp") || ends_with(p, ".cxx") || ends_with(p, ".h") ||
       ends_with(p, ".hpp") || ends_with(p, ".hh") || ends_with(p, ".hxx") || ends_with(p, ".cu") || ends_with(p, ".cuh") { return "cpp"; }
    if ends_with(p, ".cs") { return "csharp"; }
    if ends_with(p, ".lua") { return "lua"; }
    if ends_with(p, ".glsl") || ends_with(p, ".vert") || ends_with(p, ".frag") || ends_with(p, ".comp") ||
       ends_with(p, ".geom") || ends_with(p, ".tesc") || ends_with(p, ".tese") { return "glsl"; }
    if ends_with(p, ".hlsl") || ends_with(p, ".hlsli") || ends_with(p, ".fx") { return "hlsl"; }
    if ends_with(p, ".wgsl") { return "wgsl"; }
    if ends_with(p, ".ts") || ends_with(p, ".tsx") || ends_with(p, ".mts") || ends_with(p, ".cts") ||
       ends_with(p, ".js") || ends_with(p, ".jsx") || ends_with(p, ".mjs") || ends_with(p, ".cjs") { return "typescript"; }
    return "";
}

// `swan format <repo> <out-dir> <file>...` and the MCP tool format_file:
// each file through its language's formatter. Positions in a reformatted
// file change, so its answers say stale until the next update_map.
fn format_main(repo_arg: const u8[:], out_arg: const u8[:], files: const u8[:], report: u8[>..]&) -> bool {
    let repo = abs_path(repo_arg);
    let out = abs_path(out_arg);
    let home = swan_home();
    var l = detect(repo);
    if !build_trusted(repo, out) { l.venv.clear(); }    // the repo's virtualenv is its own code
    let c = mod_ctx(repo, out, home, l);
    var ok = true;
    for lang in ["python", "typescript", "rust"] {
        var mine: u8[>..] = [];
        each_split(files, '\n') { f => if f.len > 0 && lang_of_path(f) == lang { mine.append(f); mine.push('\n'); } };
        if mine.len > 0 {
            var o: u8[>..] = [];
            var src: u8[>..] = [];
            var par: u8[>..] = [];
            let code = run_module(home, lang, "format", c, child_env(l, ""), mine, o, src, par);
            if code == -100 { format(report, lang, ": no formatter in tools/modules.json applies\n"); }
            else {
                format(report, lang, " format: exit ", code, "\n");
                if code != 0 { ok = false; report.append(if o.len > 600 { o[o.len - 600..] } else { o[..] }); report.push('\n'); }
            }
        }
    }
    report.append("positions in reformatted files are stale until update_map");
    return ok;
}

// Test files that reach any of `ids` through calls, up to `depth` steps,
// counting calls to the methods they override (dynamic dispatch). One per
// line.
fn affected_tests(db: i64, ids: const u8[:], depth: i64) -> u8[>..] {
    var sql: u8[>..] = [];
    format_replaced(sql, """
        WITH RECURSIVE up(id, depth) AS (
            SELECT id, 0 FROM symbols WHERE id IN (#IDS#)
            UNION
            -- an override is reached through calls to what it overrides
            SELECT related_id, 0 FROM relationships WHERE symbol_id IN (#IDS#) AND is_impl = 1
            UNION
            SELECT o.enclosing_id, up.depth + 1 FROM up
            JOIN occurrences o ON o.symbol_id = up.id AND o.is_def = 0 AND o.is_import = 0
            WHERE up.depth < ?1 AND o.enclosing_id IS NOT NULL)
        SELECT DISTINCT s.def_file, s.scip LIKE 'rust-analyzer %/tests/%' FROM up JOIN symbols s ON s.id = up.id
        WHERE s.def_file IS NOT NULL
        """, "#IDS#", ids);
    let st = prepare_or_die(db, sql);
    sqlite::bind_int(st, 1, depth);
    var e: u8[>..] = [];
    var tests: u8[>..] = [];
    while sqlite::step(st, e) == 1 {
        var f: u8[>..] = [];
        sqlite::col_text(st, 0, f);
        // Rust keeps unit tests in a `mod tests` inside the source file.
        if is_test_path(f) || sqlite::col_int(st, 1) == 1 { tests.append(f); tests.push('\n'); }
    }
    sqlite::finalize(st);
    return tests;
}

// `swan test <repo> <out-dir> <name_path|file> [relative_path]` and the MCP
// tool run_tests: the tests that reach a symbol (or a file's symbols), run
// with each language's test runner.
fn test_main(repo_arg: const u8[:], out_arg: const u8[:], target: const u8[:], rel: const u8[:], depth: i64,
             report: u8[>..]&) -> bool {
    let repo = abs_path(repo_arg);
    let out = abs_path(out_arg);
    let home = swan_home();
    let db = open_map(str(out, "/swan.db"));
    var ids: u8[>..] = [];
    var tests: u8[>..] = [];
    if file_exists(str(repo, "/", target)) {
        if is_test_path(target) { tests.append(target); tests.push('\n'); }
        let st = prepare_or_die(db, "SELECT id FROM symbols WHERE def_file = ?1 AND in_repo = 1 AND kind NOT IN ('parameter', 'module')");
        sqlite::bind_text(st, 1, target);
        var e: u8[>..] = [];
        while sqlite::step(st, e) == 1 { if ids.len > 0 { ids.push(','); } format(ids, sqlite::col_int(st, 0)); }
        sqlite::finalize(st);
    } else {
        var ignored: u8[>..] = [];
        ids = targets(db, target, rel, ignored);
        if targets_matched > 1 {
            format(report, "'", target, "' matches ", targets_matched, " symbols; pass relative_path");
            sqlite::close(db);
            return false;
        }
    }
    if ids.len > 0 { tests.append(affected_tests(db, ids, depth)); }
    sqlite::close(db);
    // One line per file, without repeats.
    var uniq: u8[>..] = [];
    each_split(tests, '\n') { t => if t.len > 0 && find(uniq, str(t, "\n")) < 0 { uniq.append(t); uniq.push('\n'); } };
    guard uniq.len > 0 else { format(report, "no test reaches ", target, " (looked ", depth, " calls out)"); return true; }
    format(report, "tests that reach ", target, ":\n", uniq);
    var l = detect(repo);
    if !build_trusted(repo, out) { l.venv.clear(); }    // the repo's virtualenv is its own code
    let c = mod_ctx(repo, out, home, l);
    var all_ok = true;
    for lang in ["python", "typescript", "rust"] {
        var mine: u8[>..] = [];
        each_split(uniq, '\n') { f => if f.len > 0 && lang_of_path(f) == lang { mine.append(f); mine.push('\n'); } };
        if mine.len > 0 {
            var o: u8[>..] = [];
            var src: u8[>..] = [];
            var par: u8[>..] = [];
            let code = run_module(home, lang, "test", c, child_env(l, ""), mine, o, src, par);
            if code == -100 { format(report, lang, ": no test runner in tools/modules.json applies\n"); continue; }
            format(report, lang, " tests: ", if code == 0 { "passed" } else { "FAILED" }, " (exit ", code, ")\n");
            if code != 0 { all_ok = false; }
            report.append(if o.len > 1500 { o[o.len - 1500..] } else { o[..] });
            report.push('\n');
        }
    }
    return all_ok;
}
