// Forwarding of edit and run tools to a Goose `swan serve` child process.
// Started lazily on the first forwarded call with the same target (`<map>` or
// `--maps <dir>`), kept in sync with the selected repo, and ended when the
// Rust server ends.

use std::ffi::{OsStr, OsString};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::ffi::OsStrExt;
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};
use std::time::{Duration, Instant};

use rmcp::model::{CallToolResult, ContentBlock};
use serde_json::{Value, json};

use crate::serve_repo::{self, Selected};
use crate::sys;

pub const GOOSE_SERVE_ENV: &str = "SWAN_GOOSE_SERVE";

// Time to wait for the Goose child to exit after closing its stdin before
// killing it. Matches a clean shutdown without hanging on a stuck child.
const SHUTDOWN_GRACE: Duration = Duration::from_secs(2);

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ForwardTarget {
    Map(Vec<u8>),
    MapsDir(Vec<u8>),
}

pub fn is_forwarded_tool(name: &str) -> bool {
    matches!(
        name,
        "replace_symbol_body"
            | "insert_after_symbol"
            | "insert_before_symbol"
            | "rename_symbol"
            | "update_map"
            | "check_errors"
            | "run_tests"
            | "format_file"
            | "rewrite_pattern"
            | "edit_batch"
    )
}

pub struct Forward {
    child: Child,
    stdin: Option<ChildStdin>,
    stdout: BufReader<ChildStdout>,
    next_id: i64,
    synced_map: Option<Vec<u8>>,
    stopped: bool,
}

impl Forward {
    pub fn start(goose_bin: &OsStr, target: &ForwardTarget) -> Result<Self, String> {
        let mut cmd = Command::new(goose_bin);
        cmd.arg("serve");
        let synced_map = match target {
            ForwardTarget::Map(db) => {
                cmd.arg(OsStr::from_bytes(db));
                Some(db.clone())
            }
            ForwardTarget::MapsDir(dir) => {
                cmd.arg("--maps").arg(OsStr::from_bytes(dir));
                None
            }
        };
        // Inherit stderr so a chatty child cannot fill a pipe buffer and deadlock,
        // and disable self-reexec so the child stays on our stdio pipes.
        cmd.env("SWAN_NO_RESTART", "1")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit());
        let mut child = cmd.spawn().map_err(|e| {
            format!(
                "cannot start Goose server ({}): {e}",
                goose_bin.to_string_lossy()
            )
        })?;
        let stdin = child
            .stdin
            .take()
            .ok_or_else(|| "cannot open Goose server stdin".to_string())?;
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| "cannot open Goose server stdout".to_string())?;
        let mut fwd = Self {
            child,
            stdin: Some(stdin),
            stdout: BufReader::new(stdout),
            next_id: 1,
            synced_map,
            stopped: false,
        };
        if let Err(e) = fwd.handshake() {
            fwd.shutdown();
            return Err(e);
        }
        Ok(fwd)
    }

    fn write_json(&mut self, msg: &Value) -> Result<(), String> {
        let stdin = self
            .stdin
            .as_mut()
            .ok_or_else(|| "Goose server stdin is closed".to_string())?;
        serde_json::to_writer(&mut *stdin, msg)
            .map_err(|e| format!("cannot write to Goose server: {e}"))?;
        stdin
            .write_all(b"\n")
            .and_then(|()| stdin.flush())
            .map_err(|e| format!("cannot flush Goose server stdin: {e}"))
    }

    fn read_response(&mut self, expected_id: i64) -> Result<Value, String> {
        loop {
            let mut line = String::new();
            let n = self
                .stdout
                .read_line(&mut line)
                .map_err(|e| format!("cannot read from Goose server: {e}"))?;
            if n == 0 {
                return Err("Goose server closed stdout before answering".to_string());
            }
            let trimmed = line.trim();
            if trimmed.is_empty() {
                continue;
            }
            let msg: Value = serde_json::from_str(trimmed)
                .map_err(|e| format!("invalid JSON from Goose server: {e}"))?;
            // Skip JSON-RPC notifications (no id) while waiting for our reply.
            let Some(id) = msg.get("id") else {
                continue;
            };
            if id.as_i64() != Some(expected_id) {
                return Err(format!(
                    "Goose server reply id mismatch: expected {expected_id}, got {id}"
                ));
            }
            return Ok(msg);
        }
    }

    fn request(&mut self, method: &str, params: Value) -> Result<Value, String> {
        let id = self.next_id;
        self.next_id += 1;
        let req = json!({
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params,
        });
        self.write_json(&req)?;
        self.read_response(id)
    }

    fn handshake(&mut self) -> Result<(), String> {
        let reply = self.request(
            "initialize",
            json!({
                "protocolVersion": "2025-06-18",
                "capabilities": {},
                "clientInfo": {"name": "swan-forward", "version": env!("CARGO_PKG_VERSION")},
            }),
        )?;
        if let Some(err) = reply.get("error") {
            return Err(format!("Goose server initialize failed: {}", rpc_error_text(err)));
        }
        self.write_json(&json!({
            "jsonrpc": "2.0",
            "method": "notifications/initialized",
        }))
    }

    pub fn call_tool(&mut self, name: &str, args: &Value) -> Result<CallToolResult, String> {
        let reply = self.request(
            "tools/call",
            json!({
                "name": name,
                "arguments": args,
            }),
        )?;
        if let Some(err) = reply.get("error") {
            return Ok(CallToolResult::error(vec![ContentBlock::text(
                rpc_error_text(err),
            )]));
        }
        let result = reply
            .get("result")
            .cloned()
            .ok_or_else(|| "Goose server reply had neither result nor error".to_string())?;
        serde_json::from_value::<CallToolResult>(result)
            .map_err(|e| format!("unexpected tools/call result from Goose server: {e}"))
    }

    pub fn shutdown(&mut self) {
        if self.stopped {
            return;
        }
        self.stopped = true;
        drop(self.stdin.take());
        let deadline = Instant::now() + SHUTDOWN_GRACE;
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

impl Drop for Forward {
    fn drop(&mut self) {
        self.shutdown();
    }
}

fn rpc_error_text(err: &Value) -> String {
    err.get("message")
        .and_then(Value::as_str)
        .map(str::to_string)
        .unwrap_or_else(|| err.to_string())
}

fn error_result(msg: impl Into<String>) -> CallToolResult {
    CallToolResult::error(vec![ContentBlock::text(msg.into())])
}

fn cur_covers_repo(cur: &Option<Selected>, repo: &[u8]) -> bool {
    let Some(sel) = cur.as_ref() else {
        return false;
    };
    let Some(abs) = sys::realpath(repo) else {
        return false;
    };
    serve_repo::map_covers(&sel.root, &abs)
}

pub(crate) struct Forwarder {
    target: ForwardTarget,
    goose_bin_override: Option<Option<OsString>>,
    child: Option<Forward>,
}

impl Forwarder {
    pub(crate) fn new(target: ForwardTarget) -> Self {
        Self { target, goose_bin_override: None, child: None }
    }

    #[cfg(test)]
    pub(crate) fn with_bin_override(target: ForwardTarget, bin: Option<OsString>) -> Self {
        Self { target, goose_bin_override: Some(bin), child: None }
    }

    fn resolve_goose_bin(&self, name: &str) -> Result<OsString, String> {
        let val = match &self.goose_bin_override {
            Some(v) => v.clone(),
            None => std::env::var_os(GOOSE_SERVE_ENV),
        };
        match val {
            Some(v) if !v.is_empty() => Ok(v),
            _ => Err(format!(
                "{GOOSE_SERVE_ENV} is not set; cannot forward {name} to the Goose server"
            )),
        }
    }

    fn ensure_started(&mut self, name: &str) -> Result<&mut Forward, String> {
        if self.child.is_none() {
            let bin = self.resolve_goose_bin(name)?;
            let fwd = Forward::start(&bin, &self.target)?;
            self.child = Some(fwd);
        }
        Ok(self.child.as_mut().expect("child initialized"))
    }

    fn drop_dead_child(&mut self) {
        if let Some(mut child) = self.child.take() {
            child.shutdown();
        }
    }

    pub(crate) fn call(
        &mut self,
        name: &str,
        args: &Value,
        maps_root: &[u8],
        cur: &mut Option<Selected>,
    ) -> CallToolResult {
        let repo = args.get("repo").and_then(Value::as_str).unwrap_or("");
        if let Err(e) = self.ensure_started(name) {
            return error_result(e);
        }

        // When the call carries no `repo`, make sure the Goose child holds the
        // same selected map as the Rust server before forwarding the call.
        if repo.is_empty() {
            if let Some(sel) = cur.as_ref() {
                let needs_sync = self
                    .child
                    .as_ref()
                    .and_then(|c| c.synced_map.as_deref())
                    != Some(sel.map.as_slice());
                if needs_sync && !sel.root.is_empty() {
                    let root_str = String::from_utf8_lossy(&sel.root).into_owned();
                    let sync_args = json!({"path": root_str, "build": false});
                    let sync_res = match self.child.as_mut().expect("child alive").call_tool("use_repo", &sync_args) {
                        Ok(r) => r,
                        Err(e) => {
                            self.drop_dead_child();
                            return error_result(e);
                        }
                    };
                    if sync_res.is_error.unwrap_or(false) {
                        return sync_res;
                    }
                    if let Some(child) = self.child.as_mut() {
                        child.synced_map = Some(sel.map.clone());
                    }
                }
            }
        }

        let res = match self.child.as_mut().expect("child alive").call_tool(name, args) {
            Ok(r) => r,
            Err(e) => {
                self.drop_dead_child();
                return error_result(e);
            }
        };

        // Keep Rust's selection and synced_map aligned when the forwarded call
        // carried its own `repo` argument.
        if !repo.is_empty() {
            let repo_bytes = repo.as_bytes();
            let same_external = cur_covers_repo(cur, repo_bytes)
                && self
                    .child
                    .as_ref()
                    .and_then(|c| c.synced_map.as_deref())
                    == cur.as_ref().map(|s| s.map.as_slice());
            if !res.is_error.unwrap_or(false) {
                if let Ok((snap, _)) = serve_repo::select_open(maps_root, repo_bytes, false, false, cur) {
                    snap.commit();
                    if let Some(child) = self.child.as_mut() {
                        child.synced_map = cur.as_ref().map(|s| s.map.clone());
                    }
                } else if !same_external {
                    if let Some(child) = self.child.as_mut() {
                        child.synced_map = None;
                    }
                }
            } else if !same_external {
                if let Some(child) = self.child.as_mut() {
                    child.synced_map = None;
                }
            }
        }

        res
    }

    pub(crate) fn shutdown(&mut self) {
        self.drop_dead_child();
    }
}

impl Drop for Forwarder {
    fn drop(&mut self) {
        self.shutdown();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::os::unix::fs::PermissionsExt;
    use std::path::{Path, PathBuf};
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::time::{Duration, Instant};

    use serde_json::json;
    use tokio::io::{AsyncBufReadExt, AsyncRead, AsyncWrite, AsyncWriteExt, BufReader as TokioBufReader};

    use crate::serve::{SwanServer, serve_io};

    static NEXT_TMP: AtomicU64 = AtomicU64::new(1);

    struct ScratchDir(PathBuf);

    impl ScratchDir {
        fn new(name: &str) -> Self {
            let n = NEXT_TMP.fetch_add(1, Ordering::Relaxed);
            let p = std::env::temp_dir()
                .join(format!("swan-forward-unit-{}-{name}-{n}", std::process::id()));
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

    // Writes an executable stub script that behaves like a Goose MCP server:
    // answers initialize, ignores notifications, records argv/pid/calls, and
    // echoes tools/call arguments back (with special modes for error/stubborn tests).
    fn write_stub_goose(dir: &Path, log_path: &Path, pid_path: &Path, ignore_eof: bool) -> PathBuf {
        let py = dir.join("stub_goose.py");
        let sh = dir.join("stub_goose.sh");
        let script = format!(
            r#"import json, os, sys, time

log_path = {log:?}
pid_path = {pid:?}
ignore_eof = {ignore_eof}

with open(pid_path, "w") as f:
    f.write(str(os.getpid()))

with open(log_path, "a") as f:
    f.write(json.dumps({{"event": "start", "argv": sys.argv[1:]}}) + "\n")

for raw in sys.stdin:
    line = raw.strip()
    if not line:
        continue
    msg = json.loads(line)
    with open(log_path, "a") as f:
        f.write(json.dumps({{"event": "recv", "msg": msg}}) + "\n")
    if "id" not in msg:
        continue
    mid = msg["id"]
    method = msg.get("method", "")
    if method == "initialize":
        resp = {{
            "jsonrpc": "2.0",
            "id": mid,
            "result": {{
                "protocolVersion": "2025-06-18",
                "capabilities": {{"tools": {{"listChanged": True}}}},
                "serverInfo": {{"name": "swan", "version": "0.1.0"}},
            }},
        }}
    elif method == "tools/call":
        params = msg.get("params", {{}})
        name = params.get("name", "")
        arguments = params.get("arguments", {{}})
        if arguments.get("__crash"):
            sys.exit(1)
        elif arguments.get("__jsonrpc_error"):
            resp = {{
                "jsonrpc": "2.0",
                "id": mid,
                "error": {{"code": -32000, "message": arguments["__jsonrpc_error"]}},
            }}
        elif arguments.get("__tool_error"):
            resp = {{
                "jsonrpc": "2.0",
                "id": mid,
                "result": {{
                    "content": [{{"type": "text", "text": arguments["__tool_error"]}}],
                    "isError": True,
                }},
            }}
        elif name == "use_repo":
            resp = {{
                "jsonrpc": "2.0",
                "id": mid,
                "result": {{
                    "content": [{{"type": "text", "text": json.dumps({{"switched": True, "root": arguments.get("path", "")}})}}],
                    "isError": False,
                }},
            }}
        else:
            echo = {{"echo_tool": name, "echo_args": arguments, "argv": sys.argv[1:]}}
            resp = {{
                "jsonrpc": "2.0",
                "id": mid,
                "result": {{
                    "content": [{{"type": "text", "text": json.dumps(echo)}}],
                    "isError": False,
                }},
            }}
    else:
        resp = {{"jsonrpc": "2.0", "id": mid, "error": {{"code": -32601, "message": "unknown"}}}}
    sys.stdout.write(json.dumps(resp) + "\n")
    sys.stdout.flush()

if ignore_eof:
    time.sleep(30)
"#,
            log = log_path.to_str().unwrap(),
            pid = pid_path.to_str().unwrap(),
            ignore_eof = if ignore_eof { "True" } else { "False" },
        );
        fs::write(&py, script).unwrap();
        let wrapper = format!(
            "#!/bin/sh\nexec {} -I {} \"$@\"\n",
            python(),
            py.to_str().unwrap()
        );
        fs::write(&sh, wrapper).unwrap();
        fs::set_permissions(&sh, fs::Permissions::from_mode(0o755)).unwrap();
        sh
    }

    fn read_log(log_path: &Path) -> Vec<Value> {
        if !log_path.exists() {
            return Vec::new();
        }
        fs::read_to_string(log_path)
            .unwrap()
            .lines()
            .filter(|l| !l.trim().is_empty())
            .map(|l| serde_json::from_str(l).unwrap())
            .collect()
    }

    fn pid_alive(pid: i32) -> bool {
        unsafe { libc::kill(pid, 0) == 0 }
    }

    fn install_minimal_map(maps_dir: &Path, name: &str, repo_root: &Path) -> PathBuf {
        let map_dir = maps_dir.join(name);
        fs::create_dir_all(&map_dir).unwrap();
        let db_path = map_dir.join("swan.db");
        let db = crate::db::Db::open(db_path.to_str().unwrap().as_bytes()).unwrap();
        db.exec_or_die(b"CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);");
        db.exec_or_die(
            b"CREATE TABLE files (file TEXT PRIMARY KEY, hash TEXT NOT NULL, rows INTEGER NOT NULL, edited_mtime INTEGER);",
        );
        let sql = format!(
            "INSERT INTO meta VALUES ('schema_version', '{}'), ('root', '{}'), ('source', '{}'), ('symbols', '1'), ('files', '1');",
            crate::index::SCHEMA_VERSION,
            repo_root.to_str().unwrap().replace('\'', "''"),
            map_dir.to_str().unwrap().replace('\'', "''"),
        );
        db.exec_or_die(sql.as_bytes());
        drop(db);
        db_path
    }

    async fn send_line<W: AsyncWrite + Unpin>(w: &mut W, msg: &str) {
        w.write_all(msg.as_bytes()).await.unwrap();
        w.write_all(b"\n").await.unwrap();
        w.flush().await.unwrap();
    }

    async fn recv_json<R: AsyncRead + Unpin>(r: &mut TokioBufReader<R>) -> Value {
        let mut line = String::new();
        let n = r.read_line(&mut line).await.unwrap();
        assert!(n > 0, "server closed before answering");
        serde_json::from_str(&line).unwrap_or_else(|e| panic!("invalid JSON reply {line:?}: {e}"))
    }

    async fn handshake<W: AsyncWrite + Unpin, R: AsyncRead + Unpin>(
        w: &mut W,
        r: &mut TokioBufReader<R>,
    ) {
        send_line(
            w,
            r#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"0"}}}"#,
        )
        .await;
        let reply = recv_json(r).await;
        assert_eq!(reply["result"]["serverInfo"]["name"], "swan", "{reply}");
        send_line(w, r#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#).await;
    }

    #[tokio::test(flavor = "current_thread")]
    async fn a_tool_the_rust_server_lacks_is_answered_by_the_goose_server() {
        let tmp = ScratchDir::new("echo");
        let log_path = tmp.path().join("stub.log");
        let pid_path = tmp.path().join("stub.pid");
        let stub = write_stub_goose(tmp.path(), &log_path, &pid_path, false);
        let db = install_minimal_map(tmp.path(), "m", tmp.path());

        let server = SwanServer::for_map_with_goose_bin(
            tmp.path().to_str().unwrap().as_bytes().to_vec(),
            Selected {
                root: tmp.path().to_str().unwrap().as_bytes().to_vec(),
                map: db.to_str().unwrap().as_bytes().to_vec(),
            },
            Some(stub.into_os_string()),
        );
        let (mut client_w, server_r) = tokio::io::duplex(256 * 1024);
        let (server_w, client_r) = tokio::io::duplex(256 * 1024);
        let task = tokio::spawn(serve_io(server, server_r, server_w));
        let mut reader = TokioBufReader::new(client_r);
        handshake(&mut client_w, &mut reader).await;

        // Child is started lazily on first forwarded call, not on initialize or tools/list.
        send_line(&mut client_w, r#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#).await;
        let list_reply = recv_json(&mut reader).await;
        let tools = list_reply["result"]["tools"].as_array().expect("tools array");
        assert_eq!(tools.len(), 28, "{list_reply}");
        assert!(!pid_path.exists(), "child should not start before a forwarded tool call");

        // Forwarded call returns child's answer unchanged.
        send_line(
            &mut client_w,
            r#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"rename_symbol","arguments":{"name_path":"format","relative_path":"src/format.ts","new_name":"formatEntry"}}}"#,
        )
        .await;
        let reply = recv_json(&mut reader).await;
        assert_eq!(reply["id"], 3);
        assert_ne!(reply["result"]["isError"], true, "{reply}");
        let text = reply["result"]["content"][0]["text"].as_str().unwrap();
        let echoed: Value = serde_json::from_str(text).unwrap();
        assert_eq!(echoed["echo_tool"], "rename_symbol", "{echoed}");
        assert_eq!(echoed["echo_args"]["new_name"], "formatEntry", "{echoed}");
        assert_eq!(echoed["argv"], json!(["serve", db.to_str().unwrap()]), "{echoed}");

        // Forwarded error answer (isError: true) also comes back unchanged.
        send_line(
            &mut client_w,
            r#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"replace_symbol_body","arguments":{"__tool_error":"conflict in file"}}}"#,
        )
        .await;
        let err_reply = recv_json(&mut reader).await;
        assert_eq!(err_reply["result"]["isError"], true, "{err_reply}");
        assert_eq!(err_reply["result"]["content"][0]["text"], "conflict in file", "{err_reply}");

        // serve <map> target already has that map open, so no spurious use_repo was sent.
        let log_entries = read_log(&log_path);
        let calls: Vec<&str> = log_entries
            .iter()
            .filter(|e| e["event"] == "recv" && e["msg"]["method"] == "tools/call")
            .filter_map(|e| e["msg"]["params"]["name"].as_str())
            .collect();
        assert_eq!(calls, vec!["rename_symbol", "replace_symbol_body"]);

        drop(client_w);
        assert_eq!(task.await.unwrap(), 0);
    }

    #[tokio::test(flavor = "current_thread")]
    async fn selection_reaches_the_child_when_changed() {
        let tmp = ScratchDir::new("selection");
        let log_path = tmp.path().join("stub.log");
        let pid_path = tmp.path().join("stub.pid");
        let stub = write_stub_goose(tmp.path(), &log_path, &pid_path, false);

        let maps_dir = tmp.path().join("maps");
        let repo_a = tmp.path().join("repo_a");
        let repo_b = tmp.path().join("repo_b");
        fs::create_dir_all(&repo_a).unwrap();
        fs::create_dir_all(&repo_b).unwrap();
        install_minimal_map(&maps_dir, "repo_a", &repo_a);
        install_minimal_map(&maps_dir, "repo_b", &repo_b);

        let server = SwanServer::for_maps_with_goose_bin(
            maps_dir.to_str().unwrap().as_bytes().to_vec(),
            Some(stub.into_os_string()),
        );
        let (mut client_w, server_r) = tokio::io::duplex(256 * 1024);
        let (server_w, client_r) = tokio::io::duplex(256 * 1024);
        let task = tokio::spawn(serve_io(server, server_r, server_w));
        let mut reader = TokioBufReader::new(client_r);
        handshake(&mut client_w, &mut reader).await;

        // 1. Select repo_a on the Rust server. Child stays unspawned.
        let use_a = json!({
            "jsonrpc": "2.0", "id": 2, "method": "tools/call",
            "params": {"name": "use_repo", "arguments": {"path": repo_a.to_str().unwrap()}}
        });
        send_line(&mut client_w, &use_a.to_string()).await;
        let r2 = recv_json(&mut reader).await;
        assert_ne!(r2["result"]["isError"], true, "{r2}");
        assert!(!pid_path.exists(), "use_repo alone must not spawn the Goose child");

        // 2. First forwarded call spawns child with --maps <dir> and syncs repo_a via use_repo.
        send_line(
            &mut client_w,
            r#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"rename_symbol","arguments":{"name_path":"a","relative_path":"a.ts","new_name":"b"}}}"#,
        )
        .await;
        let r3 = recv_json(&mut reader).await;
        assert_ne!(r3["result"]["isError"], true, "{r3}");
        let echoed3: Value = serde_json::from_str(r3["result"]["content"][0]["text"].as_str().unwrap()).unwrap();
        assert_eq!(
            echoed3["argv"],
            json!(["serve", "--maps", maps_dir.to_str().unwrap()]),
            "{echoed3}"
        );

        // 3. Second forwarded call with same selection does not resend use_repo.
        send_line(
            &mut client_w,
            r#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"format_file","arguments":{"relative_path":"a.ts"}}}"#,
        )
        .await;
        let r4 = recv_json(&mut reader).await;
        assert_ne!(r4["result"]["isError"], true, "{r4}");

        // 4. Switch to repo_b on Rust, then forward edit_batch: child receives use_repo for repo_b.
        let use_b = json!({
            "jsonrpc": "2.0", "id": 5, "method": "tools/call",
            "params": {"name": "use_repo", "arguments": {"path": repo_b.to_str().unwrap()}}
        });
        send_line(&mut client_w, &use_b.to_string()).await;
        let r5 = recv_json(&mut reader).await;
        assert_ne!(r5["result"]["isError"], true, "{r5}");

        send_line(
            &mut client_w,
            r#"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"edit_batch","arguments":{"edits":[]}}}"#,
        )
        .await;
        let r6 = recv_json(&mut reader).await;
        assert_ne!(r6["result"]["isError"], true, "{r6}");

        // 5. Forwarded call carrying `repo` switches the child and updates Rust's selection.
        let upd_a = json!({
            "jsonrpc": "2.0", "id": 7, "method": "tools/call",
            "params": {"name": "update_map", "arguments": {"repo": repo_a.to_str().unwrap(), "build": false}}
        });
        send_line(&mut client_w, &upd_a.to_string()).await;
        let r7 = recv_json(&mut reader).await;
        assert_ne!(r7["result"]["isError"], true, "{r7}");

        // Native index_info now answers about repo_a because the repo switch persisted.
        send_line(
            &mut client_w,
            r#"{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"index_info","arguments":{}}}"#,
        )
        .await;
        let r8 = recv_json(&mut reader).await;
        assert_ne!(r8["result"]["isError"], true, "{r8}");
        let info: Value = serde_json::from_str(r8["result"]["content"][0]["text"].as_str().unwrap()).unwrap();
        assert_eq!(info["root"], repo_a.to_str().unwrap(), "{info}");

        let tool_calls: Vec<(String, Value)> = read_log(&log_path)
            .into_iter()
            .filter(|e| e["event"] == "recv" && e["msg"]["method"] == "tools/call")
            .map(|e| {
                (
                    e["msg"]["params"]["name"].as_str().unwrap().to_string(),
                    e["msg"]["params"]["arguments"].clone(),
                )
            })
            .collect();
        let names: Vec<&str> = tool_calls.iter().map(|(n, _)| n.as_str()).collect();
        assert_eq!(
            names,
            vec!["use_repo", "rename_symbol", "format_file", "use_repo", "edit_batch", "update_map"],
            "{tool_calls:?}"
        );
        assert_eq!(tool_calls[0].1["path"], repo_a.to_str().unwrap());
        assert_eq!(tool_calls[0].1["build"], false);
        assert_eq!(tool_calls[3].1["path"], repo_b.to_str().unwrap());
        assert_eq!(tool_calls[3].1["build"], false);

        drop(client_w);
        assert_eq!(task.await.unwrap(), 0);
    }

    #[test]
    fn unset_swan_goose_serve_is_an_error() {
        let mut fwd = Forwarder::with_bin_override(ForwardTarget::MapsDir(Vec::new()), None);
        let mut cur = None;
        let res = fwd.call("rename_symbol", &json!({}), b"", &mut cur);
        assert_eq!(res.is_error, Some(true), "{res:?}");
        let text = serde_json::to_value(&res).unwrap()["content"][0]["text"]
            .as_str()
            .unwrap()
            .to_string();
        assert!(text.contains(GOOSE_SERVE_ENV), "expected {GOOSE_SERVE_ENV} in error: {text}");

        // Empty string is also treated as unset.
        let mut fwd_empty = Forwarder::with_bin_override(
            ForwardTarget::MapsDir(Vec::new()),
            Some(OsString::new()),
        );
        let res2 = fwd_empty.call("update_map", &json!({}), b"", &mut cur);
        assert_eq!(res2.is_error, Some(true), "{res2:?}");
        let text2 = serde_json::to_value(&res2).unwrap()["content"][0]["text"]
            .as_str()
            .unwrap()
            .to_string();
        assert!(text2.contains(GOOSE_SERVE_ENV), "expected {GOOSE_SERVE_ENV} in error: {text2}");
    }

    #[tokio::test(flavor = "current_thread")]
    async fn dead_child_recovers_and_resyncs_selection_on_next_call() {
        let tmp = ScratchDir::new("dead-child");
        let log_path = tmp.path().join("stub.log");
        let pid_path = tmp.path().join("stub.pid");
        let stub = write_stub_goose(tmp.path(), &log_path, &pid_path, false);

        let maps_dir = tmp.path().join("maps");
        let repo_a = tmp.path().join("repo_a");
        fs::create_dir_all(&repo_a).unwrap();
        install_minimal_map(&maps_dir, "repo_a", &repo_a);

        let server = SwanServer::for_maps_with_goose_bin(
            maps_dir.to_str().unwrap().as_bytes().to_vec(),
            Some(stub.into_os_string()),
        );
        let (mut client_w, server_r) = tokio::io::duplex(256 * 1024);
        let (server_w, client_r) = tokio::io::duplex(256 * 1024);
        let task = tokio::spawn(serve_io(server, server_r, server_w));
        let mut reader = TokioBufReader::new(client_r);
        handshake(&mut client_w, &mut reader).await;

        let use_a = json!({
            "jsonrpc": "2.0", "id": 2, "method": "tools/call",
            "params": {"name": "use_repo", "arguments": {"path": repo_a.to_str().unwrap()}}
        });
        send_line(&mut client_w, &use_a.to_string()).await;
        let r2 = recv_json(&mut reader).await;
        assert_ne!(r2["result"]["isError"], true, "{r2}");

        // First forwarded call spawns child #1 and syncs repo_a.
        send_line(
            &mut client_w,
            r#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"rename_symbol","arguments":{"name_path":"a","relative_path":"a.ts","new_name":"b"}}}"#,
        )
        .await;
        let r3 = recv_json(&mut reader).await;
        assert_ne!(r3["result"]["isError"], true, "{r3}");
        let pid1: i32 = fs::read_to_string(&pid_path).unwrap().trim().parse().unwrap();

        // Child #1 crashes mid-call: Rust returns an MCP error and reaps child #1.
        send_line(
            &mut client_w,
            r#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"format_file","arguments":{"__crash":true}}}"#,
        )
        .await;
        let r4 = recv_json(&mut reader).await;
        assert_eq!(r4["result"]["isError"], true, "{r4}");
        assert!(
            r4["result"]["content"][0]["text"]
                .as_str()
                .unwrap_or("")
                .contains("closed stdout"),
            "{r4}"
        );
        let deadline = Instant::now() + Duration::from_millis(500);
        while pid_alive(pid1) && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(10));
        }
        assert!(!pid_alive(pid1), "crashed child {pid1} should be reaped");

        // Next forwarded call respawns child #2, re-syncs repo_a, and succeeds.
        send_line(
            &mut client_w,
            r#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"edit_batch","arguments":{"edits":[]}}}"#,
        )
        .await;
        let r5 = recv_json(&mut reader).await;
        assert_ne!(r5["result"]["isError"], true, "{r5}");
        let pid2: i32 = fs::read_to_string(&pid_path).unwrap().trim().parse().unwrap();
        assert_ne!(pid2, pid1, "recovery must spawn a fresh child");

        let log_entries = read_log(&log_path);
        let starts = log_entries.iter().filter(|e| e["event"] == "start").count();
        assert_eq!(starts, 2, "{log_entries:?}");
        let calls: Vec<&str> = log_entries
            .iter()
            .filter(|e| e["event"] == "recv" && e["msg"]["method"] == "tools/call")
            .filter_map(|e| e["msg"]["params"]["name"].as_str())
            .collect();
        assert_eq!(
            calls,
            vec!["use_repo", "rename_symbol", "format_file", "use_repo", "edit_batch"]
        );

        drop(client_w);
        assert_eq!(task.await.unwrap(), 0);
        let deadline2 = Instant::now() + Duration::from_millis(500);
        while pid_alive(pid2) && Instant::now() < deadline2 {
            std::thread::sleep(Duration::from_millis(10));
        }
        assert!(!pid_alive(pid2), "recovered child {pid2} should exit with server");
    }

    #[tokio::test(flavor = "current_thread")]
    async fn child_is_gone_after_server_ends() {
        for (label, ignore_eof) in [("clean-eof", false), ("stubborn-child", true)] {
            let tmp = ScratchDir::new(label);
            let log_path = tmp.path().join("stub.log");
            let pid_path = tmp.path().join("stub.pid");
            let stub = write_stub_goose(tmp.path(), &log_path, &pid_path, ignore_eof);

            let server = SwanServer::for_maps_with_goose_bin(
                tmp.path().to_str().unwrap().as_bytes().to_vec(),
                Some(stub.into_os_string()),
            );
            let (mut client_w, server_r) = tokio::io::duplex(64 * 1024);
            let (server_w, client_r) = tokio::io::duplex(64 * 1024);
            let task = tokio::spawn(serve_io(server, server_r, server_w));
            let mut reader = TokioBufReader::new(client_r);
            handshake(&mut client_w, &mut reader).await;

            send_line(
                &mut client_w,
                r#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"check_errors","arguments":{}}}"#,
            )
            .await;
            let reply = recv_json(&mut reader).await;
            assert_ne!(reply["result"]["isError"], true, "{label}: {reply}");

            let pid: i32 = fs::read_to_string(&pid_path).unwrap().trim().parse().unwrap();
            assert!(pid_alive(pid), "{label}: child {pid} should be alive while server runs");

            drop(client_w);
            assert_eq!(task.await.unwrap(), 0);

            // Child must be exited and reaped before serve_io returns.
            let deadline = Instant::now() + Duration::from_millis(500);
            while pid_alive(pid) && Instant::now() < deadline {
                std::thread::sleep(Duration::from_millis(10));
            }
            assert!(!pid_alive(pid), "{label}: child {pid} is still alive after server ended");
        }
    }

    #[tokio::test(flavor = "current_thread")]
    async fn child_jsonrpc_error_becomes_mcp_tool_error() {
        let tmp = ScratchDir::new("rpc-err");
        let log_path = tmp.path().join("stub.log");
        let pid_path = tmp.path().join("stub.pid");
        let stub = write_stub_goose(tmp.path(), &log_path, &pid_path, false);

        let server = SwanServer::for_maps_with_goose_bin(
            tmp.path().to_str().unwrap().as_bytes().to_vec(),
            Some(stub.into_os_string()),
        );
        let (mut client_w, server_r) = tokio::io::duplex(64 * 1024);
        let (server_w, client_r) = tokio::io::duplex(64 * 1024);
        let task = tokio::spawn(serve_io(server, server_r, server_w));
        let mut reader = TokioBufReader::new(client_r);
        handshake(&mut client_w, &mut reader).await;

        send_line(
            &mut client_w,
            r#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"run_tests","arguments":{"__jsonrpc_error":"child protocol error"}}}"#,
        )
        .await;
        let reply = recv_json(&mut reader).await;
        assert_eq!(reply["result"]["isError"], true, "{reply}");
        assert!(
            reply["result"]["content"][0]["text"]
                .as_str()
                .unwrap_or("")
                .contains("child protocol error"),
            "{reply}"
        );

        // Server stays up and forwards the next call.
        send_line(
            &mut client_w,
            r#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"rewrite_pattern","arguments":{"pattern":"a","rewrite":"b"}}}"#,
        )
        .await;
        let reply2 = recv_json(&mut reader).await;
        assert_ne!(reply2["result"]["isError"], true, "{reply2}");

        drop(client_w);
        assert_eq!(task.await.unwrap(), 0);
    }

    #[tokio::test(flavor = "current_thread")]
    async fn serve_map_outside_maps_root_preserves_selection_on_repo_arg() {
        let tmp = ScratchDir::new("outside-map");
        let log_path = tmp.path().join("stub.log");
        let pid_path = tmp.path().join("stub.pid");
        let stub = write_stub_goose(tmp.path(), &log_path, &pid_path, false);

        let empty_maps = tmp.path().join("empty_maps");
        let repo = tmp.path().join("repo");
        let external = tmp.path().join("external");
        fs::create_dir_all(&empty_maps).unwrap();
        fs::create_dir_all(&repo).unwrap();
        let db = install_minimal_map(&external, "custom", &repo);

        let server = SwanServer::for_map_with_goose_bin(
            empty_maps.to_str().unwrap().as_bytes().to_vec(),
            Selected {
                root: repo.to_str().unwrap().as_bytes().to_vec(),
                map: db.to_str().unwrap().as_bytes().to_vec(),
            },
            Some(stub.into_os_string()),
        );
        let (mut client_w, server_r) = tokio::io::duplex(256 * 1024);
        let (server_w, client_r) = tokio::io::duplex(256 * 1024);
        let task = tokio::spawn(serve_io(server, server_r, server_w));
        let mut reader = TokioBufReader::new(client_r);
        handshake(&mut client_w, &mut reader).await;

        // Forwarded call passes `repo` covering the same external map's root.
        let req = json!({
            "jsonrpc": "2.0", "id": 2, "method": "tools/call",
            "params": {"name": "rename_symbol", "arguments": {"repo": repo.to_str().unwrap(), "name_path": "x", "relative_path": "a.ts", "new_name": "y"}}
        });
        send_line(&mut client_w, &req.to_string()).await;
        let r2 = recv_json(&mut reader).await;
        assert_ne!(r2["result"]["isError"], true, "{r2}");

        // Next forwarded call without `repo` must NOT send a spurious use_repo
        // (which would fail because the map is outside maps_root).
        send_line(
            &mut client_w,
            r#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"format_file","arguments":{"relative_path":"a.ts"}}}"#,
        )
        .await;
        let r3 = recv_json(&mut reader).await;
        assert_ne!(r3["result"]["isError"], true, "{r3}");

        // Native index_info still answers about the external map's root.
        send_line(
            &mut client_w,
            r#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"index_info","arguments":{}}}"#,
        )
        .await;
        let r4 = recv_json(&mut reader).await;
        assert_ne!(r4["result"]["isError"], true, "{r4}");
        let info: Value = serde_json::from_str(r4["result"]["content"][0]["text"].as_str().unwrap()).unwrap();
        assert_eq!(info["root"], repo.to_str().unwrap(), "{info}");

        let log_entries = read_log(&log_path);
        let calls: Vec<&str> = log_entries
            .iter()
            .filter(|e| e["event"] == "recv" && e["msg"]["method"] == "tools/call")
            .filter_map(|e| e["msg"]["params"]["name"].as_str())
            .collect();
        assert_eq!(calls, vec!["rename_symbol", "format_file"]);

        drop(client_w);
        assert_eq!(task.await.unwrap(), 0);
    }

    #[test]
    fn is_forwarded_tool_matches_exact_ten_tools() {
        let expected = [
            "replace_symbol_body",
            "insert_after_symbol",
            "insert_before_symbol",
            "rename_symbol",
            "update_map",
            "check_errors",
            "run_tests",
            "format_file",
            "rewrite_pattern",
            "edit_batch",
        ];
        for t in expected {
            assert!(is_forwarded_tool(t), "{t} should be forwarded");
        }
        for t in [
            "use_repo",
            "find_symbol",
            "what_broke",
            "repo_projects",
            "index_info",
            "no_such_tool",
        ] {
            assert!(!is_forwarded_tool(t), "{t} should not be forwarded");
        }
    }
}
