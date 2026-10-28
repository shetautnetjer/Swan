// Editing by symbol. The map knows each definition's exact span, so an edit
// names a symbol, not a line number: replace its whole definition, insert
// code before or after it, or rename it everywhere it is used.
//
// Safety, after how Serena and JetBrains do it:
// - The target must resolve to exactly one symbol in the given file.
// - A file changed since the map was built is refused: its positions are
//   not trustworthy. Refresh first.
// - A rename is planned before it is applied (JetBrains' find-usages
//   step). Each site's text is checked to be the old name before it is
//   rewritten. A site whose text differs, such as the alias side of
//   `export { format as formatItem }`, is left alone and reported. A sibling
//   that already has the new name is a conflict, and blocks the rename.
// - Files are written atomically.
//
// After an edit Swan shifts the file's rows itself, so the next edit and the
// next query still line up without waiting for a SCIP rerun. Uses inside the
// new code appear after the next refresh. Serena checks diagnostics around
// each edit, but keeps that off by default: single edits often break the
// build on purpose until the next one lands. Swan reports which symbols use
// the edited one instead, so the agent knows what to check.

import std;
import os;
import json;
import sqlite;

struct Target {
    id: i64,
    def_line: i64, def_col: i64,
    sl: i64, sc: i64, el: i64, ec: i64,     // the body span, sl < 0 if unknown
}

// Where a SCIP (line, column) falls in the bytes. scip-typescript counts
// columns in UTF-16 units; for ASCII they are bytes.
fn offset_of(text: const u8[:], starts: const i64[:], line: i64, col: i64) -> i64 {
    guard line >= 0 && line < starts.len else { return text.len; }
    var i = starts[line];
    var units = 0;
    while i < text.len && units < col && text[i] != '\n' {
        let c = text[i];
        let n = if c < 0x80 { 1 } else if c < 0xE0 { 2 } else if c < 0xF0 { 3 } else { 4 };
        units += if n == 4 { 2 } else { 1 };
        i += n;
    }
    return i;
}

// UTF-16 units from the start of the line holding `to` up to `to`.
fn col_of(text: const u8[:], to: i64) -> i64 {
    var i = to;
    while i > 0 && text[i - 1] != '\n' { i--; }
    var units = 0;
    while i < to {
        let c = text[i];
        let n = if c < 0x80 { 1 } else if c < 0xE0 { 2 } else if c < 0xF0 { 3 } else { 4 };
        units += if n == 4 { 2 } else { 1 };
        i += n;
    }
    return units;
}

// Blank lines off both ends, but the first line's indentation kept: an
// inserted method needs it. (A replaced body starts where the old one did,
// so it is trimmed fully.)
fn trim_lines(s: const u8[:]) -> const u8[:] {
    var lo = 0;
    var i = 0;
    while i < s.len && (s[i] == ' ' || s[i] == '\t' || s[i] == '\r' || s[i] == '\n') {
        if s[i] == '\n' { lo = i + 1; }
        i++;
    }
    return trim_end(s[lo..]);
}

fn count_newlines(s: const u8[:]) -> i64 {
    var n = 0;
    for c in s { if c == '\n' { n++; } }
    return n;
}

// A name every language Swan edits accepts as an identifier: a letter, `_`
// or `$`, then those or digits. (SCIP's own descriptor characters also allow
// `+` and `-`, which no source name may hold.)
fn is_name(s: const u8[:]) -> bool {
    guard s.len > 0 && !(s[0] >= '0' && s[0] <= '9') else { return false; }
    for c in s {
        if !((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '$') { return false; }
    }
    return true;
}

// The one symbol `pattern` names in `rel`, or an error message.
fn resolve_target(db: i64, pattern: const u8[:], rel: const u8[:], err: u8[>..]&) -> Target {
    var t = Target { id: -1, def_line: -1, def_col: -1, sl: -1, sc: -1, el: -1, ec: -1 };
    guard rel.len > 0 else { err.append("relative_path is required for an edit"); return t; }
    let sql, bind = match_sql(pattern, false);
    let st = prepare_or_die(db, sql);
    sqlite::bind_text(st, 1, bind);
    sqlite::bind_text(st, 2, rel);
    sqlite::bind_int(st, 3, 5);
    var e: u8[>..] = [];
    var n = 0;
    var names: u8[>..] = [];
    while sqlite::step(st, e) == 1 {
        n++;
        var file: u8[>..] = [];
        sqlite::col_text(st, 4, file);
        if names.len > 0 { names.append(", "); }
        sqlite::col_text(st, 1, names);
        format(names, " (", file, ":", sqlite::col_int(st, 5) + 1, ")");
        if n == 1 { t.id = sqlite::col_int(st, 0); }
    }
    sqlite::finalize(st);
    if n == 0 { format(err, "no symbol matches '", pattern, "' in ", rel); t.id = -1; return t; }
    if n > 1 { format(err, "'", pattern, "' matches ", n, " symbols in ", rel, ": ", names,
                      "; use the full name path, starting with '/'"); t.id = -1; return t; }
    let q = prepare_or_die(db, """
        SELECT def_line, def_col, body_start, body_start_col, body_end, body_end_col,
               body_start IS NOT NULL AND body_start_col IS NOT NULL
        FROM symbols WHERE id = ?1
        """);
    sqlite::bind_int(q, 1, t.id);
    if sqlite::step(q, e) == 1 {
        t.def_line = sqlite::col_int(q, 0);
        t.def_col = sqlite::col_int(q, 1);
        if sqlite::col_int(q, 6) == 1 {
            t.sl = sqlite::col_int(q, 2);
            t.sc = sqlite::col_int(q, 3);
            t.el = sqlite::col_int(q, 4);
            t.ec = sqlite::col_int(q, 5);
        }
    }
    sqlite::finalize(q);
    return t;
}

// The map after the text from (sl, sc) to (el, ec) of `file` was replaced by
// text that ends at (nel, nec); an insertion is the empty span at its point.
// Positions are (line, column), so code after the change on its last line
// moves too. Uses inside the replaced text go until the next refresh, and so
// do the symbols defined there other than `keep` (the methods of a replaced
// class): their positions name code that is gone.
fn shift_span(db: i64, file: const u8[:], sl: i64, sc: i64, el: i64, ec: i64, nel: i64, nec: i64, keep: i64) {
    // A position at or after the span's end moves with it.
    fn moved(l: const u8[:], c: const u8[:]) -> u8[>..] {
        return str(l, " = CASE WHEN ", l, " > ?2 OR (", l, " = ?2 AND ", c, " >= ?3) THEN ", l, " + ?4 - ?2 ELSE ", l, " END, ",
                   c, " = CASE WHEN ", l, " = ?2 AND ", c, " >= ?3 THEN ", c, " - ?3 + ?5 ELSE ", c, " END");
    }
    // A position inside the span: at or after its start, before its end.
    fn inside(l: const u8[:], c: const u8[:]) -> u8[>..] {
        return str("(", l, " > ?2 OR (", l, " = ?2 AND ", c, " >= ?3)) AND (", l, " < ?4 OR (", l, " = ?4 AND ", c, " < ?5))");
    }
    fn run(sql: const u8[:], a: i64, b: i64, c: i64, d: i64) {
        let st = prepare_or_die(db, sql);
        sqlite::bind_text(st, 1, file);
        sqlite::bind_int(st, 2, a);
        sqlite::bind_int(st, 3, b);
        sqlite::bind_int(st, 4, c);
        sqlite::bind_int(st, 5, d);
        sqlite::bind_int(st, 6, keep);
        step_done(st);
        sqlite::finalize(st);
    }
    exec_or_die(db, "BEGIN;");
    if el > sl || ec > sc {
        run(str("DELETE FROM occurrences WHERE file = ?1 AND ", inside("start_line", "start_col")), sl, sc, el, ec);
        run(str("""
            UPDATE symbols SET def_file = NULL, def_line = NULL, def_col = NULL, body_start = NULL, body_end = NULL,
                               body_start_col = NULL, body_end_col = NULL, in_repo = 0
            WHERE def_file = ?1 AND id != ?6 AND
            """, inside("def_line", "def_col")), sl, sc, el, ec);
    }
    run(str("UPDATE occurrences SET ", moved("start_line", "start_col"), ", ", moved("end_line", "end_col"), " WHERE file = ?1"),
        el, ec, nel, nec);
    run(str("UPDATE symbols SET ", moved("def_line", "def_col"), ", ", moved("body_start", "body_start_col"), ", ",
            moved("body_end", "body_end_col"), " WHERE def_file = ?1"), el, ec, nel, nec);
    exec_or_die(db, "COMMIT;");
}

// Where text inserted at (line, col) ends.
fn end_of(line: i64, col: i64, inserted: const u8[:]) -> i64, i64 {
    let nl = count_newlines(inserted);
    return line + nl, if nl > 0 { col_of(inserted, inserted.len) } else { col + col_of(inserted, inserted.len) };
}

// Records the mtime Swan left on a file it edited, so the file still reads
// as fresh, and clears its fingerprint: the rows were changed here, not by
// a SCIP run, so the next refresh must rebuild them whatever SCIP says.
// A file with no rows (a language Swan only searches, Lua say) gets a files
// row here, so its next edit is not mistaken for an outside change.
fn mark_edited(db: i64, file: const u8[:], path: const u8[:]) {
    let st = prepare_or_die(db, """
        INSERT INTO files (file, hash, rows, edited_mtime) VALUES (?1, '', 0, ?2)
        ON CONFLICT(file) DO UPDATE SET edited_mtime = excluded.edited_mtime, hash = ''
        """);
    sqlite::bind_text(st, 1, file);
    sqlite::bind_int(st, 2, swan_mtime_ns(path));
    step_done(st);
    sqlite::finalize(st);
}

// Who uses the symbol: what to check after changing it.
fn used_by(db: i64, id: i64, out: u8[>..]&) {
    let st = prepare_or_die(db, """
        SELECT count(*), count(DISTINCT file) FROM occurrences WHERE symbol_id = ?1 AND is_def = 0
        """);
    sqlite::bind_int(st, 1, id);
    var e: u8[>..] = [];
    var refs = 0;
    var files = 0;
    if sqlite::step(st, e) == 1 { refs = sqlite::col_int(st, 0); files = sqlite::col_int(st, 1); }
    sqlite::finalize(st);
    format(out, ",\"used_by\":{\"references\":", refs, ",\"files\":", files,
           ",\"next\":\"get_callers on this symbol lists them; check those that depend on what changed\"}");
}

// The three edits share one path: find the symbol, check the file, splice
// the text, write it, shift the map.
let EDIT_REPLACE = 0;
let EDIT_AFTER = 1;
let EDIT_BEFORE = 2;

fn edit_symbol(db: i64, mode: i64, pattern: const u8[:], rel: const u8[:], body: const u8[:],
               out: u8[>..]&) -> bool {
    var err: u8[>..] = [];
    let t = resolve_target(db, pattern, rel, err);
    guard t.id >= 0 else { out.append(err); return false; }
    guard mode == EDIT_BEFORE || t.sl >= 0 else {
        format(out, "'", pattern, "' has no known body span (only functions, methods, classes and other ",
               "blocks do); use insert_before_symbol, or edit the file directly");
        return false;
    }
    guard !is_stale(rel) else {
        format(out, rel, " changed since the map was built, so its positions can't be trusted. ",
               "Refresh the map (scripts/refresh-repo.sh) and try again.");
        return false;
    }
    let path = source_path(db, rel);
    var text: u8[>..] = [];
    guard read_file(path, text) else { format(out, "cannot read ", path); return false; }
    var starts: i64[>..] = [];
    line_bounds(text, starts);
    let code = if mode == EDIT_REPLACE { trim(body) } else { trim_lines(body) };

    var updated: u8[>..] = [];
    var a = 0;
    var b = 0;
    var n = 0;
    if mode == EDIT_REPLACE {
        let so = offset_of(text, starts, t.sl, t.sc);
        let eo = offset_of(text, starts, t.el, t.ec);
        updated.append(text[..so]);
        updated.append(code);
        updated.append(text[eo..]);
        a = t.sl;
        b = t.el;
        n = count_newlines(code) + 1;
    } else if mode == EDIT_AFTER {
        // From the start of the line after the symbol, one blank line apart.
        let at = if t.el + 1 < starts.len { starts[t.el + 1] } else { text.len };
        updated.append(text[..at]);
        if at == text.len && at > 0 && text[at - 1] != '\n' { updated.push('\n'); }
        updated.push('\n');
        updated.append(code);
        updated.push('\n');
        updated.append(text[at..]);
        a = t.el + 1;
        b = t.el;
        n = count_newlines(code) + 2;
    } else {
        // Before the line the symbol starts on, one blank line apart.
        let line = if t.sl >= 0 { t.sl } else { t.def_line };
        let at = if line < starts.len { starts[line] } else { text.len };
        updated.append(text[..at]);
        updated.append(code);
        updated.append("\n\n");
        updated.append(text[at..]);
        a = line;
        b = line - 1;
        n = count_newlines(code) + 2;
    }
    guard write_file_atomic(path, updated) else { format(out, "cannot write ", path); return false; }
    if mode == EDIT_REPLACE {
        // The symbol's span, which ended at (el, ec), now ends where the new code does.
        let nel, nec = end_of(t.sl, t.sc, code);
        shift_span(db, rel, t.sl, t.sc, t.el, t.ec, nel, nec, t.id);
    } else {
        shift_span(db, rel, a, 0, a, 0, a + n, 0, t.id);
    }
    mark_edited(db, rel, path);
    out.append("{\"edited\":");
    json::format_string(out, rel);
    format(out, ",\"lines\":[", a + 1, ",", a + n, "],\"line_delta\":", n - (b - a + 1));
    out.append(",\"map\":\"positions in this file were shifted to match; uses inside the new code appear after the next refresh\"");
    used_by(db, t.id, out);
    out.push('}');
    return true;
}

// One place a rename rewrites.
struct Site { line: i64, col: i64, end_col: i64 }

// Renames a symbol at every use the compiler resolved. Without `apply` it
// only plans: every site, what it would skip, and any conflict.
fn rename_symbol(db: i64, pattern: const u8[:], rel: const u8[:], new_name: const u8[:], apply: bool,
                 out: u8[>..]&) -> bool {
    var err: u8[>..] = [];
    let t = resolve_target(db, pattern, rel, err);
    guard t.id >= 0 else { out.append(err); return false; }
    guard is_name(new_name) else {
        format(out, "new_name must be an identifier: '", new_name, "'");
        return false;
    }
    var old_name: u8[>..] = [];
    var old_path: u8[>..] = [];
    let q = prepare_or_die(db, "SELECT name, name_path FROM symbols WHERE id = ?1");
    sqlite::bind_int(q, 1, t.id);
    var e: u8[>..] = [];
    if sqlite::step(q, e) == 1 { sqlite::col_text(q, 0, old_name); sqlite::col_text(q, 1, old_path); }
    sqlite::finalize(q);
    guard old_name != new_name else { out.append("new_name is the current name"); return false; }

    // The new name path, and whether something there already has it.
    var new_path: u8[>..] = [];
    let cut = rfind(old_path, "/");
    if cut >= 0 { new_path.append(old_path[..cut + 1]); }
    new_path.append(new_name);
    let cf = prepare_or_die(db, """
        SELECT name_path, kind, def_file, def_line FROM symbols
        WHERE in_repo = 1 AND name_path = ?1 AND (instr(?1, '/') > 0 OR def_file = ?2)
        """);
    sqlite::bind_text(cf, 1, new_path);
    sqlite::bind_text(cf, 2, rel);
    var conflicts: u8[>..] = [];
    var nconf = 0;
    while sqlite::step(cf, e) == 1 {
        if nconf > 0 { conflicts.push(','); }
        nconf++;
        var s: u8[>..] = [];
        conflicts.append("{\"name_path\":");
        sqlite::col_text(cf, 0, s); json::format_string(conflicts, s); s.clear();
        conflicts.append(",\"kind\":");
        sqlite::col_text(cf, 1, s); json::format_string(conflicts, s); s.clear();
        conflicts.append(",\"relative_path\":");
        sqlite::col_text(cf, 2, s); json::format_string(conflicts, s);
        format(conflicts, ",\"line\":", sqlite::col_int(cf, 3) + 1, "}");
    }
    sqlite::finalize(cf);

    // Every site, file by file. Each file is read once and checked fresh.
    let sites_q = prepare_or_die(db, """
        SELECT file, start_line, start_col, end_line, end_col, is_def FROM occurrences
        WHERE symbol_id = ?1 ORDER BY file, start_line, start_col
        """);
    sqlite::bind_int(sites_q, 1, t.id);
    var plan: u8[>..] = [];
    var skipped: u8[>..] = [];
    var stale_files: u8[>..] = [];
    var nsites = 0;
    var nskip = 0;
    var nstale = 0;
    var nfiles = 0;
    var cur: u8[>..] = [];
    var text: u8[>..] = [];
    var starts: i64[>..] = [];
    var readable = false;
    var cur_stale = false;
    while sqlite::step(sites_q, e) == 1 {
        var file: u8[>..] = [];
        sqlite::col_text(sites_q, 0, file);
        if file != cur {
            cur.clear();
            cur.append(file);
            nfiles++;
            text.clear();
            readable = read_file(source_path(db, file), text);
            if readable { line_bounds(text, starts); }
            cur_stale = is_stale(file);
            if cur_stale {
                if nstale > 0 { stale_files.push(','); }
                nstale++;
                json::format_string(stale_files, file);
            }
        }
        let line = sqlite::col_int(sites_q, 1);
        let col = sqlite::col_int(sites_q, 2);
        let el = sqlite::col_int(sites_q, 3);
        let ec = sqlite::col_int(sites_q, 4);
        var ok = readable && el == line;
        if ok {
            let so = offset_of(text, starts, line, col);
            let eo = offset_of(text, starts, line, ec);
            ok = text[so..eo] == old_name;
        }
        var entry: u8[>..] = [];
        entry.append("{\"relative_path\":");
        json::format_string(entry, file);
        format(entry, ",\"line\":", line + 1, ",\"column\":", col + 1);
        if sqlite::col_int(sites_q, 5) == 1 { entry.append(",\"definition\":true"); }
        if !ok { entry.append(",\"why\":\"the text there is not the old name (an alias, a re-export or a generated use)\""); }
        entry.push('}');
        if ok {
            if nsites > 0 { plan.push(','); }
            nsites++;
            plan.append(entry);
        } else {
            if nskip > 0 { skipped.push(','); }
            nskip++;
            skipped.append(entry);
        }
    }
    sqlite::finalize(sites_q);

    out.append("{\"rename\":");
    json::format_string(out, old_path);
    out.append(",\"to\":");
    json::format_string(out, new_path);
    format(out, ",\"files\":", nfiles, ",\"sites\":[", plan, "],\"skipped\":[", skipped,
           "],\"conflicts\":[", conflicts, "],\"stale_files\":[", stale_files, "]");
    out.append(",\"not_covered\":\"strings, comments, docs and uses by name at run time\"");
    if !apply {
        out.append(",\"applied\":false}");
        return true;
    }
    if nconf > 0 || nstale > 0 {
        out.append(",\"applied\":false,\"refused\":\"");
        if nconf > 0 { out.append("a symbol with the new name already exists there. "); }
        if nstale > 0 { out.append("some files changed since the map was built; refresh first."); }
        out.append("\"}");
        return false;
    }

    // Apply, file by file, rewriting only the checked sites.
    let again = prepare_or_die(db, """
        SELECT file, start_line, start_col, end_line, end_col FROM occurrences
        WHERE symbol_id = ?1 ORDER BY file, start_line DESC, start_col DESC
        """);
    sqlite::bind_int(again, 1, t.id);
    let d = new_name.len - old_name.len;   // identifiers are ASCII here
    var sites: Site[>..] = [];
    cur.clear();
    var written = 0;
    fn flush() {
        guard cur.len > 0 && sites.len > 0;
        let path = source_path(db, cur);
        text.clear();
        guard read_file(path, text);
        line_bounds(text, starts);
        var updated: u8[>..] = [];
        // Sites come last-first; the cuts are walked back to front to write forward.
        var cuts: i64[>..] = [];
        var done: Site[>..] = [];       // the sites written; only their rows move
        for s in sites {
            let so = offset_of(text, starts, s.line, s.col);
            let eo = offset_of(text, starts, s.line, s.end_col);
            if text[so..eo] == old_name { cuts.push(so); cuts.push(eo); done.push(s); }
        }
        var k = cuts.len;
        var at = 0;
        while k > 0 {
            k -= 2;
            updated.append(text[at..cuts[k]]);
            updated.append(new_name);
            at = cuts[k + 1];
        }
        updated.append(text[at..]);
        fn shift(sql: const u8[:], line: i64, col: i64) {
            let st = prepare_or_die(db, sql);
            sqlite::bind_text(st, 1, cur);
            sqlite::bind_int(st, 2, line);
            sqlite::bind_int(st, 3, col);
            sqlite::bind_int(st, 4, d);
            step_done(st);
            sqlite::finalize(st);
        }
        if write_file_atomic(path, updated) {
            exec_or_die(db, "BEGIN;");
            for s in done {
                shift("UPDATE occurrences SET start_col = start_col + ?4, end_col = end_col + ?4 WHERE file = ?1 AND start_line = ?2 AND start_col > ?3", s.line, s.col);
                shift("UPDATE occurrences SET end_col = end_col + ?4 WHERE file = ?1 AND start_line = ?2 AND start_col = ?3", s.line, s.col);
                shift("UPDATE symbols SET def_col = def_col + ?4 WHERE def_file = ?1 AND def_line = ?2 AND def_col > ?3", s.line, s.col);
                shift("UPDATE symbols SET body_start_col = body_start_col + ?4 WHERE def_file = ?1 AND body_start = ?2 AND body_start_col > ?3", s.line, s.col);
                shift("UPDATE symbols SET body_end_col = body_end_col + ?4 WHERE def_file = ?1 AND body_end = ?2 AND body_end_col > ?3", s.line, s.col);
            }
            exec_or_die(db, "COMMIT;");
            mark_edited(db, cur, path);
            written++;
        }
        sites.clear();
    }
    while sqlite::step(again, e) == 1 {
        var file: u8[>..] = [];
        sqlite::col_text(again, 0, file);
        if file != cur { flush(); cur.clear(); cur.append(file); }
        if sqlite::col_int(again, 3) == sqlite::col_int(again, 1) {
            sites.push(Site { line: sqlite::col_int(again, 1), col: sqlite::col_int(again, 2),
                              end_col: sqlite::col_int(again, 4) });
        }
    }
    flush();
    sqlite::finalize(again);

    // The map's names follow: the symbol, and the paths of what it holds.
    let rn = prepare_or_die(db, """
        UPDATE symbols SET name_path = ?3 || substr(name_path, length(?2) + 1)
        WHERE def_file = ?4 AND (name_path = ?2 OR name_path LIKE ?2 || '/%')
        """);
    sqlite::bind_text(rn, 4, rel);
    sqlite::bind_text(rn, 2, old_path);
    sqlite::bind_text(rn, 3, new_path);
    step_done(rn);
    sqlite::finalize(rn);
    let nm = prepare_or_die(db, "UPDATE symbols SET name = ?2 WHERE id = ?1");
    sqlite::bind_int(nm, 1, t.id);
    sqlite::bind_text(nm, 2, new_name);
    step_done(nm);
    sqlite::finalize(nm);
    format(out, ",\"applied\":true,\"files_written\":", written, "}");
    return true;
}
