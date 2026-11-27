// Spread-Wings beside Swan: locating its binary, keeping its broad graph up
// to date beside the map, answering server queries (repo_overview,
// what_touches, file_neighbors), and supplementing get_callers with
// distance-1 syntax-only possible_callers.
//
// Carried over from src/wings.goose (wings_report stays with edit_batch).

use std::sync::atomic::{AtomicU64, Ordering};

use crate::db::Db;
use crate::fresh::Fresh;
use crate::json;
use crate::run::swan_home;
use crate::seal::sealed_run;
use crate::sys;
use crate::util::{find, json_string, parse_int, push_int, push_replaced, rfind, split, starts_with, trim, TextSet};

static NEXT_TMP: AtomicU64 = AtomicU64::new(1);

// What Spread-Wings' answers are worth, said with each of them.
const WINGS_EVIDENCE: &[u8] = b"from Spread-Wings, by syntax: links are matched by import, by the type a call names, and by name, not resolved by a compiler (each call site's resolution says which). Broad and quick, for finding your way; find_referencing_symbols and get_callers give the exact sites.";

const POSSIBLE_CALLERS_NOTE: &[u8] = b"From Spread-Wings, by syntax, not compiler-checked: call sites the compiler index does not cover. how says how each was tied to this definition; by_name means any definition with this name could be the one called. Read each site before relying on it.";

// The spread-wings program: $SWAN_SPREAD_WINGS when set, else the one that
// ships with this Swan (<swan home>/bin/spread-wings, built from the wings/
// submodule at the commit Swan pins), else `spread-wings` on PATH. "" when
// none; `why` says what was tried.
pub fn wings_bin(why: &mut Vec<u8>) -> Vec<u8> {
    let v = sys::env(b"SWAN_SPREAD_WINGS");
    if !v.is_empty() {
        if sys::file_exists(&v) {
            return v;
        }
        why.extend_from_slice(&[b"SWAN_SPREAD_WINGS is ", &v[..], b", which is not there"].concat());
        return Vec::new();
    }
    let own = [&swan_home()[..], b"/bin/spread-wings"].concat();
    if sys::file_exists(&own) {
        return own;
    }
    let mut found: Vec<u8> = Vec::new();
    for d in sys::env(b"PATH").split(|&c| c == b':') {
        if found.is_empty() && !d.is_empty() && sys::file_exists(&[d, b"/spread-wings"].concat()) {
            found = [d, b"/spread-wings"].concat();
        }
    }
    if found.is_empty() {
        why.extend_from_slice(&[b"spread-wings is not beside this swan (", &own[..], b") nor on PATH: rebuild or reinstall Swan, or set SWAN_SPREAD_WINGS to its path"].concat());
    }
    found
}

// The time and size of a file as text, by which "this file is as it was
// left" is told. Empty when it is not there.
fn wings_stamp(path: &[u8]) -> Vec<u8> {
    let mut s = Vec::new();
    let m = sys::mtime_ns(path);
    if m >= 0 {
        push_int(&mut s, m);
        s.push(b' ');
        push_int(&mut s, sys::file_size(path));
    }
    s
}

// Appends "<key>":[...] with at most `cap` of the names `r` holds under
// `key`. Returns how many it holds.
fn wings_names(doc: &json::Doc, r: Option<usize>, key: &[u8], cap: i64, out: &mut Vec<u8>) -> i64 {
    let mut n: i64 = 0;
    out.push(b'"');
    out.extend_from_slice(key);
    out.extend_from_slice(b"\":[");
    if let Some(xs) = doc.member(r, key) {
        for x in doc.each(xs) {
            if let Some(s) = doc.as_string(Some(x)) {
                if n < cap {
                    if n > 0 {
                        out.push(b',');
                    }
                    json_string(out, s);
                }
                n += 1;
            }
        }
    }
    out.push(b']');
    n
}

// Reads `spread-wings update`'s answer. True when the graph changed. When
// files changed, `since` receives what goes with the answer that follows:
// the files changed, added and gone, the files that import or call into
// them, and the tests among those and the changed files. Not when the graph
// was built whole: every file is new then, which says nothing.
fn wings_since(answer: &[u8], since: &mut Vec<u8>) -> bool {
    let Some(doc) = json::parse(answer) else {
        return true;
    };
    let r = doc.root();
    match doc.as_bool(doc.member(r, b"built_whole")) {
        Some(false) => {}
        _ => return true,
    }
    let mut lists = Vec::new();
    let c = wings_names(&doc, r, b"changed", 200, &mut lists);
    lists.push(b',');
    let a = wings_names(&doc, r, b"added", 200, &mut lists);
    lists.push(b',');
    let d = wings_names(&doc, r, b"removed", 200, &mut lists);
    if c + a + d <= 0 {
        return false;
    }
    let reach = doc.as_i64(doc.member(r, b"reaches_files")).unwrap_or(0);
    since.extend_from_slice(b"{\"files\":");
    push_int(since, c + a + d);
    since.push(b',');
    since.extend_from_slice(&lists);
    since.extend_from_slice(b",\"reaches_files\":");
    push_int(since, reach);
    since.push(b',');
    wings_names(&doc, r, b"reaches", 200, since);
    since.push(b',');
    wings_names(&doc, r, b"tests", 200, since);
    since.extend_from_slice(b",\"note\":\"files changed on disk since Spread-Wings' graph was last brought up to date; it was brought up to date from them before this answer. reaches: the files that import or call into them; tests: the tests among those and the changed files. Swan's own map is not refreshed by this: its exact tools say stale for a file changed outside Swan, until swan map runs.\"}");
    true
}

// Copies a run that was cut short left behind (wings.db.new*), once they
// are ten minutes older than `now`.
fn wings_sweep(dir: &[u8], now: i64) {
    let Some(names) = sys::list_dir(dir) else {
        return;
    };
    for nm in names {
        if starts_with(&nm, b"wings.db.new") {
            let f = [dir, b"/", &nm].concat();
            let m = sys::mtime_ns(&f);
            if m >= 0 && now - m > 600_000_000_000 {
                sys::delete_file(&f);
            }
        }
    }
}

fn dir_and_base(path: &[u8]) -> (&[u8], &[u8]) {
    let slash = rfind(path, b"/");
    if slash > 0 {
        (&path[..slash as usize], &path[slash as usize + 1..])
    } else if slash == 0 {
        (b"/", &path[1..])
    } else {
        (b".", path)
    }
}

// Spread-Wings' graph of the repo, for answers: wings-rules.db updated from
// files on disk, copied into wings.db with Swan's compiler answers settled on
// top (`compiler --into`) when the rules graph or map moved. Each step runs
// sealed. `since` receives what the update found changed.
fn wings_graph(bin: &[u8], map_db: &[u8], root: &[u8], why: &mut Vec<u8>, since: &mut Vec<u8>) -> Vec<u8> {
    let (raw_dir, base) = dir_and_base(map_db);
    let Some(dir) = sys::realpath(raw_dir) else {
        why.extend_from_slice(&[b"cannot find the map folder of ", map_db].concat());
        return Vec::new();
    };
    let rules = [&dir[..], b"/wings-rules.db"].concat();
    let path = [&dir[..], b"/wings.db"].concat();
    let mark = [&dir[..], b"/wings.checked"].concat();
    let mut left = Vec::new();
    sys::read_file(&mark, &mut left);
    let before = wings_stamp(&rules);
    let others = before.is_empty() || before != left;

    let mut o = Vec::new();
    let mut e = Vec::new();
    let code = sealed_run(&[bin, b"update", root, &rules], root, &dir, false, &[], 300000, &mut o, &mut e);
    if code != 0 {
        // A spread-wings from before `update` takes the word for something
        // else and fails in its own way: its usage tells the two apart.
        let mut uo = Vec::new();
        let mut ue = Vec::new();
        sealed_run(&[bin], root, &dir, false, &[], 10000, &mut uo, &mut ue);
        if find(&uo, b"spread-wings update <repo>") < 0 && find(&ue, b"spread-wings update <repo>") < 0 {
            why.extend_from_slice(&[
                b"this spread-wings (",
                bin,
                b") has no update command: use the one that ships with Swan (unset SWAN_SPREAD_WINGS), or one from 049fe53 or later",
            ].concat());
        } else {
            let said = if !e.is_empty() { &e[..] } else { &o[..] };
            let tail = if said.len() > 300 { &said[said.len() - 300..] } else { said };
            why.extend_from_slice(b"spread-wings update failed (exit ");
            push_int(why, code as i64);
            why.extend_from_slice(b"): ");
            why.extend_from_slice(trim(tail));
        }
        return Vec::new();
    }
    let changed = wings_since(trim(&o), since);
    // update writes its file even when it found nothing: this is the rules
    // graph as this answer leaves it.
    let mut from = wings_stamp(&rules);
    let made_at = sys::mtime_ns(&path);
    if !others && !changed && made_at >= 0 && made_at >= sys::mtime_ns(map_db) {
        sys::write_file(&mark, &from);
        return path;
    }

    wings_sweep(&dir, sys::mtime_ns(&rules));
    let abs_map = [&dir[..], b"/", base].concat();
    let mut made = false;
    let mut tries = 0;
    while tries < 3 && !made {
        tries += 1;
        // A name of its own: two Swans may be making the copy at once.
        let seq = NEXT_TMP.fetch_add(1, Ordering::Relaxed);
        let tag = format!("{}-{}-{}", std::process::id(), sys::time_ns() as u64, seq);
        let tmp = [&dir[..], b"/wings.db.new.", tag.as_bytes()].concat();
        o.clear();
        e.clear();
        sealed_run(&[bin, b"compiler", &rules, &abs_map, b"--into", &tmp], root, &dir, false, &[], 300000, &mut o, &mut e);
        if !sys::file_exists(&tmp) {
            break;
        }
        let now = wings_stamp(&rules);
        if now == from {
            if !sys::rename_file(&tmp, &path) {
                sys::delete_file(&tmp);
                why.extend_from_slice(&[b"cannot write ", &path[..]].concat());
                return Vec::new();
            }
            made = true;
        } else {
            // Another update wrote the rules graph while the copy was being
            // made, and the copy may be of either: again, from what is there now.
            sys::delete_file(&tmp);
            from = now;
        }
    }
    if made {
        sys::write_file(&mark, &from);
        path
    } else {
        rules
    }
}

// One Spread-Wings query about the selected repo, through the server:
// `cmd` is overview, touches or neighbors; a and b its arguments (empty for
// none). Brings the graph beside the map up to date first (wings_graph);
// when files had changed, "files_changed" says which and what they reach.
// The answer is Spread-Wings' own JSON under "result". False with the
// reason in `out` when Spread-Wings is missing or the query fails.
pub fn wings_answer(root: &[u8], map_db: &[u8], cmd: &[u8], a: &[u8], b: &[u8], out: &mut Vec<u8>) -> bool {
    let mut why = Vec::new();
    let bin = wings_bin(&mut why);
    if bin.is_empty() {
        out.extend_from_slice(&why);
        return false;
    }
    let mut since = Vec::new();
    let g = wings_graph(&bin, map_db, root, &mut why, &mut since);
    if g.is_empty() {
        out.extend_from_slice(&why);
        return false;
    }
    let mut argv: Vec<&[u8]> = vec![&bin, cmd, &g];
    if !a.is_empty() {
        argv.push(a);
    }
    if !b.is_empty() {
        argv.push(b);
    }
    let (g_dir, _) = dir_and_base(&g);
    let mut o = Vec::new();
    let mut e = Vec::new();
    let code = sealed_run(&argv, root, g_dir, false, &[], 60000, &mut o, &mut e);
    let answer = trim(&o);
    if !(code == 0 && !answer.is_empty() && (answer[0] == b'{' || answer[0] == b'[')) {
        // Spread-Wings says what was wrong on stderr ("no definition named x").
        let said = trim(if !e.is_empty() { &e[..] } else { &o[..] });
        out.extend_from_slice(if !said.is_empty() { said } else { b"spread-wings gave no answer" });
        return false;
    }
    out.extend_from_slice(b"{\"source\":\"spread-wings\",\"evidence\":");
    json_string(out, WINGS_EVIDENCE);
    if !since.is_empty() {
        out.extend_from_slice(b",\"files_changed\":");
        out.extend_from_slice(&since);
    }
    out.extend_from_slice(b",\"result\":");
    out.extend_from_slice(answer);
    out.push(b'}');
    true
}

fn append_unchecked(out: &mut Vec<u8>, reason: &[u8]) {
    out.pop();
    out.extend_from_slice(b",\"possible_callers\":{\"checked\":false,\"why\":");
    json_string(out, reason);
    out.extend_from_slice(b"}}");
}

// Distance-1 call sites Spread-Wings ties to the target definition(s) that
// the compiler index neither put in the exact callers nor resolved to another
// symbol. Reads wings.db directly after bringing it up to date via
// wings_graph; runs outside any read snapshot on `db`.
// Leaves `out` unchanged when Spread-Wings succeeds with 0 sites; appends
// {"checked":false,"why":"..."} when Spread-Wings is missing or fails.
#[allow(clippy::too_many_arguments)]
pub fn wings_possible_callers(
    db: &Db,
    fr: &Fresh,
    map_db: &[u8],
    root: &[u8],
    ids: &[u8],
    specs: &[u8],
    exact: &[u8],
    out: &mut Vec<u8>,
) {
    if out.last() != Some(&b'}') {
        return;
    }
    if root.is_empty() {
        append_unchecked(out, b"the map does not record its repo root; rebuild it with swan map");
        return;
    }
    if map_db.is_empty() {
        append_unchecked(out, b"no map path is set for this server");
        return;
    }
    let mut why = Vec::new();
    let bin = wings_bin(&mut why);
    if bin.is_empty() {
        append_unchecked(out, &why);
        return;
    }
    let mut since = Vec::new();
    let g = wings_graph(&bin, map_db, root, &mut why, &mut since);
    if g.is_empty() {
        append_unchecked(out, &why);
        return;
    }
    if specs.is_empty() {
        return;
    }
    possible_callers_from_graph(db, fr, &g, ids, specs, exact, out);
}

fn possible_callers_from_graph(
    db: &Db,
    fr: &Fresh,
    graph_db: &[u8],
    ids: &[u8],
    specs: &[u8],
    exact: &[u8],
    out: &mut Vec<u8>,
) {
    let wdb = match Db::open_existing(graph_db) {
        Ok(w) => w,
        Err(werr) => {
            append_unchecked(out, &[b"cannot open Spread-Wings graph: ", &werr[..]].concat());
            return;
        }
    };
    let _ = wdb.exec(b"PRAGMA busy_timeout = 5000;");

    // Match each Swan target definition to its symbol id in wings.db.
    let find_sym = match wdb.prepare(
        b"SELECT g.id FROM symbols g JOIN files f ON f.id = g.file_id
WHERE f.path = ?1 AND g.name = ?2 AND g.row <= ?3 AND g.end_row >= ?3
ORDER BY g.end_row - g.row LIMIT 1
",
    ) {
        Ok(st) => st,
        Err(werr) => {
            drop(wdb);
            append_unchecked(out, &[b"cannot read Spread-Wings graph: ", &werr[..]].concat());
            return;
        }
    };
    let mut gids = Vec::new();
    let mut read_err: Option<Vec<u8>> = None;
    for rec in specs.split(|&c| c == 0x1e) {
        if read_err.is_some() || rec.is_empty() {
            continue;
        }
        let f = split(rec, 0x1f);
        if f.len() >= 3 {
            if let Some(dline) = parse_int(f[2]) {
                find_sym.bind_text(1, f[1]);
                find_sym.bind_text(2, f[0]);
                find_sym.bind_int(3, dline + 1);
                match find_sym.step() {
                    Ok(true) => {
                        if !gids.is_empty() {
                            gids.push(b',');
                        }
                        push_int(&mut gids, find_sym.col_int(0));
                    }
                    Ok(false) => {}
                    Err(e) => read_err = Some(e),
                }
                find_sym.reset();
            }
        }
    }
    drop(find_sym);
    if let Some(werr) = read_err {
        drop(wdb);
        append_unchecked(out, &[b"cannot read Spread-Wings graph: ", &werr[..]].concat());
        return;
    }
    if gids.is_empty() {
        drop(wdb);
        return;
    }

    // Exact distance-1 sites from the snapshot, keyed by "<file>\x1f<1-based line>".
    let mut exact_set: TextSet<&[u8]> = TextSet::default();
    for k in exact.split(|&c| c == b'\n') {
        if !k.is_empty() {
            exact_set.insert(k);
        }
    }

    // Non-compiler edges pointing at the target definition(s), ordered by path
    // and line (strongest resolution first when a line has more than one edge).
    let mut edge_sql = Vec::new();
    push_replaced(
        &mut edge_sql,
        b"SELECT f.path, e.row,
       CASE WHEN COALESCE(cs.container, '') <> '' THEN cs.container || '/' || cs.name
            ELSE COALESCE(cs.name, '') END,
       COALESCE(e.resolution, ''),
       t.name,
       (SELECT COUNT(*) FROM calls c
        WHERE c.file_id = e.file_id AND c.row = e.row AND c.callee = t.name)
FROM call_edges e
JOIN files f ON f.id = e.file_id
JOIN symbols t ON t.id = e.callee
LEFT JOIN symbols cs ON cs.id = e.caller
WHERE e.callee IN (#GIDS#) AND COALESCE(e.resolution, '') != 'compiler'
ORDER BY f.path, e.row,
         CASE e.resolution
             WHEN 'own_type' THEN 1 WHEN 'type_name' THEN 2 WHEN 'same_file' THEN 3
             WHEN 'imported_name' THEN 4 WHEN 'module_alias' THEN 5 WHEN 'imported_file' THEN 6
             WHEN 'decided' THEN 7 WHEN 'by_name' THEN 8 ELSE 9 END
",
        b"#GIDS#",
        &gids,
    );
    let edges = match wdb.prepare(&edge_sql) {
        Ok(st) => st,
        Err(werr) => {
            drop(wdb);
            append_unchecked(out, &[b"cannot read Spread-Wings graph: ", &werr[..]].concat());
            return;
        }
    };

    // Check whether Swan's compiler index already resolved calls of this name
    // on the same file and line to another symbol (in-repo or external).
    let mut other_sql = Vec::new();
    push_replaced(
        &mut other_sql,
        b"SELECT COUNT(*) FROM occurrences o JOIN symbols s ON s.id = o.symbol_id
WHERE o.file = ?1 AND o.start_line = ?2
  AND o.is_def = 0 AND o.by_name = 0 AND o.is_import = 0
  AND s.name = ?3 AND o.symbol_id NOT IN (#IDS#)
",
        b"#IDS#",
        ids,
    );
    let other_st = match db.prepare(&other_sql) {
        Ok(st) => st,
        Err(derr) => {
            drop(edges);
            drop(wdb);
            append_unchecked(out, &[b"cannot check compiler index: ", &derr[..]].concat());
            return;
        }
    };

    let mut sites_json = Vec::new();
    let mut total: i64 = 0;
    let mut listed: i64 = 0;
    let mut prev_path: Vec<u8> = Vec::new();
    let mut prev_row: i64 = -1;
    let mut loop_err: Option<Vec<u8>> = None;
    loop {
        match edges.step() {
            Ok(true) => {}
            Ok(false) => break,
            Err(e) => {
                loop_err = Some(e);
                break;
            }
        }
        let path = edges.col_text(0);
        let row = edges.col_int(1);
        if path == prev_path && row == prev_row {
            continue;
        }
        prev_path = path.clone();
        prev_row = row;

        let mut key = Vec::with_capacity(path.len() + 16);
        key.extend_from_slice(&path);
        key.push(0x1f);
        push_int(&mut key, row);
        if exact_set.contains(key.as_slice()) {
            continue;
        }

        if !fr.is_stale(&path) {
            let tname = edges.col_text(4);
            let raw_ncalls = edges.col_int(5);
            let ncalls = if raw_ncalls > 0 { raw_ncalls } else { 1 };

            other_st.bind_text(1, &path);
            other_st.bind_int(2, row - 1);
            other_st.bind_text(3, &tname);
            let mut other_n: i64 = 0;
            let step_res = other_st.step();
            if let Ok(true) = step_res {
                other_n = other_st.col_int(0);
            }
            other_st.reset();
            if let Err(derr) = step_res {
                loop_err = Some([b"compiler index check failed: ", &derr[..]].concat());
                break;
            }
            if other_n >= ncalls {
                continue;
            }
        }

        total += 1;
        if listed < 50 {
            let in_sym = edges.col_text(2);
            let how = edges.col_text(3);
            if listed > 0 {
                sites_json.push(b',');
            }
            listed += 1;
            sites_json.extend_from_slice(b"{\"relative_path\":");
            json_string(&mut sites_json, &path);
            sites_json.extend_from_slice(b",\"line\":");
            push_int(&mut sites_json, row);
            sites_json.extend_from_slice(b",\"in_symbol\":");
            json_string(&mut sites_json, &in_sym);
            sites_json.extend_from_slice(b",\"how\":");
            json_string(&mut sites_json, &how);
            sites_json.push(b'}');
        }
    }
    drop(other_st);
    drop(edges);
    drop(wdb);
    if let Some(werr) = loop_err {
        append_unchecked(out, &[b"cannot read Spread-Wings graph: ", &werr[..]].concat());
        return;
    }
    if total == 0 {
        return;
    }

    out.pop();
    out.extend_from_slice(b",\"possible_callers\":{\"note\":");
    json_string(out, POSSIBLE_CALLERS_NOTE);
    out.extend_from_slice(b",\"total\":");
    push_int(out, total);
    out.extend_from_slice(b",\"sites\":[");
    out.extend_from_slice(&sites_json);
    out.extend_from_slice(b"]}}");
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::path::PathBuf;

    struct Scratch(PathBuf);

    impl Scratch {
        fn new(tag: &str) -> Self {
            let seq = NEXT_TMP.fetch_add(1, Ordering::Relaxed);
            let p = std::env::temp_dir().join(format!("swan-wings-unit-{}-{tag}-{seq}", std::process::id()));
            let _ = fs::remove_dir_all(&p);
            fs::create_dir_all(&p).unwrap();
            Self(p.canonicalize().unwrap())
        }
    }

    impl Drop for Scratch {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn wings_since_handles_whole_clean_changed_and_invalid() {
        let mut since = Vec::new();
        assert!(wings_since(b"not json", &mut since));
        assert!(since.is_empty());

        assert!(wings_since(br#"{"built_whole":true,"changed":["a.py"]}"#, &mut since));
        assert!(since.is_empty());

        assert!(!wings_since(br#"{"built_whole":false,"changed":[],"added":[],"removed":[]}"#, &mut since));
        assert!(since.is_empty());

        let msg = br#"{"built_whole":false,"changed":["a.py"],"added":["b.py"],"removed":[],"reaches_files":2,"reaches":["c.py","t.py"],"tests":["t.py"]}"#;
        assert!(wings_since(msg, &mut since));
        let v: serde_json::Value = serde_json::from_slice(&since).unwrap();
        assert_eq!(v["files"], 2);
        assert_eq!(v["changed"], serde_json::json!(["a.py"]));
        assert_eq!(v["added"], serde_json::json!(["b.py"]));
        assert_eq!(v["removed"], serde_json::json!([]));
        assert_eq!(v["reaches_files"], 2);
        assert_eq!(v["reaches"], serde_json::json!(["c.py", "t.py"]));
        assert_eq!(v["tests"], serde_json::json!(["t.py"]));
        assert!(v["note"].as_str().unwrap().contains("Spread-Wings"));
    }

    #[test]
    fn wings_sweep_removes_only_old_temp_copies() {
        let s = Scratch::new("sweep");
        let old = s.0.join("wings.db.new.1");
        let keep = s.0.join("wings.db");
        fs::write(&old, b"x").unwrap();
        fs::write(&keep, b"y").unwrap();
        let m = sys::mtime_ns(old.to_str().unwrap().as_bytes());
        // Not older than 10 minutes: kept.
        wings_sweep(s.0.to_str().unwrap().as_bytes(), m + 1000);
        assert!(old.exists());
        assert!(keep.exists());
        // Older than 10 minutes: temp copy removed, wings.db kept.
        wings_sweep(s.0.to_str().unwrap().as_bytes(), m + 700_000_000_000);
        assert!(!old.exists());
        assert!(keep.exists());
    }

    #[test]
    fn possible_callers_from_graph_filters_dedups_handles_stale_and_caps() {
        let s = Scratch::new("possible");
        let repo = s.0.join("repo");
        fs::create_dir_all(repo.join("pkg")).unwrap();
        fs::write(repo.join("pkg/cli.py"), "x\n").unwrap();
        fs::write(repo.join("pkg/stale.py"), "x\n").unwrap();

        let swan_path = s.0.join("swan.db");
        let db = Db::open(swan_path.to_str().unwrap().as_bytes()).unwrap();
        db.exec_or_die(b"CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);");
        db.exec_or_die(b"CREATE TABLE files (file TEXT PRIMARY KEY, hash TEXT NOT NULL, rows INTEGER NOT NULL, edited_mtime INTEGER);");
        db.exec_or_die(b"CREATE TABLE symbols (id INTEGER PRIMARY KEY, name TEXT);");
        db.exec_or_die(b"CREATE TABLE occurrences (symbol_id INTEGER, file TEXT, start_line INTEGER, is_def INTEGER, by_name INTEGER, is_import INTEGER);");
        let now_ns = sys::time_ns();
        // Set scip_time in the future so pkg/cli.py is fresh, and remove pkg/stale.py
        // so pkg/stale.py is stale (missing on disk).
        fs::remove_file(repo.join("pkg/stale.py")).unwrap();
        let meta_sql = format!(
            "INSERT INTO meta VALUES ('root', '{}'), ('scip_time', '{}');",
            repo.display(),
            now_ns + 60_000_000_000i64
        );
        db.exec_or_die(meta_sql.as_bytes());
        db.exec_or_die(b"INSERT INTO symbols VALUES (1, 'ensure'), (2, 'ensure');");
        // Other symbol (id=2) resolved at pkg/cli.py 0-based line 12 (1-based line 13),
        // and also at pkg/stale.py 0-based line 4 (1-based line 5).
        db.exec_or_die(
            b"INSERT INTO occurrences VALUES
              (2, 'pkg/cli.py', 12, 0, 0, 0),
              (2, 'pkg/stale.py', 4, 0, 0, 0);",
        );
        let fr = Fresh::load(&db);

        let wings_path = s.0.join("wings.db");
        let wdb = Db::open(wings_path.to_str().unwrap().as_bytes()).unwrap();
        wdb.exec_or_die(b"CREATE TABLE files (id INTEGER PRIMARY KEY, path TEXT);");
        wdb.exec_or_die(b"CREATE TABLE symbols (id INTEGER PRIMARY KEY, file_id INTEGER, name TEXT, container TEXT, row INTEGER, end_row INTEGER);");
        wdb.exec_or_die(b"CREATE TABLE call_edges (file_id INTEGER, row INTEGER, caller INTEGER, callee INTEGER, resolution TEXT);");
        wdb.exec_or_die(b"CREATE TABLE calls (file_id INTEGER, row INTEGER, callee TEXT);");
        wdb.exec_or_die(
            b"INSERT INTO files VALUES (1, 'pkg/paths.py'), (2, 'pkg/cli.py'), (3, 'pkg/stale.py');
              INSERT INTO symbols VALUES
                (10, 1, 'ensure', 'Paths', 2, 4),
                (20, 2, 'untyped', '', 4, 6),
                (21, 2, 'method', 'Runner', 8, 10),
                (30, 3, 'edited', '', 4, 6);
              INSERT INTO calls VALUES (2, 5, 'ensure'), (2, 13, 'ensure'), (3, 5, 'ensure');
              INSERT INTO call_edges VALUES
                -- Duplicate at pkg/cli.py:5: imported_name must win over by_name.
                (2, 5, 20, 10, 'by_name'),
                (2, 5, 20, 10, 'imported_name'),
                -- Compiler edge must be ignored.
                (2, 7, 20, 10, 'compiler'),
                -- Exact site in exact_set (pkg/cli.py:9) must be skipped.
                (2, 9, 21, 10, 'by_name'),
                -- Fresh file with other_n (1) >= ncalls (1) at pkg/cli.py:13 must be skipped.
                (2, 13, 21, 10, 'by_name'),
                -- Stale file at pkg/stale.py:5 must NOT be skipped by other_n.
                (3, 5, 30, 10, 'by_name');",
        );
        drop(wdb);

        let mut out = br#"{"callers":[]}"#.to_vec();
        possible_callers_from_graph(
            &db,
            &fr,
            wings_path.to_str().unwrap().as_bytes(),
            b"1",
            b"ensure\x1fpkg/paths.py\x1f1\x1e",
            b"pkg/cli.py\x1f9\n",
            &mut out,
        );
        let v: serde_json::Value = serde_json::from_slice(&out).unwrap();
        let pc = &v["possible_callers"];
        assert_eq!(pc["total"], 2, "{v}");
        let sites = pc["sites"].as_array().unwrap();
        assert_eq!(sites.len(), 2, "{v}");
        assert_eq!(sites[0]["relative_path"], "pkg/cli.py");
        assert_eq!(sites[0]["line"], 5);
        assert_eq!(sites[0]["in_symbol"], "untyped");
        assert_eq!(sites[0]["how"], "imported_name");
        assert_eq!(sites[1]["relative_path"], "pkg/stale.py");
        assert_eq!(sites[1]["line"], 5);
        assert_eq!(sites[1]["in_symbol"], "edited");
        assert_eq!(sites[1]["how"], "by_name");

        // Zero matching sites leaves out unchanged.
        let mut unchanged = br#"{"callers":[]}"#.to_vec();
        possible_callers_from_graph(
            &db,
            &fr,
            wings_path.to_str().unwrap().as_bytes(),
            b"1",
            b"missing\x1fpkg/paths.py\x1f1\x1e",
            b"",
            &mut unchanged,
        );
        assert_eq!(unchanged, br#"{"callers":[]}"#);

        // Missing graph db appends checked:false and why.
        let mut missing_out = br#"{"callers":[]}"#.to_vec();
        possible_callers_from_graph(
            &db,
            &fr,
            s.0.join("no-such.db").to_str().unwrap().as_bytes(),
            b"1",
            b"ensure\x1fpkg/paths.py\x1f1\x1e",
            b"",
            &mut missing_out,
        );
        let mv: serde_json::Value = serde_json::from_slice(&missing_out).unwrap();
        assert_eq!(mv["possible_callers"]["checked"], false, "{mv}");
        assert!(mv["possible_callers"]["why"].as_str().unwrap().contains("cannot open Spread-Wings graph"));

        // Over 50 sites caps listed sites at 50 while total counts all.
        let wdb2 = Db::open_existing(wings_path.to_str().unwrap().as_bytes()).unwrap();
        for row in 100..160 {
            let sql = format!("INSERT INTO call_edges VALUES (2, {row}, 21, 10, 'by_name');");
            wdb2.exec_or_die(sql.as_bytes());
        }
        drop(wdb2);
        let mut capped = br#"{"callers":[]}"#.to_vec();
        possible_callers_from_graph(
            &db,
            &fr,
            wings_path.to_str().unwrap().as_bytes(),
            b"1",
            b"ensure\x1fpkg/paths.py\x1f1\x1e",
            b"pkg/cli.py\x1f9\n",
            &mut capped,
        );
        let cv: serde_json::Value = serde_json::from_slice(&capped).unwrap();
        assert_eq!(cv["possible_callers"]["total"], 62, "{cv}");
        let csites = cv["possible_callers"]["sites"].as_array().unwrap();
        assert_eq!(csites.len(), 50, "{cv}");
        assert_eq!(csites[1]["in_symbol"], "Runner/method");

        drop(fr);
        drop(db);
    }
}
