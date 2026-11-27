// Repository selection for `swan serve` (`use_repo`, the `repo` argument and
// `--maps` registry discovery). Carried over from src/serve.goose.

use crate::db::Db;
use crate::fresh::Fresh;
use crate::index::SCHEMA_VERSION;
use crate::pipeline;
use crate::query::meta_value;
use crate::serve::{open_map_snapshot_for, MapSnapshot};
use crate::sys;
use crate::util::{find, hash, json_string, parse_int, push_int, rfind, starts_with};

// The currently selected repository map. Each tool call reopens `map` in a
// fresh read snapshot so external map replacements and refreshes are visible
// on the next call.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Selected {
    pub root: Vec<u8>,
    pub map: Vec<u8>,
}

// Resolves the `--maps` directory if it already exists, and drops a trailing
// slash so joined paths stay canonical.
pub(crate) fn normalize_maps_root(root: &[u8]) -> Vec<u8> {
    let mut r = sys::realpath(root).unwrap_or_else(|| root.to_vec());
    if r.last() == Some(&b'/') {
        r.pop();
    }
    r
}

pub(crate) fn map_covers(root: &[u8], path: &[u8]) -> bool {
    !root.is_empty()
        && (path == root
            || (starts_with(path, root) && path.len() > root.len() && path[root.len()] == b'/'))
}

// Reads one meta entry without ending the server on a damaged or foreign file.
pub(crate) fn meta_try(db: &Db, key: &[u8]) -> Result<Vec<u8>, Vec<u8>> {
    let st = db.prepare(b"SELECT value FROM meta WHERE key = ?1")?;
    st.bind_text(1, key);
    let val = if st.step()? { st.col_text(0) } else { Vec::new() };
    drop(st);
    Ok(val)
}

// Foreign or corrupt registry entries are skipped, while a locked map may be
// the requested repo's current map and must not trigger a rebuild.
fn map_access_error(map_error: &mut Vec<u8>, err: &[u8]) {
    if map_error.is_empty() && (find(err, b"locked") >= 0 || find(err, b"busy") >= 0) {
        map_error.extend_from_slice(b"swan: cannot read map: ");
        map_error.extend_from_slice(err);
    }
}

// One known map's identity, read from its meta; None for a map that cannot be read.
fn map_meta(db_path: &[u8], map_error: &mut Vec<u8>) -> Option<(Vec<u8>, Vec<u8>)> {
    let db = match Db::open_existing(db_path) {
        Ok(db) => db,
        Err(e) => {
            map_access_error(map_error, &e);
            return None;
        }
    };
    let root = match meta_try(&db, b"root") {
        Ok(v) => v,
        Err(e) => {
            drop(db);
            map_access_error(map_error, &e);
            return None;
        }
    };
    let symbols = match meta_try(&db, b"symbols") {
        Ok(v) => v,
        Err(e) => {
            drop(db);
            map_access_error(map_error, &e);
            return None;
        }
    };
    drop(db);
    if root.is_empty() {
        None
    } else {
        Some((root, symbols))
    }
}

fn map_schema_current(db_path: &[u8], map_error: &mut Vec<u8>) -> bool {
    let db = match Db::open_existing(db_path) {
        Ok(db) => db,
        Err(e) => {
            map_access_error(map_error, &e);
            return false;
        }
    };
    let version = match meta_try(&db, b"schema_version") {
        Ok(v) => v,
        Err(e) => {
            drop(db);
            map_access_error(map_error, &e);
            return false;
        }
    };
    drop(db);
    version == SCHEMA_VERSION.to_string().as_bytes()
}

// The map covering `abs`: its own root, or the nearest root above it, among
// the `<maps>/*/swan.db` maps. Returns the map's db path, or empty.
fn find_map(maps: &[u8], abs: &[u8], map_error: &mut Vec<u8>) -> Vec<u8> {
    let mut found = Vec::new();
    let mut best: usize = 0;
    let Some(names) = sys::list_dir(maps) else {
        return found;
    };
    for nm in names {
        if nm.is_empty() {
            continue;
        }
        let dbf = [maps, b"/", &nm, b"/swan.db"].concat();
        if !sys::file_exists(&dbf) {
            continue;
        }
        // Skip maps from an older Swan or damaged/foreign swan.db files.
        if !map_schema_current(&dbf, map_error) {
            continue;
        }
        let Some((root, _)) = map_meta(&dbf, map_error) else {
            continue;
        };
        if root.len() > best && map_covers(&root, abs) {
            best = root.len();
            found = dbf;
        }
    }
    found
}

// The map dir for a repo with no map yet: `<maps>/<basename>`, or
// `<basename>-<short hash of the path>` when that name is another repo's.
fn map_dir_for(maps: &[u8], abs: &[u8], map_error: &mut Vec<u8>) -> Vec<u8> {
    let slash = rfind(abs, b"/");
    let base = if slash >= 0 { &abs[slash as usize + 1..] } else { abs };
    let mut name = base.to_vec();
    let mut tries: i64 = 0;
    while tries < 100 {
        let dir = [maps, b"/", &name].concat();
        let dbf = [&dir[..], b"/swan.db"].concat();
        if !sys::file_exists(&dbf) {
            return dir;
        }
        if let Some((root, _)) = map_meta(&dbf, map_error) {
            if root == abs {
                return dir;
            }
        }
        tries += 1;
        name.clear();
        name.extend_from_slice(base);
        name.push(b'-');
        let h = hash(abs) % 100000;
        name.extend_from_slice(h.to_string().as_bytes());
        if tries > 1 {
            name.push(b'-');
            push_int(&mut name, tries);
        }
    }
    [maps, b"/", &name].concat()
}

// Every readable map under `maps`, for `index_info` when no repo is selected.
pub(crate) fn list_maps(maps: &[u8]) -> Result<Vec<u8>, Vec<u8>> {
    let mut out = b"{\"maps\":[".to_vec();
    let mut map_error = Vec::new();
    let mut n = 0;
    if let Some(names) = sys::list_dir(maps) {
        for nm in names {
            if nm.is_empty() {
                continue;
            }
            let dbf = [maps, b"/", &nm, b"/swan.db"].concat();
            if !sys::file_exists(&dbf) {
                continue;
            }
            let Some((root, syms)) = map_meta(&dbf, &mut map_error) else {
                continue;
            };
            if n > 0 {
                out.push(b',');
            }
            n += 1;
            out.extend_from_slice(b"{\"name\":");
            json_string(&mut out, &nm);
            out.extend_from_slice(b",\"root\":");
            json_string(&mut out, &root);
            out.extend_from_slice(b",\"symbols\":");
            push_int(&mut out, parse_int(&syms).unwrap_or(0));
            out.push(b'}');
        }
    }
    out.extend_from_slice(b"]}");
    if !map_error.is_empty() {
        return Err(map_error);
    }
    Ok(out)
}

// Files changed since the map's SCIP run, or added since.
fn stale_count(db: &Db, fresh: &Fresh) -> i64 {
    let fs = db.prepare_or_die(b"SELECT file FROM files");
    let mut n: i64 = 0;
    while fs.step_checked() {
        let f = fs.col_text(0);
        if fresh.is_stale(&f) {
            n += 1;
        }
    }
    drop(fs);
    let mut added = Vec::new();
    n += fresh.new_files(db, &mut added);
    n
}

// Points `cur` at the map for `path` (its own root, or the nearest mapped root
// above it), building the map first when `build` is true. Returns the open
// snapshot for this request and, when `summary` is true, the `use_repo` JSON.
pub(crate) fn select_open(
    maps: &[u8],
    path: &[u8],
    build: bool,
    summary: bool,
    cur: &mut Option<Selected>,
) -> Result<(MapSnapshot, Vec<u8>), Vec<u8>> {
    if path.is_empty() {
        return Err(b"path is required".to_vec());
    }
    let Some(abs) = sys::realpath(path) else {
        return Err([b"no such path: ", path].concat());
    };
    if !sys::is_dir(&abs) {
        return Err([b"not a directory: ", &abs[..]].concat());
    }
    let mut map_error = Vec::new();
    let mut db_path = find_map(maps, &abs, &mut map_error);
    if !map_error.is_empty() {
        return Err(map_error);
    }
    let mut built = false;
    let mut built_report = Vec::new();
    if db_path.is_empty() {
        if !build {
            let dir = map_dir_for(maps, &abs, &mut map_error);
            if !map_error.is_empty() {
                return Err(map_error);
            }
            return Err([
                b"no map for ",
                &abs[..],
                b": run 'swan map ",
                &abs[..],
                b" ",
                &dir[..],
                b"' or call use_repo without build:false",
            ]
            .concat());
        }
        let dir = map_dir_for(maps, &abs, &mut map_error);
        if !map_error.is_empty() {
            return Err(map_error);
        }
        if !pipeline::map_main(&abs, &dir, &mut built_report, false) {
            return Err(built_report);
        }
        db_path = [&dir[..], b"/swan.db"].concat();
        if !sys::file_exists(&db_path) {
            return Err([
                b"the map ran but left no swan.db in ",
                &dir[..],
                b":\n",
                &built_report[..],
            ]
            .concat());
        }
        built = true;
    }
    let switched = cur.as_ref().map(|s| s.map.as_slice()) != Some(db_path.as_slice());
    let snap = open_map_snapshot_for(&db_path, &abs)?;
    let root = meta_value(&snap.db, b"root");
    *cur = Some(Selected { root, map: db_path.clone() });
    if !summary {
        return Ok((snap, Vec::new()));
    }
    let sel_root = cur.as_ref().map(|s| s.root.as_slice()).unwrap_or(&[]);
    let syms = parse_int(&meta_value(&snap.db, b"symbols")).unwrap_or(0);
    let files = parse_int(&meta_value(&snap.db, b"files")).unwrap_or(0);
    let stale = stale_count(&snap.db, &snap.fresh);
    let skipped = if built { pipeline::map_held_indexers() } else { Vec::new() };
    let mut out = Vec::new();
    out.extend_from_slice(b"{\"root\":");
    json_string(&mut out, sel_root);
    out.extend_from_slice(b",\"map\":");
    json_string(&mut out, &db_path);
    out.extend_from_slice(b",\"symbols\":");
    push_int(&mut out, syms);
    out.extend_from_slice(b",\"files\":");
    push_int(&mut out, files);
    out.extend_from_slice(b",\"built\":");
    out.extend_from_slice(if built { b"true" } else { b"false" });
    out.extend_from_slice(b",\"switched\":");
    out.extend_from_slice(if switched { b"true" } else { b"false" });
    out.extend_from_slice(b",\"stale_file_count\":");
    push_int(&mut out, stale);
    out.extend_from_slice(b",\"skipped\":");
    json_string(&mut out, &skipped);
    out.extend_from_slice(b",\"report\":");
    json_string(&mut out, &built_report);
    out.push(b'}');
    Ok((snap, out))
}

// `use_repo`: selects (and optionally builds) the map for `path`, updates
// `cur`, commits the read snapshot, and returns the JSON answer.
pub fn select(
    maps: &[u8],
    path: &[u8],
    build: bool,
    cur: &mut Option<Selected>,
) -> Result<Vec<u8>, Vec<u8>> {
    let (snap, out) = select_open(maps, path, build, true, cur)?;
    snap.commit();
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicU64, Ordering};

    static NEXT_TMP: AtomicU64 = AtomicU64::new(1);

    struct ScratchDir(PathBuf);

    impl ScratchDir {
        fn new(name: &str) -> Self {
            let n = NEXT_TMP.fetch_add(1, Ordering::Relaxed);
            let p = std::env::temp_dir().join(format!("swan-serve-repo-unit-{}-{name}-{n}", std::process::id()));
            let _ = fs::remove_dir_all(&p);
            fs::create_dir_all(&p).unwrap();
            Self(p.canonicalize().unwrap())
        }

        fn bytes(&self) -> Vec<u8> {
            self.0.to_str().unwrap().as_bytes().to_vec()
        }
    }

    impl Drop for ScratchDir {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn map_covers_matches_exact_and_children_only() {
        assert!(map_covers(b"/a/b", b"/a/b"));
        assert!(map_covers(b"/a/b", b"/a/b/src"));
        assert!(!map_covers(b"/a/b", b"/a/bc"));
        assert!(!map_covers(b"", b"/a/b"));
    }

    #[test]
    fn map_access_error_captures_lock_and_busy_only() {
        let mut err = Vec::new();
        map_access_error(&mut err, b"file is not a database");
        assert!(err.is_empty());
        map_access_error(&mut err, b"database is locked");
        assert_eq!(err, b"swan: cannot read map: database is locked");
        map_access_error(&mut err, b"database is busy");
        assert_eq!(err, b"swan: cannot read map: database is locked");
    }

    #[test]
    fn map_dir_for_avoids_collisions_and_reuses_own_map() {
        let maps = ScratchDir::new("maps");
        let maps_b = maps.bytes();
        let mut err = Vec::new();

        // Unused basename gets <maps>/<basename>.
        let dir1 = map_dir_for(&maps_b, b"/tmp/alpha/app", &mut err);
        assert_eq!(dir1, [&maps_b[..], b"/app"].concat());
        assert!(err.is_empty());

        // Create an old-schema map for /tmp/alpha/app at <maps>/app/swan.db.
        let app_dir = maps.0.join("app");
        fs::create_dir_all(&app_dir).unwrap();
        let db = Db::open(app_dir.join("swan.db").to_str().unwrap().as_bytes()).unwrap();
        db.exec_or_die(b"CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);");
        db.exec_or_die(b"INSERT INTO meta VALUES ('root', '/tmp/alpha/app'), ('schema_version', '1');");
        drop(db);

        // Same repo reuses its own dir (even with an older schema) so it rebuilds in place.
        let same = map_dir_for(&maps_b, b"/tmp/alpha/app", &mut err);
        assert_eq!(same, [&maps_b[..], b"/app"].concat());

        // Another repo with the same basename gets a hash-suffixed dir.
        let other = map_dir_for(&maps_b, b"/tmp/beta/app", &mut err);
        let want = format!("{}/app-{}", maps.0.display(), hash(b"/tmp/beta/app") % 100000);
        assert_eq!(String::from_utf8_lossy(&other), want);
    }

    #[test]
    fn open_map_snapshot_for_rejects_uncovered_repo() {
        let maps = ScratchDir::new("uncovered");
        let db_path = maps.0.join("swan.db");
        let db = Db::open(db_path.to_str().unwrap().as_bytes()).unwrap();
        db.exec_or_die(b"CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);");
        db.exec_or_die(b"CREATE TABLE files (file TEXT PRIMARY KEY, hash TEXT NOT NULL, rows INTEGER NOT NULL, edited_mtime INTEGER);");
        let ver = format!("INSERT INTO meta VALUES ('schema_version', '{}'), ('root', '/tmp/other'), ('source', '/tmp/map');", SCHEMA_VERSION);
        db.exec_or_die(ver.as_bytes());
        drop(db);

        let err = match open_map_snapshot_for(db_path.to_str().unwrap().as_bytes(), b"/tmp/requested") {
            Ok(snap) => {
                snap.commit();
                panic!("expected map coverage mismatch error");
            }
            Err(e) => e,
        };
        let msg = String::from_utf8_lossy(&err);
        assert!(msg.contains("map changed during repository selection"), "{msg}");
    }

    #[test]
    fn select_untrusted_maven_repo_reports_skipped_indexers() {
        let maps = ScratchDir::new("untrusted-maps");
        let work = ScratchDir::new("untrusted-repo");
        let repo = work.0.join("java_demo");
        fs::create_dir_all(repo.join("src")).unwrap();
        fs::write(repo.join("pom.xml"), "<project></project>\n").unwrap();
        fs::write(repo.join("src/Main.java"), "class Main {}\n").unwrap();
        let repo_real = repo.canonicalize().unwrap();

        let mut cur = None;
        let out = select(&maps.bytes(), repo_real.to_str().unwrap().as_bytes(), true, &mut cur)
            .unwrap_or_else(|e| panic!("select failed: {}", String::from_utf8_lossy(&e)));
        let v: serde_json::Value = serde_json::from_slice(&out).unwrap();
        assert_eq!(v["built"], true, "{v}");
        assert_eq!(v["switched"], true, "{v}");
        assert_eq!(v["skipped"], "scip-java (Maven)", "{v}");
        assert!(cur.is_some());
    }
}
