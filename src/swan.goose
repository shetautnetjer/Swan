// Swan: a code map for agents. SCIP data in, SQLite map, MCP tools out.
//   swan index <flattened-dir> <db> [repo-root]     a new map
//   swan refresh <flattened-dir> <db> [repo-root]   rewrite only the files whose rows changed
//   swan query <db> symbol|refs|uses|at|overview|callers|callees|impls|hierarchy|unused|info|diag|diagfile|pattern <arg> [relative_path]
//   swan serve <db>            MCP over stdio
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
import .modules;
import .live;
import .structural;
import treesitter from "shetautnetjer/goose-treesitter@v0.1.2";   // tree-sitter and its grammars, built once and cached
import sqlite from "shetautnetjer/goose-sqlite@v0.1.1";   // SQLite, built once and cached

fn usage() {
    write_stderr("""
        usage: swan map <repo> <out-dir>        index every language in the repo (or refresh)
               swan check <repo> <out-dir>      run compilers and linters into the map
               swan format <repo> <out-dir> <file>...
               swan test <repo> <out-dir> <name_path|file> [relative_path]
               swan index <flattened-dir> <db> [repo-root]
               swan refresh <flattened-dir> <db> [repo-root]
               swan diagnostics <dir-with-diagnostics.tsv> <db>
               swan query <db> symbol|refs|uses|at|overview|callers|callees|impls|hierarchy|unused|info|diag|diagfile|pattern <arg> [relative_path]
               swan serve <db>

        """);
    exit(2);
}

fn open_db(path: const u8[:]) -> i64 {
    guard file_exists(path) else { abort(str("swan: no index at ", path)); }
    var err: u8[>..] = [];
    let db = sqlite::open(path, err);
    if db == 0 { abort(str("swan: cannot open ", path, ": ", err)); }
    load_freshness(db);
    return db;
}

fn main() {
    let a = args();
    if a.len < 2 { usage(); }
    if a[1] == "index" && a.len >= 4 {
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
        else if a[3] == "callees" { get_callees(db, a[4], rel, 200, out); }
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
        print(out);
    } else if a[1] == "map" && a.len == 4 {
        var report: u8[>..] = [];
        let ok = map_main(a[2], a[3], report);
        print(report);
        if !ok { exit(1); }
    } else if a[1] == "check" && a.len == 4 {
        var report: u8[>..] = [];
        let ok = check_main(a[2], a[3], report);
        print(report);
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
    } else { usage(); }
}
