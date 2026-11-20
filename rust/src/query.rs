// The questions Swan answers, each written as JSON into a builder. Tool names
// and arguments follow Serena's (github.com/oraios/serena; interface only, see NOTICE): a name path
// is the chain of enclosing symbol names joined by '/', "add" matches any
// symbol named add, "Store/add" any whose path ends that way, and "/Store/add"
// only that whole path. Lines and columns in the output are 1-based.
//
// Carried over from src/query.goose.

use crate::db::{Db, Stmt};
use crate::fresh::Fresh;
use crate::scip::package_of;
use crate::sys;
use crate::util::{find, json_key, json_string, push_int, trim};

pub fn line_bounds(text: &[u8], starts: &mut Vec<usize>) {
    starts.clear();
    starts.push(0);
    for (i, &ch) in text.iter().enumerate() {
        if ch == b'\n' {
            starts.push(i + 1);
        }
    }
}

pub fn line_of<'a>(text: &'a [u8], starts: &[usize], line: i64) -> &'a [u8] {
    if !(line >= 0 && (line as usize) < starts.len()) {
        return &text[0..0];
    }
    let line = line as usize;
    let lo = starts[line];
    let mut hi = if line + 1 < starts.len() { starts[line + 1] - 1 } else { text.len() };
    if hi > lo && text[hi - 1] == b'\r' {
        hi -= 1;
    }
    &text[lo..hi]
}

// Serena-style matching. Returns the SQL for the pattern and the text to bind.
pub fn match_sql(pattern: &[u8], substring: bool) -> (&'static [u8], &[u8]) {
    if pattern.len() > 1 && pattern[0] == b'/' {
        return (b"SELECT id, name_path, kind, signature, def_file, def_line, def_col, body_start, body_end FROM symbols WHERE in_repo = 1 AND kind NOT IN ('parameter', 'type_parameter') AND name_path = ?1 AND (?2 = '' OR def_file = ?2 OR def_file LIKE ?2 || '/%') ORDER BY def_file, def_line LIMIT ?3",
                &pattern[1..]);
    }
    if find(pattern, b"/") >= 0 {
        return (b"SELECT id, name_path, kind, signature, def_file, def_line, def_col, body_start, body_end FROM symbols WHERE in_repo = 1 AND kind NOT IN ('parameter', 'type_parameter') AND (name_path = ?1 OR name_path LIKE '%/' || ?1) AND (?2 = '' OR def_file = ?2 OR def_file LIKE ?2 || '/%') ORDER BY def_file, def_line LIMIT ?3",
                pattern);
    }
    if substring {
        return (b"SELECT id, name_path, kind, signature, def_file, def_line, def_col, body_start, body_end FROM symbols WHERE in_repo = 1 AND kind NOT IN ('parameter', 'type_parameter') AND instr(name, ?1) > 0 AND (?2 = '' OR def_file = ?2 OR def_file LIKE ?2 || '/%') ORDER BY def_file, def_line LIMIT ?3",
                pattern);
    }
    (b"SELECT id, name_path, kind, signature, def_file, def_line, def_col, body_start, body_end FROM symbols WHERE in_repo = 1 AND kind NOT IN ('parameter', 'type_parameter') AND name = ?1 AND (?2 = '' OR def_file = ?2 OR def_file LIKE ?2 || '/%') ORDER BY def_file, def_line LIMIT ?3",
     pattern)
}

/// The map's value for key; empty when it has none.
pub fn meta_value(db: &Db, key: &[u8]) -> Vec<u8> {
    let st = db.prepare_or_die(b"SELECT value FROM meta WHERE key = ?1");
    st.bind_text(1, key);
    if st.step_checked() {
        st.col_text(0)
    } else {
        Vec::new()
    }
}

pub fn source_path(db: &Db, file: &[u8]) -> Vec<u8> {
    let mut p = meta_value(db, b"root");
    if !p.is_empty() && p[p.len() - 1] != b'/' {
        p.push(b'/');
    }
    p.extend_from_slice(file);
    p
}

// Writes the symbol at the current row of a match_sql statement.
pub fn symbol_json(fr: &Fresh, st: &Stmt, out: &mut Vec<u8>) {
    out.push(b'{');
    json_key(out, b"name_path");
    json_string(out, &st.col_text(1));
    out.push(b',');
    json_key(out, b"kind");
    json_string(out, &st.col_text(2));
    out.push(b',');
    json_key(out, b"signature");
    json_string(out, &st.col_text(3));
    out.push(b',');
    json_key(out, b"relative_path");
    let s = st.col_text(4);
    json_string(out, &s);
    if fr.is_stale(&s) {
        out.extend_from_slice(b",\"stale\":true");
    }
    out.push(b',');
    json_key(out, b"line");
    push_int(out, st.col_int(5) + 1);
    out.push(b',');
    json_key(out, b"column");
    push_int(out, st.col_int(6) + 1);
    let tx = st.col_text(7);
    if !tx.is_empty() {
        out.push(b',');
        json_key(out, b"body_lines");
        out.push(b'[');
        push_int(out, st.col_int(7) + 1);
        out.push(b',');
        push_int(out, st.col_int(8) + 1);
        out.push(b']');
    }
    out.push(b'}');
}

pub fn find_symbol(db: &Db, fr: &Fresh, pattern: &[u8], rel: &[u8], substring: bool, include_body: bool, limit: i64, out: &mut Vec<u8>) {
    let (sql, bind) = match_sql(pattern, substring);
    let st = db.prepare_or_die(sql);
    st.bind_text(1, bind);
    st.bind_text(2, rel);
    st.bind_int(3, limit);
    let mut text: Vec<u8> = Vec::new();
    let mut starts: Vec<usize> = Vec::new();
    let mut n = 0;
    out.push(b'[');
    while st.step_checked() {
        if n > 0 {
            out.push(b',');
        }
        n += 1;
        symbol_json(fr, &st, out);
        let bs = st.col_text(7);
        if include_body && !bs.is_empty() {
            let file = st.col_text(4);
            text.clear();
            if sys::read_file(&source_path(db, &file), &mut text) {
                line_bounds(&text, &mut starts);
                let mut body: Vec<u8> = Vec::new();
                for l in st.col_int(7)..st.col_int(8) + 1 {
                    body.extend_from_slice(line_of(&text, &starts, l));
                    body.push(b'\n');
                }
                out.pop(); // reopen the object for one more member
                out.push(b',');
                json_key(out, b"body");
                json_string(out, &body);
                out.push(b'}');
            }
        }
    }
    out.push(b']');
}

// The references to every symbol the name path matches, each with the
// symbol it sits inside and its line of source.
// With `members`, uses of what the symbol holds count too, each marked with
// the member it went through ("via"): an enum's variants, a class's methods
// and fields, and in Rust the functions of its impl blocks. That is how
// `Shape::Square` or `Tile::new` counts as a use of the type,
// which rust-analyzer records only against the variant or function.
pub fn find_referencing_symbols(db: &Db, fr: &Fresh, pattern: &[u8], rel: &[u8], limit: i64, members: bool, out: &mut Vec<u8>) {
    let (sql, bind) = match_sql(pattern, false);
    let st = db.prepare_or_die(sql);
    st.bind_text(1, bind);
    st.bind_text(2, rel);
    st.bind_int(3, 20);
    let refs = db.prepare_or_die(
        b"WITH t AS (SELECT id, scip, name,
                  substr(scip, 1, length(rtrim(scip, replace(scip, '/', '')))) AS module
           FROM symbols WHERE id = ?1),
targets AS (
    SELECT id FROM t
    UNION
    SELECT s.id FROM symbols s, t
    WHERE s.id != t.id AND s.name = '<init>' AND substr(s.scip, 1, length(t.scip)) = t.scip
    UNION
    SELECT s.id FROM symbols s, t
    WHERE ?3 = 1 AND s.id != t.id AND (
        substr(s.scip, 1, length(t.scip)) = t.scip
        OR substr(s.scip, 1, length(t.module) + length(t.name) + 7) = t.module || 'impl#[' || t.name || ']'
        OR substr(s.scip, 1, length(t.module) + length(t.name) + 8) = t.module || 'impl#[`' || t.name || '<'))
SELECT o.file, o.start_line, o.start_col, e.name_path, e.kind,
       CASE WHEN o.symbol_id = ?1 THEN '' ELSE v.name_path END, o.by_name, o.is_import
FROM occurrences o
JOIN symbols v ON v.id = o.symbol_id
LEFT JOIN symbols e ON e.id = o.enclosing_id
WHERE o.symbol_id IN (SELECT id FROM targets) AND o.is_def = 0
ORDER BY o.file, o.start_line, o.start_col
LIMIT ?2
",
    );
    let mut text: Vec<u8> = Vec::new();
    let mut starts: Vec<usize> = Vec::new();
    let mut loaded: Vec<u8> = Vec::new();
    let mut loaded_stale = false;
    let mut n = 0;
    out.push(b'[');
    while st.step_checked() {
        if n > 0 {
            out.push(b',');
        }
        n += 1;
        out.push(b'{');
        json_key(out, b"symbol");
        symbol_json(fr, &st, out);
        out.push(b',');
        json_key(out, b"references");
        out.push(b'[');
        refs.bind_int(1, st.col_int(0));
        refs.bind_int(2, limit);
        refs.bind_int(3, if members { 1 } else { 0 });
        let mut k = 0;
        while refs.step_checked() {
            if k > 0 {
                out.push(b',');
            }
            k += 1;
            let file = refs.col_text(0);
            if file != loaded {
                loaded.clear();
                loaded.extend_from_slice(&file);
                loaded_stale = fr.is_stale(&file);
                text.clear();
                if sys::read_file(&source_path(db, &file), &mut text) {
                    line_bounds(&text, &mut starts);
                } else {
                    starts.clear();
                }
            }
            let line = refs.col_int(1);
            out.push(b'{');
            json_key(out, b"relative_path");
            json_string(out, &file);
            if loaded_stale {
                out.extend_from_slice(b",\"stale\":true");
            }
            out.push(b',');
            json_key(out, b"line");
            push_int(out, line + 1);
            out.push(b',');
            json_key(out, b"column");
            push_int(out, refs.col_int(2) + 1);
            let enc = refs.col_text(3);
            if !enc.is_empty() {
                out.push(b',');
                json_key(out, b"in_symbol");
                json_string(out, &enc);
                out.push(b',');
                json_key(out, b"in_kind");
                json_string(out, &refs.col_text(4));
            }
            if refs.col_int(6) == 1 {
                out.extend_from_slice(b",\"by_name\":true");
            }
            if refs.col_int(7) == 1 {
                out.extend_from_slice(b",\"import\":true");
            }
            let via = refs.col_text(5);
            if !via.is_empty() {
                out.push(b',');
                json_key(out, b"via");
                json_string(out, &via);
            }
            if !starts.is_empty() {
                out.push(b',');
                json_key(out, b"text");
                json_string(out, trim(line_of(&text, &starts, line)));
            }
            out.push(b'}');
        }
        refs.reset();
        out.extend_from_slice(b"]}");
    }
    out.push(b']');
}

// Every symbol a file (or every file under a directory) defines, in order.
pub fn get_symbols_overview(db: &Db, fr: &Fresh, rel: &[u8], out: &mut Vec<u8>) {
    let st = db.prepare_or_die(
        b"SELECT id, name_path, kind, signature, def_file, def_line, def_col, body_start, body_end
FROM symbols
WHERE in_repo = 1 AND kind NOT IN ('parameter', 'type_parameter', 'module')
  AND (def_file = ?1 OR def_file LIKE ?1 || '/%')
ORDER BY def_file, def_line, def_col
LIMIT 2000
",
    );
    st.bind_text(1, rel);
    let mut n = 0;
    out.push(b'[');
    while st.step_checked() {
        if n > 0 {
            out.push(b',');
        }
        n += 1;
        symbol_json(fr, &st, out);
    }
    out.push(b']');
}

pub fn index_info(db: &Db, fr: &Fresh, out: &mut Vec<u8>) {
    let st = db.prepare_or_die(b"SELECT key, value FROM meta ORDER BY key");
    let mut n = 0;
    out.push(b'{');
    while st.step_checked() {
        if n > 0 {
            out.push(b',');
        }
        n += 1;
        json_key(out, &st.col_text(0));
        json_string(out, &st.col_text(1));
    }
    drop(st);
    // Files changed since the SCIP run: the map's answers about them may be old.
    let fs = db.prepare_or_die(b"SELECT file FROM files ORDER BY file");
    let mut stale = 0;
    let mut listed: Vec<u8> = Vec::new();
    while fs.step_checked() {
        let f = fs.col_text(0);
        if fr.is_stale(&f) {
            if stale < 50 {
                if stale > 0 {
                    listed.push(b',');
                }
                json_string(&mut listed, &f);
            }
            stale += 1;
        }
    }
    drop(fs);
    // Files added since the build count too: the map has no answers for them at all.
    let mut added: Vec<u8> = Vec::new();
    let nnew = fr.new_files(db, &mut added);
    for f in added.split(|&c| c == b'\n') {
        if f.is_empty() {
            continue;
        }
        if stale < 50 {
            if stale > 0 {
                listed.push(b',');
            }
            json_string(&mut listed, f);
        }
        stale += 1;
    }
    out.extend_from_slice(b",\"stale_file_count\":");
    push_int(out, stale);
    out.extend_from_slice(b",\"stale_files\":[");
    out.extend_from_slice(&listed);
    out.extend_from_slice(b"],\"new_file_count\":");
    push_int(out, nnew);
    out.push(b'}');
}

// What is at a position: the symbol whose occurrence covers line:column
// (1-based), with its definition, signature and the symbol around it.
// JetBrains' get_symbol_info. When nothing covers the column, the line's
// other occurrences are listed, to help aim.
pub fn get_symbol_at(db: &Db, fr: &Fresh, rel: &[u8], line: i64, col: i64, out: &mut Vec<u8>) {
    let st = db.prepare_or_die(
        b"SELECT s.id, s.name_path, s.kind, s.signature, s.def_file, s.def_line, s.def_col,
       s.body_start, s.body_end, s.in_repo, s.scip, o.is_def, o.by_name, o.is_import,
       e.name_path, o.start_col, o.end_col, s.doc
FROM occurrences o JOIN symbols s ON s.id = o.symbol_id
LEFT JOIN symbols e ON e.id = o.enclosing_id
WHERE o.file = ?1 AND o.start_line = ?2 AND ((o.start_col <= ?3 AND o.end_col > ?3) OR ?4 = 1)
ORDER BY CASE WHEN o.start_col <= ?3 AND o.end_col > ?3 THEN 0 ELSE 1 END,
         o.end_col - o.start_col, o.start_col
LIMIT 20
",
    );
    let run = |any_on_line: bool, out: &mut Vec<u8>| -> i64 {
        st.bind_text(1, rel);
        st.bind_int(2, line - 1);
        st.bind_int(3, col - 1);
        st.bind_int(4, if any_on_line { 1 } else { 0 });
        let mut n = 0;
        while st.step_checked() {
            if n > 0 {
                out.push(b',');
            }
            n += 1;
            if st.col_int(9) == 1 {
                symbol_json(fr, &st, out);
                out.pop();
            } else {
                out.extend_from_slice(b"{\"name_path\":");
                json_string(out, &st.col_text(1));
                out.extend_from_slice(b",\"kind\":");
                json_string(out, &st.col_text(2));
                out.extend_from_slice(b",\"signature\":");
                json_string(out, &st.col_text(3));
                out.extend_from_slice(b",\"package\":");
                json_string(out, package_of(&st.col_text(10)));
            }
            out.extend_from_slice(b",\"at_columns\":[");
            push_int(out, st.col_int(15) + 1);
            out.push(b',');
            push_int(out, st.col_int(16));
            out.push(b']');
            let doc = st.col_text(17);
            if !doc.is_empty() {
                out.extend_from_slice(b",\"doc\":");
                json_string(out, &doc);
            }
            if st.col_int(11) == 1 {
                out.extend_from_slice(b",\"is_definition\":true");
            }
            if st.col_int(12) == 1 {
                out.extend_from_slice(b",\"by_name\":true");
            }
            if st.col_int(13) == 1 {
                out.extend_from_slice(b",\"import\":true");
            }
            let enc = st.col_text(14);
            if !enc.is_empty() {
                out.extend_from_slice(b",\"in_symbol\":");
                json_string(out, &enc);
            }
            out.push(b'}');
        }
        st.reset();
        n
    };
    out.extend_from_slice(b"{\"at\":[");
    let n = run(false, out);
    out.push(b']');
    if n == 0 {
        out.extend_from_slice(b",\"nothing_at_column\":true,\"on_this_line\":[");
        run(true, out);
        out.push(b']');
    }
    if fr.is_stale(rel) {
        out.extend_from_slice(b",\"stale\":true");
    }
    out.push(b'}');
}
