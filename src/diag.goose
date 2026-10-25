// Where errors are, and where an edit could cause them. The compilers'
// own diagnostics (tools/diagnostics.ts runs tsc and cargo check) are loaded
// into the map and pinned to the innermost symbol they fall in. A question
// about a symbol can then take in its callers too. This is Serena's
// get_diagnostics_for_symbol with check_symbol_references, and the use that
// JetBrains' Problems view makes of call hierarchy: after changing a
// function, the errors that matter are in it and in what calls it.

import std;
import os;
import json;

let DIAG_TABLE = """
    CREATE TABLE IF NOT EXISTS diagnostics (
        file TEXT NOT NULL,
        line INTEGER NOT NULL,
        col INTEGER NOT NULL,
        end_line INTEGER NOT NULL,
        end_col INTEGER NOT NULL,
        severity TEXT NOT NULL,
        source TEXT NOT NULL,
        code TEXT NOT NULL,
        message TEXT NOT NULL,
        symbol_id INTEGER
    );
    CREATE INDEX IF NOT EXISTS diagnostics_symbol ON diagnostics (symbol_id);
    CREATE INDEX IF NOT EXISTS diagnostics_file ON diagnostics (file, line);
    """;

// `swan diagnostics <dir> <db>`: replaces the map's diagnostics with
// <dir>/diagnostics.tsv.
fn diagnostics_main(dir: const u8[:], db_path: const u8[:]) {
    let t0 = clock();
    var text: u8[>..] = [];
    let path = str(dir, "/diagnostics.tsv");
    guard read_file(path, text) else { abort(str("cannot read ", path)); }
    var err: u8[>..] = [];
    let db = swan_db_open(db_path, err);
    if db == 0 { abort(str("swan: cannot open ", db_path, ": ", err)); }
    exec_or_die(db, DIAG_TABLE);
    exec_or_die(db, "BEGIN; DELETE FROM diagnostics;");
    let ins = prepare_or_die(db, """
        INSERT INTO diagnostics VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9,
            -- the innermost symbol around the line, else the file's own module
            COALESCE(
                (SELECT id FROM symbols
                 WHERE def_file = ?1 AND body_start <= ?2 AND body_end >= ?2
                   AND kind NOT IN ('module', 'parameter', 'namespace')
                 ORDER BY body_end - body_start LIMIT 1),
                (SELECT id FROM symbols WHERE def_file = ?1 AND kind = 'module' LIMIT 1)))
        """);
    var n = 0;
    var errors = 0;
    each_split(text, '\n') {
        guard it.len > 0;
        let f = split(it, '\t');
        guard f.len >= 9;
        swan_bind_text(ins, 1, f[0]);
        swan_bind_int(ins, 2, field_int(f[1]));
        swan_bind_int(ins, 3, field_int(f[2]));
        swan_bind_int(ins, 4, field_int(f[3]));
        swan_bind_int(ins, 5, field_int(f[4]));
        swan_bind_text(ins, 6, f[5]);
        swan_bind_text(ins, 7, f[6]);
        swan_bind_text(ins, 8, f[7]);
        swan_bind_text(ins, 9, f[8]);
        step_done(ins);
        n++;
        if f[5] == "error" { errors++; }
    };
    swan_finalize(ins);
    let m = prepare_or_die(db, "INSERT OR REPLACE INTO meta VALUES ('diagnostics_time', ?1)");
    swan_bind_text(m, 1, str(swan_mtime_ns(path)));
    step_done(m);
    swan_finalize(m);
    exec_or_die(db, "COMMIT;");
    swan_db_close(db);
    print("swan diagnostics: ", n, " loaded (", errors, " errors) into ", db_path, " in ",
          ((clock() - t0) * 1000.0) as i64, " ms");
}

// Diagnostics for a symbol (and, with depth > 0, the symbols that use it, up
// to depth steps out), or for a file or directory, or a summary of the whole
// map. Each one names the symbol it sits in, and says stale when its file
// changed after the check ran.
fn get_diagnostics(db: i64, pattern: const u8[:], rel: const u8[:], depth: i64, errors_only: bool,
                   limit: i64, out: u8[>..]&) -> bool {
    var e: u8[>..] = [];
    var t: u8[>..] = [];
    meta_value(db, "diagnostics_time", t);
    guard t.len > 0 else {
        out.append("no diagnostics loaded: run scripts/diagnose-repo.sh <repo> <map-dir> after indexing");
        return false;
    }
    let checked, ok = parse_int(t);
    assert(ok);
    out.push('{');
    var scope: u8[>..] = [];
    if pattern.len > 0 {
        let ids = targets(db, pattern, rel, out);
        out.push(',');
        guard ids.len > 0 else { out.append("\"diagnostics\":[]}"); return true; }
        format_replaced(scope, """
            WITH RECURSIVE up(id, distance) AS (
                SELECT id, 0 FROM symbols WHERE id IN (#IDS#)
                UNION
                SELECT o.enclosing_id, up.distance + 1
                FROM up
                JOIN symbols su ON su.id = up.id AND su.kind != 'module'
                JOIN occurrences o ON o.symbol_id = up.id AND o.is_def = 0
                WHERE up.distance < ?1 AND o.enclosing_id IS NOT NULL),
            -- A symbol's diagnostics include those of what it holds (a class's
            -- methods). A module caller stands for its top-level code only.
            scope AS (
                SELECT s.id, min(up.distance) AS distance FROM up
                JOIN symbols p ON p.id = up.id
                JOIN symbols s ON (p.kind = 'module' AND s.id = p.id)
                     OR (p.kind != 'module' AND s.def_file = p.def_file
                         AND s.body_start >= p.body_start AND s.body_end <= p.body_end)
                GROUP BY s.id)
            SELECT d.file, d.line, d.col, d.severity, d.source, d.code, d.message, s.name_path, scope.distance
            FROM diagnostics d JOIN scope ON scope.id = d.symbol_id
            LEFT JOIN symbols s ON s.id = d.symbol_id
            WHERE (?2 = 0 OR d.severity = 'error')
            ORDER BY scope.distance, d.file, d.line
            LIMIT ?3
            """, "#IDS#", ids);
    } else {
        scope.append("""
            SELECT d.file, d.line, d.col, d.severity, d.source, d.code, d.message, s.name_path, -1
            FROM diagnostics d LEFT JOIN symbols s ON s.id = d.symbol_id
            WHERE (?2 = 0 OR d.severity = 'error')
              AND (?4 = '' OR d.file = ?4 OR d.file LIKE ?4 || '/%')
            ORDER BY d.file, d.line
            LIMIT ?3
            """);
    }
    let st = prepare_or_die(db, scope);
    swan_bind_int(st, 1, depth);
    swan_bind_int(st, 2, if errors_only { 1 } else { 0 });
    swan_bind_int(st, 3, limit);
    if pattern.len == 0 { swan_bind_text(st, 4, rel); }
    out.append("\"diagnostics\":[");
    var n = 0;
    var errors = 0;
    while swan_step(st, e) == 1 {
        if n > 0 { out.push(','); }
        n++;
        var s: u8[>..] = [];
        swan_col_text(st, 0, s);
        let file_changed = swan_mtime_ns(source_path(db, s)) > checked;
        out.append("{\"relative_path\":");
        json::format_string(out, s);
        format(out, ",\"line\":", swan_col_int(st, 1) + 1, ",\"column\":", swan_col_int(st, 2) + 1);
        s.clear();
        swan_col_text(st, 3, s);
        if s == "error" { errors++; }
        out.append(",\"severity\":");
        json::format_string(out, s);
        s.clear();
        swan_col_text(st, 4, s);
        out.append(",\"source\":");
        json::format_string(out, s);
        s.clear();
        swan_col_text(st, 5, s);
        out.append(",\"code\":");
        json::format_string(out, s);
        s.clear();
        swan_col_text(st, 6, s);
        out.append(",\"message\":");
        json::format_string(out, s);
        s.clear();
        swan_col_text(st, 7, s);
        if s.len > 0 { out.append(",\"in_symbol\":"); json::format_string(out, s); }
        let dist = swan_col_int(st, 8);
        if dist >= 0 { format(out, ",\"distance\":", dist); }
        if file_changed { out.append(",\"stale\":true"); }
        out.push('}');
    }
    swan_finalize(st);
    format(out, "],\"shown\":", n, ",\"errors_shown\":", errors);

    // The whole map, for the question "where are the errors at all".
    let sum = prepare_or_die(db, """
        SELECT count(*), sum(severity = 'error'), count(DISTINCT file) FROM diagnostics
        """);
    if swan_step(sum, e) == 1 {
        format(out, ",\"map_total\":{\"diagnostics\":", swan_col_int(sum, 0), ",\"errors\":",
               swan_col_int(sum, 1), ",\"files\":", swan_col_int(sum, 2), "}");
    }
    swan_finalize(sum);
    out.append(",\"note\":\"from the last tsc / cargo check run; rerun scripts/diagnose-repo.sh after edits\"}");
    return true;
}
