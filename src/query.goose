// The questions Swan answers, each written as JSON into a builder. Tool names
// and arguments follow Serena's (github.com/oraios/serena; interface only, see NOTICE): a name path
// is the chain of enclosing symbol names joined by '/', "add" matches any
// symbol named add, "Store/add" any whose path ends that way, and "/Store/add"
// only that whole path. Lines and columns in the output are 1-based.

import std;
import os;
import json;


fn line_bounds(text: const u8[:], starts: i64[>..]&) {
    starts.clear();
    starts.push(0);
    for ch, i in text { if ch == '\n' { starts.push(i + 1); } }
}

fn line_of(text: const u8[:], starts: const i64[:], line: i64) -> const u8[:] {
    guard line >= 0 && line < starts.len else { return text[0..0]; }
    let lo = starts[line];
    var hi = if line + 1 < starts.len { starts[line + 1] - 1 } else { text.len };
    if hi > lo && text[hi - 1] == '\r' { hi--; }
    return text[lo..hi];
}

// Serena-style matching. Returns the SQL for the pattern and the text to bind.
fn match_sql(pattern: const u8[:], substring: bool) -> const u8[:], const u8[:] {
    if pattern.len > 1 && pattern[0] == '/' {
        return "SELECT id, name_path, kind, signature, def_file, def_line, def_col, body_start, body_end FROM symbols WHERE in_repo = 1 AND kind NOT IN ('parameter', 'type_parameter') AND name_path = ?1 AND (?2 = '' OR def_file = ?2 OR def_file LIKE ?2 || '/%') ORDER BY def_file, def_line LIMIT ?3",
               pattern[1..];
    }
    if find(pattern, "/") >= 0 {
        return "SELECT id, name_path, kind, signature, def_file, def_line, def_col, body_start, body_end FROM symbols WHERE in_repo = 1 AND kind NOT IN ('parameter', 'type_parameter') AND (name_path = ?1 OR name_path LIKE '%/' || ?1) AND (?2 = '' OR def_file = ?2 OR def_file LIKE ?2 || '/%') ORDER BY def_file, def_line LIMIT ?3",
               pattern;
    }
    if substring {
        return "SELECT id, name_path, kind, signature, def_file, def_line, def_col, body_start, body_end FROM symbols WHERE in_repo = 1 AND kind NOT IN ('parameter', 'type_parameter') AND instr(name, ?1) > 0 AND (?2 = '' OR def_file = ?2 OR def_file LIKE ?2 || '/%') ORDER BY def_file, def_line LIMIT ?3",
               pattern;
    }
    return "SELECT id, name_path, kind, signature, def_file, def_line, def_col, body_start, body_end FROM symbols WHERE in_repo = 1 AND kind NOT IN ('parameter', 'type_parameter') AND name = ?1 AND (?2 = '' OR def_file = ?2 OR def_file LIKE ?2 || '/%') ORDER BY def_file, def_line LIMIT ?3",
           pattern;
}

fn meta_value(db: i64, key: const u8[:], out: u8[>..]&) {
    let st = prepare_or_die(db, "SELECT value FROM meta WHERE key = ?1");
    swan_bind_text(st, 1, key);
    var err: u8[>..] = [];
    if swan_step(st, err) == 1 { swan_col_text(st, 0, out); }
    swan_finalize(st);
}

fn source_path(db: i64, file: const u8[:]) -> u8[>..] {
    var p: u8[>..] = [];
    meta_value(db, "root", p);
    if p.len > 0 && p[p.len - 1] != '/' { p.push('/'); }
    p.append(file);
    return p;
}

// Writes the symbol at the current row of a match_sql statement.
fn symbol_json(st: i64, out: u8[>..]&) {
    var s: u8[>..] = [];
    out.push('{');
    json::format_key(out, "name_path");
    swan_col_text(st, 1, s); json::format_string(out, s); s.clear();
    out.push(',');
    json::format_key(out, "kind");
    swan_col_text(st, 2, s); json::format_string(out, s); s.clear();
    out.push(',');
    json::format_key(out, "signature");
    swan_col_text(st, 3, s); json::format_string(out, s); s.clear();
    out.push(',');
    json::format_key(out, "relative_path");
    swan_col_text(st, 4, s); json::format_string(out, s); s.clear();
    out.push(',');
    json::format_key(out, "line");
    json::format_int(out, swan_col_int(st, 5) + 1);
    out.push(',');
    json::format_key(out, "column");
    json::format_int(out, swan_col_int(st, 6) + 1);
    var tx: u8[>..] = [];
    swan_col_text(st, 7, tx);
    if tx.len > 0 {
        out.push(',');
        json::format_key(out, "body_lines");
        out.push('[');
        json::format_int(out, swan_col_int(st, 7) + 1);
        out.push(',');
        json::format_int(out, swan_col_int(st, 8) + 1);
        out.push(']');
    }
    out.push('}');
}

fn find_symbol(db: i64, pattern: const u8[:], rel: const u8[:], substring: bool, include_body: bool,
               limit: i64, out: u8[>..]&) {
    let sql, bind = match_sql(pattern, substring);
    let st = prepare_or_die(db, sql);
    swan_bind_text(st, 1, bind);
    swan_bind_text(st, 2, rel);
    swan_bind_int(st, 3, limit);
    var err: u8[>..] = [];
    var text: u8[>..] = [];
    var starts: i64[>..] = [];
    var n = 0;
    out.push('[');
    while swan_step(st, err) == 1 {
        if n > 0 { out.push(','); }
        n++;
        symbol_json(st, out);
        var bs: u8[>..] = [];
        swan_col_text(st, 7, bs);
        if include_body && bs.len > 0 {
            var file: u8[>..] = [];
            swan_col_text(st, 4, file);
            text.clear();
            if read_file(source_path(db, file), text) {
                line_bounds(text, starts);
                var body: u8[>..] = [];
                for l in swan_col_int(st, 7)..swan_col_int(st, 8) + 1 {
                    body.append(line_of(text, starts, l));
                    body.push('\n');
                }
                out.pop();     // reopen the object for one more member
                out.push(',');
                json::format_key(out, "body");
                json::format_string(out, body);
                out.push('}');
            }
        }
    }
    out.push(']');
    swan_finalize(st);
}

// The references to every symbol the name path matches, each with the
// symbol it sits inside and its line of source.
fn find_referencing_symbols(db: i64, pattern: const u8[:], rel: const u8[:], limit: i64, out: u8[>..]&) {
    let sql, bind = match_sql(pattern, false);
    let st = prepare_or_die(db, sql);
    swan_bind_text(st, 1, bind);
    swan_bind_text(st, 2, rel);
    swan_bind_int(st, 3, 20);
    let refs = prepare_or_die(db, """
        SELECT o.file, o.start_line, o.start_col, e.name_path, e.kind
        FROM occurrences o LEFT JOIN symbols e ON e.id = o.enclosing_id
        WHERE o.symbol_id = ?1 AND o.is_def = 0
        ORDER BY o.file, o.start_line, o.start_col
        LIMIT ?2
        """);
    var err: u8[>..] = [];
    var text: u8[>..] = [];
    var starts: i64[>..] = [];
    var loaded: u8[>..] = [];
    var n = 0;
    out.push('[');
    while swan_step(st, err) == 1 {
        if n > 0 { out.push(','); }
        n++;
        out.append("{");
        json::format_key(out, "symbol");
        symbol_json(st, out);
        out.push(',');
        json::format_key(out, "references");
        out.push('[');
        swan_bind_int(refs, 1, swan_col_int(st, 0));
        swan_bind_int(refs, 2, limit);
        var k = 0;
        while swan_step(refs, err) == 1 {
            if k > 0 { out.push(','); }
            k++;
            var file: u8[>..] = [];
            swan_col_text(refs, 0, file);
            if file != loaded {
                loaded.clear();
                loaded.append(file);
                text.clear();
                if read_file(source_path(db, file), text) { line_bounds(text, starts); } else { starts.clear(); }
            }
            let line = swan_col_int(refs, 1);
            out.push('{');
            json::format_key(out, "relative_path");
            json::format_string(out, file);
            out.push(',');
            json::format_key(out, "line");
            json::format_int(out, line + 1);
            out.push(',');
            json::format_key(out, "column");
            json::format_int(out, swan_col_int(refs, 2) + 1);
            var enc: u8[>..] = [];
            swan_col_text(refs, 3, enc);
            if enc.len > 0 {
                out.push(',');
                json::format_key(out, "in_symbol");
                json::format_string(out, enc);
                enc.clear();
                swan_col_text(refs, 4, enc);
                out.push(',');
                json::format_key(out, "in_kind");
                json::format_string(out, enc);
            }
            if starts.len > 0 {
                out.push(',');
                json::format_key(out, "text");
                json::format_string(out, trim(line_of(text, starts, line)));
            }
            out.push('}');
        }
        swan_reset(refs);
        out.append("]}");
    }
    out.push(']');
    swan_finalize(refs);
    swan_finalize(st);
}

// Every symbol a file (or every file under a directory) defines, in order.
fn get_symbols_overview(db: i64, rel: const u8[:], out: u8[>..]&) {
    let st = prepare_or_die(db, """
        SELECT id, name_path, kind, signature, def_file, def_line, def_col, body_start, body_end
        FROM symbols
        WHERE in_repo = 1 AND kind NOT IN ('parameter', 'type_parameter', 'module')
          AND (def_file = ?1 OR def_file LIKE ?1 || '/%')
        ORDER BY def_file, def_line, def_col
        LIMIT 2000
        """);
    swan_bind_text(st, 1, rel);
    var err: u8[>..] = [];
    var n = 0;
    out.push('[');
    while swan_step(st, err) == 1 {
        if n > 0 { out.push(','); }
        n++;
        symbol_json(st, out);
    }
    out.push(']');
    swan_finalize(st);
}

fn index_info(db: i64, out: u8[>..]&) {
    let st = prepare_or_die(db, "SELECT key, value FROM meta ORDER BY key");
    var err: u8[>..] = [];
    var n = 0;
    out.push('{');
    while swan_step(st, err) == 1 {
        if n > 0 { out.push(','); }
        n++;
        var k: u8[>..] = [];
        var v: u8[>..] = [];
        swan_col_text(st, 0, k);
        swan_col_text(st, 1, v);
        json::format_key(out, k);
        json::format_string(out, v);
    }
    out.push('}');
    swan_finalize(st);
}
