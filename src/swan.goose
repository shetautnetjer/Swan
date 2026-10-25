// Swan: a code map for agents. SCIP data in, SQLite map, MCP tools out.
//   swan index <flattened-dir> <db> [repo-root]     a new map
//   swan refresh <flattened-dir> <db> [repo-root]   rewrite only the files whose rows changed
//   swan query <db> symbol|refs|overview|callers|callees|impls|hierarchy|unused|info <arg> [relative_path]
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

fn usage() {
    write_stderr("""
        usage: swan index <flattened-dir> <db> [repo-root]
               swan refresh <flattened-dir> <db> [repo-root]
               swan query <db> symbol|refs|overview|callers|callees|impls|hierarchy|unused|info <arg> [relative_path]
               swan serve <db>

        """);
    exit(2);
}

fn open_db(path: const u8[:]) -> i64 {
    guard file_exists(path) else { abort(str("swan: no index at ", path)); }
    var err: u8[>..] = [];
    let db = swan_db_open(path, err);
    if db == 0 { abort(str("swan: cannot open ", path, ": ", err)); }
    load_freshness(db);
    return db;
}

fn main() {
    let a = args();
    if a.len < 2 { usage(); }
    if a[1] == "index" && a.len >= 4 {
        index_main(a[2], a[3], if a.len > 4 { a[4] } else { "" }, false);
    } else if a[1] == "refresh" && a.len >= 4 {
        index_main(a[2], a[3], if a.len > 4 { a[4] } else { "" }, true);
    } else if a[1] == "query" && a.len >= 5 {
        let db = open_db(a[2]);
        let rel = if a.len > 5 { a[5] } else { "" };
        var out: u8[>..] = [];
        if a[3] == "symbol" { find_symbol(db, a[4], rel, false, true, 50, out); }
        else if a[3] == "refs" { find_referencing_symbols(db, a[4], rel, 500, out); }
        else if a[3] == "overview" { get_symbols_overview(db, a[4], out); }
        else if a[3] == "callers" { get_callers(db, a[4], rel, 3, 200, out); }
        else if a[3] == "callees" { get_callees(db, a[4], rel, 200, out); }
        else if a[3] == "unused" { find_unused_symbols(db, a[4], false, 200, out); }
        else if a[3] == "info" { index_info(db, out); }
        else if a[3] == "impls" { find_implementations(db, a[4], rel, 200, out); }
        else if a[3] == "hierarchy" { get_type_hierarchy(db, a[4], rel, 3, 200, out); }
        else { usage(); }
        print(out);
    } else if a[1] == "serve" && a.len == 3 {
        serve_main(a[2]);
    } else { usage(); }
}
