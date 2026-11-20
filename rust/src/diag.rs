// Where errors are, and where an edit could cause them. The compilers'
// own diagnostics (`swan check` runs tsc, cargo check and pyright) are loaded
// into the map and pinned to the innermost symbol they fall in. A question
// about a symbol can then take in its callers too. This is Serena's
// get_diagnostics_for_symbol with check_symbol_references, and the use that
// JetBrains' Problems view makes of call hierarchy: after changing a
// function, the errors that matter are in it and in what calls it.
//
// Carried over from src/diag.goose: the question only (`swan query ... diag`
// and `diagfile`). Loading diagnostics (`swan diagnostics`) is stage 6.

use crate::db::Db;
use crate::fresh::Fresh;
use crate::graph::{refuse_ambiguous, targets};
use crate::query::{meta_value, source_path};
use crate::sys;
use crate::util::{die, json_string, parse_int, push_int, push_replaced};

// Diagnostics for a symbol (and, with depth > 0, the symbols that use it, up
// to depth steps out), or for a file or directory, or a summary of the whole
// map. Each one names the symbol it sits in, and says stale when its file
// changed after the check ran.
pub fn get_diagnostics(db: &Db, fr: &Fresh, pattern: &[u8], rel: &[u8], depth: i64, errors_only: bool, limit: i64, out: &mut Vec<u8>) -> bool {
    let t = meta_value(db, b"diagnostics_time");
    if t.is_empty() {
        out.extend_from_slice(b"no diagnostics loaded: run scripts/diagnose-repo.sh <repo> <map-dir> after indexing");
        return false;
    }
    // The Goose program asserts this parses; a value that does not is a bug
    // in whatever wrote it.
    let checked = match parse_int(&t) {
        Some(v) => v,
        None => die(b"swan: the map's diagnostics_time is not a number"),
    };
    out.push(b'{');
    let mut scope: Vec<u8> = Vec::new();
    if !pattern.is_empty() {
        let (ids, matched) = targets(db, fr, pattern, rel, out);
        out.push(b',');
        if ids.is_empty() {
            out.extend_from_slice(b"\"diagnostics\":[]}");
            return true;
        }
        out.pop(); // targets() is followed by a comma here; refuse_ambiguous adds its own
        if refuse_ambiguous(matched, out) {
            return true;
        }
        out.push(b',');
        push_replaced(
            &mut scope,
            b"WITH RECURSIVE up(id, distance) AS (
    SELECT id, 0 FROM symbols WHERE id IN (#IDS#)
    UNION
    SELECT o.enclosing_id, up.distance + 1
    FROM up
    JOIN symbols su ON su.id = up.id AND su.kind != 'module'
    JOIN occurrences o ON o.symbol_id = up.id AND o.is_def = 0 AND o.is_import = 0
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
",
            b"#IDS#",
            &ids,
        );
    } else {
        scope.extend_from_slice(
            b"SELECT d.file, d.line, d.col, d.severity, d.source, d.code, d.message, s.name_path, -1
FROM diagnostics d LEFT JOIN symbols s ON s.id = d.symbol_id
WHERE (?2 = 0 OR d.severity = 'error')
  AND (?4 = '' OR d.file = ?4 OR d.file LIKE ?4 || '/%')
ORDER BY d.file, d.line
LIMIT ?3
",
        );
    }
    let st = db.prepare_or_die(&scope);
    st.bind_int(1, depth);
    st.bind_int(2, if errors_only { 1 } else { 0 });
    st.bind_int(3, limit);
    if pattern.is_empty() {
        st.bind_text(4, rel);
    }
    out.extend_from_slice(b"\"diagnostics\":[");
    let mut n = 0;
    let mut errors = 0;
    while st.step_checked() {
        if n > 0 {
            out.push(b',');
        }
        n += 1;
        let file = st.col_text(0);
        let file_changed = sys::mtime_ns(&source_path(db, &file)) > checked;
        out.extend_from_slice(b"{\"relative_path\":");
        json_string(out, &file);
        out.extend_from_slice(b",\"line\":");
        push_int(out, st.col_int(1) + 1);
        out.extend_from_slice(b",\"column\":");
        push_int(out, st.col_int(2) + 1);
        let severity = st.col_text(3);
        if severity == b"error" {
            errors += 1;
        }
        out.extend_from_slice(b",\"severity\":");
        json_string(out, &severity);
        out.extend_from_slice(b",\"source\":");
        json_string(out, &st.col_text(4));
        out.extend_from_slice(b",\"code\":");
        json_string(out, &st.col_text(5));
        out.extend_from_slice(b",\"message\":");
        json_string(out, &st.col_text(6));
        let name = st.col_text(7);
        if !name.is_empty() {
            out.extend_from_slice(b",\"in_symbol\":");
            json_string(out, &name);
        }
        let dist = st.col_int(8);
        if dist >= 0 {
            out.extend_from_slice(b",\"distance\":");
            push_int(out, dist);
        }
        if file_changed {
            out.extend_from_slice(b",\"stale\":true");
        }
        out.push(b'}');
    }
    drop(st);
    out.extend_from_slice(b"],\"shown\":");
    push_int(out, n);
    out.extend_from_slice(b",\"errors_shown\":");
    push_int(out, errors);

    // The whole map, for the question "where are the errors at all".
    let sum = db.prepare_or_die(
        b"SELECT count(*), sum(severity = 'error'), count(DISTINCT file) FROM diagnostics
",
    );
    if sum.step_checked() {
        out.extend_from_slice(b",\"map_total\":{\"diagnostics\":");
        push_int(out, sum.col_int(0));
        out.extend_from_slice(b",\"errors\":");
        push_int(out, sum.col_int(1));
        out.extend_from_slice(b",\"files\":");
        push_int(out, sum.col_int(2));
        out.push(b'}');
    }
    drop(sum);
    out.extend_from_slice(b",\"note\":\"from the last tsc / cargo check run; rerun scripts/diagnose-repo.sh after edits\"}");
    true
}
