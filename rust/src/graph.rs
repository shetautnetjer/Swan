// The reference graph: who uses a symbol and what it uses. An edge runs from
// the symbol a reference sits inside (its enclosing function, method or
// class) to the symbol referenced. SCIP does not tell a call from any other
// use, so "callers" here means every symbol that references the target:
// calls and type uses, with import rows excluded from caller traversal.
// Modules are where a walk stops, since
// a file is not called; a reference at a file's top level shows its module.
//
// Carried over from src/graph.goose. Its global `targets_matched` is the
// second value targets() returns.

use crate::db::Db;
use crate::fresh::Fresh;
use crate::query::{match_sql, symbol_json};
use crate::scip::package_of;
use crate::util::{ends_with, find, json_key, json_string, push_int, push_replaced, rfind, starts_with};

// JS/TS (.test., .spec., __tests__), Python (test_*.py, *_test.py, conftest),
// and test directories anywhere (Rust's tests/ included).
pub fn is_test_path(p: &[u8]) -> bool {
    let slash = rfind(p, b"/");
    let base = if slash >= 0 { &p[slash as usize + 1..] } else { p };
    starts_with(base, b"test_")
        || ends_with(base, b"_test.py")
        || base == b"conftest.py"
        || find(p, b".test.") >= 0
        || find(p, b".spec.") >= 0
        || find(p, b"__tests__/") >= 0
        || starts_with(p, b"test/")
        || starts_with(p, b"tests/")
        || find(p, b"/test/") >= 0
        || find(p, b"/tests/") >= 0
}

// For questions about one symbol's impact (callers, callees, diagnostics),
// several matches would merge unrelated answers, so the question is sent
// back, as JetBrains does with an ambiguous call hierarchy. Writes the end of
// the JSON object and returns true when it did.
pub fn refuse_ambiguous(matched: i64, out: &mut Vec<u8>) -> bool {
    if matched <= 1 {
        return false;
    }
    out.extend_from_slice(b",\"ambiguous\":true,\"hint\":\"");
    push_int(out, matched);
    out.extend_from_slice(b" symbols match: pass relative_path for the file that defines the one you mean, or its full name path starting with '/'\"}");
    true
}

// The symbols a name path matches, written as "targets", and their ids as a
// SQL list ("3,17"). Empty when nothing matches. The second value is how
// many symbols matched, constructors aside.
pub fn targets(db: &Db, fr: &Fresh, pattern: &[u8], rel: &[u8], out: &mut Vec<u8>) -> (Vec<u8>, i64) {
    let mut ids: Vec<u8> = Vec::new();
    let (sql, bind) = match_sql(pattern, false);
    let st = db.prepare_or_die(sql);
    st.bind_text(1, bind);
    st.bind_text(2, rel);
    st.bind_int(3, 20);
    json_key(out, b"targets");
    out.push(b'[');
    let mut matched = 0;
    while st.step_checked() {
        if !ids.is_empty() {
            ids.push(b',');
            out.push(b',');
        }
        push_int(&mut ids, st.col_int(0));
        symbol_json(fr, &st, out);
        matched += 1;
    }
    out.push(b']');
    drop(st);
    // A class in Java is used through its constructors (`new Square(2)`
    // references Square#<init>(), not Square#), so they count as the class.
    if !ids.is_empty() {
        let mut sql: Vec<u8> = Vec::new();
        push_replaced(
            &mut sql,
            b"SELECT c.id FROM symbols c JOIN symbols t ON t.id IN (#IDS#)
WHERE c.name = '<init>' AND substr(c.scip, 1, length(t.scip)) = t.scip
",
            b"#IDS#",
            &ids,
        );
        let cs = db.prepare_or_die(&sql);
        while cs.step_checked() {
            ids.push(b',');
            push_int(&mut ids, cs.col_int(0));
        }
    }
    (ids, matched)
}

// Who references the target, and who references those, up to `depth` steps:
// the impact radius of changing it. Each result has its distance and whether
// it is test code, and a summary counts the files and lists the test files.
// Returns the SQL id list of the matched target (plus constructors and repo
// base methods it implements), or empty when nothing matched or the match was
// ambiguous.
pub fn get_callers_exact(db: &Db, fr: &Fresh, pattern: &[u8], rel: &[u8], depth: i64, limit: i64, out: &mut Vec<u8>) -> Vec<u8> {
    out.push(b'{');
    let (mut ids, matched) = targets(db, fr, pattern, rel, out);
    if ids.is_empty() {
        out.extend_from_slice(b",\"callers\":[]}");
        return Vec::new();
    }
    if refuse_ambiguous(matched, out) {
        return Vec::new();
    }
    // A method that implements or overrides another is also called through
    // it: `s.area()` on a Shape may run Circle.area. So the callers of the
    // repo methods it implements count as its callers, and the answer names
    // those methods ("through"). JetBrains' call hierarchy does the same;
    // before, Circle.area had no callers at all. Library bases
    // (Object.toString) are left out: every toString() call would follow.
    let mut through: Vec<u8> = Vec::new();
    let mut bases_sql: Vec<u8> = Vec::new();
    push_replaced(
        &mut bases_sql,
        b"WITH RECURSIVE b(id) AS (
    SELECT related_id FROM relationships WHERE symbol_id IN (#IDS#) AND is_impl = 1
    UNION
    SELECT r.related_id FROM b JOIN relationships r ON r.symbol_id = b.id AND r.is_impl = 1)
SELECT s.id, s.name_path FROM b JOIN symbols s ON s.id = b.id
WHERE s.in_repo = 1 AND s.kind IN ('method', 'function', 'getter', 'setter') AND s.id NOT IN (#IDS#)
ORDER BY s.name_path
",
        b"#IDS#",
        &ids,
    );
    let bq = db.prepare_or_die(&bases_sql);
    let mut base_ids: Vec<u8> = Vec::new();
    while bq.step_checked() {
        base_ids.push(b',');
        push_int(&mut base_ids, bq.col_int(0));
        if !through.is_empty() {
            through.push(b',');
        }
        json_string(&mut through, &bq.col_text(1));
    }
    drop(bq);
    ids.extend_from_slice(&base_ids);
    if !through.is_empty() {
        out.extend_from_slice(b",\"through\":[");
        out.extend_from_slice(&through);
        out.push(b']');
    }
    let mut walk: Vec<u8> = Vec::new();
    push_replaced(
        &mut walk,
        b"WITH RECURSIVE up(id, depth) AS (
    SELECT id, 0 FROM symbols WHERE id IN (#IDS#)
    UNION
    SELECT o.enclosing_id, up.depth + 1
    FROM up
    JOIN symbols su ON su.id = up.id AND su.kind != 'module'
    JOIN occurrences o ON o.symbol_id = up.id AND o.is_def = 0 AND o.is_import = 0
    WHERE up.depth < ?1 AND o.enclosing_id IS NOT NULL AND o.enclosing_id != up.id)
, found AS (
    SELECT s.id, s.name_path, s.kind, s.signature, s.def_file, s.def_line, s.def_col,
           s.body_start, s.body_end, min(up.depth) AS distance
    FROM up JOIN symbols s ON s.id = up.id
    WHERE s.id NOT IN (#IDS#)
    GROUP BY s.id)
",
        b"#IDS#",
        &ids,
    );
    // The walk runs once, into a temporary table that the list, the summary
    // and the test files are then read from.
    db.exec_or_die(b"DROP TABLE IF EXISTS temp.callers_found;");
    let mk = db.prepare_or_die(&[b"CREATE TEMP TABLE callers_found AS ", &walk[..], b"SELECT * FROM found"].concat());
    mk.bind_int(1, depth);
    mk.step_done();
    drop(mk);

    let st = db.prepare_or_die(b"SELECT * FROM temp.callers_found ORDER BY distance, def_file, def_line LIMIT ?1");
    st.bind_int(1, limit);
    // The exact lines where each caller uses the target (or, further out, the
    // caller one step nearer). A caller whose kind is "module" is top-level
    // code or an anonymous callback (a test body, an event handler), so its
    // name alone points at line 1; these lines say where the uses really are.
    let mut sites_sql: Vec<u8> = Vec::new();
    push_replaced(
        &mut sites_sql,
        b"SELECT o.file, o.start_line FROM occurrences o
WHERE o.enclosing_id = ?1 AND o.is_def = 0 AND o.is_import = 0
  AND ((?2 = 1 AND o.symbol_id IN (#IDS#))
       OR o.symbol_id IN (SELECT id FROM temp.callers_found WHERE distance = ?2 - 1))
GROUP BY o.file, o.start_line ORDER BY o.file, o.start_line LIMIT 200
",
        b"#IDS#",
        &ids,
    );
    let sites = db.prepare_or_die(&sites_sql);
    out.push(b',');
    json_key(out, b"callers");
    out.push(b'[');
    let mut n = 0;
    while st.step_checked() {
        if n > 0 {
            out.push(b',');
        }
        n += 1;
        symbol_json(fr, &st, out);
        let file = st.col_text(4);
        out.pop();
        out.push(b',');
        json_key(out, b"distance");
        push_int(out, st.col_int(9));
        out.push(b',');
        json_key(out, b"is_test");
        out.extend_from_slice(if is_test_path(&file) { b"true" } else { b"false" });
        out.push(b',');
        json_key(out, b"call_sites");
        out.push(b'[');
        sites.bind_int(1, st.col_int(0));
        sites.bind_int(2, st.col_int(9));
        let mut k = 0;
        while sites.step_checked() {
            let sf = sites.col_text(0);
            if k > 0 {
                out.push(b',');
            }
            k += 1;
            out.push(b'{');
            json_key(out, b"relative_path");
            json_string(out, &sf);
            out.push(b',');
            json_key(out, b"line");
            push_int(out, sites.col_int(1) + 1);
            out.push(b'}');
        }
        sites.reset();
        out.push(b']');
        out.push(b'}');
    }
    out.push(b']');
    drop(sites);
    drop(st);

    // The summary covers every caller, not only the ones listed.
    let sum = db.prepare_or_die(b"SELECT count(*), count(DISTINCT def_file) FROM temp.callers_found");
    let mut total = 0;
    let mut files = 0;
    if sum.step_checked() {
        total = sum.col_int(0);
        files = sum.col_int(1);
    }
    drop(sum);
    let tf = db.prepare_or_die(b"SELECT DISTINCT def_file FROM temp.callers_found ORDER BY def_file");
    out.push(b',');
    json_key(out, b"summary");
    out.push(b'{');
    json_key(out, b"symbols");
    push_int(out, total);
    out.push(b',');
    json_key(out, b"files");
    push_int(out, files);
    out.push(b',');
    json_key(out, b"depth");
    push_int(out, depth);
    out.push(b',');
    json_key(out, b"test_files");
    out.push(b'[');
    let mut t = 0;
    while tf.step_checked() {
        let file = tf.col_text(0);
        if is_test_path(&file) {
            if t > 0 {
                out.push(b',');
            }
            t += 1;
            json_string(out, &file);
        }
    }
    drop(tf);
    out.extend_from_slice(b"]}}");
    ids
}

pub fn get_callers(db: &Db, fr: &Fresh, pattern: &[u8], rel: &[u8], depth: i64, limit: i64, out: &mut Vec<u8>) {
    let _ = get_callers_exact(db, fr, pattern, rel, depth, limit, out);
}

// Target definitions and exact distance-1 call sites from the current read
// snapshot, so Spread-Wings can look up syntax-only callers after the
// snapshot is released.
// `specs`: "<name>\x1f<def_file>\x1f<0-based def_line>\x1e" per definition.
// `exact`: "<file>\x1f<1-based line>\n" per exact distance-1 occurrence.
pub fn callers_target_info(db: &Db, ids: &[u8], specs: &mut Vec<u8>, exact: &mut Vec<u8>) {
    let mut sym_sql: Vec<u8> = Vec::new();
    push_replaced(
        &mut sym_sql,
        b"SELECT name, def_file, def_line FROM symbols
WHERE id IN (#IDS#) AND in_repo = 1 AND name != '<init>'
  AND def_file IS NOT NULL AND def_line IS NOT NULL
",
        b"#IDS#",
        ids,
    );
    let st = db.prepare_or_die(&sym_sql);
    while st.step_checked() {
        let nm = st.col_text(0);
        let df = st.col_text(1);
        specs.extend_from_slice(&nm);
        specs.push(0x1f);
        specs.extend_from_slice(&df);
        specs.push(0x1f);
        push_int(specs, st.col_int(2));
        specs.push(0x1e);
    }
    drop(st);
    let mut occ_sql: Vec<u8> = Vec::new();
    push_replaced(
        &mut occ_sql,
        b"SELECT DISTINCT file, start_line + 1 FROM occurrences
WHERE symbol_id IN (#IDS#) AND is_def = 0 AND is_import = 0
",
        b"#IDS#",
        ids,
    );
    let os = db.prepare_or_die(&occ_sql);
    while os.step_checked() {
        let f = os.col_text(0);
        exact.extend_from_slice(&f);
        exact.push(0x1f);
        push_int(exact, os.col_int(1));
        exact.push(b'\n');
    }
}

// A symbol from outside the repo, in place of symbol_json: its name path,
// kind and package (the SCIP string is column `scip_col`).
fn outside_json(st: &crate::db::Stmt, scip_col: i32, out: &mut Vec<u8>) {
    out.push(b'{');
    json_key(out, b"name_path");
    json_string(out, &st.col_text(1));
    out.push(b',');
    json_key(out, b"kind");
    json_string(out, &st.col_text(2));
    out.push(b',');
    json_key(out, b"package");
    json_string(out, package_of(&st.col_text(scip_col)));
}

// What the target references from inside its own body: the functions it
// calls, the types and constants it uses. Symbols from outside the repo
// carry their package instead of a file.
pub fn get_callees(db: &Db, fr: &Fresh, pattern: &[u8], rel: &[u8], calls_only: bool, limit: i64, out: &mut Vec<u8>) {
    out.push(b'{');
    let (ids, matched) = targets(db, fr, pattern, rel, out);
    if ids.is_empty() {
        out.extend_from_slice(b",\"callees\":[]}");
        return;
    }
    if refuse_ambiguous(matched, out) {
        return;
    }
    let mut sql: Vec<u8> = Vec::new();
    push_replaced(
        &mut sql,
        b"SELECT s.id, s.name_path, s.kind, s.signature, s.def_file, s.def_line, s.def_col,
       s.body_start, s.body_end, s.in_repo, s.scip, count(*)
FROM occurrences o JOIN symbols s ON s.id = o.symbol_id
WHERE o.enclosing_id IN (#IDS#) AND o.is_def = 0
  AND s.kind NOT IN ('parameter', 'type_parameter') AND s.id NOT IN (#IDS#)
  AND (?2 = 0 OR s.kind IN ('function', 'method', 'constructor', 'macro', 'class', 'struct'))
GROUP BY s.id
ORDER BY s.in_repo DESC, s.def_file, s.def_line
LIMIT ?1
",
        b"#IDS#",
        &ids,
    );
    let st = db.prepare_or_die(&sql);
    st.bind_int(1, limit);
    st.bind_int(2, if calls_only { 1 } else { 0 });
    out.push(b',');
    json_key(out, b"callees");
    out.push(b'[');
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
            outside_json(&st, 10, out);
        }
        out.push(b',');
        json_key(out, b"uses");
        push_int(out, st.col_int(11));
        out.push(b'}');
    }
    out.extend_from_slice(b"]}");
}

// The type hierarchy from SCIP relationships: a class implementing an
// interface or extending a class, and a method implementing or overriding
// another, are each an "impl" edge from the subtype to the supertype.
// Walks `depth` steps in one direction and writes each symbol found with its
// distance.
fn hierarchy(db: &Db, fr: &Fresh, ids: &[u8], down: bool, depth: i64, limit: i64, out: &mut Vec<u8>) {
    let mut sql: Vec<u8> = Vec::new();
    let walk: &[u8] = if down {
            b"WITH RECURSIVE walk(id, distance) AS (
    SELECT id, 0 FROM symbols WHERE id IN (#IDS#)
    UNION
    SELECT r.symbol_id, walk.distance + 1 FROM walk
    JOIN relationships r ON r.related_id = walk.id AND r.is_impl = 1
    WHERE walk.distance < ?1)
"
        } else {
            b"WITH RECURSIVE walk(id, distance) AS (
    SELECT id, 0 FROM symbols WHERE id IN (#IDS#)
    UNION
    SELECT r.related_id, walk.distance + 1 FROM walk
    JOIN relationships r ON r.symbol_id = walk.id AND r.is_impl = 1
    WHERE walk.distance < ?1)
"
        };
    push_replaced(&mut sql, walk, b"#IDS#", ids);
    sql.extend_from_slice(
        b"SELECT s.id, s.name_path, s.kind, s.signature, s.def_file, s.def_line, s.def_col,
       s.body_start, s.body_end, min(walk.distance) AS distance, s.in_repo, s.scip
FROM walk JOIN symbols s ON s.id = walk.id
WHERE walk.distance > 0
GROUP BY s.id
ORDER BY distance, s.def_file, s.def_line
LIMIT ?2
",
    );
    let st = db.prepare_or_die(&sql);
    st.bind_int(1, depth);
    st.bind_int(2, limit);
    out.push(b'[');
    let mut n = 0;
    while st.step_checked() {
        if n > 0 {
            out.push(b',');
        }
        n += 1;
        if st.col_int(10) == 1 {
            symbol_json(fr, &st, out);
            out.pop();
        } else {
            outside_json(&st, 11, out);
        }
        out.push(b',');
        json_key(out, b"distance");
        push_int(out, st.col_int(9));
        out.push(b'}');
    }
    out.push(b']');
}

// A type from outside the repo (the standard library's Error, a framework's
// base class) is never a target by name, since only the repo's own symbols
// are. When nothing in the repo matches, the ones outside it that the repo's
// types extend or implement are used instead, listed as library_targets.
fn library_targets(db: &Db, pattern: &[u8], rel: &[u8], ids: Vec<u8>, out: &mut Vec<u8>) -> Vec<u8> {
    if !(ids.is_empty() && rel.is_empty() && !pattern.is_empty()) {
        return ids;
    }
    let asked = if pattern[0] == b'/' { &pattern[1..] } else { pattern };
    // Python's old exception names are aliases of OSError: the indexer
    // resolves `class E(IOError)` to OSError, so that is what to look for.
    let name: &[u8] = if asked == b"IOError" || asked == b"EnvironmentError" || asked == b"WindowsError" { b"OSError" } else { asked };
    let st = db.prepare_or_die(
        b"SELECT DISTINCT s.id, s.scip FROM symbols s
JOIN relationships r ON r.related_id = s.id AND r.is_impl = 1
WHERE s.in_repo = 0 AND (s.name = ?1 OR s.name_path = ?1)
ORDER BY s.id LIMIT 20
",
    );
    st.bind_text(1, name);
    let mut found: Vec<u8> = Vec::new();
    out.push(b',');
    json_key(out, b"library_targets");
    out.push(b'[');
    while st.step_checked() {
        if !found.is_empty() {
            found.push(b',');
            out.push(b',');
        }
        push_int(&mut found, st.col_int(0));
        out.push(b'{');
        json_key(out, b"name_path");
        json_string(out, name);
        out.push(b',');
        json_key(out, b"package");
        json_string(out, package_of(&st.col_text(1)));
        out.push(b'}');
    }
    out.push(b']');
    found
}

// What implements, extends or overrides the target, at any depth up to 5:
// the classes behind an interface, the overrides of a method.
pub fn find_implementations(db: &Db, fr: &Fresh, pattern: &[u8], rel: &[u8], limit: i64, out: &mut Vec<u8>) {
    out.push(b'{');
    let (matched_ids, _) = targets(db, fr, pattern, rel, out);
    let ids = library_targets(db, pattern, rel, matched_ids, out);
    out.push(b',');
    json_key(out, b"implementations");
    if !ids.is_empty() {
        hierarchy(db, fr, &ids, true, 5, limit, out);
    } else {
        out.extend_from_slice(b"[]");
    }
    out.push(b'}');
}

// Both directions: what the target implements or extends (supertypes) and
// what implements or extends it (subtypes).
pub fn get_type_hierarchy(db: &Db, fr: &Fresh, pattern: &[u8], rel: &[u8], depth: i64, limit: i64, out: &mut Vec<u8>) {
    out.push(b'{');
    let (matched_ids, _) = targets(db, fr, pattern, rel, out);
    let ids = library_targets(db, pattern, rel, matched_ids, out);
    out.push(b',');
    json_key(out, b"supertypes");
    if !ids.is_empty() {
        hierarchy(db, fr, &ids, false, depth, limit, out);
    } else {
        out.extend_from_slice(b"[]");
    }
    out.push(b',');
    json_key(out, b"subtypes");
    if !ids.is_empty() {
        hierarchy(db, fr, &ids, true, depth, limit, out);
    } else {
        out.extend_from_slice(b"[]");
    }
    out.push(b'}');
}

// Symbols defined in the repo that nothing references: no use anywhere,
// nothing implementing or overriding them, and, for a method, not itself an
// implementation or override (it is reached through its base). Candidates, not verdicts:
// entry points, framework hooks, and code reached by name at run time
// (dynamic imports, string lookups) show up here too. Properties, parameters
// and modules are left out, and test files unless asked.
pub fn find_unused_symbols(db: &Db, fr: &Fresh, rel: &[u8], include_tests: bool, limit: i64, out: &mut Vec<u8>) {
    let st = db.prepare_or_die(
        b"SELECT s.id, s.name_path, s.kind, s.signature, s.def_file, s.def_line, s.def_col,
       s.body_start, s.body_end
FROM symbols s
WHERE s.in_repo = 1
  AND s.kind NOT IN ('parameter', 'type_parameter', 'module', 'property', 'namespace')
  AND (?1 = '' OR s.def_file = ?1 OR s.def_file LIKE ?1 || '/%')
  AND NOT EXISTS (SELECT 1 FROM occurrences o WHERE o.symbol_id = s.id AND o.is_def = 0)
  -- `new Square(2)` references Square's constructor, not Square: a
  -- class whose constructor is used is used (as references count it).
  AND NOT EXISTS (SELECT 1 FROM symbols c JOIN occurrences o ON o.symbol_id = c.id AND o.is_def = 0
                  WHERE c.name = '<init>' AND substr(c.scip, 1, length(s.scip)) = s.scip AND c.id != s.id)
  AND NOT EXISTS (SELECT 1 FROM relationships r WHERE r.related_id = s.id)
  AND NOT (s.kind IN ('method', 'getter', 'setter')
           AND EXISTS (SELECT 1 FROM relationships r WHERE r.symbol_id = s.id))
ORDER BY s.def_file, s.def_line
",
    );
    st.bind_text(1, rel);
    let mut n = 0;
    let mut total = 0;
    out.extend_from_slice(b"{\"unused\":[");
    while st.step_checked() {
        let file = st.col_text(4);
        if !include_tests && is_test_path(&file) {
            continue;
        }
        total += 1;
        if n >= limit {
            continue;
        }
        if n > 0 {
            out.push(b',');
        }
        n += 1;
        symbol_json(fr, &st, out);
    }
    drop(st);
    out.extend_from_slice(b"],\"total\":");
    push_int(out, total);
    out.push(b'}');
}
