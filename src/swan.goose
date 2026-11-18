// Swan: a code map for agents. SCIP data in, SQLite map, MCP tools out.
//   swan index <flattened-dir> <db> [repo-root]     a new map
//   swan refresh <flattened-dir> <db> [repo-root]   rewrite only the files whose rows changed
//   swan query <db> symbol|refs|uses|at|overview|callers|callees|impls|hierarchy|unused|info|diag|diagfile|pattern <arg> [relative_path]
//   swan serve [<db> | --maps <data-root>]   MCP over stdio
import std;
import os;
import .db;
import .scip;
import .index;
import .query;
import .serve;
import .graph;
import .fresh;
import .edit;
import .diag;
import .run;
import .pipeline;
import .gradle;
import .seal;
import .checkers;
import .pyplan;
import .stamp;
import .modules;
import .live;
import .structural;
import .change;
import .syntax;
import .pypatch;
import .wings;
import .broke;
import .lspindex;
import treesitter from "shetautnetjer/goose-treesitter@59313e9da0b9f1cce8df83cabe53ed73fa92345c";   // tree-sitter and its grammars, built once and cached
import sqlite from "shetautnetjer/goose-sqlite@c759de735ae936dcbc197bb9aae40e13565ef21c";   // open_existing never creates a missing map

fn usage() {
    write_stderr("""
        usage: swan map <repo> <out-dir> [--clean]  index or refresh; --clean bypasses all cached output
               swan doctor [--profile core|python-typescript] [--json]
               swan check <repo> <out-dir>      run compilers and linters into the map
               swan broke <out-dir> <file>...   errors new in these files since last asked (exit 1 if any)
               swan trust <repo>                let map, check and live answers run the repo's build files
               swan gradle-tasks <repo>         the Gradle tasks map would give scip-java (runs nothing)
               swan lsp-index <repo> <out-dir> <lang> <target.scip>   a SCIP index from the language's server (what swan map runs)
               swan lsp-ask <repo> <out-dir> <file> <method> [line col] [more]   one question to the file's language server
               swan format <repo> <out-dir> <file>...
               swan test <repo> <out-dir> <name_path|file> [relative_path]
               swan index <flattened-dir> <db> [repo-root]
               swan refresh <flattened-dir> <db> [repo-root]
               swan diagnostics <dir-with-diagnostics.tsv> <db>
               swan query <db> symbol|refs|uses|at|overview|callers|callees|impls|hierarchy|unused|info|diag|diagfile|pattern <arg> [relative_path]
               swan serve [<db> | --maps <data-root>]

        """);
    exit(2);
}

// The map at path, for a job of its own (run_tests): the freshness state
// stays with the connection that answers questions.
fn open_map(path: const u8[:]) -> i64 {
    guard file_exists(path) else { abort(str("swan: no index at ", path)); }
    var err: u8[>..] = [];
    let db = sqlite::open_existing(path, err);
    if db == 0 { abort(str("swan: cannot open ", path, ": ", err)); }
    return db;
}

fn open_db(path: const u8[:]) -> i64 {
    let db = open_map(path);
    // CLI queries, like read-only MCP tools, use one database generation
    // across freshness metadata and all statements that build their answer.
    exec_or_die(db, "BEGIN;");
    var version: u8[>..] = [];
    meta_value(db, "schema_version", version);
    if version != str(SCHEMA_VERSION) {
        abort(str("swan: index schema ", version, ", this swan reads ", SCHEMA_VERSION, "; rebuild the map"));
    }
    load_freshness(db);
    return db;
}

// The other end of open_db: the freshness statement belongs to this
// connection, so it is finalized before the handle.
fn close_db(db: i64) {
    drop_freshness();
    sqlite::close(db);
}

fn main() {
    let a = args();
    if a.len < 2 { usage(); }
    if a[1] == "doctor" {
        let home = swan_home();
        var cmd: u8[>..] = [];
        arg(cmd, "python3");
        arg(cmd, "-I");
        arg(cmd, str(home, "/scripts/doctor.py"));
        arg(cmd, "--home");
        arg(cmd, home);
        for k in 2..a.len {
            // Diagnose this executable's installation, never a caller-supplied
            // repository passed off as a different runtime home.
            if a[k] == "--home" || starts_with(a[k], "--home=") { usage(); }
            arg(cmd, a[k]);
        }
        var environment: u8[>..] = [];
        arg(environment, "PATH=/usr/local/bin:/usr/bin:/bin");
        var result: u8[>..] = [];
        let code = run_step("doctor", cmd, home, environment, 60000, result);
        print(result);
        exit(code);
    } else if a[1] == "index" && a.len >= 4 {
        var report: u8[>..] = [];
        index_main(a[2], a[3], if a.len > 4 { a[4] } else { "" }, false, report);
        print(report);
    } else if a[1] == "refresh" && a.len >= 4 {
        var report: u8[>..] = [];
        index_main(a[2], a[3], if a.len > 4 { a[4] } else { "" }, true, report);
        print(report);
    } else if a[1] == "query" && a.len >= 5 {
        let db = open_db(a[2]);
        let rel = if a.len > 5 { a[5] } else { "" };
        var out: u8[>..] = [];
        if a[3] == "symbol" { find_symbol(db, a[4], rel, false, true, 50, out); }
        else if a[3] == "refs" { find_referencing_symbols(db, a[4], rel, 500, false, out); }
        else if a[3] == "uses" { find_referencing_symbols(db, a[4], rel, 2000, true, out); }
        else if a[3] == "overview" { get_symbols_overview(db, a[4], out); }
        else if a[3] == "callers" { get_callers(db, a[4], rel, 3, 200, out); }
        else if a[3] == "callees" { get_callees(db, a[4], rel, false, 200, out); }
        else if a[3] == "unused" { find_unused_symbols(db, a[4], false, 200, out); }
        else if a[3] == "info" { index_info(db, out); }
        else if a[3] == "at" {
            let p = split(a[4], ':');
            guard p.len == 3 else { abort("swan query <db> at <file>:<line>:<column>"); }
            let ln, ok1 = parse_int(p[1]);
            let cn, ok2 = parse_int(p[2]);
            get_symbol_at(db, p[0], ln, cn, out);
        }
        else if a[3] == "diag" { get_diagnostics(db, a[4], rel, 2, false, 200, out); }
        else if a[3] == "diagfile" { get_diagnostics(db, "", a[4], 0, false, 200, out); }
        else if a[3] == "impls" { find_implementations(db, a[4], rel, 200, out); }
        else if a[3] == "hierarchy" { get_type_hierarchy(db, a[4], rel, 3, 200, out); }
        else if a[3] == "pattern" { search_pattern(db, a[4], "", rel, 1000000, out); }
        else { usage(); }
        exec_or_die(db, "COMMIT;");
        close_db(db);
        print(out);
    } else if a[1] == "map" && (a.len == 4 || (a.len == 5 && a[4] == "--clean")) {
        var report: u8[>..] = [];
        let ok = map_main(a[2], a[3], report, a.len == 5);
        print(report);
        if !ok { exit(1); }
    } else if a[1] == "syntax-index" && (a.len == 4 || (a.len == 6 && a[4] == "--skip")) {
        if a.len == 6 && a[5] == "go" { sx_skip_go = true; }
        if !syntax_index_main(a[2], a[3]) { exit(1); }
    } else if a[1] == "plan-python" && (a.len == 3 || a.len == 4) {
        // The Python pieces a map would index in parallel, one per line ("" = the whole repo).
        var k: i64 = 6;
        if a.len == 4 { let v, ok = parse_int(a[3]); guard ok && v > 0 else { usage(); } k = v; }
        write_stdout(plan_python(abs_path(a[2]), k));
    } else if a[1] == "scip-python-patch" && (a.len == 3 || (a.len == 4 && a[3] == "--revert")) {
        // Applies (or undoes) the reachability memo on one pyright-internal.js.
        let r = pypatch_file(a[2], a.len == 4);
        print(r);
        if r == "no match" { exit(1); }
    } else if a[1] == "stamp-bench" && a.len == 4 {
        if !stamp_bench_main(a[2], a[3]) { exit(1); }
    } else if a[1] == "stamp-worker" && a.len == 6 {
        if !stamp_worker_main(a[2], a[3], a[4], a[5]) { exit(1); }
    } else if a[1] == "trust" && a.len == 3 {
        var report: u8[>..] = [];
        let ok = trust_main(a[2], report);
        print(report);
        if !ok { exit(1); }
    } else if a[1] == "gradle-tasks" && a.len == 3 {
        write_stdout(gradle_scip_tasks(abs_path(a[2])));
    } else if a[1] == "check" && a.len == 4 {
        var report: u8[>..] = [];
        let ok = check_main(a[2], a[3], report);
        print(report);
        if !ok { exit(1); }
    } else if a[1] == "broke" && a.len >= 4 {
        // swan broke <map-dir> <file>...: files relative to the repo, or absolute inside it.
        let db = open_db(str(a[2], "/swan.db"));
        exec_or_die(db, "COMMIT;");
        var root: u8[>..] = [];
        meta_value(db, "root", root);
        var files: u8[>..] = [];
        for k in 3..a.len {
            // Relative: to the repo. Absolute: inside it, else not this map's.
            if a[k].len > 0 && a[k][0] != '/' { format(files, a[k], "\n"); }
            else if starts_with(a[k], str(root, "/")) { format(files, a[k][root.len + 1..], "\n"); }
        }
        var report: u8[>..] = [];
        let n = what_broke(db, a[2], files, report);
        live_stop();
        close_db(db);
        print(report);
        if n > 0 { exit(1); }
    } else if a[1] == "lsp-index" && a.len == 6 {
        if !lsp_index_main(abs_path(a[2]), abs_path(a[3]), a[4], a[5]) { exit(1); }
    } else if a[1] == "lsp-ask" && a.len >= 6 {
        // swan lsp-ask <repo> <out-dir> <file> <method> [line col] [more]: one question to the file's language server.
        var ans: u8[>..] = [];
        let ln, l_ok = parse_int(if a.len >= 8 { a[6] } else { "0" });
        let cn, c_ok = parse_int(if a.len >= 8 { a[7] } else { "0" });
        let more = if a.len == 9 { a[8] } else if a.len == 7 { a[6] } else { "" };
        let ok = live_request(abs_path(a[2]), abs_path(a[3]), a[4], a[5], if l_ok { ln } else { 0 }, if c_ok { cn } else { 0 }, more, ans);
        live_stop();
        print(ans);
        if !ok { exit(1); }
    } else if a[1] == "format" && a.len >= 5 {
        var files: u8[>..] = [];
        for k in 4..a.len { files.append(a[k]); files.push('\n'); }
        var report: u8[>..] = [];
        let ok = format_main(a[2], a[3], files, report);
        print(report);
        if !ok { exit(1); }
    } else if a[1] == "test" && a.len >= 5 {
        var report: u8[>..] = [];
        let ok = test_main(a[2], a[3], a[4], if a.len > 5 { a[5] } else { "" }, 3, report);
        print(report);
        if !ok { exit(1); }
    } else if a[1] == "diagnostics" && a.len == 4 {
        var report: u8[>..] = [];
        diagnostics_main(a[2], a[3], report);
        print(report);
    } else if a[1] == "serve" && a.len == 3 {
        serve_main(a[2]);
    } else if a[1] == "serve" && (a.len == 2 || (a.len == 4 && a[2] == "--maps")) {
        let maps_root: u8[>..] = if a.len == 4 { a[3] } else { str(swan_home(), "/data") };
        serve_any(maps_root);
    } else { usage(); }
}
