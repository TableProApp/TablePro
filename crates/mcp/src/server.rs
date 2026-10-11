use std::net::{IpAddr, SocketAddr};
use std::sync::Arc;

use axum::http::{HeaderMap, Uri, header::ORIGIN};
use serde_json::{Value as JsonValue, json};
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};

use crate::bridge::McpBridge;
use crate::tools::{self, TOOL_NAMES};

#[derive(Debug, Clone)]
pub struct McpServerConfig {
    pub bind_host: String,
    pub bind_port: u16,
}

impl Default for McpServerConfig {
    fn default() -> Self {
        Self {
            bind_host: "127.0.0.1".into(),
            bind_port: 17432,
        }
    }
}

const MAX_REQUEST_BYTES: usize = 1024 * 1024;
const DISCARD_CHUNK_BYTES: u64 = 8 * 1024;

/// Revision advertised to a client that does not ask for one, and the
/// older revisions still accepted from a client that does.
const PROTOCOL_VERSION: &str = "2026-07-28";
const ACCEPTED_PROTOCOL_VERSIONS: &[&str] = &[PROTOCOL_VERSION, "2025-11-25", "2025-06-18"];

fn negotiate_protocol_version(params: &JsonValue) -> Result<&'static str, String> {
    let Some(requested) = params.get("protocolVersion") else {
        return Ok(PROTOCOL_VERSION);
    };
    let requested = requested
        .as_str()
        .ok_or_else(|| "protocolVersion must be a string".to_string())?;
    ACCEPTED_PROTOCOL_VERSIONS
        .iter()
        .find(|accepted| **accepted == requested)
        .copied()
        .ok_or_else(|| format!("unsupported protocolVersion; this server accepts {ACCEPTED_PROTOCOL_VERSIONS:?}"))
}

fn initialize_result(params: &JsonValue) -> Result<JsonValue, String> {
    let version = negotiate_protocol_version(params)?;
    Ok(json!({
        "protocolVersion": version,
        "capabilities": {"tools": {}},
        "serverInfo": {"name": "tablepro", "version": "0.1.0"}
    }))
}

fn json_rpc_error(id: &JsonValue, code: i64, message: String) -> JsonValue {
    json!({"jsonrpc": "2.0", "id": id, "error": {"code": code, "message": message}})
}

/// Loopback-only bind resolution. A host that is not a loopback literal
/// is refused before any socket is opened; there is no configuration
/// that reaches a routable interface.
fn loopback_bind_addr(host: &str, port: u16) -> Result<SocketAddr, String> {
    let host = host.trim();
    let literal = host
        .strip_prefix('[')
        .and_then(|rest| rest.strip_suffix(']'))
        .unwrap_or(host);
    let ip: IpAddr = match literal {
        "localhost" => IpAddr::from([127, 0, 0, 1]),
        other => other
            .parse()
            .map_err(|_| format!("refusing to bind MCP HTTP to a non-loopback host: {other}"))?,
    };
    if !ip.is_loopback() {
        return Err(format!("refusing to bind MCP HTTP outside loopback: {ip}"));
    }
    Ok(SocketAddr::new(ip, port))
}

async fn discard_rest_of_line<R>(reader: &mut R) -> Result<(), String>
where
    R: tokio::io::AsyncBufRead + Unpin,
{
    let mut chunk = Vec::new();
    loop {
        chunk.clear();
        let read = reader
            .take(DISCARD_CHUNK_BYTES)
            .read_until(b'\n', &mut chunk)
            .await
            .map_err(|e| e.to_string())?;
        if read == 0 || chunk.last() == Some(&b'\n') {
            return Ok(());
        }
    }
}

/// Minimal MCP-compatible JSON-RPC loop over stdio. Speaks enough of the
/// protocol for Cursor / Claude Code: `initialize`, `tools/list`,
/// `tools/call`. Auth via `Authorization` in `_meta` or `params.token`.
pub async fn serve_stdio(bridge: Arc<McpBridge>) -> Result<(), String> {
    let reader = BufReader::new(tokio::io::stdin());
    let stdout = tokio::io::stdout();
    serve_json_rpc_lines(&bridge, reader, stdout).await
}

async fn serve_json_rpc_lines<R, W>(bridge: &McpBridge, mut reader: R, mut stdout: W) -> Result<(), String>
where
    R: tokio::io::AsyncBufRead + Unpin,
    W: tokio::io::AsyncWrite + Unpin,
{
    let mut line = String::new();

    loop {
        line.clear();
        let read = (&mut reader)
            .take(MAX_REQUEST_BYTES as u64 + 1)
            .read_line(&mut line)
            .await;
        let n = match read {
            Ok(n) => n,
            // read_line still consumes the malformed bytes before failing
            // the UTF-8 conversion, so the stream is resynced at the next
            // newline -- this can recover the same way an invalid JSON
            // line does, instead of ending the whole session.
            Err(error) if error.kind() == std::io::ErrorKind::InvalidData => {
                write_response(
                    &mut stdout,
                    json!({
                        "jsonrpc": "2.0",
                        "id": null,
                        "error": {"code": -32700, "message": format!("parse error: {error}")}
                    }),
                )
                .await?;
                continue;
            }
            Err(error) => return Err(error.to_string()),
        };
        if n == 0 {
            break;
        }
        if n > MAX_REQUEST_BYTES && !line.ends_with('\n') {
            discard_rest_of_line(&mut reader).await?;
            write_response(
                &mut stdout,
                json!({
                    "jsonrpc": "2.0",
                    "id": null,
                    "error": {"code": -32600, "message": format!("request exceeds {MAX_REQUEST_BYTES} bytes")}
                }),
            )
            .await?;
            continue;
        }
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        let request: JsonValue = match serde_json::from_str(trimmed) {
            Ok(v) => v,
            Err(e) => {
                write_response(
                    &mut stdout,
                    json!({
                        "jsonrpc": "2.0",
                        "id": null,
                        "error": {"code": -32700, "message": format!("parse error: {e}")}
                    }),
                )
                .await?;
                continue;
            }
        };
        let id = request.get("id").cloned().unwrap_or(JsonValue::Null);
        let method = request.get("method").and_then(|m| m.as_str()).unwrap_or("");
        let params = request.get("params").cloned().unwrap_or(json!({}));

        let response = match method {
            "initialize" => match initialize_result(&params) {
                Ok(result) => json!({"jsonrpc": "2.0", "id": id, "result": result}),
                Err(message) => json_rpc_error(&id, -32602, message),
            },
            "notifications/initialized" | "initialized" => continue,
            "tools/list" => match handle_tools_list(bridge, &params) {
                Ok(result) => json!({"jsonrpc": "2.0", "id": id, "result": result}),
                Err(message) => json_rpc_error(&id, -32000, message),
            },
            "tools/call" => match handle_tool_call(bridge, params).await {
                Ok(content) => json!({
                    "jsonrpc": "2.0",
                    "id": id,
                    "result": {
                        "content": [{"type": "text", "text": content.to_string()}],
                        "isError": false
                    }
                }),
                Err(e) => json!({
                    "jsonrpc": "2.0",
                    "id": id,
                    "result": {
                        "content": [{"type": "text", "text": e}],
                        "isError": true
                    }
                }),
            },
            "ping" => json!({"jsonrpc": "2.0", "id": id, "result": {}}),
            other => json!({
                "jsonrpc": "2.0",
                "id": id,
                "error": {"code": -32601, "message": format!("method not found: {other}")}
            }),
        };
        write_response(&mut stdout, response).await?;
    }
    Ok(())
}

/// Shared lookup for every method that requires a token: `params.token`,
/// `params._meta.authorization`, then (for `tools/call`) `arguments.token`.
fn extract_token_str(params: &JsonValue) -> Option<&str> {
    params
        .get("token")
        .and_then(|v| v.as_str())
        .or_else(|| params.pointer("/_meta/authorization").and_then(|v| v.as_str()))
        .or_else(|| params.pointer("/arguments/token").and_then(|v| v.as_str()))
}

async fn handle_tool_call(bridge: &McpBridge, params: JsonValue) -> Result<JsonValue, String> {
    let name = params.get("name").and_then(|v| v.as_str()).ok_or("missing tool name")?;
    let args = params.get("arguments").cloned().unwrap_or(json!({}));
    let token_str = extract_token_str(&params).ok_or("missing token (pass params.token or arguments.token)")?;
    let token = bridge.authenticate(token_str)?;
    tools::dispatch(bridge, &token, name, args).await
}

/// `tools/list` names every tool this server exposes, including ones a
/// least-privilege token could never call. Require the same token
/// `tools/call` does rather than disclosing the catalogue to anyone who can
/// reach the loopback listener.
fn handle_tools_list(bridge: &McpBridge, params: &JsonValue) -> Result<JsonValue, String> {
    let token_str = extract_token_str(params).ok_or("missing token (pass params.token)")?;
    bridge.authenticate(token_str)?;
    Ok(json!({
        "tools": TOOL_NAMES.iter().map(|name| json!({
            "name": name,
            "description": tool_description(name),
            "inputSchema": tool_schema(name),
        })).collect::<Vec<_>>()
    }))
}

async fn write_response<W>(stdout: &mut W, value: JsonValue) -> Result<(), String>
where
    W: tokio::io::AsyncWrite + Unpin,
{
    let mut line = serde_json::to_string(&value).map_err(|e| e.to_string())?;
    line.push('\n');
    stdout.write_all(line.as_bytes()).await.map_err(|e| e.to_string())?;
    stdout.flush().await.map_err(|e| e.to_string())
}

fn tool_description(name: &str) -> &'static str {
    match name {
        "list_connections" => "List saved database connections visible to this token",
        "list_tables" => "List tables on a connection",
        "list_objects" => {
            "List routines, triggers, sequences, extensions, roles, types or table privileges on a connection, optionally in one schema"
        }
        "describe_table" => "Describe columns of a table",
        "execute_query" => "Run a read SQL query (writes require tools:write scope and policy approval)",
        "execute_write" => "Run a write with optional transaction preview (preview=true by default)",
        "explain_query" => "Run EXPLAIN on a SQL statement; plan rows are withheld from read-scoped agents",
        "export_data" => {
            "Run a query and return CSV or JSON; CSV responses include the null_marker used for SQL NULL cells"
        }
        "table_schema" => "Read the columns, primary key, indexes and foreign keys of a table",
        "count_rows" => "Count the rows of a table exactly",
        "browse_table" => "Read a page of table rows by offset and limit",
        _ => "",
    }
}

fn tool_schema(name: &str) -> JsonValue {
    match name {
        "list_connections" => json!({"type": "object", "properties": {}}),
        "list_tables" | "execute_query" | "execute_write" | "explain_query" | "export_data" => json!({
            "type": "object",
            "properties": {
                "connection_id": {"type": "string"},
                "sql": {"type": "string"},
                "preview": {"type": "boolean"},
                "format": {"type": "string"},
                "token": {"type": "string"}
            },
            "required": ["connection_id"]
        }),
        "list_objects" => json!({
            "type": "object",
            "properties": {
                "connection_id": {"type": "string"},
                "kind": {
                    "type": "string",
                    "enum": tablepro_core::CatalogObjectKind::ALL.iter().map(|kind| kind.as_str()).collect::<Vec<_>>()
                },
                "schema": {"type": "string"},
                "token": {"type": "string"}
            },
            "required": ["connection_id", "kind"]
        }),
        "describe_table" | "table_schema" | "count_rows" => json!({
            "type": "object",
            "properties": {
                "connection_id": {"type": "string"},
                "schema": {"type": "string"},
                "table": {"type": "string"},
                "token": {"type": "string"}
            },
            "required": ["connection_id", "table"]
        }),
        "browse_table" => json!({
            "type": "object",
            "properties": {
                "connection_id": {"type": "string"},
                "schema": {"type": "string"},
                "table": {"type": "string"},
                "offset": {"type": "integer", "minimum": 0},
                "limit": {"type": "integer", "minimum": 1},
                "token": {"type": "string"}
            },
            "required": ["connection_id", "table"]
        }),
        _ => json!({"type": "object"}),
    }
}

fn origin_is_allowed(headers: &HeaderMap) -> bool {
    let Some(origin) = headers.get(ORIGIN) else {
        return true;
    };
    let Ok(origin) = origin.to_str() else {
        return false;
    };
    if origin.is_empty() {
        return true;
    }
    let Ok(uri) = origin.parse::<Uri>() else {
        return false;
    };
    if !matches!(uri.scheme_str(), Some("http" | "https")) {
        return false;
    }
    matches!(
        uri.host().map(str::to_ascii_lowercase).as_deref(),
        Some("localhost" | "127.0.0.1" | "[::1]" | "claude.ai" | "app.cursor.com")
    )
}

/// Bind a loopback streamable-HTTP endpoint that forwards tool calls to
/// the same bridge. Loopback only by default.
pub async fn serve_streamable_http(bridge: Arc<McpBridge>, config: McpServerConfig) -> Result<(), String> {
    serve_streamable_http_until(bridge, config, tokio_util::sync::CancellationToken::new()).await
}

/// Extra time given to the graceful-shutdown race beyond the longest write
/// this bridge admits, so a write already in flight when shutdown begins
/// gets to finish its own bounded cancellation and reach a terminal audit
/// outcome before the runtime hosting it is torn down. A caller that drops
/// this future's loser branch does not stop an already-spawned request task,
/// but a caller that also drops the runtime (`tablepro-app`'s dedicated MCP
/// thread) does, so this deadline must never be shorter than the operation
/// bound `McpBridge` itself already enforces.
const SHUTDOWN_TEARDOWN_MARGIN: std::time::Duration = std::time::Duration::from_secs(5);

pub async fn serve_streamable_http_until(
    bridge: Arc<McpBridge>,
    config: McpServerConfig,
    shutdown: tokio_util::sync::CancellationToken,
) -> Result<(), String> {
    let addr = loopback_bind_addr(&config.bind_host, config.bind_port)?;
    let force_deadline_duration = std::time::Duration::from_secs(bridge.query_timeout_secs) + SHUTDOWN_TEARDOWN_MARGIN;
    let app = http_router(bridge);
    let listener = tokio::net::TcpListener::bind(addr).await.map_err(|e| e.to_string())?;
    tracing::info!(%addr, "MCP HTTP listening (loopback)");
    let server = axum::serve(listener, app).with_graceful_shutdown(shutdown.clone().cancelled_owned());
    let force_deadline = async move {
        shutdown.cancelled().await;
        tokio::time::sleep(force_deadline_duration).await;
    };
    tokio::select! {
        result = server => result.map_err(|error| error.to_string()),
        _ = force_deadline => Err("MCP server shutdown deadline exceeded".into()),
    }
}

fn http_router(bridge: Arc<McpBridge>) -> axum::Router {
    use axum::extract::DefaultBodyLimit;
    use axum::response::IntoResponse;
    use axum::{Json, Router, http::StatusCode, routing::post};

    Router::new()
        .route(
            "/mcp",
            post(move |headers: HeaderMap, Json(body): Json<JsonValue>| {
                let bridge = bridge.clone();
                async move {
                    let cancellation = bridge.request_cancellation();
                    let request_cancellation = cancellation.clone();
                    let (response_tx, response_rx) = tokio::sync::oneshot::channel();
                    let operation = crate::bridge::scope_request_cancellation(
                        request_cancellation,
                        process_http_request(bridge, headers, body),
                    );
                    tokio::spawn(supervise_disconnect_aware(response_tx, cancellation, operation));
                    response_rx.await.unwrap_or_else(|_| {
                        (
                            StatusCode::INTERNAL_SERVER_ERROR,
                            Json(json!({"error": "MCP request task stopped before producing a response"})),
                        )
                            .into_response()
                    })
                }
            }),
        )
        // Matches stdio's own MAX_REQUEST_BYTES instead of axum's larger
        // default, so the sql argument (and everything else in the body)
        // is bounded the same way regardless of which transport carried it.
        .layer(DefaultBodyLimit::max(MAX_REQUEST_BYTES))
}

async fn process_http_request(bridge: Arc<McpBridge>, headers: HeaderMap, body: JsonValue) -> axum::response::Response {
    use axum::response::IntoResponse;
    use axum::{Json, http::StatusCode};

    if !origin_is_allowed(&headers) {
        return (
            StatusCode::FORBIDDEN,
            Json(json!({
                "jsonrpc": "2.0",
                "id": null,
                "error": {"code": -32000, "message": "forbidden origin"}
            })),
        )
            .into_response();
    }
    let id = body.get("id").cloned().unwrap_or(JsonValue::Null);
    let method = body.get("method").and_then(|m| m.as_str()).unwrap_or("");
    let params = body.get("params").cloned().unwrap_or(json!({}));
    let result = match method {
        "tools/call" => handle_tool_call(&bridge, params).await,
        "tools/list" => handle_tools_list(&bridge, &params),
        "initialize" => match initialize_result(&params) {
            Ok(result) => Ok(result),
            Err(message) => return Json(json_rpc_error(&id, -32602, message)).into_response(),
        },
        other => Err(format!("unsupported method: {other}")),
    };
    let response = match result {
        Ok(result) => json!({"jsonrpc": "2.0", "id": id, "result": result}),
        Err(error) => json_rpc_error(&id, -32000, error),
    };
    Json(response).into_response()
}

async fn supervise_disconnect_aware<T, F>(
    mut response: tokio::sync::oneshot::Sender<T>,
    cancellation: tokio_util::sync::CancellationToken,
    operation: F,
) where
    F: std::future::Future<Output = T>,
{
    tokio::pin!(operation);
    tokio::select! {
        biased;
        _ = response.closed() => {
            cancellation.cancel();
            let _ = operation.await;
        }
        result = &mut operation => {
            let _ = response.send(result);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::http::HeaderValue;
    use std::sync::{
        Mutex,
        atomic::{AtomicUsize, Ordering},
    };
    use tablepro_core::{ColumnInfo, Connection, DriverError, Environment, ExecResult, QueryResult, TableInfo, Value};
    use tablepro_policy::{
        ApprovalOutcome, ApprovalRequest, ApprovalSink, AuditError, AuditEvent, AuditRecordPhase, AuditSink,
        AuditState, AuditTerminalStatus, GuardContext, PolicyConfig, PolicyGuard, Principal,
    };
    use tokio::{
        io::AsyncWriteExt,
        net::{TcpListener, TcpStream},
        sync::Notify,
    };

    fn headers_with_origin(origin: &str) -> HeaderMap {
        let mut headers = HeaderMap::new();
        headers.insert(ORIGIN, HeaderValue::from_str(origin).unwrap());
        headers
    }

    struct NoProvider;

    #[async_trait::async_trait]
    impl crate::bridge::ConnectionProvider for NoProvider {
        async fn list_saved_connections(&self) -> Result<Vec<tablepro_storage::SavedConnection>, String> {
            Ok(Vec::new())
        }
        async fn connection(
            &self,
            _connection_id: uuid::Uuid,
            _principal: tablepro_policy::Principal,
        ) -> Result<Arc<dyn tablepro_core::Connection>, String> {
            Err("no connections in this test".into())
        }
    }

    /// Keeps the temporary token-store directory alive for the test's
    /// duration -- dropping it early deletes tokens.json out from under
    /// a later `authenticate` call.
    fn bridge_with_token() -> (tempfile::TempDir, McpBridge, String) {
        let dir = tempfile::tempdir().unwrap();
        let store = Arc::new(crate::tokens::TokenStore::open(dir.path().join("tokens.json")).unwrap());
        let (_metadata, plaintext) = store
            .issue("test".into(), crate::TokenPermissions::ReadOnly, vec![], None)
            .unwrap();
        (dir, McpBridge::new(Arc::new(NoProvider), store), plaintext)
    }

    #[tokio::test]
    async fn streamable_http_server_stops_after_shutdown_is_requested() {
        let (_dir, bridge, _) = bridge_with_token();
        let shutdown = tokio_util::sync::CancellationToken::new();
        let server_shutdown = shutdown.clone();
        let task = tokio::spawn(async move {
            serve_streamable_http_until(
                Arc::new(bridge),
                McpServerConfig {
                    bind_host: "127.0.0.1".into(),
                    bind_port: 0,
                },
                server_shutdown,
            )
            .await
        });
        tokio::time::sleep(std::time::Duration::from_millis(10)).await;
        shutdown.cancel();
        let result = task.await.unwrap();
        assert!(result.is_ok(), "{result:?}");
    }

    #[tokio::test]
    async fn a_disconnected_http_caller_cancels_but_does_not_drop_its_operation() {
        let (response_tx, response_rx) = tokio::sync::oneshot::channel::<()>();
        let cancellation = tokio_util::sync::CancellationToken::new();
        let observed = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let operation_cancellation = cancellation.clone();
        let operation_observed = observed.clone();
        let task = tokio::spawn(supervise_disconnect_aware(
            response_tx,
            cancellation.clone(),
            async move {
                operation_cancellation.cancelled().await;
                operation_observed.store(true, std::sync::atomic::Ordering::SeqCst);
            },
        ));

        drop(response_rx);
        task.await.expect("request supervisor should finish after cancellation");

        assert!(cancellation.is_cancelled());
        assert!(observed.load(std::sync::atomic::Ordering::SeqCst));
    }

    struct PendingApproval {
        requested: Arc<Notify>,
    }

    #[async_trait::async_trait]
    impl ApprovalSink for PendingApproval {
        async fn request(&self, _request: ApprovalRequest) -> ApprovalOutcome {
            self.requested.notify_one();
            std::future::pending().await
        }
    }

    struct RecordingAudit {
        events: std::sync::Mutex<Vec<AuditEvent>>,
        recorded: Notify,
    }

    #[async_trait::async_trait]
    impl AuditSink for RecordingAudit {
        async fn record(&self, event: AuditEvent) -> Result<(), AuditError> {
            self.events.lock().expect("audit events").push(event);
            self.recorded.notify_one();
            Ok(())
        }
    }

    struct WriteProbeConnection {
        executions: Arc<AtomicUsize>,
    }

    #[async_trait::async_trait]
    impl Connection for WriteProbeConnection {
        async fn list_tables(&self) -> Result<Vec<TableInfo>, DriverError> {
            Ok(Vec::new())
        }
        async fn fetch_columns(&self, _schema: Option<&str>, _table: &str) -> Result<Vec<ColumnInfo>, DriverError> {
            Ok(Vec::new())
        }
        async fn fetch_rows(
            &self,
            _schema: Option<&str>,
            _table: &str,
            _offset: u64,
            _limit: u64,
        ) -> Result<QueryResult, DriverError> {
            Ok(QueryResult {
                columns: Vec::new(),
                rows: Vec::new(),
                truncated: false,
            })
        }
        async fn query(&self, _sql: &str) -> Result<QueryResult, DriverError> {
            Ok(QueryResult {
                columns: Vec::new(),
                rows: Vec::new(),
                truncated: false,
            })
        }
        async fn execute(&self, _sql: &str) -> Result<ExecResult, DriverError> {
            self.executions.fetch_add(1, Ordering::SeqCst);
            Ok(ExecResult { rows_affected: 1 })
        }
        async fn execute_params(&self, sql: &str, _params: &[Value]) -> Result<ExecResult, DriverError> {
            self.execute(sql).await
        }
        async fn execute_in_transaction(&self, _statements: &[(String, Vec<Value>)]) -> Result<Vec<u64>, DriverError> {
            Ok(Vec::new())
        }
        async fn ping(&self) -> Result<(), DriverError> {
            Ok(())
        }
        async fn close(self: Box<Self>) -> Result<(), DriverError> {
            Ok(())
        }
    }

    struct ApprovalProvider {
        saved: tablepro_storage::SavedConnection,
        connection: Arc<dyn Connection>,
    }

    #[async_trait::async_trait]
    impl crate::bridge::ConnectionProvider for ApprovalProvider {
        async fn list_saved_connections(&self) -> Result<Vec<tablepro_storage::SavedConnection>, String> {
            Ok(vec![self.saved.clone()])
        }
        async fn connection(
            &self,
            _connection_id: uuid::Uuid,
            _principal: Principal,
        ) -> Result<Arc<dyn Connection>, String> {
            Ok(self.connection.clone())
        }
    }

    #[tokio::test]
    async fn disconnecting_during_agent_approval_records_cancellation_and_never_executes() {
        let connection_id = uuid::Uuid::new_v4();
        let saved = serde_json::from_value(serde_json::json!({
            "id": connection_id,
            "name": "approval fixture",
            "driver_id": "sqlite",
            "host": "",
            "port": 0,
            "database": ":memory:",
            "username": "",
        }))
        .expect("saved connection fixture");
        let requested = Arc::new(Notify::new());
        let audit = Arc::new(RecordingAudit {
            events: Mutex::new(Vec::new()),
            recorded: Notify::new(),
        });
        let executions = Arc::new(AtomicUsize::new(0));
        let guarded: Arc<dyn Connection> = Arc::new(PolicyGuard::new(
            Arc::new(WriteProbeConnection {
                executions: executions.clone(),
            }),
            GuardContext {
                connection_id,
                connection_name: "approval fixture".into(),
                driver_id: "sqlite".into(),
                environment: Environment::Local,
                read_only: false,
                principal: Principal::Agent {
                    token: "test-token".into(),
                    client: Some("disconnect test".into()),
                    model: None,
                },
                policy: Arc::new(PolicyConfig::default()),
                approval: Arc::new(PendingApproval {
                    requested: requested.clone(),
                }),
                audit: audit.clone(),
                audit_state: Arc::new(AuditState::new()),
            },
        ));
        let directory = tempfile::tempdir().unwrap();
        let tokens = Arc::new(crate::tokens::TokenStore::open(directory.path().join("tokens.json")).unwrap());
        let (_, plaintext) = tokens
            .issue(
                "disconnect test".into(),
                crate::auth::TokenPermissions::ReadWrite,
                vec![connection_id],
                None,
            )
            .unwrap();
        let bridge = Arc::new(McpBridge::new(
            Arc::new(ApprovalProvider {
                saved,
                connection: guarded,
            }),
            tokens,
        ));

        let probe = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = probe.local_addr().unwrap();
        drop(probe);
        let shutdown = tokio_util::sync::CancellationToken::new();
        let server_shutdown = shutdown.clone();
        let server = tokio::spawn(async move {
            serve_streamable_http_until(
                bridge,
                McpServerConfig {
                    bind_host: "127.0.0.1".into(),
                    bind_port: address.port(),
                },
                server_shutdown,
            )
            .await
        });
        let mut stream = tokio::time::timeout(std::time::Duration::from_secs(5), async {
            loop {
                match TcpStream::connect(address).await {
                    Ok(stream) => break stream,
                    Err(_) => tokio::time::sleep(std::time::Duration::from_millis(10)).await,
                }
            }
        })
        .await
        .expect("MCP listener should start");
        let body = serde_json::json!({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": {
                "name": "execute_write",
                "arguments": {
                    "connection_id": connection_id,
                    "sql": "INSERT INTO jobs(id) VALUES (1)",
                    "preview": false,
                    "token": plaintext,
                }
            }
        })
        .to_string();
        let request = format!(
            "POST /mcp HTTP/1.1\r\nHost: {address}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: keep-alive\r\n\r\n{body}",
            body.len()
        );
        stream.write_all(request.as_bytes()).await.unwrap();
        tokio::time::timeout(std::time::Duration::from_secs(5), requested.notified())
            .await
            .expect("write should reach human approval");
        drop(stream);

        tokio::time::timeout(std::time::Duration::from_secs(5), audit.recorded.notified())
            .await
            .expect("disconnect should produce a terminal audit record");
        {
            let events = audit.events.lock().expect("audit events");
            assert_eq!(events.len(), 1);
            assert_eq!(events[0].phase, AuditRecordPhase::Outcome);
            assert_eq!(events[0].terminal_status, AuditTerminalStatus::Cancelled);
        }
        assert_eq!(
            executions.load(Ordering::SeqCst),
            0,
            "cancelled write must not reach the driver"
        );

        shutdown.cancel();
        assert!(server.await.expect("server task").is_ok());
    }

    /// H-adjacent finding: tools/list disclosed the full tool catalogue to
    /// any caller that could reach the listener, with no token at all.
    #[test]
    fn tools_list_is_refused_without_a_token() {
        let (_dir, bridge, _) = bridge_with_token();
        let error = handle_tools_list(&bridge, &json!({})).unwrap_err();
        assert!(error.contains("token"), "{error}");
    }

    #[test]
    fn tools_list_is_refused_with_a_bad_token() {
        let (_dir, bridge, _) = bridge_with_token();
        let error = handle_tools_list(&bridge, &json!({"token": "not-a-real-token"})).unwrap_err();
        assert!(!error.is_empty());
    }

    #[test]
    fn tools_list_succeeds_with_a_valid_token() {
        let (_dir, bridge, token) = bridge_with_token();
        let result = handle_tools_list(&bridge, &json!({"token": token})).unwrap();
        let tools = result["tools"].as_array().unwrap();
        assert_eq!(tools.len(), TOOL_NAMES.len());
    }

    /// A minimal in-memory `AsyncWrite` sink so `serve_json_rpc_lines` can be
    /// driven from a test without real stdio: pushes every write straight
    /// into a shared buffer the test can inspect afterward.
    #[derive(Clone)]
    struct RecordingWriter(std::sync::Arc<std::sync::Mutex<Vec<u8>>>);

    impl tokio::io::AsyncWrite for RecordingWriter {
        fn poll_write(
            self: std::pin::Pin<&mut Self>,
            _cx: &mut std::task::Context<'_>,
            buf: &[u8],
        ) -> std::task::Poll<std::io::Result<usize>> {
            self.0.lock().unwrap().extend_from_slice(buf);
            std::task::Poll::Ready(Ok(buf.len()))
        }
        fn poll_flush(
            self: std::pin::Pin<&mut Self>,
            _cx: &mut std::task::Context<'_>,
        ) -> std::task::Poll<std::io::Result<()>> {
            std::task::Poll::Ready(Ok(()))
        }
        fn poll_shutdown(
            self: std::pin::Pin<&mut Self>,
            _cx: &mut std::task::Context<'_>,
        ) -> std::task::Poll<std::io::Result<()>> {
            std::task::Poll::Ready(Ok(()))
        }
    }

    /// The stdio server used to terminate the whole session on the first
    /// non-UTF-8 byte instead of resyncing the way it already does for
    /// invalid JSON. A malformed line must produce one parse-error
    /// response and leave the loop able to answer the next request.
    #[tokio::test]
    async fn a_non_utf8_line_is_resynced_instead_of_ending_the_session() {
        let (_dir, bridge, _) = bridge_with_token();
        let mut input = Vec::new();
        input.extend_from_slice(&[0xFF, 0xFE, 0xFD, b'\n']);
        input.extend_from_slice(b"{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}\n");
        let reader = BufReader::new(std::io::Cursor::new(input));
        let output = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
        let writer = RecordingWriter(output.clone());

        serve_json_rpc_lines(&bridge, reader, writer).await.unwrap();

        let bytes = output.lock().unwrap().clone();
        let text = String::from_utf8(bytes).unwrap();
        let mut responses = text
            .lines()
            .map(|line| serde_json::from_str::<JsonValue>(line).unwrap());
        let first = responses.next().unwrap();
        assert_eq!(first["error"]["code"], -32700, "{first}");
        let second = responses.next().unwrap();
        assert_eq!(
            second["result"],
            json!({}),
            "the ping after the bad line must still be answered: {second}"
        );
    }

    #[tokio::test]
    async fn discarding_an_oversized_line_resyncs_on_the_next_request() {
        let oversized = "x".repeat(DISCARD_CHUNK_BYTES as usize * 3);
        let payload = format!("{oversized}\n{{\"id\":1}}\n");
        let mut reader = BufReader::new(std::io::Cursor::new(payload.into_bytes()));

        discard_rest_of_line(&mut reader).await.unwrap();

        let mut next = String::new();
        reader.read_line(&mut next).await.unwrap();
        assert_eq!(next.trim(), "{\"id\":1}");
    }

    #[tokio::test]
    async fn discarding_stops_at_end_of_input() {
        let mut reader = BufReader::new(std::io::Cursor::new(b"no newline here".to_vec()));
        discard_rest_of_line(&mut reader).await.unwrap();
        let mut next = String::new();
        assert_eq!(reader.read_line(&mut next).await.unwrap(), 0);
    }

    #[test]
    fn the_advertised_protocol_revision_is_the_current_one() {
        let result = initialize_result(&json!({})).expect("no requested revision negotiates");
        assert_eq!(result["protocolVersion"], "2026-07-28");
    }

    #[test]
    fn an_older_client_revision_is_accepted_and_echoed() {
        for older in ["2025-11-25", "2025-06-18"] {
            let result = initialize_result(&json!({"protocolVersion": older})).expect("older revision");
            assert_eq!(result["protocolVersion"], older);
        }
    }

    #[test]
    fn an_unknown_protocol_revision_is_refused_as_invalid_params() {
        for bad in [json!("2019-01-01"), json!("garbage"), json!(7), json!(null)] {
            let message =
                initialize_result(&json!({"protocolVersion": bad})).expect_err("an unknown revision must be refused");
            let error = json_rpc_error(&JsonValue::from(1), -32602, message);
            assert_eq!(error["error"]["code"], -32602);
        }
    }

    #[test]
    fn loopback_hosts_resolve_to_a_loopback_socket() {
        for host in ["127.0.0.1", "localhost", "::1", "[::1]", "127.0.0.53", " 127.0.0.1 "] {
            let addr = loopback_bind_addr(host, 17432).unwrap_or_else(|e| panic!("{host}: {e}"));
            assert!(addr.ip().is_loopback(), "{host}");
            assert_eq!(addr.port(), 17432);
        }
    }

    #[test]
    fn a_non_loopback_bind_host_is_refused() {
        for host in [
            "0.0.0.0",
            "::",
            "[::]",
            "192.168.1.10",
            "10.0.0.1",
            "203.0.113.5",
            "example.com",
            "127.0.0.1.evil.com",
            "",
        ] {
            let error = loopback_bind_addr(host, 17432).expect_err(host);
            assert!(error.contains("refusing to bind"), "{host}: {error}");
        }
    }

    #[test]
    fn native_requests_without_origin_are_allowed() {
        assert!(origin_is_allowed(&HeaderMap::new()));
    }

    #[test]
    fn trusted_browser_origins_are_allowed() {
        for origin in [
            "http://localhost:3000",
            "http://127.0.0.1:8080",
            "http://[::1]:8080",
            "https://claude.ai",
            "https://app.cursor.com",
        ] {
            assert!(origin_is_allowed(&headers_with_origin(origin)), "{origin}");
        }
    }

    #[test]
    fn untrusted_browser_origins_are_rejected() {
        for origin in [
            "https://example.com",
            "https://cursor.com",
            "https://evil.claude.ai",
            "file:///tmp/request",
            "null",
        ] {
            assert!(!origin_is_allowed(&headers_with_origin(origin)), "{origin}");
        }
    }
}
