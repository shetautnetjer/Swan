// End-to-end checks of `swan serve <db>` over stdin and stdout, porting
// tests/check/mcp_suite.goose's checks on fixtures/tiny-ts.

use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};
use std::time::{Duration, Instant};

use serde_json::{json, Value};

const EXPECTED_TOOLS: [&str; 28] = [
    "use_repo",
    "find_symbol",
    "find_referencing_symbols",
    "get_symbol_at",
    "get_symbols_overview",
    "get_callers",
    "get_callees",
    "find_implementations",
    "get_type_hierarchy",
    "find_unused_symbols",
    "replace_symbol_body",
    "insert_after_symbol",
    "insert_before_symbol",
    "rename_symbol",
    "get_diagnostics",
    "what_broke",
    "update_map",
    "check_errors",
    "run_tests",
    "format_file",
    "search_pattern",
    "rewrite_pattern",
    "edit_batch",
    "repo_projects",
    "repo_overview",
    "what_touches",
    "file_neighbors",
    "index_info",
];

fn repo_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("rust/ sits under repository root")
        .canonicalize()
        .expect("canonical repository root")
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
    assert!(status.success(), "sqlite update failed for {sql}");
}

fn copy_dir(src: &Path, dst: &Path) {
    fs::create_dir_all(dst).unwrap();
    for entry in fs::read_dir(src).unwrap() {
        let entry = entry.unwrap();
        let ty = entry.file_type().unwrap();
        let from = entry.path();
        let to = dst.join(entry.file_name());
        if ty.is_dir() {
            copy_dir(&from, &to);
        } else if ty.is_file() {
            fs::copy(&from, &to).unwrap();
        }
    }
}

struct Server {
    dir: PathBuf,
    db: PathBuf,
    child: Child,
    stdin: Option<ChildStdin>,
    stdout: BufReader<ChildStdout>,
    next_id: i64,
}

impl Server {
    fn start(name: &str, copy_fixture: bool) -> (Self, PathBuf) {
        Self::start_with_env(name, copy_fixture, &[])
    }

    fn start_with_env(name: &str, copy_fixture: bool, vars: &[(&str, &str)]) -> (Self, PathBuf) {
        Self::start_with_env_changes(name, copy_fixture, vars, &[])
    }

    fn start_with_env_changes(
        name: &str,
        copy_fixture: bool,
        vars: &[(&str, &str)],
        remove: &[&str],
    ) -> (Self, PathBuf) {
        let dir = std::env::temp_dir().join(format!("swan-serve-{}-{name}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();

        let root = repo_root();
        let db = dir.join("swan.db");
        fs::copy(root.join("rust/tests/data/tiny-ts.swan.db"), &db).unwrap();

        let fixture_root = if copy_fixture {
            let copied = dir.join("tiny-ts");
            copy_dir(&root.join("fixtures/tiny-ts"), &copied);
            copied.canonicalize().unwrap()
        } else {
            root.join("fixtures/tiny-ts").canonicalize().unwrap()
        };

        sqlite_exec(
            &db,
            "INSERT OR REPLACE INTO meta (key, value) VALUES ('root', ?)",
            &[fixture_root.to_str().unwrap()],
        );

        let mut cmd = Command::new(env!("CARGO_BIN_EXE_swan"));
        cmd.arg("serve")
            .arg(&db)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        for k in remove {
            cmd.env_remove(k);
        }
        for (k, v) in vars {
            cmd.env(k, v);
        }
        let mut child = cmd.spawn().expect("spawn swan serve");
        let stdin = child.stdin.take().unwrap();
        let stdout = BufReader::new(child.stdout.take().unwrap());

        let srv = Self { dir, db, child, stdin: Some(stdin), stdout, next_id: 1 };
        (srv, fixture_root)
    }

    fn start_initialized_with_env(name: &str, vars: &[(&str, &str)]) -> Self {
        Self::start_initialized_with_env_changes(name, vars, &[])
    }

    fn start_initialized_with_env_changes(
        name: &str,
        vars: &[(&str, &str)],
        remove: &[&str],
    ) -> Self {
        let (mut srv, _) = Self::start_with_env_changes(name, false, vars, remove);
        let init = srv.rpc(
            "initialize",
            Some(json!({
                "protocolVersion": "2025-06-18",
                "capabilities": {},
                "clientInfo": {"name": "swan-smoke", "version": "0"}
            })),
        );
        assert_eq!(init["result"]["serverInfo"]["name"], "swan", "init reply: {init}");
        srv.notify("notifications/initialized");
        srv
    }

    fn start_initialized(name: &str) -> Self {
        Self::start_initialized_with_env(name, &[])
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
        let _ = fs::remove_dir_all(&self.dir);
    }
}

fn sorted_join(items: &Value, key: &str) -> String {
    let mut vals: Vec<&str> = items
        .as_array()
        .expect("JSON array")
        .iter()
        .map(|v| v[key].as_str().unwrap_or(""))
        .collect();
    vals.sort();
    vals.join(",")
}

fn jfind<'a>(items: &'a Value, key: &str, value: &str) -> &'a Value {
    items
        .as_array()
        .expect("JSON array")
        .iter()
        .find(|v| v[key].as_str() == Some(value))
        .unwrap_or_else(|| panic!("no item with {key} == {value:?} in {items}"))
}

fn jany(items: &Value, key: &str, value: &str) -> bool {
    items
        .as_array()
        .map(|a| a.iter().any(|v| v[key].as_str() == Some(value)))
        .unwrap_or(false)
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

// initialize names the server; tools/list is the 28 names in order; unknown method is a JSON-RPC error
#[test]
fn initialize_tools_list_and_unknown_method() {
    let (mut srv, _) = Server::start("init-list-unknown", false);
    let init = srv.rpc(
        "initialize",
        Some(json!({
            "protocolVersion": "2025-06-18",
            "capabilities": {},
            "clientInfo": {"name": "swan-smoke", "version": "0"}
        })),
    );
    assert_eq!(init["result"]["serverInfo"]["name"], "swan", "{init}");
    srv.notify("notifications/initialized");

    let list = srv.rpc("tools/list", None);
    let names: Vec<&str> = list["result"]["tools"]
        .as_array()
        .expect("tools array")
        .iter()
        .filter_map(|t| t["name"].as_str())
        .collect();
    assert_eq!(names, EXPECTED_TOOLS, "{list}");

    let unknown = srv.rpc("no/such/method", None);
    assert_eq!(unknown["error"]["code"], -32601, "{unknown}");

    // Server keeps answering after an unknown method.
    let list2 = srv.rpc("tools/list", None);
    assert_eq!(list2["result"]["tools"].as_array().unwrap().len(), 28, "{list2}");

    assert_eq!(srv.close_and_wait(), 0);
}

// find_symbol Store/add: one method at src/store.ts:11
#[test]
fn find_symbol_store_add() {
    let mut srv = Server::start_initialized("find-symbol-store-add");
    let add = srv.call_tool("find_symbol", json!({"name_path_pattern": "Store/add", "include_body": true}));
    let arr = add.as_array().expect("array");
    assert_eq!(arr.len(), 1, "{add}");
    let a0 = &arr[0];
    assert_eq!(a0["kind"], "method", "{add}");
    assert_eq!(a0["relative_path"], "src/store.ts", "{add}");
    assert_eq!(a0["line"], 11, "{add}");
    assert!(a0["body"].as_str().unwrap_or("").contains("this.items.set"), "{add}");
}

// find_symbol total: the function, the method and the override stay apart
#[test]
fn find_symbol_total() {
    let mut srv = Server::start_initialized("find-symbol-total");
    let totals = srv.call_tool("find_symbol", json!({"name_path_pattern": "total"}));
    assert_eq!(sorted_join(&totals, "name_path"), "CappedStore/total,Store/total,total", "{totals}");
}

// refs to format() follow the re-export to formatItem in main.ts
#[test]
fn refs_to_format_follow_reexport() {
    let mut srv = Server::start_initialized("refs-format");
    let fmt = srv.call_tool("find_referencing_symbols", json!({"name_path": "format"}));
    let refs: Vec<String> = fmt[0]["references"]
        .as_array()
        .expect("references array")
        .iter()
        .map(|r| format!("{}:{}", r["relative_path"].as_str().unwrap_or(""), r["line"].as_i64().unwrap_or(-1)))
        .collect();
    assert!(refs.iter().any(|s| s == "src/main.ts:8"), "{refs:?}");
    assert!(refs.iter().any(|s| s == "src/index.ts:2"), "{refs:?}");
}

// overview of src/store.ts lists Store and makeStore
#[test]
fn overview_of_store_ts() {
    let mut srv = Server::start_initialized("overview-store");
    let ov = srv.call_tool("get_symbols_overview", json!({"relative_path": "src/store.ts"}));
    assert!(jany(&ov, "name_path", "Store") && jany(&ov, "name_path", "makeStore"), "{ov}");
}

// get_callers walks the chain: report at 1, summary at 2, testSummary at 3; get_callers defaults to direct callers only
#[test]
fn get_callers_walks_chain_and_defaults_direct() {
    let mut srv = Server::start_initialized("get-callers-chain");
    let impact = srv.call_tool("get_callers", json!({"name_path": "Store/total", "depth": 3}));
    let ic = &impact["callers"];
    assert_eq!(jfind(ic, "name_path", "report")["distance"], 1, "{impact}");
    assert_eq!(jfind(ic, "name_path", "summary")["distance"], 2, "{impact}");
    assert_eq!(jfind(ic, "name_path", "testSummary")["distance"], 3, "{impact}");
    let test_files: Vec<&str> = impact["summary"]["test_files"]
        .as_array()
        .expect("test_files")
        .iter()
        .filter_map(|v| v.as_str())
        .collect();
    assert!(test_files.contains(&"src/store.test.ts"), "{impact}");
    assert_eq!(jfind(ic, "name_path", "testSummary")["is_test"], true, "{impact}");

    let near = srv.call_tool("get_callers", json!({"name_path": "Store/total"}));
    let nc = near["callers"].as_array().expect("callers array");
    assert!(!nc.is_empty(), "{near}");
    assert!(nc.iter().all(|c| c["distance"] == 1), "{near}");
}

// get_callees of Store/add: DEFAULT_WEIGHT, and Map/set from the typescript package
#[test]
fn get_callees_of_store_add() {
    let mut srv = Server::start_initialized("get-callees-store-add");
    let callees = srv.call_tool("get_callees", json!({"name_path": "Store/add"}));
    let cl = &callees["callees"];
    assert!(jany(cl, "name_path", "DEFAULT_WEIGHT"), "{callees}");
    let has_map_set = cl.as_array().unwrap().iter().any(|c| {
        c["name_path"] == "Map/set" && c["package"].as_str().unwrap_or("").starts_with("typescript ")
    });
    assert!(has_map_set, "{callees}");
}

// find_implementations Weighed: Box and Crate
#[test]
fn find_implementations_weighed() {
    let mut srv = Server::start_initialized("find-impls-weighed");
    let impls = srv.call_tool("find_implementations", json!({"name_path": "Weighed"}));
    assert_eq!(sorted_join(&impls["implementations"], "name_path"), "Box,Crate", "{impls}");
}

// get_type_hierarchy: CappedStore/total overrides Store/total
#[test]
fn get_type_hierarchy_capped_store_total() {
    let mut srv = Server::start_initialized("type-hierarchy-capped");
    let th = srv.call_tool("get_type_hierarchy", json!({"name_path": "CappedStore/total"}));
    let sup = th["supertypes"].as_array().expect("supertypes");
    let sub = th["subtypes"].as_array().expect("subtypes");
    assert_eq!(sup.len(), 1, "{th}");
    assert_eq!(sup[0]["name_path"], "Store/total", "{th}");
    assert_eq!(sub.len(), 0, "{th}");
}

// find_unused_symbols: Box, Crate and CappedStore (nothing uses them), not testSummary (test file)
#[test]
fn find_unused_symbols_tiny_ts() {
    let mut srv = Server::start_initialized("find-unused");
    let unused = srv.call_tool("find_unused_symbols", json!({}));
    assert_eq!(sorted_join(&unused["unused"], "name_path"), "Box,CappedStore,Crate", "{unused}");
}

// get_symbol_at main.ts:8:15 is formatItem's target, format() in src/format.ts:3
#[test]
fn get_symbol_at_main_format_item() {
    let mut srv = Server::start_initialized("symbol-at-main");
    let at = srv.call_tool("get_symbol_at", json!({"relative_path": "src/main.ts", "line": 8, "column": 15}));
    let at0 = &at["at"][0];
    assert_eq!(at0["name_path"], "format", "{at}");
    assert_eq!(at0["relative_path"], "src/format.ts", "{at}");
    assert_eq!(at0["line"], 3, "{at}");
}

// index_info reports counts
#[test]
fn index_info_reports_counts() {
    let mut srv = Server::start_initialized("index-info");
    let info = srv.call_tool("index_info", json!({}));
    assert!(jnum(&info, "symbols") > 0 && jnum(&info, "occurrences") > 0, "{info}");
}

// an unknown tool answers 'unknown tool: <name>' without requiring SWAN_GOOSE_SERVE
#[test]
fn unknown_tool_answers_unknown_tool() {
    let mut srv = Server::start_initialized("unknown-tool");
    let (is_error, text) = srv.call_tool_raw("no_such_tool", json!({}));
    assert!(is_error, "expected MCP tool error, got ok: {text}");
    assert_eq!(text, "unknown tool: no_such_tool");
}

// a forwarded tool without SWAN_GOOSE_SERVE (unset or empty) returns an MCP error naming the env var
#[test]
fn forwarded_tool_without_swan_goose_serve_returns_error() {
    let mut srv_unset =
        Server::start_initialized_with_env_changes("forward-unset-env", &[], &["SWAN_GOOSE_SERVE"]);
    let (is_error, text) = srv_unset.call_tool_raw("rename_symbol", json!({}));
    assert!(is_error, "expected MCP tool error when unset, got ok: {text}");
    assert!(text.contains("SWAN_GOOSE_SERVE"), "{text}");
    assert_eq!(srv_unset.close_and_wait(), 0);

    let mut srv_empty =
        Server::start_initialized_with_env("forward-empty-env", &[("SWAN_GOOSE_SERVE", "")]);
    let (is_error2, text2) = srv_empty.call_tool_raw("update_map", json!({}));
    assert!(is_error2, "expected MCP tool error when empty, got ok: {text2}");
    assert!(text2.contains("SWAN_GOOSE_SERVE"), "{text2}");
    assert_eq!(srv_empty.close_and_wait(), 0);
}

// get_callers with a name three symbols share sends the question back instead of merging
#[test]
fn get_callers_ambiguous_name_returns_targets() {
    let mut srv = Server::start_initialized("callers-ambiguous");
    let amb = srv.call_tool("get_callers", json!({"name_path": "total"}));
    assert_eq!(amb["ambiguous"], true, "{amb}");
    assert_eq!(amb["targets"].as_array().unwrap().len(), 3, "{amb}");
    assert!(amb.get("callers").is_none(), "{amb}");

    let one = srv.call_tool("get_callers", json!({"name_path": "total", "relative_path": "src/format.ts"}));
    assert_ne!(one["ambiguous"], true, "{one}");
    assert!(jany(&one["callers"], "relative_path", "src/main.ts"), "{one}");
}

// an edited file's answers say stale, others don't
#[test]
fn edited_file_answers_say_stale_others_dont() {
    let (mut srv, fixture_root) = Server::start("freshness-stale", true);
    // Pin scip_time past the freshly copied fixture files so the baseline is clean.
    let now_ns = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_nanos() as i64;
    let scip_ns = now_ns + 5_000_000_000;
    sqlite_exec(
        &srv.db,
        "INSERT OR REPLACE INTO meta (key, value) VALUES ('scip_time', ?)",
        &[&scip_ns.to_string()],
    );

    let init = srv.rpc(
        "initialize",
        Some(json!({
            "protocolVersion": "2025-06-18",
            "capabilities": {},
            "clientInfo": {"name": "swan-smoke", "version": "0"}
        })),
    );
    assert_eq!(init["result"]["serverInfo"]["name"], "swan");
    srv.notify("notifications/initialized");

    let fresh = srv.call_tool("index_info", json!({}));
    assert_eq!(fresh["stale_file_count"], 0, "{fresh}");

    // Advance src/report.ts mtime past scip_time to simulate an edit after the SCIP run.
    let report_ts = fixture_root.join("src/report.ts");
    let future_s = (scip_ns / 1_000_000_000) + 60;
    let status = Command::new(python())
        .args(["-I", "-c", "import os, sys; t = int(sys.argv[2]); os.utime(sys.argv[1], (t, t))"])
        .arg(&report_ts)
        .arg(future_s.to_string())
        .status()
        .unwrap();
    assert!(status.success());

    let stale = srv.call_tool("find_referencing_symbols", json!({"name_path": "Store/total"}));
    let sr = stale[0]["references"].as_array().expect("references");
    assert!(!sr.is_empty(), "{stale}");
    for r in sr {
        let is_report = r["relative_path"] == "src/report.ts";
        assert_eq!(r["stale"].as_bool().unwrap_or(false), is_report, "{stale}");
    }
    let stale_info = srv.call_tool("index_info", json!({}));
    let stale_files: Vec<&str> = stale_info["stale_files"]
        .as_array()
        .expect("stale_files")
        .iter()
        .filter_map(|v| v.as_str())
        .collect();
    assert_eq!(stale_files, vec!["src/report.ts"], "{stale_info}");
}

// search_pattern finds structural matches with captures and enclosing symbol
#[test]
fn search_pattern_finds_store_items_set() {
    let mut srv = Server::start_initialized("search-pattern");
    let res = srv.call_tool(
        "search_pattern",
        json!({
            "pattern": "this.items.set($K, $V)",
            "language": "typescript",
            "relative_path": "src/store.ts"
        }),
    );
    let matches = res["matches"].as_array().expect("matches");
    assert_eq!(matches.len(), 1, "{res}");
    assert_eq!(matches[0]["relative_path"], "src/store.ts", "{res}");
    assert_eq!(matches[0]["in_symbol"], "Store/add", "{res}");
}

// get_diagnostics reports when no diagnostics are loaded
#[test]
fn get_diagnostics_without_loaded_data_returns_error() {
    let mut srv = Server::start_initialized("diag-missing");
    let (is_error, text) = srv.call_tool_raw("get_diagnostics", json!({}));
    assert!(is_error, "expected error when no diagnostics loaded, got: {text}");
    assert!(text.contains("no diagnostics loaded"), "{text}");
}

// what_broke requires the files argument
#[test]
fn what_broke_missing_files_returns_error() {
    let mut srv = Server::start_initialized("what-broke-missing-files");
    let (is_error, text) = srv.call_tool_raw("what_broke", json!({}));
    assert!(is_error, "expected error, got: {text}");
    assert!(text.contains("files is required"), "{text}");
    assert_eq!(srv.close_and_wait(), 0);
}

// what_broke reports new errors once, remembers them in broke-seen.tsv beside
// the map, and returns isError:true when no file could be asked.
#[test]
fn what_broke_reports_new_errors_once_and_remembers_seen() {
    let dir = std::env::temp_dir().join(format!("swan-serve-what-broke-{}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    let home = dir.join("home");
    let repo = dir.join("repo");
    let map = dir.join("map");
    for d in [home.join("bin"), home.join("tools"), repo.clone(), map.clone()] {
        fs::create_dir_all(d).unwrap();
    }
    fs::copy(env!("CARGO_BIN_EXE_swan"), home.join("bin/swan")).unwrap();
    let fake = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fake_lsp.py");
    let mods = json!({
        "nolsp": {"match": [".nl"]},
        "fake": {
            "match": [".fake"],
            "lsp": [{
                "cmd": [python(), "-I", fake, "publish"],
                "language_id": "fake",
                "settle": "publish"
            }]
        },
        "guarded": {
            "match": [".tr"],
            "lsp": [{
                "cmd": [python(), "-I", fake, "publish"],
                "language_id": "guarded",
                "settle": "publish",
                "runs_repo_code": true
            }]
        }
    });
    fs::write(home.join("tools/modules.json"), mods.to_string()).unwrap();
    fs::write(repo.join("b.fake"), "fine\n").unwrap();
    fs::write(repo.join("note.nl"), "plain text\n").unwrap();
    fs::write(repo.join("a.tr"), "fine\n").unwrap();
    let repo_real = repo.canonicalize().unwrap();
    let db = map.join("swan.db");
    fs::copy(repo_root().join("rust/tests/data/tiny-ts.swan.db"), &db).unwrap();
    sqlite_exec(
        &db,
        "INSERT OR REPLACE INTO meta (key, value) VALUES ('root', ?)",
        &[repo_real.to_str().unwrap()],
    );

    let mut child = Command::new(home.join("bin/swan"))
        .arg("serve")
        .arg(&db)
        .env_remove("SWAN_TRUST_BUILD")
        .env_remove("SWAN_SANDBOX")
        .env("SWAN_LIVE_BUDGET_MS", "20000")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn swan serve from fake home");
    let stdin = child.stdin.take().unwrap();
    let stdout = BufReader::new(child.stdout.take().unwrap());
    let mut srv = Server { dir, db, child, stdin: Some(stdin), stdout, next_id: 1 };
    let init = srv.rpc(
        "initialize",
        Some(json!({
            "protocolVersion": "2025-06-18",
            "capabilities": {},
            "clientInfo": {"name": "swan-smoke", "version": "0"}
        })),
    );
    assert_eq!(init["result"]["serverInfo"]["name"], "swan", "{init}");
    srv.notify("notifications/initialized");

    // First look on a clean file: asked:true, first_look:true, 0 new errors.
    let clean = srv.call_tool("what_broke", json!({"files": ["b.fake"]}));
    assert_eq!(clean["new_errors"], 0, "{clean}");
    assert_eq!(clean["files"][0]["asked"], true, "{clean}");
    assert_eq!(clean["files"][0]["first_look"], true, "{clean}");
    assert!(map.join("broke-seen.tsv").exists());

    // Introduce an error and a warning: reported once with line 2.
    fs::write(repo_real.join("b.fake"), "fine\nan ERROR here\na WARN here\n").unwrap();
    let broken = srv.call_tool("what_broke", json!({"files": ["b.fake"]}));
    assert_eq!(broken["new_errors"], 1, "{broken}");
    assert_eq!(broken["files"][0]["asked"], true, "{broken}");
    assert_eq!(broken["files"][0]["first_look"], false, "{broken}");
    assert_eq!(broken["files"][0]["new_errors"][0]["line"], 2, "{broken}");
    assert_eq!(broken["files"][0]["errors_already_there"], 0, "{broken}");
    assert_eq!(broken["files"][0]["warnings"], 1, "{broken}");

    // Asked again: already there, not new.
    let again = srv.call_tool("what_broke", json!({"files": ["b.fake"]}));
    assert_eq!(again["new_errors"], 0, "{again}");
    assert_eq!(again["files"][0]["errors_already_there"], 1, "{again}");

    // No server for .nl alone -> asked == 0 -> isError:true with JSON payload.
    let (nl_err, nl_text) = srv.call_tool_raw("what_broke", json!({"files": ["note.nl"]}));
    assert!(nl_err, "expected isError:true when asked == 0: {nl_text}");
    let nl_json: Value = serde_json::from_str(&nl_text).expect("valid JSON");
    assert_eq!(nl_json["files"][0]["asked"], false, "{nl_json}");
    assert_eq!(nl_json["files"][0]["reason"], "no_server", "{nl_json}");
    assert!(nl_json["files"][0].get("first_time").is_none(), "{nl_json}");

    // Untrusted language alone -> asked == 0 -> isError:true, first_time true then false.
    let (tr_err1, tr_text1) = srv.call_tool_raw("what_broke", json!({"files": ["a.tr"]}));
    assert!(tr_err1, "expected isError:true for untrusted file: {tr_text1}");
    let tr_json1: Value = serde_json::from_str(&tr_text1).expect("valid JSON");
    assert_eq!(tr_json1["files"][0]["reason"], "untrusted", "{tr_json1}");
    assert_eq!(tr_json1["files"][0]["first_time"], true, "{tr_json1}");

    let (tr_err2, tr_text2) = srv.call_tool_raw("what_broke", json!({"files": ["a.tr"]}));
    assert!(tr_err2, "expected isError:true for untrusted file: {tr_text2}");
    let tr_json2: Value = serde_json::from_str(&tr_text2).expect("valid JSON");
    assert_eq!(tr_json2["files"][0]["reason"], "untrusted", "{tr_json2}");
    assert_eq!(tr_json2["files"][0]["first_time"], false, "{tr_json2}");

    // Mixed: one asked file + one unasked file -> asked > 0 -> isError:false.
    let mixed = srv.call_tool("what_broke", json!({"files": ["b.fake", "note.nl"]}));
    assert_eq!(mixed["files"][0]["asked"], true, "{mixed}");
    assert_eq!(mixed["files"][1]["asked"], false, "{mixed}");

    assert_eq!(srv.close_and_wait(), 0);
}

// The four Spread-Wings tools report where spread-wings was looked for when missing.
#[test]
fn wings_tools_missing_spread_wings_return_error() {
    let mut srv = Server::start_initialized_with_env(
        "wings-missing",
        &[("SWAN_SPREAD_WINGS", "/nonexistent/spread-wings")],
    );

    for (tool, args) in [
        ("repo_projects", json!({})),
        ("repo_overview", json!({})),
        ("what_touches", json!({"name": "Store"})),
        ("file_neighbors", json!({"relative_path": "src/store.ts"})),
    ] {
        let (is_error, text) = srv.call_tool_raw(tool, args);
        assert!(is_error, "expected error for {tool}, got: {text}");
        assert!(
            text.contains("SWAN_SPREAD_WINGS is /nonexistent/spread-wings, which is not there"),
            "{tool}: {text}"
        );
    }

    assert_eq!(srv.close_and_wait(), 0);
}

// what_touches and file_neighbors validate their required arguments before running Spread-Wings.
#[test]
fn wings_tools_validate_required_arguments() {
    let mut srv = Server::start_initialized_with_env(
        "wings-args",
        &[("SWAN_SPREAD_WINGS", "/nonexistent/spread-wings")],
    );

    let (e1, t1) = srv.call_tool_raw("what_touches", json!({}));
    assert!(e1, "expected error, got: {t1}");
    assert!(t1.contains("name is required"), "{t1}");

    let (e2, t2) = srv.call_tool_raw("file_neighbors", json!({}));
    assert!(e2, "expected error, got: {t2}");
    assert!(t2.contains("relative_path is required"), "{t2}");

    assert_eq!(srv.close_and_wait(), 0);
}

// get_callers without spread-wings still returns exact callers and adds
// possible_callers with checked:false and why; ambiguous targets omit it.
#[test]
fn get_callers_possible_callers_without_spread_wings_reports_unchecked() {
    let mut srv = Server::start_initialized_with_env(
        "callers-no-wings",
        &[("SWAN_SPREAD_WINGS", "/nonexistent/spread-wings")],
    );

    let res = srv.call_tool("get_callers", json!({"name_path": "Store/total"}));
    assert!(!res["callers"].as_array().unwrap().is_empty(), "{res}");
    assert!(res["summary"]["symbols"].as_i64().unwrap_or(0) > 0, "{res}");
    let pc = &res["possible_callers"];
    assert_eq!(pc["checked"], false, "{res}");
    assert!(
        pc["why"]
            .as_str()
            .unwrap_or("")
            .contains("SWAN_SPREAD_WINGS is /nonexistent/spread-wings"),
        "{res}"
    );
    assert!(pc.get("sites").is_none(), "{res}");

    // Ambiguous target returns targets only and omits possible_callers.
    let amb = srv.call_tool("get_callers", json!({"name_path": "total"}));
    assert_eq!(amb["ambiguous"], true, "{amb}");
    assert!(amb.get("possible_callers").is_none(), "{amb}");

    assert_eq!(srv.close_and_wait(), 0);
}

// End-to-end Spread-Wings tools against real bin/spread-wings and bin/eggshell.
#[test]
#[ignore = "requires bin/eggshell and bin/spread-wings not present in this scratch copy"]
fn wings_tools_end_to_end_with_spread_wings() {
    let mut srv = Server::start_initialized("wings-e2e");
    let proj = srv.call_tool("repo_projects", json!({}));
    assert_eq!(proj["source"], "spread-wings", "{proj}");
    assert!(proj["in_folders_git_ignores"].is_array(), "{proj}");
    assert!(proj["result"].is_object(), "{proj}");

    let ov = srv.call_tool("repo_overview", json!({}));
    assert_eq!(ov["source"], "spread-wings", "{ov}");
    assert!(ov["evidence"].as_str().unwrap_or("").contains("not resolved by a compiler"), "{ov}");
    assert!(ov["result"]["communities"].is_array(), "{ov}");

    let tc = srv.call_tool("what_touches", json!({"name": "makeStore"}));
    assert_eq!(tc["source"], "spread-wings", "{tc}");
    assert!(tc["result"]["files"].is_array(), "{tc}");

    let nb = srv.call_tool("file_neighbors", json!({"relative_path": "src/main.ts"}));
    assert_eq!(nb["source"], "spread-wings", "{nb}");
    assert!(nb["result"].is_object(), "{nb}");

    let (bad_err, bad_text) = srv.call_tool_raw("what_touches", json!({"name": "no_such_name_here"}));
    assert!(bad_err, "expected error for unknown name: {bad_text}");
    assert!(bad_text.contains("no definition named"), "{bad_text}");

    assert_eq!(srv.close_and_wait(), 0);
}
