// Resident live language server for `swan serve`: keeps at most one Live
// across MCP requests, stops it on language/repo switch or server end,
// answers `get_diagnostics` and `find_implementations` with `live: true`
// using the Goose server's JSON and refusals, and warms on `SWAN_WARM`.

use std::collections::HashMap;
use std::time::{Duration, Instant};

use serde_json::{Map, Value};

use crate::db::Db;
use crate::graph;
use crate::live::{self, Diag, Diagnosed, Live, Refusal};
use crate::lsp::uri_path;
use crate::modules::{self, Entry};
use crate::query::{line_bounds, line_of, meta_value};
use crate::serve::{map_dir_of, MapSnapshot};
use crate::serve_repo::Selected;
use crate::sys;
use crate::util::{ends_with, json_string, parse_int, push_int, trim};
use crate::walk::Walk;

pub(crate) struct LiveLocation {
    pub(crate) relative_path: Vec<u8>,
    pub(crate) line: i64,
    pub(crate) column: i64,
    pub(crate) source: Vec<u8>,
}

struct Running {
    lang: String,
    repo: Vec<u8>,
    map_dir: Vec<u8>,
    live: Live,
}

// Holds at most one running language server for `swan serve`. Any switch of
// language or repository stops the previous server before starting another.
pub(crate) struct LiveManager {
    running: Option<Running>,
    needs_warm: bool,
}

impl LiveManager {
    pub(crate) fn new(needs_warm: bool) -> Self {
        Self { running: None, needs_warm }
    }

    pub(crate) fn on_repo_switch(&mut self) {
        self.stop();
        self.needs_warm = true;
    }

    pub(crate) fn will_warm(&self) -> bool {
        self.needs_warm && !sys::env(b"SWAN_WARM").is_empty()
    }

    pub(crate) fn stop(&mut self) {
        if let Some(r) = self.running.take() {
            r.live.stop_within(Duration::from_secs(3));
        }
    }

    fn clear_dead(&mut self) {
        let dead = self.running.as_mut().is_some_and(|r| !r.live.is_alive());
        if dead {
            if let Some(r) = self.running.take() {
                r.live.stop_within(Duration::ZERO);
            }
        }
    }

    fn close_if_open(&mut self, repo: &[u8], map_dir: &[u8], lang: &str, arg: &[u8]) {
        let rel = if arg.len() > repo.len() + 1 && arg.starts_with(repo) && arg[repo.len()] == b'/' {
            &arg[repo.len() + 1..]
        } else {
            arg.strip_prefix(b"./").unwrap_or(arg)
        };
        if let Some(r) = self.running.as_mut() {
            if r.lang == lang && r.repo == repo && r.map_dir == map_dir {
                r.live.close_if_open(rel);
                self.clear_dead();
            }
        }
    }

    pub(crate) fn ensure_live(
        &mut self,
        repo: &[u8],
        map_dir: &[u8],
        lang: &str,
        entry: &Entry,
        deadline: Instant,
    ) -> Result<&mut Live, Refusal> {
        let reuse = match self.running.as_mut() {
            Some(r) if r.lang == lang && r.repo == repo && r.map_dir == map_dir => r.live.is_alive(),
            _ => false,
        };
        if !reuse {
            self.stop();
            let mut walk = Walk::default();
            walk.load(repo, map_dir);
            let live = Live::start(&walk, repo, map_dir, lang, entry, deadline)?;
            self.running = Some(Running {
                lang: lang.to_string(),
                repo: repo.to_vec(),
                map_dir: map_dir.to_vec(),
                live,
            });
        }
        Ok(&mut self.running.as_mut().expect("live started").live)
    }

    // Starts the language server named by SWAN_WARM (<lang> or "auto") and
    // opens its largest mapped file so indexing runs ahead of the first live
    // question. Off by default when SWAN_WARM is unset or empty.
    pub(crate) fn warm_if_needed(&mut self, sel: &Selected) {
        if !self.needs_warm {
            return;
        }
        self.needs_warm = false;
        let want_env = sys::env(b"SWAN_WARM");
        if want_env.is_empty() {
            return;
        }
        let t0 = Instant::now();
        let (want, entry, file) = match pick_warm_target(&sel.map, &want_env) {
            Ok(Some(t)) => t,
            Ok(None) => return,
            Err((lang, why)) => {
                sys::write_stderr(
                    format!("swan serve: could not warm {lang}: {why}\n").as_bytes(),
                );
                return;
            }
        };
        let Some(repo) = sys::realpath(&sel.root).filter(|r| !sel.root.is_empty() && sys::is_dir(r)) else {
            sys::write_stderr(
                format!(
                    "swan serve: could not warm {want}: the map does not record its repo; rebuild it with swan map\n"
                )
                .as_bytes(),
            );
            return;
        };
        let raw_dir = map_dir_of(&sel.map);
        let map_dir = sys::realpath(raw_dir).unwrap_or_else(|| raw_dir.to_vec());
        let deadline = Instant::now() + live::budget();
        match self.ensure_live(&repo, &map_dir, &want, &entry, deadline) {
            Ok(live) => {
                if let Some(f) = file {
                    if let Ok(rel) = live::file_in(&repo, &f) {
                        let _ = live.open(&rel);
                    }
                }
                sys::write_stderr(
                    format!(
                        "swan serve: {want} server started (warm) in {} ms\n",
                        t0.elapsed().as_millis()
                    )
                    .as_bytes(),
                );
            }
            Err(refusal) => {
                sys::write_stderr(
                    format!("swan serve: could not warm {want}: {}\n", refusal.why).as_bytes(),
                );
            }
        }
    }
}

impl Drop for LiveManager {
    fn drop(&mut self) {
        self.stop();
    }
}

// Language name for a file path, matching lang_of_path in src/modules.goose.
pub(crate) fn lang_of_file(p: &[u8]) -> Option<&'static str> {
    if ends_with(p, b".py") || ends_with(p, b".pyi") {
        return Some("python");
    }
    if ends_with(p, b".rs") {
        return Some("rust");
    }
    if ends_with(p, b".kt") || ends_with(p, b".kts") {
        return Some("kotlin");
    }
    if ends_with(p, b".java") {
        return Some("java");
    }
    if ends_with(p, b".goose") {
        return Some("goose");
    }
    if ends_with(p, b".go") {
        return Some("go");
    }
    if ends_with(p, b".c")
        || ends_with(p, b".cc")
        || ends_with(p, b".cpp")
        || ends_with(p, b".cxx")
        || ends_with(p, b".h")
        || ends_with(p, b".hpp")
        || ends_with(p, b".hh")
        || ends_with(p, b".hxx")
        || ends_with(p, b".cu")
        || ends_with(p, b".cuh")
    {
        return Some("cpp");
    }
    if ends_with(p, b".cs") {
        return Some("csharp");
    }
    if ends_with(p, b".lua") {
        return Some("lua");
    }
    if ends_with(p, b".glsl")
        || ends_with(p, b".vert")
        || ends_with(p, b".frag")
        || ends_with(p, b".comp")
        || ends_with(p, b".geom")
        || ends_with(p, b".tesc")
        || ends_with(p, b".tese")
    {
        return Some("glsl");
    }
    if ends_with(p, b".hlsl") || ends_with(p, b".hlsli") || ends_with(p, b".fx") {
        return Some("hlsl");
    }
    if ends_with(p, b".wgsl") {
        return Some("wgsl");
    }
    if ends_with(p, b".ts")
        || ends_with(p, b".tsx")
        || ends_with(p, b".mts")
        || ends_with(p, b".cts")
        || ends_with(p, b".js")
        || ends_with(p, b".jsx")
        || ends_with(p, b".mjs")
        || ends_with(p, b".cjs")
    {
        return Some("typescript");
    }
    None
}

// Resolves a file's language and tools/modules.json entry. Checks language
// membership before touching disk so an unsupported extension like
// src/missing.rb always reports "no live server for <rel>".
fn resolve_language(rel: &[u8]) -> Result<(String, Entry), Vec<u8>> {
    match modules::language_of(rel) {
        Ok(Some(pair)) => Ok(pair),
        Ok(None) => Err([b"no live server for ", rel].concat()),
        Err(why) => {
            if lang_of_file(rel).is_none() {
                Err([b"no live server for ", rel].concat())
            } else {
                Err(why)
            }
        }
    }
}

fn pick_warm_target(
    map_path: &[u8],
    want_env: &[u8],
) -> Result<Option<(String, Entry, Option<Vec<u8>>)>, (String, String)> {
    let db = Db::open_existing(map_path).ok();
    let want_bytes = if want_env == b"auto" {
        let Some(ref db) = db else { return Ok(None) };
        let Ok(st) = db.prepare(
            b"SELECT lang, count(*) AS n FROM (
                SELECT CASE WHEN file LIKE '%.py' THEN 'python' WHEN file LIKE '%.rs' THEN 'rust'
                            WHEN file LIKE '%.kt' THEN 'kotlin'
                            WHEN file LIKE '%.ts' OR file LIKE '%.tsx' OR file LIKE '%.js' THEN 'typescript' END AS lang
                FROM files) WHERE lang IS NOT NULL GROUP BY lang ORDER BY n DESC LIMIT 1",
        ) else {
            return Ok(None);
        };
        let found = if st.step().unwrap_or(false) { st.col_text(0) } else { Vec::new() };
        drop(st);
        if found.is_empty() {
            return Ok(None);
        }
        found
    } else {
        want_env.to_vec()
    };
    let want = String::from_utf8_lossy(&want_bytes).into_owned();
    let entry = modules::map_entry(&want_bytes)
        .map_err(|e| (want.clone(), String::from_utf8_lossy(&e).into_owned()))?;
    let mut file = None;
    if let Some(ref db) = db {
        if let Ok(st) = db.prepare(b"SELECT file FROM files ORDER BY rows DESC") {
            while st.step().unwrap_or(false) {
                let candidate = st.col_text(0);
                if entry.holds(&candidate) {
                    file = Some(candidate);
                    break;
                }
            }
        }
    }
    drop(db);
    Ok(Some((want, entry, file)))
}

// Formats live diagnostics in the Goose server's JSON shape.
pub(crate) fn format_diagnostics_json(rel: &[u8], items: &[Diag]) -> Vec<u8> {
    let mut out = Vec::new();
    out.extend_from_slice(b"{\"ok\":true,\"file\":");
    json_string(&mut out, rel);
    out.extend_from_slice(b",\"settled\":true,\"diagnostics\":[");
    for (i, d) in items.iter().enumerate() {
        if i > 0 {
            out.push(b',');
        }
        out.extend_from_slice(b"{\"line\":");
        push_int(&mut out, d.line as i64);
        out.extend_from_slice(b",\"col\":");
        push_int(&mut out, d.col as i64);
        out.extend_from_slice(b",\"severity\":");
        json_string(&mut out, d.severity.as_bytes());
        out.extend_from_slice(b",\"code\":");
        json_string(&mut out, d.code.as_bytes());
        out.extend_from_slice(b",\"message\":");
        json_string(&mut out, d.message.as_bytes());
        out.push(b'}');
    }
    out.extend_from_slice(b"]}");
    out
}

fn extract_location(item: &Value) -> Option<(&str, i64, i64)> {
    if let (Some(uri), Some(start)) = (
        item.get("uri").and_then(Value::as_str),
        item.get("range").and_then(|r| r.get("start")),
    ) {
        let line = start.get("line").and_then(Value::as_i64)?;
        let col = start.get("character").and_then(Value::as_i64)?;
        return Some((uri, line + 1, col + 1));
    }
    let uri = item.get("targetUri").and_then(Value::as_str)?;
    let range = item
        .get("targetSelectionRange")
        .or_else(|| item.get("targetRange"))?;
    let start = range.get("start")?;
    let line = start.get("line").and_then(Value::as_i64)?;
    let col = start.get("character").and_then(Value::as_i64)?;
    Some((uri, line + 1, col + 1))
}

// Parses an LSP textDocument/implementation result (null, Location, Location[]
// or LocationLink[]) into repo-relative 1-based locations with trimmed source lines.
pub(crate) fn parse_implementations(result: &Value, repo: &[u8]) -> Vec<LiveLocation> {
    let raw: Vec<&Value> = match result {
        Value::Null => Vec::new(),
        Value::Object(_) => vec![result],
        Value::Array(items) => items.iter().collect(),
        _ => Vec::new(),
    };
    let mut cache: HashMap<Vec<u8>, (Vec<u8>, Vec<usize>)> = HashMap::new();
    let mut out = Vec::new();
    for item in raw {
        let Some((uri, line, column)) = extract_location(item) else {
            continue;
        };
        let decoded = uri_path(uri);
        if !(decoded.len() > repo.len() + 1
            && decoded.starts_with(repo)
            && decoded[repo.len()] == b'/')
        {
            continue;
        }
        let rel = decoded[repo.len() + 1..].to_vec();
        let entry = cache.entry(rel.clone()).or_insert_with(|| {
            let mut text = Vec::new();
            let mut starts = Vec::new();
            if sys::read_file(&[repo, b"/", &rel].concat(), &mut text) {
                line_bounds(&text, &mut starts);
            }
            (text, starts)
        });
        let source = if !entry.1.is_empty() {
            trim(line_of(&entry.0, &entry.1, line - 1)).to_vec()
        } else {
            Vec::new()
        };
        out.push(LiveLocation { relative_path: rel, line, column, source });
    }
    out
}

fn file_in_or_close(
    manager: &mut LiveManager,
    repo: &[u8],
    map_dir: &[u8],
    lang: &str,
    rel_arg: &[u8],
) -> Result<Vec<u8>, Vec<u8>> {
    match live::file_in(repo, rel_arg) {
        Ok(rel) => Ok(rel),
        Err(why) => {
            // Tell any running server to close a previously opened file that
            // was removed on disk, without starting a new server.
            let full = if rel_arg.starts_with(b"/") {
                rel_arg.to_vec()
            } else {
                [repo, b"/", rel_arg].concat()
            };
            if !sys::file_exists(&full) {
                manager.close_if_open(repo, map_dir, lang, rel_arg);
            }
            Err(why.into_bytes())
        }
    }
}

// Answers `get_diagnostics` with `live: true`, matching live_diagnostics_why in
// src/live.goose and the Goose server's refusals.
pub(crate) fn call_live_diagnostics(
    manager: &mut LiveManager,
    root: &[u8],
    map_path: &[u8],
    args: &Value,
) -> Result<Vec<u8>, Vec<u8>> {
    let rel_arg = args
        .get("relative_path")
        .and_then(Value::as_str)
        .unwrap_or("")
        .as_bytes();
    if rel_arg.is_empty() {
        return Err(b"live diagnostics need relative_path (one file)".to_vec());
    }
    if root.is_empty() {
        return Err(b"the map does not record its repo; rebuild it with swan map".to_vec());
    }
    let (lang, entry) = resolve_language(rel_arg)?;
    let Some(repo) = sys::realpath(root).filter(|r| sys::is_dir(r)) else {
        return Err(b"the map does not record its repo; rebuild it with swan map".to_vec());
    };
    let raw_dir = map_dir_of(map_path);
    let map_dir = sys::realpath(raw_dir).unwrap_or_else(|| raw_dir.to_vec());
    let rel = file_in_or_close(manager, &repo, &map_dir, &lang, rel_arg)?;
    let deadline = Instant::now() + live::budget();
    let live = manager
        .ensure_live(&repo, &map_dir, &lang, &entry, deadline)
        .map_err(|r| r.why.into_bytes())?;
    live.begin(deadline);
    match live.diagnostics(&rel) {
        Ok(Diagnosed::Settled(items)) => Ok(format_diagnostics_json(&rel, &items)),
        Ok(Diagnosed::Unsettled(why)) => {
            manager.clear_dead();
            Err(why.into_bytes())
        }
        Err(why) => {
            manager.clear_dead();
            Err(why.into_bytes())
        }
    }
}

// Answers `find_implementations` with `live: true`, matching
// live_implementations in src/live.goose. Commits `snap` before any LSP I/O so
// SQLite is never held open across language-server calls.
pub(crate) fn call_live_implementations(
    manager: &mut LiveManager,
    snap: MapSnapshot,
    map_path: &[u8],
    args: &Value,
) -> Result<Vec<u8>, Vec<u8>> {
    let pattern = args
        .get("name_path")
        .and_then(Value::as_str)
        .unwrap_or("")
        .as_bytes();
    if pattern.is_empty() {
        snap.commit();
        return Err(b"name_path is required".to_vec());
    }
    let rel_filter = args
        .get("relative_path")
        .and_then(Value::as_str)
        .unwrap_or("")
        .as_bytes();
    let mut head = b"{".to_vec();
    let (ids, matched) = graph::targets(&snap.db, &snap.fresh, pattern, rel_filter, &mut head);
    if graph::refuse_ambiguous(matched, &mut head) {
        snap.commit();
        return Ok(head);
    }
    if ids.is_empty() {
        head.extend_from_slice(b",\"implementations\":[]}");
        snap.commit();
        return Ok(head);
    }
    let first_id = match ids.iter().position(|&b| b == b',') {
        Some(pos) => &ids[..pos],
        None => &ids[..],
    };
    let first_num = parse_int(first_id).unwrap_or(0);
    let st = snap.db.prepare_or_die(
        b"SELECT file, start_line, start_col FROM occurrences WHERE symbol_id = ?1 AND is_def = 1 ORDER BY start_line LIMIT 1",
    );
    st.bind_int(1, first_num);
    let def = if st.step_checked() {
        Some((st.col_text(0), st.col_int(1) + 1, st.col_int(2) + 1))
    } else {
        None
    };
    drop(st);
    let root = meta_value(&snap.db, b"root");
    snap.commit();

    let Some((file, line, col)) = def.filter(|(f, _, _)| !f.is_empty()) else {
        return Err(b"no definition of that symbol in the map".to_vec());
    };
    if root.is_empty() {
        return Err(b"the map does not record its repo; rebuild it with swan map".to_vec());
    }
    let (lang, entry) = resolve_language(&file)?;
    let Some(repo) = sys::realpath(&root).filter(|r| sys::is_dir(r)) else {
        return Err(b"the map does not record its repo; rebuild it with swan map".to_vec());
    };
    let raw_dir = map_dir_of(map_path);
    let map_dir = sys::realpath(raw_dir).unwrap_or_else(|| raw_dir.to_vec());
    let rel = file_in_or_close(manager, &repo, &map_dir, &lang, &file)?;
    let deadline = Instant::now() + live::budget();
    let live = manager
        .ensure_live(&repo, &map_dir, &lang, &entry, deadline)
        .map_err(|r| r.why.into_bytes())?;
    live.begin(deadline);
    let place = Some((line.max(1) as u32, col.max(1) as u32));
    let result = match live.request(&rel, "textDocument/implementation", place, Map::new()) {
        Ok(v) => v,
        Err(why) => {
            manager.clear_dead();
            return Err(why.into_bytes());
        }
    };
    let locs = parse_implementations(&result, &repo);
    head.extend_from_slice(b",\"live\":true,\"implementations\":[");
    for (i, loc) in locs.iter().enumerate() {
        if i > 0 {
            head.push(b',');
        }
        head.extend_from_slice(b"{\"relative_path\":");
        json_string(&mut head, &loc.relative_path);
        head.extend_from_slice(b",\"line\":");
        push_int(&mut head, loc.line);
        head.extend_from_slice(b",\"column\":");
        push_int(&mut head, loc.column);
        head.extend_from_slice(b",\"source\":");
        json_string(&mut head, &loc.source);
        head.push(b'}');
    }
    head.extend_from_slice(b"]}");
    Ok(head)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::path::{Path, PathBuf};
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::time::{Duration, Instant};

    use serde_json::json;

    use crate::db::Db;
    use crate::index::SCHEMA_VERSION;
    use crate::modules::Entry;
    use crate::serve::open_map_snapshot;

    static NEXT_TMP: AtomicU64 = AtomicU64::new(1);

    struct ScratchDir(PathBuf);

    impl ScratchDir {
        fn new(name: &str) -> Self {
            let n = NEXT_TMP.fetch_add(1, Ordering::Relaxed);
            let p = std::env::temp_dir()
                .join(format!("swan-serve-live-unit-{}-{name}-{n}", std::process::id()));
            let _ = fs::remove_dir_all(&p);
            fs::create_dir_all(&p).unwrap();
            Self(p.canonicalize().unwrap())
        }

        fn path(&self) -> &Path {
            &self.0
        }
    }

    impl Drop for ScratchDir {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    fn python() -> String {
        let path = std::env::var("PATH").unwrap_or_default();
        path.split(':')
            .map(|d| format!("{d}/python3"))
            .find(|p| Path::new(p).exists())
            .expect("python3 on PATH")
    }

    fn running(pid: i32) -> bool {
        fs::read_to_string(format!("/proc/{pid}/stat"))
            .is_ok_and(|st| !st.rsplit(')').next().unwrap_or("").trim_start().starts_with('Z'))
    }

    fn wait_dead(pid: i32) -> bool {
        let until = Instant::now() + Duration::from_secs(3);
        while running(pid) && Instant::now() < until {
            std::thread::sleep(Duration::from_millis(20));
        }
        !running(pid)
    }

    fn make_test_db(dir: &Path, root: &Path) -> PathBuf {
        let db_path = dir.join("swan.db");
        let db = Db::open(db_path.to_str().unwrap().as_bytes()).unwrap();
        db.exec_or_die(
            b"CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);
              CREATE TABLE files (file TEXT PRIMARY KEY, hash TEXT NOT NULL, rows INTEGER NOT NULL, edited_mtime INTEGER);
              CREATE TABLE symbols (id INTEGER PRIMARY KEY, scip TEXT UNIQUE, name TEXT, name_path TEXT, kind TEXT, signature TEXT, doc TEXT, def_file TEXT, def_line INTEGER, def_col INTEGER, body_start INTEGER, body_end INTEGER, in_repo INTEGER, language TEXT);
              CREATE TABLE occurrences (symbol_id INTEGER, file TEXT, start_line INTEGER, start_col INTEGER, end_line INTEGER, end_col INTEGER, is_def INTEGER, enclosing_id INTEGER, by_name INTEGER, is_import INTEGER);",
        );
        let sql = format!(
            "INSERT INTO meta VALUES ('schema_version', '{}'), ('root', '{}'), ('source', '{}'), ('scip_time', '0');",
            SCHEMA_VERSION,
            root.to_str().unwrap().replace('\'', "''"),
            dir.to_str().unwrap().replace('\'', "''"),
        );
        db.exec_or_die(sql.as_bytes());
        db.exec_or_die(
            b"INSERT INTO symbols VALUES (1, 's1', 'dup', 'A/dup', 'function', 'fn dup()', '', 'a.fake', 0, 0, 0, 0, 1, 'fake');
              INSERT INTO symbols VALUES (2, 's2', 'dup', 'B/dup', 'function', 'fn dup()', '', 'b.fake', 0, 0, 0, 0, 1, 'fake');
              INSERT INTO symbols VALUES (3, 's3', 'NoDef', 'NoDef', 'struct', 'struct NoDef', '', 'a.fake', 0, 0, 0, 0, 1, 'fake');",
        );
        drop(db);
        db_path
    }

    #[test]
    fn lang_of_file_matches_goose_extensions() {
        let cases = [
            ("a.py", Some("python")),
            ("a.pyi", Some("python")),
            ("src/lib.rs", Some("rust")),
            ("Main.kt", Some("kotlin")),
            ("build.gradle.kts", Some("kotlin")),
            ("App.java", Some("java")),
            ("main.goose", Some("goose")),
            ("main.go", Some("go")),
            ("a.c", Some("cpp")),
            ("a.cc", Some("cpp")),
            ("a.cpp", Some("cpp")),
            ("a.cxx", Some("cpp")),
            ("a.h", Some("cpp")),
            ("a.hpp", Some("cpp")),
            ("a.hh", Some("cpp")),
            ("a.hxx", Some("cpp")),
            ("a.cu", Some("cpp")),
            ("a.cuh", Some("cpp")),
            ("Program.cs", Some("csharp")),
            ("game.lua", Some("lua")),
            ("a.glsl", Some("glsl")),
            ("a.vert", Some("glsl")),
            ("a.frag", Some("glsl")),
            ("a.comp", Some("glsl")),
            ("a.geom", Some("glsl")),
            ("a.tesc", Some("glsl")),
            ("a.tese", Some("glsl")),
            ("a.hlsl", Some("hlsl")),
            ("a.hlsli", Some("hlsl")),
            ("a.fx", Some("hlsl")),
            ("a.wgsl", Some("wgsl")),
            ("a.ts", Some("typescript")),
            ("a.tsx", Some("typescript")),
            ("a.mts", Some("typescript")),
            ("a.cts", Some("typescript")),
            ("a.js", Some("typescript")),
            ("a.jsx", Some("typescript")),
            ("a.mjs", Some("typescript")),
            ("a.cjs", Some("typescript")),
            ("src/missing.rb", None),
            ("README.md", None),
        ];
        for (path, want) in cases {
            assert_eq!(lang_of_file(path.as_bytes()), want, "path={path}");
        }
    }

    #[test]
    fn format_diagnostics_json_matches_goose_shape() {
        let items = vec![
            Diag {
                line: 56,
                col: 9,
                severity: "error",
                code: "E0061".to_string(),
                message: "wrong number of arguments".to_string(),
            },
            Diag {
                line: 10,
                col: 1,
                severity: "warning",
                code: "2322".to_string(),
                message: "unused".to_string(),
            },
        ];
        let out = format_diagnostics_json(b"src/lib.rs", &items);
        let v: Value = serde_json::from_slice(&out).expect("valid JSON");
        assert_eq!(v["ok"], true, "{v}");
        assert_eq!(v["file"], "src/lib.rs", "{v}");
        assert_eq!(v["settled"], true, "{v}");
        let ds = v["diagnostics"].as_array().expect("diagnostics array");
        assert_eq!(ds.len(), 2, "{v}");
        assert_eq!(ds[0]["line"], 56);
        assert_eq!(ds[0]["col"], 9);
        assert_eq!(ds[0]["severity"], "error");
        assert_eq!(ds[0]["code"], "E0061");
        assert_eq!(ds[0]["message"], "wrong number of arguments");
        assert_eq!(ds[1]["code"], "2322");
    }

    #[test]
    fn parse_implementations_handles_all_lsp_shapes_and_reads_source() {
        let tmp = ScratchDir::new("impls-parse");
        let repo = tmp.path();
        fs::create_dir_all(repo.join("src")).unwrap();
        fs::write(repo.join("src/a b.rs"), "line one\n    impl Area for Tile {\n").unwrap();
        let repo_b = repo.to_str().unwrap().as_bytes();
        let inside_uri = format!("file://{}/src/a%20b.rs", repo.to_str().unwrap());
        let outside_uri = "file:///other/repo/src/x.rs";

        // null -> empty
        assert!(parse_implementations(&Value::Null, repo_b).is_empty());

        // Single Location object
        let scalar = json!({
            "uri": inside_uri,
            "range": {"start": {"line": 1, "character": 4}, "end": {"line": 1, "character": 8}}
        });
        let got = parse_implementations(&scalar, repo_b);
        assert_eq!(got.len(), 1);
        assert_eq!(got[0].relative_path, b"src/a b.rs");
        assert_eq!(got[0].line, 2);
        assert_eq!(got[0].column, 5);
        assert_eq!(got[0].source, b"impl Area for Tile {");

        // Array mixing inside + outside URIs
        let arr = json!([
            {"uri": outside_uri, "range": {"start": {"line": 0, "character": 0}, "end": {"line": 0, "character": 1}}},
            {"uri": inside_uri, "range": {"start": {"line": 0, "character": 0}, "end": {"line": 0, "character": 4}}}
        ]);
        let got_arr = parse_implementations(&arr, repo_b);
        assert_eq!(got_arr.len(), 1);
        assert_eq!(got_arr[0].line, 1);
        assert_eq!(got_arr[0].column, 1);
        assert_eq!(got_arr[0].source, b"line one");

        // LocationLink array
        let link = json!([{
            "targetUri": inside_uri,
            "targetRange": {"start": {"line": 0, "character": 0}, "end": {"line": 1, "character": 1}},
            "targetSelectionRange": {"start": {"line": 1, "character": 0}, "end": {"line": 1, "character": 4}}
        }]);
        let got_link = parse_implementations(&link, repo_b);
        assert_eq!(got_link.len(), 1);
        assert_eq!(got_link[0].line, 2);
        assert_eq!(got_link[0].column, 1);
        assert_eq!(got_link[0].source, b"impl Area for Tile {");
    }

    #[test]
    fn refusals_without_server_match_goose_wording() {
        let tmp = ScratchDir::new("refusals");
        let repo = tmp.path().join("repo");
        let map = tmp.path().join("map");
        fs::create_dir_all(&repo).unwrap();
        fs::create_dir_all(&map).unwrap();
        let db = make_test_db(&map, &repo);
        let root_b = repo.to_str().unwrap().as_bytes();
        let db_b = db.to_str().unwrap().as_bytes();
        let mut mgr = LiveManager::new(false);

        // Missing relative_path on live get_diagnostics
        let e1 = call_live_diagnostics(&mut mgr, root_b, db_b, &json!({"live": true})).unwrap_err();
        assert_eq!(String::from_utf8_lossy(&e1), "live diagnostics need relative_path (one file)");

        // Missing root
        let e2 = call_live_diagnostics(&mut mgr, b"", db_b, &json!({"relative_path": "a.rs", "live": true})).unwrap_err();
        assert_eq!(String::from_utf8_lossy(&e2), "the map does not record its repo; rebuild it with swan map");

        // Unknown extension on nonexistent file (src/missing.rb) must say "no live server"
        let e3 = call_live_diagnostics(&mut mgr, root_b, db_b, &json!({"relative_path": "src/missing.rb", "live": true})).unwrap_err();
        assert_eq!(String::from_utf8_lossy(&e3), "no live server for src/missing.rb");

        // find_implementations empty name_path
        let snap = open_map_snapshot(db_b).unwrap();
        let e4 = call_live_implementations(&mut mgr, snap, db_b, &json!({"live": true})).unwrap_err();
        assert_eq!(String::from_utf8_lossy(&e4), "name_path is required");

        // find_implementations ambiguous symbol -> Ok with ambiguous:true, no server started
        let snap = open_map_snapshot(db_b).unwrap();
        let amb = call_live_implementations(&mut mgr, snap, db_b, &json!({"name_path": "dup", "live": true})).unwrap();
        let amb_v: Value = serde_json::from_slice(&amb).unwrap();
        assert_eq!(amb_v["ambiguous"], true, "{amb_v}");

        // find_implementations unknown symbol -> Ok with empty implementations, no live:true
        let snap = open_map_snapshot(db_b).unwrap();
        let none = call_live_implementations(&mut mgr, snap, db_b, &json!({"name_path": "Ghost", "live": true})).unwrap();
        let none_v: Value = serde_json::from_slice(&none).unwrap();
        assert_eq!(none_v["implementations"], json!([]), "{none_v}");
        assert!(none_v.get("live").is_none(), "{none_v}");

        // find_implementations target with no definition occurrence
        let snap = open_map_snapshot(db_b).unwrap();
        let nodef = call_live_implementations(&mut mgr, snap, db_b, &json!({"name_path": "NoDef", "live": true})).unwrap_err();
        assert_eq!(String::from_utf8_lossy(&nodef), "no definition of that symbol in the map");
    }

    #[test]
    fn live_manager_keeps_one_server_at_a_time_across_switches() {
        let tmp = ScratchDir::new("switch");
        let repo = tmp.path().join("repo");
        let out = tmp.path().join("out");
        fs::create_dir_all(&repo).unwrap();
        fs::create_dir_all(&out).unwrap();
        fs::write(repo.join("a.fake"), "fine\n").unwrap();
        fs::write(repo.join("a.qt"), "fine\n").unwrap();
        let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_lsp.py");
        let pids_file = out.join("pids");
        let entry1: Entry = serde_json::from_value(json!({
            "match": [".fake"],
            "lsp": [{"cmd": [python(), "-I", fake, "publish"], "language_id": "fake", "env": [format!("FAKE_PIDS={}", pids_file.display())]}]
        })).unwrap();
        let entry2: Entry = serde_json::from_value(json!({
            "match": [".qt"],
            "lsp": [{"cmd": [python(), "-I", fake, "quiet"], "language_id": "quiet", "quiet_ms": 500, "env": [format!("FAKE_PIDS={}", pids_file.display())]}]
        })).unwrap();

        let repo_b = repo.to_str().unwrap().as_bytes();
        let out_b = out.to_str().unwrap().as_bytes();
        let mut mgr = LiveManager::new(false);
        let deadline = Instant::now() + Duration::from_secs(20);

        // Start lang1; second call for same lang1+repo reuses same pid.
        let _ = mgr.ensure_live(repo_b, out_b, "fake", &entry1, deadline).expect("start lang1");
        let _ = mgr.ensure_live(repo_b, out_b, "fake", &entry1, deadline).expect("reuse lang1");
        let pids1: Vec<i32> = fs::read_to_string(&pids_file).unwrap().lines().map(|l| l.parse().unwrap()).collect();
        assert_eq!(pids1.len(), 1, "expected 1 server start, got {pids1:?}");
        assert!(running(pids1[0]), "first server should be running");

        // Switch to lang2: lang1 is stopped before lang2 starts.
        let _ = mgr.ensure_live(repo_b, out_b, "quiet", &entry2, deadline).expect("start lang2");
        assert!(wait_dead(pids1[0]), "lang1 server {} was not stopped on switch", pids1[0]);
        let pids2: Vec<i32> = fs::read_to_string(&pids_file).unwrap().lines().map(|l| l.parse().unwrap()).collect();
        assert_eq!(pids2.len(), 2, "expected 2 starts total, got {pids2:?}");
        assert!(running(pids2[1]), "second server should be running");

        // Repo switch stops lang2.
        mgr.on_repo_switch();
        assert!(wait_dead(pids2[1]), "lang2 server {} was not stopped on repo switch", pids2[1]);
    }
}
