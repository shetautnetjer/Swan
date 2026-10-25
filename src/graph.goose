// The reference graph: who uses a symbol and what it uses. An edge runs from
// the symbol a reference sits inside (its enclosing function, method or
// class) to the symbol referenced. SCIP does not tell a call from any other
// use, so "callers" here means every symbol that references the target:
// calls, type uses and imports alike. Modules are where a walk stops, since
// a file is not called; a reference at a file's top level shows its module.

import std;
import json;

fn is_test_path(p: const u8[:]) -> bool {
    find(p, ".test.") >= 0 || find(p, ".spec.") >= 0 || find(p, "__tests__/") >= 0 ||
        starts_with(p, "test/") || starts_with(p, "tests/") ||
        find(p, "/test/") >= 0 || find(p, "/tests/") >= 0
}

// The symbols a name path matches, written as "targets", and their ids as a
// SQL list ("3,17"). Empty when nothing matches.
fn targets(db: i64, pattern: const u8[:], rel: const u8[:], out: u8[>..]&) -> u8[>..] {
    var ids: u8[>..] = [];
    let sql, bind = match_sql(pattern, false);
    let st = prepare_or_die(db, sql);
    swan_bind_text(st, 1, bind);
    swan_bind_text(st, 2, rel);
    swan_bind_int(st, 3, 20);
    var err: u8[>..] = [];
    json::format_key(out, "targets");
    out.push('[');
    while swan_step(st, err) == 1 {
        if ids.len > 0 { ids.push(','); out.push(','); }
        format(ids, swan_col_int(st, 0));
        symbol_json(st, out);
    }
    out.push(']');
    swan_finalize(st);
    return ids;
}

// Who references the target, and who references those, up to `depth` steps:
// the impact radius of changing it. Each result has its distance and whether
// it is test code, and a summary counts the files and lists the test files.
fn get_callers(db: i64, pattern: const u8[:], rel: const u8[:], depth: i64, limit: i64, out: u8[>..]&) {
    out.push('{');
    let ids = targets(db, pattern, rel, out);
    guard ids.len > 0 else { out.append(",\"callers\":[]}"); return; }
    var walk: u8[>..] = [];
    format_replaced(walk, """
        WITH RECURSIVE up(id, depth) AS (
            SELECT id, 0 FROM symbols WHERE id IN (#IDS#)
            UNION
            SELECT o.enclosing_id, up.depth + 1
            FROM up
            JOIN symbols su ON su.id = up.id AND su.kind != 'module'
            JOIN occurrences o ON o.symbol_id = up.id AND o.is_def = 0
            WHERE up.depth < ?1 AND o.enclosing_id IS NOT NULL AND o.enclosing_id != up.id)
        , found AS (
            SELECT s.id, s.name_path, s.kind, s.signature, s.def_file, s.def_line, s.def_col,
                   s.body_start, s.body_end, min(up.depth) AS distance
            FROM up JOIN symbols s ON s.id = up.id
            WHERE s.id NOT IN (#IDS#)
            GROUP BY s.id)
        """, "#IDS#", ids);
    var err: u8[>..] = [];

    let st = prepare_or_die(db, str(walk, "SELECT * FROM found ORDER BY distance, def_file, def_line LIMIT ?2"));
    swan_bind_int(st, 1, depth);
    swan_bind_int(st, 2, limit);
    out.append(",");
    json::format_key(out, "callers");
    out.push('[');
    var n = 0;
    while swan_step(st, err) == 1 {
        if n > 0 { out.push(','); }
        n++;
        symbol_json(st, out);
        var file: u8[>..] = [];
        swan_col_text(st, 4, file);
        out.pop();
        out.push(',');
        json::format_key(out, "distance");
        json::format_int(out, swan_col_int(st, 9));
        out.push(',');
        json::format_key(out, "is_test");
        json::format_bool(out, is_test_path(file));
        out.push('}');
    }
    out.push(']');
    swan_finalize(st);

    // The summary covers every caller, not only the ones listed.
    let sum = prepare_or_die(db, str(walk, """
        SELECT count(*), count(DISTINCT def_file) FROM found;
        """));
    swan_bind_int(sum, 1, depth);
    var total = 0;
    var files = 0;
    if swan_step(sum, err) == 1 { total = swan_col_int(sum, 0); files = swan_col_int(sum, 1); }
    swan_finalize(sum);
    let tf = prepare_or_die(db, str(walk, "SELECT DISTINCT def_file FROM found ORDER BY def_file"));
    swan_bind_int(tf, 1, depth);
    out.append(",");
    json::format_key(out, "summary");
    out.push('{');
    json::format_key(out, "symbols");
    json::format_int(out, total);
    out.push(',');
    json::format_key(out, "files");
    json::format_int(out, files);
    out.push(',');
    json::format_key(out, "depth");
    json::format_int(out, depth);
    out.push(',');
    json::format_key(out, "test_files");
    out.push('[');
    var t = 0;
    while swan_step(tf, err) == 1 {
        var file: u8[>..] = [];
        swan_col_text(tf, 0, file);
        if is_test_path(file) {
            if t > 0 { out.push(','); }
            t++;
            json::format_string(out, file);
        }
    }
    swan_finalize(tf);
    out.append("]}}");
}

// What the target references from inside its own body: the functions it
// calls, the types and constants it uses. Symbols from outside the repo
// carry their package instead of a file.
fn get_callees(db: i64, pattern: const u8[:], rel: const u8[:], limit: i64, out: u8[>..]&) {
    out.push('{');
    let ids = targets(db, pattern, rel, out);
    guard ids.len > 0 else { out.append(",\"callees\":[]}"); return; }
    var sql: u8[>..] = [];
    format_replaced(sql, """
        SELECT s.id, s.name_path, s.kind, s.signature, s.def_file, s.def_line, s.def_col,
               s.body_start, s.body_end, s.in_repo, s.scip, count(*)
        FROM occurrences o JOIN symbols s ON s.id = o.symbol_id
        WHERE o.enclosing_id IN (#IDS#) AND o.is_def = 0
          AND s.kind NOT IN ('parameter', 'type_parameter') AND s.id NOT IN (#IDS#)
        GROUP BY s.id
        ORDER BY s.in_repo DESC, s.def_file, s.def_line
        LIMIT ?1
        """, "#IDS#", ids);
    let st = prepare_or_die(db, sql);
    swan_bind_int(st, 1, limit);
    var err: u8[>..] = [];
    out.append(",");
    json::format_key(out, "callees");
    out.push('[');
    var n = 0;
    while swan_step(st, err) == 1 {
        if n > 0 { out.push(','); }
        n++;
        if swan_col_int(st, 9) == 1 {
            symbol_json(st, out);
            out.pop();
        } else {
            var s: u8[>..] = [];
            out.push('{');
            json::format_key(out, "name_path");
            swan_col_text(st, 1, s); json::format_string(out, s); s.clear();
            out.push(',');
            json::format_key(out, "kind");
            swan_col_text(st, 2, s); json::format_string(out, s); s.clear();
            out.push(',');
            json::format_key(out, "package");
            swan_col_text(st, 10, s);
            json::format_string(out, package_of(s));
        }
        out.push(',');
        json::format_key(out, "uses");
        json::format_int(out, swan_col_int(st, 11));
        out.push('}');
    }
    out.append("]}");
    swan_finalize(st);
}
