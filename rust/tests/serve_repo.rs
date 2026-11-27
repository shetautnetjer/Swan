// End-to-end checks of `swan serve --maps <dir>`, bare `swan serve`,
// `use_repo`, and the per-call `repo` argument over stdin and stdout,
// porting all 27 checks from tests/check/maps_suite.goose.

mod common;

use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

use serde_json::{json, Value};

static NEXT_TMP: AtomicU64 = AtomicU64::new(1);

fn repo_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("rust/ sits under repository root")
        .canonicalize()
        .expect("canonical repository root")
}

fn fixture_path(rel: &str) -> PathBuf {
    repo_root()
        .join(rel)
        .canonicalize()
        .unwrap_or_else(|e| panic!("canonicalize {rel}: {e}"))
}

fn python() -> String {
    let path = std::env::var("PATH").unwrap_or_default();
    path.split(':')
        .map(|d| format!("{d}/python3"))
        .find(|p| Path::new(p).exists())
        .expect("python3 on PATH")
}

fn sqlite_exec(db: &Path, sql: &str, params: &[&str]) {
    let mut cmd = Command::new(python());
    cmd.args([
        "-I",
        "-c",
        "import sqlite3, sys; c = sqlite3.connect(sys.argv[1]); c.execute(sys.argv[2], sys.argv[3:]); c.commit(); c.close()",
    ])
    .arg(db)
    .arg(sql);
    for p in params {
        cmd.arg(p);
    }
    let status = cmd.status().expect("run python3 sqlite3");
    assert!(status.success(), "sqlite exec failed for {sql}");
}

// Temporary directory removed automatically when dropped, even on panic.
struct TempDir {
    path: PathBuf,
}

impl TempDir {
    fn new(prefix: &str) -> Self {
        let seq = NEXT_TMP.fetch_add(1, Ordering::Relaxed);
        let raw = std::env::temp_dir().join(format!("{prefix}{}-{seq}", std::process::id()));
        let _ = fs::remove_dir_all(&raw);
        fs::create_dir_all(&raw).unwrap();
        let path = raw.canonicalize().unwrap();
        Self { path }
    }

    fn path(&self) -> &Path {
        &self.path
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.path);
    }
}

// A swan.db with only an old-schema meta table naming root.
fn write_old_map(db_path: &Path, root: &Path) {
    if let Some(parent) = db_path.parent() {
        fs::create_dir_all(parent).unwrap();
    }
    sqlite_exec(db_path, "CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT)", &[]);
    sqlite_exec(
        db_path,
        "INSERT INTO meta VALUES ('root', ?), ('schema_version', '1')",
        &[root.to_str().unwrap()],
    );
}

// Copies the prebuilt tiny-ts map into <data_root>/<dir_name>/swan.db and
// points its meta.root at the target repository root.
fn install_tiny_ts_map(data_root: &Path, dir_name: &str, target_root: &Path) -> PathBuf {
    let map_dir = data_root.join(dir_name);
    fs::create_dir_all(&map_dir).unwrap();
    let db = map_dir.join("swan.db");
    fs::copy(repo_root().join("rust/tests/data/tiny-ts.swan.db"), &db).unwrap();
    sqlite_exec(
        &db,
        "INSERT OR REPLACE INTO meta (key, value) VALUES ('root', ?)",
        &[target_root.to_str().unwrap()],
    );
    db
}

// Builds a current-schema map for fixtures/tiny-rs using `swan index` so
// switching checks can run without rust-analyzer installed.
fn install_tiny_rs_map(data_root: &Path, dir_name: &str, target_root: &Path) -> PathBuf {
    let flat = TempDir::new("swan-flat-rs-");
    let sym = "rust-analyzer cargo tiny-rs 0.1.0 Tile#new().";
    fs::write(
        flat.path().join("symbols.tsv"),
        format!("{sym}\tnew\t6\t\tpub fn new(side: u32) -> Tile\n"),
    )
    .unwrap();
    fs::write(
        flat.path().join("extents.tsv"),
        format!("{sym}\tsrc/lib.rs\t35\t4\t37\t5\n"),
    )
    .unwrap();
    fs::write(flat.path().join("relationships.tsv"), "").unwrap();
    fs::write(
        flat.path().join("occurrences.tsv"),
        format!("{sym}\tsrc/lib.rs\t35\t11\t35\t14\tdef\n"),
    )
    .unwrap();

    let map_dir = data_root.join(dir_name);
    fs::create_dir_all(&map_dir).unwrap();
    let db = map_dir.join("swan.db");
    let out = Command::new(env!("CARGO_BIN_EXE_swan"))
        .arg("index")
        .arg(flat.path())
        .arg(&db)
        .arg(target_root)
        .output()
        .expect("run swan index for tiny-rs");
    assert!(
        out.status.success(),
        "swan index failed: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    db
}

// Builds a minimal current-schema map for an arbitrary repo root with one symbol.
fn install_single_symbol_map(
    data_root: &Path,
    dir_name: &str,
    target_root: &Path,
    rel_file: &str,
    sym_name: &str,
) -> PathBuf {
    let flat = TempDir::new("swan-flat-one-");
    let scip = format!("scip-typescript npm {dir_name} 0.0.0 `{rel_file}`/{sym_name}().");
    fs::write(
        flat.path().join("symbols.tsv"),
        format!("{scip}\t{sym_name}\t12\t\tfunction {sym_name}()\n"),
    )
    .unwrap();
    fs::write(
        flat.path().join("extents.tsv"),
        format!("{scip}\t{rel_file}\t0\t0\t0\t20\n"),
    )
    .unwrap();
    fs::write(flat.path().join("relationships.tsv"), "").unwrap();
    fs::write(
        flat.path().join("occurrences.tsv"),
        format!("{scip}\t{rel_file}\t0\t0\t0\t10\tdef\n"),
    )
    .unwrap();

    let map_dir = data_root.join(dir_name);
    fs::create_dir_all(&map_dir).unwrap();
    let db = map_dir.join("swan.db");
    let out = Command::new(env!("CARGO_BIN_EXE_swan"))
        .arg("index")
        .arg(flat.path())
        .arg(&db)
        .arg(target_root)
        .output()
        .expect("run swan index");
    assert!(
        out.status.success(),
        "swan index failed: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    db
}

struct Server {
    child: Child,
    stdin: Option<ChildStdin>,
    stdout: BufReader<ChildStdout>,
    next_id: i64,
}

impl Server {
    fn spawn(args: &[&str], trust_build: bool) -> Self {
        let mut cmd = Command::new(common::swan_beside_tools());
        cmd.args(args)
            .current_dir(repo_root())
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        if trust_build {
            cmd.env("SWAN_TRUST_BUILD", "1");
        }
        let mut child = cmd.spawn().expect("spawn swan serve");
        let stdin = child.stdin.take().unwrap();
        let stdout = BufReader::new(child.stdout.take().unwrap());
        Self { child, stdin: Some(stdin), stdout, next_id: 1 }
    }

    fn spawn_maps(data_root: &Path, trust_build: bool) -> Self {
        let root_str = data_root.to_str().unwrap();
        Self::spawn(&["serve", "--maps", root_str], trust_build)
    }

    fn start_maps_initialized(data_root: &Path, trust_build: bool) -> Self {
        let mut srv = Self::spawn_maps(data_root, trust_build);
        let init = srv.initialize();
        assert_eq!(init["result"]["serverInfo"]["name"], "swan", "init reply: {init}");
        srv.notify("notifications/initialized");
        srv
    }

    fn initialize(&mut self) -> Value {
        self.rpc(
            "initialize",
            Some(json!({
                "protocolVersion": "2025-06-18",
                "capabilities": {},
                "clientInfo": {"name": "swan-maps-check", "version": "0"}
            })),
        )
    }

    fn write_json(&mut self, msg: &Value) {
        let stdin = self.stdin.as_mut().expect("stdin still open");
        serde_json::to_writer(&mut *stdin, msg).unwrap();
        stdin.write_all(b"\n").unwrap();
        stdin.flush().unwrap();
    }

    fn read_json(&mut self) -> Value {
        let mut line = String::new();
        let n = self.stdout.read_line(&mut line).expect("read reply line");
        assert!(n > 0, "server closed stdout before answering");
        serde_json::from_str(&line).unwrap_or_else(|e| panic!("invalid JSON reply {line:?}: {e}"))
    }

    fn notify(&mut self, method: &str) {
        self.write_json(&json!({"jsonrpc": "2.0", "method": method}));
    }

    fn rpc(&mut self, method: &str, params: Option<Value>) -> Value {
        let id = self.next_id;
        self.next_id += 1;
        let mut req = json!({"jsonrpc": "2.0", "id": id, "method": method});
        if let Some(p) = params {
            req["params"] = p;
        }
        self.write_json(&req);
        let reply = self.read_json();
        assert_eq!(reply["id"], id, "reply id mismatch: {reply}");
        reply
    }

    fn call_tool_raw(&mut self, name: &str, arguments: Value) -> (bool, String) {
        let reply = self.rpc("tools/call", Some(json!({"name": name, "arguments": arguments})));
        let result = &reply["result"];
        let is_error = result["isError"].as_bool().unwrap_or(false);
        let text = result["content"][0]["text"]
            .as_str()
            .unwrap_or_else(|| panic!("missing text content in {reply}"))
            .to_string();
        (is_error, text)
    }

    fn call_tool(&mut self, name: &str, arguments: Value) -> Value {
        let (is_error, text) = self.call_tool_raw(name, arguments);
        assert!(!is_error, "tool {name} returned error: {text}");
        serde_json::from_str(&text)
            .unwrap_or_else(|e| panic!("tool {name} returned non-JSON text {text:?}: {e}"))
    }

    fn close_and_wait(mut self) -> i32 {
        drop(self.stdin.take());
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            if let Some(status) = self.child.try_wait().unwrap() {
                return status.code().unwrap_or(-1);
            }
            if Instant::now() >= deadline {
                let _ = self.child.kill();
                let _ = self.child.wait();
                panic!("swan serve did not exit after stdin closed");
            }
            std::thread::sleep(Duration::from_millis(20));
        }
    }
}

impl Drop for Server {
    fn drop(&mut self) {
        drop(self.stdin.take());
        let deadline = Instant::now() + Duration::from_secs(2);
        loop {
            match self.child.try_wait() {
                Ok(Some(_)) => break,
                Ok(None) if Instant::now() < deadline => {
                    std::thread::sleep(Duration::from_millis(10));
                }
                _ => {
                    let _ = self.child.kill();
                    let _ = self.child.wait();
                    break;
                }
            }
        }
    }
}

fn jnum(obj: &Value, key: &str) -> i64 {
    if let Some(n) = obj[key].as_i64() {
        return n;
    }
    if let Some(s) = obj[key].as_str() {
        if let Ok(n) = s.parse::<i64>() {
            return n;
        }
    }
    -1
}

// ---------------------------------------------------------------------------
// Port of tests/check/maps_suite.goose (all 27 checks).
// ---------------------------------------------------------------------------

// swan serve <db> still answers about its map
#[test]
fn swan_serve_db_still_answers_about_its_map() {
    let data = TempDir::new("swan-maps-db-");
    let tiny_ts = fixture_path("fixtures/tiny-ts");
    let db = install_tiny_ts_map(data.path(), "tiny-ts", &tiny_ts);

    let mut srv = Server::spawn(&["serve", db.to_str().unwrap()], false);
    let init = srv.initialize();
    assert_eq!(init["result"]["serverInfo"]["name"], "swan", "{init}");
    srv.notify("notifications/initialized");

    let syms = srv.call_tool("find_symbol", json!({"name_path_pattern": "Store/add"}));
    let arr = syms.as_array().expect("symbols array");
    assert_eq!(arr.len(), 1, "{syms}");
    assert_eq!(arr[0]["relative_path"], "src/store.ts", "{syms}");
    assert_eq!(srv.close_and_wait(), 0);
}

// initialize names the server
#[test]
fn initialize_names_the_server() {
    let data = TempDir::new("swan-maps-init-");
    let mut srv = Server::spawn_maps(data.path(), false);
    let init = srv.initialize();
    assert_eq!(init["result"]["serverInfo"]["name"], "swan", "{init}");
    assert_eq!(srv.close_and_wait(), 0);
}

// tools/list includes use_repo
#[test]
fn tools_list_includes_use_repo() {
    let data = TempDir::new("swan-maps-tools-");
    let mut srv = Server::start_maps_initialized(data.path(), false);
    let list = srv.rpc("tools/list", None);
    let names: Vec<&str> = list["result"]["tools"]
        .as_array()
        .expect("tools array")
        .iter()
        .filter_map(|t| t["name"].as_str())
        .collect();
    assert!(names.contains(&"use_repo"), "{list}");
    assert_eq!(names.first().copied(), Some("use_repo"), "{list}");
    assert_eq!(srv.close_and_wait(), 0);
}

// no repo selected: find_symbol says to call use_repo or pass repo
#[test]
fn no_repo_selected_find_symbol_says_to_call_use_repo_or_pass_repo() {
    let data = TempDir::new("swan-maps-norepo-");
    let mut srv = Server::start_maps_initialized(data.path(), false);
    let (is_error, text) = srv.call_tool_raw("find_symbol", json!({"name_path_pattern": "Store/add"}));
    assert!(is_error, "expected error, got: {text}");
    assert!(
        text.contains("no repo selected: call use_repo with a path, or pass repo"),
        "{text}"
    );
    assert_eq!(srv.close_and_wait(), 0);
}

// no repo selected: index_info lists the known maps
#[test]
fn no_repo_selected_index_info_lists_the_known_maps() {
    let data = TempDir::new("swan-maps-list-");
    let mut srv = Server::start_maps_initialized(data.path(), false);
    let (is_error, text) = srv.call_tool_raw("index_info", json!({}));
    assert!(!is_error, "expected ok, got error: {text}");
    assert!(text.contains("\"maps\":["), "{text}");

    // When a map exists under the data root, index_info lists it.
    let tiny_ts = fixture_path("fixtures/tiny-ts");
    install_tiny_ts_map(data.path(), "tiny-ts", &tiny_ts);
    let listed = srv.call_tool("index_info", json!({}));
    let maps = listed["maps"].as_array().expect("maps array");
    assert_eq!(maps.len(), 1, "{listed}");
    assert_eq!(maps[0]["name"], "tiny-ts", "{listed}");
    assert_eq!(maps[0]["root"], tiny_ts.to_str().unwrap(), "{listed}");
    assert!(jnum(&maps[0], "symbols") > 0, "{listed}");
    assert_eq!(srv.close_and_wait(), 0);
}

// use_repo fixtures/tiny-ts: built the map under the data root
#[test]
#[ignore = "requires scip-typescript (tools/node_modules/.bin/scip-typescript) not present in this scratch copy"]
fn use_repo_fixtures_tiny_ts_built_the_map_under_the_data_root() {
    let data = TempDir::new("swan-maps-build-ts-");
    let tiny_ts = fixture_path("fixtures/tiny-ts");
    let mut srv = Server::start_maps_initialized(data.path(), true);

    let use_ts = srv.call_tool("use_repo", json!({"path": "fixtures/tiny-ts"}));
    assert_eq!(use_ts["built"], true, "{use_ts}");
    assert_eq!(use_ts["root"], tiny_ts.to_str().unwrap(), "{use_ts}");
    assert_eq!(
        use_ts["map"],
        format!("{}/tiny-ts/swan.db", data.path().display()),
        "{use_ts}"
    );
    assert_eq!(srv.close_and_wait(), 0);
}

// use_repo reports counts and a timed report
#[test]
#[ignore = "requires scip-typescript (tools/node_modules/.bin/scip-typescript) not present in this scratch copy"]
fn use_repo_reports_counts_and_a_timed_report() {
    let data = TempDir::new("swan-maps-counts-");
    let mut srv = Server::start_maps_initialized(data.path(), true);

    let use_ts = srv.call_tool("use_repo", json!({"path": "fixtures/tiny-ts"}));
    assert!(jnum(&use_ts, "symbols") > 0, "{use_ts}");
    assert!(jnum(&use_ts, "files") > 0, "{use_ts}");
    assert_eq!(jnum(&use_ts, "stale_file_count"), 0, "{use_ts}");
    assert!(
        use_ts["report"].as_str().unwrap_or("").contains("ms in all"),
        "{use_ts}"
    );
    assert_eq!(srv.close_and_wait(), 0);
}

// after use_repo, find_symbol answers about tiny-ts
#[test]
fn after_use_repo_find_symbol_answers_about_tiny_ts() {
    let data = TempDir::new("swan-maps-after-ts-");
    let tiny_ts = fixture_path("fixtures/tiny-ts");
    install_tiny_ts_map(data.path(), "tiny-ts", &tiny_ts);
    let mut srv = Server::start_maps_initialized(data.path(), false);

    let _ = srv.call_tool("use_repo", json!({"path": "fixtures/tiny-ts"}));
    let add = srv.call_tool("find_symbol", json!({"name_path_pattern": "Store/add"}));
    let arr = add.as_array().expect("symbols array");
    assert_eq!(arr.len(), 1, "{add}");
    assert_eq!(arr[0]["kind"], "method", "{add}");
    assert_eq!(arr[0]["relative_path"], "src/store.ts", "{add}");
    assert_eq!(srv.close_and_wait(), 0);
}

// use_repo fixtures/tiny-rs: built its map too
#[test]
#[ignore = "requires rust-analyzer (.tools/rust-analyzer/rust-analyzer) not present in this scratch copy"]
fn use_repo_fixtures_tiny_rs_built_its_map_too() {
    let data = TempDir::new("swan-maps-build-rs-");
    let tiny_rs = fixture_path("fixtures/tiny-rs");
    let mut srv = Server::start_maps_initialized(data.path(), true);

    let use_rs = srv.call_tool("use_repo", json!({"path": "fixtures/tiny-rs"}));
    assert_eq!(use_rs["built"], true, "{use_rs}");
    assert_eq!(use_rs["root"], tiny_rs.to_str().unwrap(), "{use_rs}");
    assert_eq!(srv.close_and_wait(), 0);
}

// after the switch, find_symbol answers about tiny-rs (Tile/new in src/lib.rs)
#[test]
fn after_switch_find_symbol_answers_about_tiny_rs() {
    let data = TempDir::new("swan-maps-switch-rs-");
    let tiny_ts = fixture_path("fixtures/tiny-ts");
    let tiny_rs = fixture_path("fixtures/tiny-rs");
    install_tiny_ts_map(data.path(), "tiny-ts", &tiny_ts);
    install_tiny_rs_map(data.path(), "tiny-rs", &tiny_rs);
    let mut srv = Server::start_maps_initialized(data.path(), false);

    let _ = srv.call_tool("use_repo", json!({"path": "fixtures/tiny-ts"}));
    let _ = srv.call_tool("use_repo", json!({"path": "fixtures/tiny-rs"}));
    let tile = srv.call_tool("find_symbol", json!({"name_path_pattern": "Tile/new"}));
    let arr = tile.as_array().expect("symbols array");
    assert_eq!(arr.len(), 1, "{tile}");
    assert_eq!(arr[0]["relative_path"], "src/lib.rs", "{tile}");
    assert_eq!(srv.close_and_wait(), 0);
}

// tiny-ts's symbols are gone after the switch
#[test]
fn tiny_ts_symbols_are_gone_after_the_switch() {
    let data = TempDir::new("swan-maps-gone-");
    let tiny_ts = fixture_path("fixtures/tiny-ts");
    let tiny_rs = fixture_path("fixtures/tiny-rs");
    install_tiny_ts_map(data.path(), "tiny-ts", &tiny_ts);
    install_tiny_rs_map(data.path(), "tiny-rs", &tiny_rs);
    let mut srv = Server::start_maps_initialized(data.path(), false);

    let _ = srv.call_tool("use_repo", json!({"path": "fixtures/tiny-ts"}));
    let _ = srv.call_tool("use_repo", json!({"path": "fixtures/tiny-rs"}));
    let gone = srv.call_tool("find_symbol", json!({"name_path_pattern": "Store/add"}));
    assert_eq!(gone.as_array().expect("symbols array").len(), 0, "{gone}");
    assert_eq!(srv.close_and_wait(), 0);
}

// a call's repo argument switches to that repo and answers
#[test]
fn call_repo_argument_switches_to_that_repo_and_answers() {
    let data = TempDir::new("swan-maps-repo-arg-");
    let tiny_ts = fixture_path("fixtures/tiny-ts");
    let tiny_rs = fixture_path("fixtures/tiny-rs");
    install_tiny_ts_map(data.path(), "tiny-ts", &tiny_ts);
    install_tiny_rs_map(data.path(), "tiny-rs", &tiny_rs);
    let mut srv = Server::start_maps_initialized(data.path(), false);

    let _ = srv.call_tool("use_repo", json!({"path": "fixtures/tiny-rs"}));
    let back = srv.call_tool(
        "find_symbol",
        json!({"name_path_pattern": "Store/add", "repo": "fixtures/tiny-ts"}),
    );
    let arr = back.as_array().expect("symbols array");
    assert_eq!(arr.len(), 1, "{back}");
    assert_eq!(arr[0]["relative_path"], "src/store.ts", "{back}");
    assert_eq!(srv.close_and_wait(), 0);
}

// the switch persists after the call
#[test]
fn switch_persists_after_the_call() {
    let data = TempDir::new("swan-maps-persist-");
    let tiny_ts = fixture_path("fixtures/tiny-ts");
    let tiny_rs = fixture_path("fixtures/tiny-rs");
    install_tiny_ts_map(data.path(), "tiny-ts", &tiny_ts);
    install_tiny_rs_map(data.path(), "tiny-rs", &tiny_rs);
    let mut srv = Server::start_maps_initialized(data.path(), false);

    let _ = srv.call_tool("use_repo", json!({"path": "fixtures/tiny-rs"}));
    let _ = srv.call_tool(
        "find_symbol",
        json!({"name_path_pattern": "Store/add", "repo": "fixtures/tiny-ts"}),
    );
    let stays = srv.call_tool("find_symbol", json!({"name_path_pattern": "Tile/new"}));
    assert_eq!(stays.as_array().expect("symbols array").len(), 0, "{stays}");
    assert_eq!(srv.close_and_wait(), 0);
}

// use_repo of a path inside a mapped repo finds the repo's map
#[test]
fn use_repo_of_path_inside_mapped_repo_finds_the_repo_map() {
    let data = TempDir::new("swan-maps-inside-");
    let tiny_ts = fixture_path("fixtures/tiny-ts");
    install_tiny_ts_map(data.path(), "tiny-ts", &tiny_ts);
    let mut srv = Server::start_maps_initialized(data.path(), false);

    let inner = srv.call_tool("use_repo", json!({"path": "fixtures/tiny-ts/src"}));
    assert_eq!(inner["root"], tiny_ts.to_str().unwrap(), "{inner}");
    assert_eq!(inner["built"], false, "{inner}");
    assert_eq!(
        inner["map"],
        format!("{}/tiny-ts/swan.db", data.path().display()),
        "{inner}"
    );
    assert_eq!(srv.close_and_wait(), 0);
}

// use_repo of the already-selected repo does not reopen the map
#[test]
fn use_repo_of_already_selected_repo_does_not_reopen_the_map() {
    let data = TempDir::new("swan-maps-reselect-");
    let tiny_ts = fixture_path("fixtures/tiny-ts");
    install_tiny_ts_map(data.path(), "tiny-ts", &tiny_ts);
    let mut srv = Server::start_maps_initialized(data.path(), false);

    let _ = srv.call_tool("use_repo", json!({"path": "fixtures/tiny-ts/src"}));
    let again = srv.call_tool("use_repo", json!({"path": "fixtures/tiny-ts"}));
    assert_eq!(again["switched"], false, "{again}");
    assert_eq!(srv.close_and_wait(), 0);
}

// a real switch reports switched
#[test]
fn real_switch_reports_switched() {
    let data = TempDir::new("swan-maps-real-switch-");
    let tiny_ts = fixture_path("fixtures/tiny-ts");
    let tiny_rs = fixture_path("fixtures/tiny-rs");
    install_tiny_ts_map(data.path(), "tiny-ts", &tiny_ts);
    install_tiny_rs_map(data.path(), "tiny-rs", &tiny_rs);
    let mut srv = Server::start_maps_initialized(data.path(), false);

    let _ = srv.call_tool("use_repo", json!({"path": "fixtures/tiny-ts"}));
    let _ = srv.call_tool("use_repo", json!({"path": "fixtures/tiny-rs"}));
    let back = srv.call_tool("use_repo", json!({"path": "fixtures/tiny-ts"}));
    assert_eq!(back["switched"], true, "{back}");
    assert_eq!(srv.close_and_wait(), 0);
}

// after several switches, reselecting the current repo is still a no-op
#[test]
fn after_several_switches_reselecting_current_repo_is_still_a_noop() {
    let data = TempDir::new("swan-maps-reselect-multi-");
    let tiny_ts = fixture_path("fixtures/tiny-ts");
    let tiny_rs = fixture_path("fixtures/tiny-rs");
    install_tiny_ts_map(data.path(), "tiny-ts", &tiny_ts);
    install_tiny_rs_map(data.path(), "tiny-rs", &tiny_rs);
    let mut srv = Server::start_maps_initialized(data.path(), false);

    let _ = srv.call_tool("use_repo", json!({"path": "fixtures/tiny-ts"}));
    let _ = srv.call_tool("use_repo", json!({"path": "fixtures/tiny-rs"}));
    let _ = srv.call_tool("use_repo", json!({"path": "fixtures/tiny-ts"}));
    let same = srv.call_tool("use_repo", json!({"path": "fixtures/tiny-ts/src"}));
    assert_eq!(same["switched"], false, "{same}");
    assert_eq!(srv.close_and_wait(), 0);
}

// use_repo on a missing path errors
#[test]
fn use_repo_on_a_missing_path_errors() {
    let data = TempDir::new("swan-maps-missing-");
    let mut srv = Server::start_maps_initialized(data.path(), false);

    let (is_error, text) = srv.call_tool_raw("use_repo", json!({"path": "fixtures/no-such-dir"}));
    assert!(is_error, "expected error, got: {text}");
    assert!(text.contains("no such path"), "{text}");
    assert_eq!(srv.close_and_wait(), 0);
}

// use_repo on a file errors
#[test]
fn use_repo_on_a_file_errors() {
    let data = TempDir::new("swan-maps-file-");
    let mut srv = Server::start_maps_initialized(data.path(), false);

    let (is_error, text) =
        srv.call_tool_raw("use_repo", json!({"path": "fixtures/tiny-ts/src/store.ts"}));
    assert!(is_error, "expected error, got: {text}");
    assert!(text.contains("not a directory"), "{text}");
    assert_eq!(srv.close_and_wait(), 0);
}

// build:false for a same-basename repo suggests a dir other than the existing map's
#[test]
fn build_false_for_same_basename_repo_suggests_different_dir() {
    let data = TempDir::new("swan-maps-twin-data-");
    let tiny_ts = fixture_path("fixtures/tiny-ts");
    install_tiny_ts_map(data.path(), "tiny-ts", &tiny_ts);

    let twin_root = TempDir::new("swan-twin-");
    let twin = twin_root.path().join("tiny-ts");
    fs::create_dir_all(&twin).unwrap();
    fs::write(twin.join("x.ts"), "export const x = 1;\n").unwrap();

    let mut srv = Server::start_maps_initialized(data.path(), false);
    let (is_error, text) = srv.call_tool_raw(
        "use_repo",
        json!({"path": twin.to_str().unwrap(), "build": false}),
    );
    assert!(is_error, "expected error, got: {text}");
    assert!(text.contains("swan map "), "{text}");
    assert!(
        !text.contains(&format!(" {}/tiny-ts'", data.path().display())),
        "{text}"
    );
    assert_eq!(srv.close_and_wait(), 0);
}

// an old-schema map is skipped, not opened (server stays up, repo counts as unmapped)
#[test]
fn old_schema_map_is_skipped_not_opened() {
    let data = TempDir::new("swan-maps-old-data-");
    let old_root = TempDir::new("swan-old-");
    let old_repo = old_root.path().join("oldrepo");
    fs::create_dir_all(&old_repo).unwrap();
    fs::write(old_repo.join("y.ts"), "export const y = 2;\n").unwrap();
    let old_repo_real = old_repo.canonicalize().unwrap();
    write_old_map(&data.path().join("oldrepo/swan.db"), &old_repo_real);

    let mut srv = Server::start_maps_initialized(data.path(), false);
    let (is_error, text) = srv.call_tool_raw(
        "use_repo",
        json!({"path": old_repo_real.to_str().unwrap(), "build": false}),
    );
    assert!(is_error, "expected error, got: {text}");
    assert!(text.contains("no map for"), "{text}");
    assert_eq!(srv.close_and_wait(), 0);
}

// damaged and meta-less maps under the data root don't stop selecting a healthy repo
#[test]
fn damaged_and_meta_less_maps_do_not_stop_selecting_healthy_repo() {
    let data = TempDir::new("swan-maps-damaged-");
    let tiny_ts = fixture_path("fixtures/tiny-ts");
    install_tiny_ts_map(data.path(), "tiny-ts", &tiny_ts);

    let junk_dir = data.path().join("junk");
    fs::create_dir_all(&junk_dir).unwrap();
    fs::write(junk_dir.join("swan.db"), "this is not a sqlite database\n").unwrap();

    let nometa_dir = data.path().join("nometa");
    fs::create_dir_all(&nometa_dir).unwrap();
    sqlite_exec(&nometa_dir.join("swan.db"), "CREATE TABLE other (x INTEGER)", &[]);

    let mut srv = Server::start_maps_initialized(data.path(), false);
    let via = srv.call_tool(
        "find_symbol",
        json!({"name_path_pattern": "Store/add", "repo": "fixtures/tiny-ts"}),
    );
    assert_eq!(via.as_array().expect("symbols array").len(), 1, "{via}");
    assert_eq!(srv.close_and_wait(), 0);
}

// use_repo over an old-schema map in the repo's own dir rebuilds it and stays up
#[test]
#[ignore = "requires scip-typescript (tools/node_modules/.bin/scip-typescript) not present in this scratch copy"]
fn use_repo_over_old_schema_map_rebuilds_it_and_stays_up() {
    let data = TempDir::new("swan-maps-rebuild-data-");
    let rebuild_work = TempDir::new("swan-rebuild-");
    let rebuild_repo = rebuild_work.path().join("rebuildme");
    fs::create_dir_all(rebuild_repo.join("src")).unwrap();
    fs::write(
        rebuild_repo.join("src/r.ts"),
        "export function rebuilt(): number { return 3; }\n",
    )
    .unwrap();
    fs::write(
        rebuild_repo.join("tsconfig.json"),
        "{\"compilerOptions\":{\"strict\":true},\"include\":[\"src\"]}\n",
    )
    .unwrap();
    let rebuild_real = rebuild_repo.canonicalize().unwrap();
    write_old_map(&data.path().join("rebuildme/swan.db"), &rebuild_real);

    let mut srv = Server::start_maps_initialized(data.path(), true);
    let rbj = srv.call_tool("use_repo", json!({"path": rebuild_real.to_str().unwrap()}));
    assert_eq!(rbj["built"], true, "{rbj}");
    assert_eq!(srv.close_and_wait(), 0);
}

// the rebuilt map answers
#[test]
#[ignore = "requires scip-typescript (tools/node_modules/.bin/scip-typescript) not present in this scratch copy"]
fn rebuilt_map_answers() {
    let data = TempDir::new("swan-maps-rebuilt-ans-");
    let rebuild_work = TempDir::new("swan-rebuild-ans-");
    let rebuild_repo = rebuild_work.path().join("rebuildme");
    fs::create_dir_all(rebuild_repo.join("src")).unwrap();
    fs::write(
        rebuild_repo.join("src/r.ts"),
        "export function rebuilt(): number { return 3; }\n",
    )
    .unwrap();
    fs::write(
        rebuild_repo.join("tsconfig.json"),
        "{\"compilerOptions\":{\"strict\":true},\"include\":[\"src\"]}\n",
    )
    .unwrap();
    let rebuild_real = rebuild_repo.canonicalize().unwrap();
    write_old_map(&data.path().join("rebuildme/swan.db"), &rebuild_real);

    let mut srv = Server::start_maps_initialized(data.path(), true);
    let _ = srv.call_tool("use_repo", json!({"path": rebuild_real.to_str().unwrap()}));
    let rsym = srv.call_tool("find_symbol", json!({"name_path_pattern": "rebuilt"}));
    assert_eq!(rsym.as_array().expect("symbols array").len(), 1, "{rsym}");
    assert_eq!(srv.close_and_wait(), 0);
}

// the server still answers after meeting an old-schema map
#[test]
fn server_still_answers_after_meeting_old_schema_map() {
    let data = TempDir::new("swan-maps-alive-");
    let tiny_ts = fixture_path("fixtures/tiny-ts");
    install_tiny_ts_map(data.path(), "tiny-ts", &tiny_ts);

    let old_root = TempDir::new("swan-old-alive-");
    let old_repo = old_root.path().join("oldrepo");
    fs::create_dir_all(&old_repo).unwrap();
    fs::write(old_repo.join("y.ts"), "export const y = 2;\n").unwrap();
    let old_repo_real = old_repo.canonicalize().unwrap();
    write_old_map(&data.path().join("oldrepo/swan.db"), &old_repo_real);

    let mut srv = Server::start_maps_initialized(data.path(), false);
    let (is_error, _) = srv.call_tool_raw(
        "use_repo",
        json!({"path": old_repo_real.to_str().unwrap(), "build": false}),
    );
    assert!(is_error);

    let _ = srv.call_tool("use_repo", json!({"path": "fixtures/tiny-ts"}));
    let (info_err, text) = srv.call_tool_raw("index_info", json!({}));
    assert!(!info_err, "expected ok, got: {text}");
    assert!(text.trim().starts_with('{'), "{text}");
    let alive: Value = serde_json::from_str(&text).expect("valid JSON");
    assert!(alive.is_object(), "{alive}");
    assert_eq!(srv.close_and_wait(), 0);
}

// use_repo with build:false names the swan map command
#[test]
fn use_repo_with_build_false_names_the_swan_map_command() {
    let data = TempDir::new("swan-maps-nobuild-");
    let mut srv = Server::start_maps_initialized(data.path(), false);

    let (is_error, text) =
        srv.call_tool_raw("use_repo", json!({"path": "fixtures/tiny-py", "build": false}));
    assert!(is_error, "expected error, got: {text}");
    assert!(text.contains("swan map "), "{text}");
    assert_eq!(srv.close_and_wait(), 0);
}

// index_info answers about the selected repo
#[test]
fn index_info_answers_about_the_selected_repo() {
    let data = TempDir::new("swan-maps-info-");
    let tiny_ts = fixture_path("fixtures/tiny-ts");
    install_tiny_ts_map(data.path(), "tiny-ts", &tiny_ts);
    let mut srv = Server::start_maps_initialized(data.path(), false);

    let _ = srv.call_tool("use_repo", json!({"path": "fixtures/tiny-ts"}));
    let info = srv.call_tool("index_info", json!({}));
    assert_eq!(info["root"], tiny_ts.to_str().unwrap(), "{info}");
    assert!(jnum(&info, "symbols") > 0, "{info}");
    assert_eq!(srv.close_and_wait(), 0);
}

// ---------------------------------------------------------------------------
// Additional Task 2 checks: in-process build and rebuild, bare `swan serve`,
// malformed `build` arguments, and longest-prefix map selection.
// ---------------------------------------------------------------------------

// use_repo builds a shader-only repo in process under the data root without external indexers
#[test]
fn use_repo_builds_shader_repo_in_process_under_data_root() {
    let data = TempDir::new("swan-maps-shader-");
    let tiny_shaders = fixture_path("fixtures/tiny-shaders");
    let mut srv = Server::start_maps_initialized(data.path(), false);

    let res = srv.call_tool("use_repo", json!({"path": "fixtures/tiny-shaders"}));
    assert_eq!(res["built"], true, "{res}");
    assert_eq!(res["switched"], true, "{res}");
    assert_eq!(res["root"], tiny_shaders.to_str().unwrap(), "{res}");
    assert_eq!(
        res["map"],
        format!("{}/tiny-shaders/swan.db", data.path().display()),
        "{res}"
    );
    assert_eq!(jnum(&res, "stale_file_count"), 0, "{res}");
    assert!(
        res["report"].as_str().unwrap_or("").contains("ms in all"),
        "{res}"
    );
    assert!(data.path().join("tiny-shaders/swan.db").exists());
    assert_eq!(srv.close_and_wait(), 0);
}

// use_repo rebuilds an old-schema map in the repo's own dir in process and stays up
#[test]
fn use_repo_rebuilds_old_schema_map_in_repo_own_dir_in_process() {
    let data = TempDir::new("swan-maps-rebuild-wgsl-");
    let work = TempDir::new("swan-rebuild-wgsl-");
    let repo = work.path().join("rebuildwgsl");
    fs::create_dir_all(&repo).unwrap();
    fs::write(repo.join("shade.wgsl"), "@vertex fn main() -> @builtin(position) vec4<f32> { return vec4<f32>(0.0); }\n").unwrap();
    let repo_real = repo.canonicalize().unwrap();
    write_old_map(&data.path().join("rebuildwgsl/swan.db"), &repo_real);

    let mut srv = Server::start_maps_initialized(data.path(), false);
    let res = srv.call_tool("use_repo", json!({"path": repo_real.to_str().unwrap()}));
    assert_eq!(res["built"], true, "{res}");
    assert_eq!(res["root"], repo_real.to_str().unwrap(), "{res}");
    assert_eq!(
        res["map"],
        format!("{}/rebuildwgsl/swan.db", data.path().display()),
        "{res}"
    );

    let info = srv.call_tool("index_info", json!({}));
    assert_eq!(info["root"], repo_real.to_str().unwrap(), "{info}");
    assert_eq!(srv.close_and_wait(), 0);
}

// bare `swan serve` starts with no repo selected and lists maps on index_info
#[test]
fn bare_swan_serve_starts_with_no_repo_selected() {
    let mut srv = Server::spawn(&["serve"], false);
    let init = srv.initialize();
    assert_eq!(init["result"]["serverInfo"]["name"], "swan", "{init}");
    srv.notify("notifications/initialized");

    let list = srv.rpc("tools/list", None);
    let names: Vec<&str> = list["result"]["tools"]
        .as_array()
        .expect("tools array")
        .iter()
        .filter_map(|t| t["name"].as_str())
        .collect();
    assert_eq!(names.first().copied(), Some("use_repo"), "{list}");

    let (is_error, text) = srv.call_tool_raw("find_symbol", json!({"name_path_pattern": "Store/add"}));
    assert!(is_error, "expected error, got: {text}");
    assert!(
        text.contains("no repo selected: call use_repo with a path, or pass repo"),
        "{text}"
    );

    let (info_err, info_text) = srv.call_tool_raw("index_info", json!({}));
    assert!(!info_err, "expected ok, got: {info_text}");
    assert!(info_text.contains("\"maps\":["), "{info_text}");
    assert_eq!(srv.close_and_wait(), 0);
}

// non-boolean build argument errors without changing the selected repo
#[test]
fn non_boolean_build_argument_errors_without_changing_selection() {
    let data = TempDir::new("swan-maps-bad-build-");
    let tiny_ts = fixture_path("fixtures/tiny-ts");
    let tiny_rs = fixture_path("fixtures/tiny-rs");
    install_tiny_ts_map(data.path(), "tiny-ts", &tiny_ts);
    install_tiny_rs_map(data.path(), "tiny-rs", &tiny_rs);
    let mut srv = Server::start_maps_initialized(data.path(), false);

    let _ = srv.call_tool("use_repo", json!({"path": "fixtures/tiny-ts"}));

    let (err1, text1) = srv.call_tool_raw(
        "use_repo",
        json!({"path": "fixtures/tiny-rs", "build": "yes"}),
    );
    assert!(err1, "expected error, got: {text1}");
    assert!(text1.contains("build must be a boolean"), "{text1}");

    let (err2, text2) = srv.call_tool_raw(
        "find_symbol",
        json!({"name_path_pattern": "Tile/new", "repo": "fixtures/tiny-rs", "build": Value::Null}),
    );
    assert!(err2, "expected error, got: {text2}");
    assert!(text2.contains("build must be a boolean"), "{text2}");

    // Selection stayed on tiny-ts after both rejected calls.
    let info = srv.call_tool("index_info", json!({}));
    assert_eq!(info["root"], tiny_ts.to_str().unwrap(), "{info}");
    assert_eq!(srv.close_and_wait(), 0);
}

// use_repo without a path reports path is required
#[test]
fn use_repo_missing_path_arg_errors() {
    let data = TempDir::new("swan-maps-emptypath-");
    let mut srv = Server::start_maps_initialized(data.path(), false);

    let (is_error, text) = srv.call_tool_raw("use_repo", json!({}));
    assert!(is_error, "expected error, got: {text}");
    assert!(text.contains("path is required"), "{text}");
    assert_eq!(srv.close_and_wait(), 0);
}

// find_map prefers the nearest (longest-prefix) mapped root above a path
#[test]
fn find_map_prefers_longest_matching_root() {
    let data = TempDir::new("swan-maps-nested-");
    let work = TempDir::new("swan-nested-repo-");
    let outer = work.path().join("outer");
    let inner = outer.join("sub/inner");
    let deeper = inner.join("src");
    fs::create_dir_all(&deeper).unwrap();
    fs::write(outer.join("outer.ts"), "export function outerFn() {}\n").unwrap();
    fs::write(deeper.join("inner.ts"), "export function innerFn() {}\n").unwrap();
    let outer_real = outer.canonicalize().unwrap();
    let inner_real = inner.canonicalize().unwrap();
    let deeper_real = deeper.canonicalize().unwrap();

    install_single_symbol_map(data.path(), "outer", &outer_real, "outer.ts", "outerFn");
    install_single_symbol_map(data.path(), "inner", &inner_real, "src/inner.ts", "innerFn");

    let mut srv = Server::start_maps_initialized(data.path(), false);
    let pick_inner = srv.call_tool("use_repo", json!({"path": deeper_real.to_str().unwrap()}));
    assert_eq!(pick_inner["root"], inner_real.to_str().unwrap(), "{pick_inner}");
    assert_eq!(pick_inner["built"], false, "{pick_inner}");

    let pick_outer = srv.call_tool("use_repo", json!({"path": outer_real.to_str().unwrap()}));
    assert_eq!(pick_outer["root"], outer_real.to_str().unwrap(), "{pick_outer}");
    assert_eq!(pick_outer["built"], false, "{pick_outer}");
    assert_eq!(srv.close_and_wait(), 0);
}
