// `swan serve`: MCP server over stdin and stdout, built on rmcp.
// Each tool request reopens the map path in a read transaction so completed
// map replacements, refreshes and disk edits are seen on the next call.

use std::io::Write;
use std::sync::{Arc, Mutex};

use rmcp::{
    ErrorData as McpError, RoleServer, ServerHandler,
    model::{
        CallToolRequestParams, CallToolResponse, CallToolResult, ContentBlock, Implementation,
        ListToolsResult, PaginatedRequestParams, ProtocolVersion, ServerCapabilities, ServerConfig,
    },
    service::{QuitReason, RequestContext, ServerInitializeError, serve_server},
};
use tokio::io::{AsyncRead, AsyncWrite};

use crate::db::Db;
use crate::fresh::Fresh;
use crate::index::SCHEMA_VERSION;
use crate::query::meta_value;
use crate::run;
use crate::serve_forward::{self, ForwardTarget, Forwarder};
use crate::serve_read;
use crate::serve_repo::{self, Selected};
use crate::serve_tools;
use crate::serve_wings;
use crate::util::rfind;

// The directory containing `map_path`, or "." when `map_path` has no slash.
pub(crate) fn map_dir_of(map_path: &[u8]) -> &[u8] {
    let slash = rfind(map_path, b"/");
    if slash > 0 {
        &map_path[..slash as usize]
    } else if slash == 0 {
        b"/"
    } else {
        b"."
    }
}

// Holds one database generation for a read tool. `fresh` owns a prepared
// statement on `db`, so it is declared first to drop before `db` closes.
pub(crate) struct MapSnapshot {
    pub(crate) fresh: Fresh,
    pub(crate) db: Db,
    in_tx: bool,
}

impl MapSnapshot {
    pub(crate) fn end_tx(&mut self) {
        if self.in_tx {
            let _ = self.db.exec(b"COMMIT;");
            self.in_tx = false;
        }
    }

    pub(crate) fn commit(mut self) {
        self.end_tx();
        drop(self.fresh);
        drop(self.db);
    }
}

// Reopens the map path in a read transaction, checks its schema version and
// optional repo coverage, and loads freshness state for this connection.
pub(crate) fn open_map_snapshot_for(db_path: &[u8], repo: &[u8]) -> Result<MapSnapshot, Vec<u8>> {
    let db = Db::open_existing(db_path)
        .map_err(|e| [b"swan: cannot open map ", db_path, b": ", &e[..]].concat())?;
    db.exec(b"BEGIN;")
        .map_err(|e| [b"swan: cannot start map read: ", &e[..]].concat())?;
    let version = serve_repo::meta_try(&db, b"schema_version")
        .map_err(|e| [b"swan: cannot read map ", db_path, b": ", &e[..]].concat())?;
    let root = serve_repo::meta_try(&db, b"root")
        .map_err(|e| [b"swan: cannot read map ", db_path, b": ", &e[..]].concat())?;
    let _source = serve_repo::meta_try(&db, b"source")
        .map_err(|e| [b"swan: cannot read map ", db_path, b": ", &e[..]].concat())?;
    let reads = SCHEMA_VERSION.to_string().into_bytes();
    if version != reads {
        return Err([
            b"swan: index schema ",
            &version[..],
            b", this swan reads ",
            &reads[..],
            b"; rebuild the map",
        ]
        .concat());
    }
    if !repo.is_empty() && !serve_repo::map_covers(&root, repo) {
        return Err([
            b"swan: map changed during repository selection; retry use_repo for ",
            repo,
        ]
        .concat());
    }
    let fresh = Fresh::load(&db);
    Ok(MapSnapshot { fresh, db, in_tx: true })
}

pub(crate) fn open_map_snapshot(db_path: &[u8]) -> Result<MapSnapshot, Vec<u8>> {
    open_map_snapshot_for(db_path, b"")
}

#[derive(Clone)]
pub(crate) struct SwanServer {
    maps_root: Vec<u8>,
    selected: Arc<Mutex<Option<Selected>>>,
    forward: Arc<Mutex<Forwarder>>,
}

impl SwanServer {
    fn for_map(maps_root: Vec<u8>, selected: Selected) -> Self {
        let target = ForwardTarget::Map(selected.map.clone());
        Self {
            maps_root,
            selected: Arc::new(Mutex::new(Some(selected))),
            forward: Arc::new(Mutex::new(Forwarder::new(target))),
        }
    }

    fn for_maps(maps_root: Vec<u8>) -> Self {
        let target = ForwardTarget::MapsDir(maps_root.clone());
        Self {
            maps_root,
            selected: Arc::new(Mutex::new(None)),
            forward: Arc::new(Mutex::new(Forwarder::new(target))),
        }
    }

    #[cfg(test)]
    pub(crate) fn for_map_with_goose_bin(
        maps_root: Vec<u8>,
        selected: Selected,
        bin: Option<std::ffi::OsString>,
    ) -> Self {
        let target = ForwardTarget::Map(selected.map.clone());
        Self {
            maps_root,
            selected: Arc::new(Mutex::new(Some(selected))),
            forward: Arc::new(Mutex::new(Forwarder::with_bin_override(target, bin))),
        }
    }

    #[cfg(test)]
    pub(crate) fn for_maps_with_goose_bin(
        maps_root: Vec<u8>,
        bin: Option<std::ffi::OsString>,
    ) -> Self {
        let target = ForwardTarget::MapsDir(maps_root.clone());
        Self {
            maps_root,
            selected: Arc::new(Mutex::new(None)),
            forward: Arc::new(Mutex::new(Forwarder::with_bin_override(target, bin))),
        }
    }

    fn dispatch_tool(&self, name: &str, args: &serde_json::Value) -> CallToolResult {
        // Validate build even without a repo, before selection or reopening.
        let build = match args.get("build") {
            None => true,
            Some(v) => match v.as_bool() {
                Some(b) => b,
                None => {
                    return CallToolResult::error(vec![ContentBlock::text(
                        "build must be a boolean",
                    )]);
                }
            },
        };
        if name == "use_repo" {
            let path = args.get("path").and_then(serde_json::Value::as_str).unwrap_or("").as_bytes();
            let mut cur = self.selected.lock().unwrap_or_else(|e| e.into_inner());
            return match serve_repo::select(&self.maps_root, path, build, &mut cur) {
                Ok(out) => CallToolResult::success(vec![ContentBlock::text(
                    String::from_utf8_lossy(&out).into_owned(),
                )]),
                Err(e) => CallToolResult::error(vec![ContentBlock::text(
                    String::from_utf8_lossy(&e).into_owned(),
                )]),
            };
        }
        // `live: true` asks a running language server, which the Rust server does not keep yet (step 4): until then
        // it goes to the Goose server like the tools the Rust one lacks (the owner's decision A, 2026-11-27).
        let live = (name == "find_implementations" || name == "get_diagnostics")
            && args.get("live").and_then(serde_json::Value::as_bool) == Some(true);
        if live || serve_forward::is_forwarded_tool(name) {
            let mut cur = self.selected.lock().unwrap_or_else(|e| e.into_inner());
            let mut fwd = self.forward.lock().unwrap_or_else(|e| e.into_inner());
            return fwd.call(name, args, &self.maps_root, &mut cur);
        }
        let is_read = serve_read::is_read_tool(name);
        let is_broke = name == "what_broke";
        let is_wings = serve_wings::is_wings_tool(name);
        if !is_read && !is_broke && !is_wings {
            return CallToolResult::error(vec![ContentBlock::text(format!(
                "unknown tool: {name}"
            ))]);
        }
        let repo = args.get("repo").and_then(serde_json::Value::as_str).unwrap_or("").as_bytes();
        let mut cur = self.selected.lock().unwrap_or_else(|e| e.into_inner());
        let mut snap = if !repo.is_empty() {
            match serve_repo::select_open(&self.maps_root, repo, build, false, &mut cur) {
                Ok((snap, _)) => snap,
                Err(e) => {
                    return CallToolResult::error(vec![ContentBlock::text(
                        String::from_utf8_lossy(&e).into_owned(),
                    )]);
                }
            }
        } else if let Some(sel) = cur.as_ref() {
            match open_map_snapshot(&sel.map) {
                Ok(snap) => snap,
                Err(e) => {
                    return CallToolResult::error(vec![ContentBlock::text(
                        String::from_utf8_lossy(&e).into_owned(),
                    )]);
                }
            }
        } else if name == "index_info" {
            return match serve_repo::list_maps(&self.maps_root) {
                Ok(out) => CallToolResult::success(vec![ContentBlock::text(
                    String::from_utf8_lossy(&out).into_owned(),
                )]),
                Err(e) => CallToolResult::error(vec![ContentBlock::text(
                    String::from_utf8_lossy(&e).into_owned(),
                )]),
            };
        } else {
            return CallToolResult::error(vec![ContentBlock::text(
                "no repo selected: call use_repo with a path, or pass repo",
            )]);
        };
        let map_path = cur.as_ref().map(|s| s.map.clone()).unwrap_or_default();
        drop(cur);
        if is_broke {
            let root = meta_value(&snap.db, b"root");
            snap.commit();
            return match serve_read::call_what_broke(&map_path, &root, args) {
                Ok((out, true)) => CallToolResult::success(vec![ContentBlock::text(
                    String::from_utf8_lossy(&out).into_owned(),
                )]),
                Ok((out, false)) => CallToolResult::error(vec![ContentBlock::text(
                    String::from_utf8_lossy(&out).into_owned(),
                )]),
                Err(e) => CallToolResult::error(vec![ContentBlock::text(
                    String::from_utf8_lossy(&e).into_owned(),
                )]),
            };
        }
        if is_wings {
            let root = meta_value(&snap.db, b"root");
            snap.commit();
            let mut out = Vec::new();
            return match serve_wings::call_wings(&map_path, &root, name, args, &mut out) {
                Some(Ok(())) => CallToolResult::success(vec![ContentBlock::text(
                    String::from_utf8_lossy(&out).into_owned(),
                )]),
                Some(Err(e)) => CallToolResult::error(vec![ContentBlock::text(
                    String::from_utf8_lossy(&e).into_owned(),
                )]),
                None => CallToolResult::error(vec![ContentBlock::text(format!(
                    "not yet in the Rust server: {name}"
                ))]),
            };
        }
        let mut out = Vec::new();
        let res = serve_read::call_read(&mut snap, &map_path, name, args, &mut out);
        snap.commit();
        match res {
            Some(Ok(())) => CallToolResult::success(vec![ContentBlock::text(
                String::from_utf8_lossy(&out).into_owned(),
            )]),
            Some(Err(e)) => CallToolResult::error(vec![ContentBlock::text(
                String::from_utf8_lossy(&e).into_owned(),
            )]),
            None => CallToolResult::error(vec![ContentBlock::text(format!(
                "not yet in the Rust server: {name}"
            ))]),
        }
    }
}

impl ServerHandler for SwanServer {
    fn get_info(&self) -> ServerConfig {
        ServerConfig::new(
            ServerCapabilities::builder()
                .enable_tools()
                .enable_tool_list_changed()
                .build(),
        )
        .with_protocol_version(ProtocolVersion::V_2025_06_18)
        .with_server_info(Implementation::new("swan", env!("CARGO_PKG_VERSION")))
    }

    async fn list_tools(
        &self,
        _request: Option<PaginatedRequestParams>,
        _context: RequestContext<RoleServer>,
    ) -> Result<ListToolsResult, McpError> {
        Ok(ListToolsResult::with_all_items(serve_tools::tools()))
    }

    async fn call_tool(
        &self,
        request: CallToolRequestParams,
        _context: RequestContext<RoleServer>,
    ) -> Result<CallToolResponse, McpError> {
        let args = serde_json::Value::Object(request.arguments.unwrap_or_default());
        Ok(self.dispatch_tool(request.name.as_ref(), &args).into())
    }
}

fn write_stderr_line(msg: &[u8]) {
    let mut err = std::io::stderr();
    let _ = err.write_all(msg);
    let _ = err.write_all(b"\n");
    let _ = err.flush();
}

pub(crate) async fn serve_io<R, W>(server: SwanServer, reader: R, writer: W) -> i32
where
    R: AsyncRead + Send + Unpin + 'static,
    W: AsyncWrite + Send + Unpin + 'static,
{
    let forward = server.forward.clone();
    let code = match serve_server(server, (reader, writer)).await {
        Ok(running) => match running.waiting().await {
            Ok(QuitReason::Closed | QuitReason::Cancelled) => 0,
            Ok(QuitReason::JoinError(e)) => {
                write_stderr_line(format!("swan: serve task failed: {e}").as_bytes());
                1
            }
            Ok(other) => {
                write_stderr_line(format!("swan: serve stopped: {other:?}").as_bytes());
                1
            }
            Err(e) => {
                write_stderr_line(format!("swan: serve wait failed: {e}").as_bytes());
                1
            }
        },
        Err(ServerInitializeError::ConnectionClosed(_)) => 0,
        Err(e) => {
            write_stderr_line(format!("swan: serve failed: {e}").as_bytes());
            1
        }
    };
    forward.lock().unwrap_or_else(|e| e.into_inner()).shutdown();
    code
}

fn run_server(server: SwanServer) -> i32 {
    let rt = match tokio::runtime::Builder::new_current_thread().enable_all().build() {
        Ok(rt) => rt,
        Err(e) => {
            write_stderr_line(format!("swan: cannot start runtime: {e}").as_bytes());
            return 1;
        }
    };
    rt.block_on(async move {
        let (stdin, stdout) = rmcp::transport::stdio();
        serve_io(server, stdin, stdout).await
    })
}

pub fn serve_main(target: &[u8]) -> i32 {
    // Check that the map can be opened and matches our schema before serving,
    // then close it so every request reopens the path fresh.
    let root = match open_map_snapshot(target) {
        Ok(snap) => {
            let root = meta_value(&snap.db, b"root");
            snap.commit();
            root
        }
        Err(e) => {
            write_stderr_line(&e);
            return 1;
        }
    };
    let maps_root = [&run::swan_home()[..], b"/data"].concat();
    run_server(SwanServer::for_map(maps_root, Selected { root, map: target.to_vec() }))
}

pub fn serve_any(maps_root: &[u8]) -> i32 {
    run_server(SwanServer::for_maps(serve_repo::normalize_maps_root(maps_root)))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};

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

    async fn send_line<W: AsyncWrite + Unpin>(w: &mut W, msg: &str) {
        w.write_all(msg.as_bytes()).await.unwrap();
        w.write_all(b"\n").await.unwrap();
        w.flush().await.unwrap();
    }

    async fn recv_json<R: AsyncRead + Unpin>(r: &mut BufReader<R>) -> Value {
        let mut line = String::new();
        let n = r.read_line(&mut line).await.unwrap();
        assert!(n > 0, "server closed before answering");
        serde_json::from_str(&line).unwrap_or_else(|e| panic!("invalid JSON reply {line:?}: {e}"))
    }

    fn init_request(id: i64) -> String {
        format!(
            r#"{{"jsonrpc":"2.0","id":{id},"method":"initialize","params":{{"protocolVersion":"2025-06-18","capabilities":{{}},"clientInfo":{{"name":"test","version":"0"}}}}}}"#
        )
    }

    #[tokio::test(flavor = "current_thread")]
    async fn initialize_names_the_server() {
        let (mut client_w, server_r) = tokio::io::duplex(64 * 1024);
        let (server_w, client_r) = tokio::io::duplex(64 * 1024);
        let task = tokio::spawn(serve_io(SwanServer::for_maps(Vec::new()), server_r, server_w));

        let mut reader = BufReader::new(client_r);
        send_line(&mut client_w, &init_request(1)).await;
        let reply = recv_json(&mut reader).await;
        assert_eq!(reply["id"], 1);
        assert_eq!(reply["result"]["serverInfo"]["name"], "swan");
        assert_eq!(reply["result"]["protocolVersion"], "2025-06-18");

        drop(client_w);
        assert_eq!(task.await.unwrap(), 0);
    }

    #[tokio::test(flavor = "current_thread")]
    async fn tools_list_is_the_read_tools() {
        let (mut client_w, server_r) = tokio::io::duplex(256 * 1024);
        let (server_w, client_r) = tokio::io::duplex(256 * 1024);
        let task = tokio::spawn(serve_io(SwanServer::for_maps(Vec::new()), server_r, server_w));

        let mut reader = BufReader::new(client_r);
        send_line(&mut client_w, &init_request(1)).await;
        let _ = recv_json(&mut reader).await;
        send_line(&mut client_w, r#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#).await;

        send_line(&mut client_w, r#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#).await;
        let reply = recv_json(&mut reader).await;
        assert_eq!(reply["id"], 2);
        let tools = reply["result"]["tools"].as_array().expect("tools array");
        let names: Vec<&str> = tools.iter().filter_map(|t| t["name"].as_str()).collect();
        assert_eq!(names, EXPECTED_TOOLS);

        let expected: Vec<Value> = serde_json::from_str(serve_tools::TOOLS_JSON).unwrap();
        assert_eq!(tools.len(), expected.len());
        for (got, want) in tools.iter().zip(expected.iter()) {
            assert_eq!(got["name"], want["name"]);
            assert_eq!(got["description"], want["description"]);
            assert_eq!(got["inputSchema"], want["inputSchema"]);
        }

        drop(client_w);
        assert_eq!(task.await.unwrap(), 0);
    }

    #[tokio::test(flavor = "current_thread")]
    async fn unknown_method_is_an_error() {
        let (mut client_w, server_r) = tokio::io::duplex(256 * 1024);
        let (server_w, client_r) = tokio::io::duplex(256 * 1024);
        let task = tokio::spawn(serve_io(SwanServer::for_maps(Vec::new()), server_r, server_w));

        let mut reader = BufReader::new(client_r);
        send_line(&mut client_w, &init_request(1)).await;
        let _ = recv_json(&mut reader).await;
        send_line(&mut client_w, r#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#).await;

        send_line(&mut client_w, r#"{"jsonrpc":"2.0","id":2,"method":"no/such/method"}"#).await;
        let err_reply = recv_json(&mut reader).await;
        assert_eq!(err_reply["id"], 2);
        assert_eq!(err_reply["error"]["code"], -32601);

        // Server stays up and answers subsequent requests.
        send_line(&mut client_w, r#"{"jsonrpc":"2.0","id":3,"method":"tools/list"}"#).await;
        let list_reply = recv_json(&mut reader).await;
        assert_eq!(list_reply["id"], 3);
        let tools = list_reply["result"]["tools"].as_array().expect("tools array");
        assert_eq!(tools.len(), 28);

        drop(client_w);
        assert_eq!(task.await.unwrap(), 0);
    }

    #[tokio::test(flavor = "current_thread")]
    async fn unknown_tool_returns_mcp_error() {
        let (mut client_w, server_r) = tokio::io::duplex(64 * 1024);
        let (server_w, client_r) = tokio::io::duplex(64 * 1024);
        let task = tokio::spawn(serve_io(SwanServer::for_maps(Vec::new()), server_r, server_w));

        let mut reader = BufReader::new(client_r);
        send_line(&mut client_w, &init_request(1)).await;
        let _ = recv_json(&mut reader).await;
        send_line(&mut client_w, r#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#).await;

        send_line(
            &mut client_w,
            r#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"no_such_tool","arguments":{}}}"#,
        )
        .await;
        let reply = recv_json(&mut reader).await;
        assert_eq!(reply["id"], 2);
        assert_eq!(reply["result"]["isError"], true);
        assert_eq!(reply["result"]["content"][0]["type"], "text");
        assert_eq!(
            reply["result"]["content"][0]["text"],
            "unknown tool: no_such_tool"
        );

        drop(client_w);
        assert_eq!(task.await.unwrap(), 0);
    }

    #[tokio::test(flavor = "current_thread")]
    async fn eof_exits_cleanly() {
        // Immediate EOF before initialize.
        let (client_w, server_r) = tokio::io::duplex(4096);
        let (server_w, _client_r) = tokio::io::duplex(4096);
        drop(client_w);
        assert_eq!(serve_io(SwanServer::for_maps(Vec::new()), server_r, server_w).await, 0);

        // EOF after initialize.
        let (mut client_w, server_r) = tokio::io::duplex(4096);
        let (server_w, client_r) = tokio::io::duplex(4096);
        let task = tokio::spawn(serve_io(SwanServer::for_maps(Vec::new()), server_r, server_w));
        let mut reader = BufReader::new(client_r);
        send_line(&mut client_w, &init_request(1)).await;
        let _ = recv_json(&mut reader).await;
        drop(client_w);
        assert_eq!(task.await.unwrap(), 0);
    }

    #[test]
    fn serve_main_missing_db_returns_nonzero() {
        let code = serve_main(b"/nonexistent/swan-serve-test-db/swan.db");
        assert_ne!(code, 0);
    }

    #[tokio::test(flavor = "current_thread")]
    async fn new_read_tools_require_selected_repo() {
        let (mut client_w, server_r) = tokio::io::duplex(64 * 1024);
        let (server_w, client_r) = tokio::io::duplex(64 * 1024);
        let task = tokio::spawn(serve_io(SwanServer::for_maps(Vec::new()), server_r, server_w));

        let mut reader = BufReader::new(client_r);
        send_line(&mut client_w, &init_request(1)).await;
        let _ = recv_json(&mut reader).await;
        send_line(&mut client_w, r#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#).await;

        let mut id = 2;
        for tool in ["what_broke", "repo_projects", "repo_overview", "what_touches", "file_neighbors"] {
            let req = format!(
                r#"{{"jsonrpc":"2.0","id":{id},"method":"tools/call","params":{{"name":"{tool}","arguments":{{}}}}}}"#
            );
            send_line(&mut client_w, &req).await;
            let reply = recv_json(&mut reader).await;
            assert_eq!(reply["id"], id);
            assert_eq!(reply["result"]["isError"], true, "{tool}: {reply}");
            assert_eq!(
                reply["result"]["content"][0]["text"],
                "no repo selected: call use_repo with a path, or pass repo",
                "{tool}: {reply}"
            );
            id += 1;
        }

        drop(client_w);
        assert_eq!(task.await.unwrap(), 0);
    }
}
