// `swan serve`: MCP server over stdin and stdout, built on rmcp.
// Each tool request reopens the map path in a read transaction so completed
// map replacements, refreshes and disk edits are seen on the next call.

use std::io::Write;

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
use crate::serve_read;
use crate::serve_tools;

// Holds one database generation for a read tool. `fresh` owns a prepared
// statement on `db`, so it is declared first to drop before `db` closes.
pub(crate) struct MapSnapshot {
    pub(crate) fresh: Fresh,
    pub(crate) db: Db,
}

impl MapSnapshot {
    pub(crate) fn commit(self) {
        let _ = self.db.exec(b"COMMIT;");
        drop(self.fresh);
        drop(self.db);
    }
}

// Reads one meta entry without ending the server on a damaged or foreign file.
fn meta_try(db: &Db, key: &[u8]) -> Result<Vec<u8>, Vec<u8>> {
    let st = db.prepare(b"SELECT value FROM meta WHERE key = ?1")?;
    st.bind_text(1, key);
    let val = if st.step()? { st.col_text(0) } else { Vec::new() };
    drop(st);
    Ok(val)
}

// Reopens the map path in a read transaction, checks its schema version and
// loads freshness state for this connection.
pub(crate) fn open_map_snapshot(db_path: &[u8]) -> Result<MapSnapshot, Vec<u8>> {
    let db = Db::open_existing(db_path)
        .map_err(|e| [b"swan: cannot open map ", db_path, b": ", &e[..]].concat())?;
    db.exec(b"BEGIN;")
        .map_err(|e| [b"swan: cannot start map read: ", &e[..]].concat())?;
    let version = meta_try(&db, b"schema_version")
        .map_err(|e| [b"swan: cannot read map ", db_path, b": ", &e[..]].concat())?;
    let _root = meta_try(&db, b"root")
        .map_err(|e| [b"swan: cannot read map ", db_path, b": ", &e[..]].concat())?;
    let _source = meta_try(&db, b"source")
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
    let fresh = Fresh::load(&db);
    Ok(MapSnapshot { fresh, db })
}

#[derive(Clone)]
struct SwanServer {
    db_path: Vec<u8>,
}

impl SwanServer {
    fn new(db_path: Vec<u8>) -> Self {
        Self { db_path }
    }

    fn dispatch_tool(&self, name: &str, args: &serde_json::Value) -> CallToolResult {
        if !serve_read::is_read_tool(name) {
            return CallToolResult::error(vec![ContentBlock::text(format!(
                "not yet in the Rust server: {name}"
            ))]);
        }
        if let Some(build) = args.get("build") {
            if !build.is_boolean() {
                return CallToolResult::error(vec![ContentBlock::text("build must be a boolean")]);
            }
        }
        let snap = match open_map_snapshot(&self.db_path) {
            Ok(snap) => snap,
            Err(e) => {
                return CallToolResult::error(vec![ContentBlock::text(
                    String::from_utf8_lossy(&e).into_owned(),
                )]);
            }
        };
        let mut out = Vec::new();
        let res = serve_read::call_read(&snap, name, args, &mut out);
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

async fn serve_io<R, W>(server: SwanServer, reader: R, writer: W) -> i32
where
    R: AsyncRead + Send + Unpin + 'static,
    W: AsyncWrite + Send + Unpin + 'static,
{
    match serve_server(server, (reader, writer)).await {
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
    }
}

pub fn serve_main(target: &[u8]) -> i32 {
    // Check that the map can be opened and matches our schema before serving,
    // then close it so every request reopens the path fresh.
    match open_map_snapshot(target) {
        Ok(snap) => snap.commit(),
        Err(e) => {
            write_stderr_line(&e);
            return 1;
        }
    }
    let rt = match tokio::runtime::Builder::new_current_thread().enable_all().build() {
        Ok(rt) => rt,
        Err(e) => {
            write_stderr_line(format!("swan: cannot start runtime: {e}").as_bytes());
            return 1;
        }
    };
    rt.block_on(async move {
        let (stdin, stdout) = rmcp::transport::stdio();
        serve_io(SwanServer::new(target.to_vec()), stdin, stdout).await
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};

    const EXPECTED_TOOLS: [&str; 12] = [
        "find_symbol",
        "find_referencing_symbols",
        "get_symbol_at",
        "get_symbols_overview",
        "get_callers",
        "get_callees",
        "find_implementations",
        "get_type_hierarchy",
        "find_unused_symbols",
        "get_diagnostics",
        "search_pattern",
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
        let task = tokio::spawn(serve_io(SwanServer::new(Vec::new()), server_r, server_w));

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
        let task = tokio::spawn(serve_io(SwanServer::new(Vec::new()), server_r, server_w));

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
        let task = tokio::spawn(serve_io(SwanServer::new(Vec::new()), server_r, server_w));

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
        assert_eq!(tools.len(), 12);

        drop(client_w);
        assert_eq!(task.await.unwrap(), 0);
    }

    #[tokio::test(flavor = "current_thread")]
    async fn unimplemented_tool_returns_mcp_error() {
        let (mut client_w, server_r) = tokio::io::duplex(64 * 1024);
        let (server_w, client_r) = tokio::io::duplex(64 * 1024);
        let task = tokio::spawn(serve_io(SwanServer::new(Vec::new()), server_r, server_w));

        let mut reader = BufReader::new(client_r);
        send_line(&mut client_w, &init_request(1)).await;
        let _ = recv_json(&mut reader).await;
        send_line(&mut client_w, r#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#).await;

        send_line(
            &mut client_w,
            r#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"rename_symbol","arguments":{}}}"#,
        )
        .await;
        let reply = recv_json(&mut reader).await;
        assert_eq!(reply["id"], 2);
        assert_eq!(reply["result"]["isError"], true);
        assert_eq!(reply["result"]["content"][0]["type"], "text");
        assert_eq!(
            reply["result"]["content"][0]["text"],
            "not yet in the Rust server: rename_symbol"
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
        assert_eq!(serve_io(SwanServer::new(Vec::new()), server_r, server_w).await, 0);

        // EOF after initialize.
        let (mut client_w, server_r) = tokio::io::duplex(4096);
        let (server_w, client_r) = tokio::io::duplex(4096);
        let task = tokio::spawn(serve_io(SwanServer::new(Vec::new()), server_r, server_w));
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
}
