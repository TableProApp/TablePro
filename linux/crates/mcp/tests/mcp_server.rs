//! The MCP server over HTTP, against real SQLite sessions.

#![expect(
    clippy::expect_used,
    reason = "the setup helpers fail a test the way the test functions themselves do"
)]
#![expect(
    clippy::disallowed_types,
    reason = "requests are written with json!, and a request's key order means nothing to the server"
)]

use std::collections::HashMap;
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use async_trait::async_trait;
use secrecy::{ExposeSecret, SecretString};
use serde_json::{Value as Json, json};
use tablepro_core::credentials::CredentialInteraction;
use tablepro_core::dialect::SqlDialect;
use tablepro_core::{
    ConnectEnvironment, ExternalAccess, FileEndpoint, LivenessPolicy, ResultEvent, ResultSink, RunOptions,
    SafeModeLevel, SinkFlow, TlsConfig, UserSql, WorkspaceSettings,
};
use tablepro_driver_sqlite::SqliteDriver;
use tablepro_mcp::{AccessToken, McpHost, McpServer, OpenOutcome, ToolContext, WriteApproval};
use tablepro_session::runtime::Tasks;
use tablepro_session::{
    ConnectRequest, ConnectServices, ConnectionMetadata, Connector, DefaultDeadlines, DriverConnector,
    NoStoredCredentials, RequestTarget, Session, SessionDeps,
};
use tablepro_ssh::{SshRuntimeCell, SshServices};
use tablepro_storage::query_history::NewEntry;
use tablepro_storage::{ConnectionStore, SavedConnection, StoragePaths};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio_util::sync::CancellationToken;
use uuid::Uuid;

const TOKEN: &str = "tp_test_token";

/// The test runtime's handle. A test is already inside its runtime, so
/// this is where taking the ambient handle is correct.
#[expect(
    clippy::disallowed_methods,
    reason = "a test runs inside its own runtime; the app passes its Tasks in"
)]
fn tasks() -> Tasks {
    Tasks::new(tokio::runtime::Handle::current())
}

/// The app's side as the server sees it: the open sessions, and the
/// user's answer to every write.
#[derive(Default)]
struct TestHost {
    sessions: Mutex<HashMap<Uuid, Arc<Session>>>,
    approves: AtomicBool,
    asked: Mutex<Vec<WriteApproval>>,
    recorded: Mutex<Vec<NewEntry>>,
}

#[async_trait]
impl McpHost for TestHost {
    async fn session(&self, id: Uuid) -> Option<Arc<Session>> {
        self.sessions.lock().expect("sessions").get(&id).cloned()
    }

    async fn open_connections(&self) -> Vec<Uuid> {
        self.sessions.lock().expect("sessions").keys().copied().collect()
    }

    async fn open(&self, _connection: SavedConnection) -> OpenOutcome {
        OpenOutcome::Closed
    }

    async fn approve(&self, approval: WriteApproval) -> bool {
        self.asked.lock().expect("asked").push(approval);
        self.approves.load(Ordering::SeqCst)
    }

    async fn record(&self, entry: NewEntry, _dialect: Arc<dyn SqlDialect>) {
        self.recorded.lock().expect("recorded").push(entry);
    }
}

struct Ids {
    readable: Uuid,
    writable: Uuid,
    locked: Uuid,
    blocked: Uuid,
    closed: Uuid,
}

struct Harness {
    _dir: tempfile::TempDir,
    server: McpServer,
    host: Arc<TestHost>,
    ids: Ids,
}

fn saved(id: Uuid, name: &str, file: &Path, access: ExternalAccess) -> SavedConnection {
    SavedConnection {
        id,
        name: name.to_owned(),
        driver_id: "sqlite".to_owned(),
        host: String::new(),
        port: 0,
        database: file.display().to_string(),
        username: String::new(),
        tls: TlsConfig::disabled(),
        safe_mode: SafeModeLevel::Off,
        external_access: access,
        ai_policy: tablepro_core::AiPolicy::Ask,
        auth_mode: tablepro_core::AuthMode::Password,
        ssh: None,
        last_opened_at: None,
        color: None,
        group: None,
        tags: Vec::new(),
        icon: None,
        options: Default::default(),
    }
}

async fn open_session(dir: &Path, file: &Path, id: Uuid, read_only: bool, create: bool) -> Arc<Session> {
    let connector = Arc::new(DriverConnector::new(
        ConnectServices {
            environment: ConnectEnvironment::new("test"),
            ssh: SshServices {
                runtime: Arc::new(SshRuntimeCell::new(dir.join("runtime"))),
                ssh_program: "ssh".into(),
                ssh_keygen_program: "ssh-keygen".into(),
                askpass_program: "/nonexistent/tablepro-askpass".into(),
                config_file: None,
            },
            liveness: LivenessPolicy::DESKTOP,
        },
        Arc::new(DefaultDeadlines::new(LivenessPolicy::DESKTOP)),
    ));
    let endpoint = match create {
        true => FileEndpoint::create_new(file.to_owned()),
        false => FileEndpoint::open_existing(file.to_owned()),
    }
    .expect("a file endpoint");
    let request = ConnectRequest {
        metadata: ConnectionMetadata {
            id,
            name: "shop".to_owned(),
            driver_id: "sqlite".to_owned(),
        },
        driver: Arc::new(SqliteDriver),
        target: RequestTarget::File(endpoint),
        workspace_settings: WorkspaceSettings::workspace(read_only),
        safe_mode: match read_only {
            true => SafeModeLevel::ReadOnly,
            false => SafeModeLevel::Off,
        },
    };
    let pending = connector
        .establish(request, CredentialInteraction::Unattended, CancellationToken::new())
        .await
        .expect("an open SQLite file");
    Session::start(
        pending,
        SessionDeps {
            connector,
            credentials: Arc::new(NoStoredCredentials),
            deadlines: Arc::new(DefaultDeadlines::new(LivenessPolicy::DESKTOP)),
            tasks: tasks(),
            prompter: None,
        },
    )
}

struct Discard;

#[async_trait]
impl ResultSink for Discard {
    async fn accept(&mut self, _event: ResultEvent) -> SinkFlow {
        SinkFlow::Continue
    }
}

async fn seed(session: &Session) {
    let editor = session
        .open_editor_session(Default::default(), &CancellationToken::new())
        .await
        .expect("an editor session");
    for sql in [
        "CREATE TABLE orders (id INTEGER PRIMARY KEY, status TEXT NOT NULL, total NUMERIC)",
        "INSERT INTO orders (status, total) VALUES ('open', 10), ('open', 20), ('paid', 30)",
    ] {
        let summary = editor
            .run(
                UserSql::new(sql),
                RunOptions::new(CancellationToken::new()),
                Box::new(Discard),
            )
            .await
            .expect("a run");
        assert!(summary.succeeded(), "{sql}: {:?}", summary.end);
    }
    editor.close().await;
}

async fn harness() -> Harness {
    let dir = tempfile::tempdir().expect("a temporary directory");
    let file = dir.path().join("shop.db");
    let ids = Ids {
        readable: Uuid::new_v4(),
        writable: Uuid::new_v4(),
        locked: Uuid::new_v4(),
        blocked: Uuid::new_v4(),
        closed: Uuid::new_v4(),
    };
    let writable = open_session(dir.path(), &file, ids.writable, false, true).await;
    seed(&writable).await;
    let host = Arc::new(TestHost::default());
    let mut opened = vec![(ids.writable, writable)];
    for (id, read_only) in [(ids.readable, false), (ids.locked, true), (ids.blocked, false)] {
        opened.push((id, open_session(dir.path(), &file, id, read_only, false).await));
    }
    host.sessions.lock().expect("sessions").extend(opened);
    let paths = StoragePaths::under(dir.path(), "tablepro-test", "app.tablepro.TablePro.Test");
    let store = ConnectionStore::new(&paths);
    for connection in [
        saved(ids.readable, "Readable", &file, ExternalAccess::ReadOnly),
        saved(ids.writable, "Writable", &file, ExternalAccess::ReadWrite),
        saved(ids.locked, "Locked", &file, ExternalAccess::ReadWrite),
        saved(ids.blocked, "Blocked", &file, ExternalAccess::Blocked),
        saved(ids.closed, "Closed", &file, ExternalAccess::ReadOnly),
    ] {
        store.upsert_blocking(connection).expect("a saved connection");
    }
    let token = AccessToken::from_secret(SecretString::from(TOKEN.to_owned())).expect("a token");
    let context = ToolContext {
        host: host.clone(),
        connections: store,
    };
    let server = McpServer::start(0, token, context, "0.0.0-test", &tasks())
        .await
        .expect("a listening server");
    Harness {
        _dir: dir,
        server,
        host,
        ids,
    }
}

struct Reply {
    status: u16,
    headers: String,
    body: String,
}

/// One request on a connection of its own, written by hand so the test
/// controls every header a client sends.
async fn send(port: u16, path: &str, headers: &[(&str, &str)], body: &str) -> Reply {
    let mut stream = tokio::net::TcpStream::connect(("127.0.0.1", port))
        .await
        .expect("a connection to the server");
    let mut request = format!(
        "POST {path} HTTP/1.1\r\nConnection: close\r\nContent-Length: {}\r\n",
        body.len()
    );
    if !headers.iter().any(|(name, _)| name.eq_ignore_ascii_case("host")) {
        request.push_str(&format!("Host: 127.0.0.1:{port}\r\n"));
    }
    for (name, value) in headers {
        request.push_str(&format!("{name}: {value}\r\n"));
    }
    request.push_str("\r\n");
    request.push_str(body);
    stream.write_all(request.as_bytes()).await.expect("the request");
    let mut raw = Vec::new();
    stream.read_to_end(&mut raw).await.expect("the response");
    let text = String::from_utf8(raw).expect("a UTF-8 response");
    let (head, body) = text.split_once("\r\n\r\n").expect("a header block");
    let status = head
        .split(' ')
        .nth(1)
        .and_then(|code| code.parse().ok())
        .expect("a status code");
    let headers = head.to_ascii_lowercase();
    let body = match headers.contains("transfer-encoding: chunked") {
        true => unchunk(body),
        false => body.to_owned(),
    };
    Reply { status, headers, body }
}

fn unchunk(mut body: &str) -> String {
    let mut out = String::new();
    while let Some((size, rest)) = body.split_once("\r\n") {
        let size = usize::from_str_radix(size.trim(), 16).expect("a chunk size");
        if size == 0 {
            break;
        }
        out.push_str(&rest[..size]);
        body = &rest[size + 2..];
    }
    out
}

const MCP_HEADERS: [(&str, &str); 4] = [
    ("Authorization", "Bearer tp_test_token"),
    ("Content-Type", "application/json"),
    ("Accept", "application/json, text/event-stream"),
    ("MCP-Protocol-Version", "2025-06-18"),
];

async fn rpc(harness: &Harness, method: &str, params: Json) -> Json {
    let body = json!({ "jsonrpc": "2.0", "id": 1, "method": method, "params": params }).to_string();
    let reply = send(harness.server.address().port(), "/mcp", &MCP_HEADERS, &body).await;
    assert_eq!(reply.status, 200, "{method}: {}", reply.body);
    let payload = reply
        .body
        .lines()
        .find_map(|line| line.strip_prefix("data: "))
        .unwrap_or(&reply.body);
    let message: Json = serde_json::from_str(payload).expect("a JSON-RPC reply");
    message.get("result").cloned().expect("a result")
}

/// A tool's answer: whether it failed, and its text.
async fn call(harness: &Harness, tool: &str, arguments: Json) -> (bool, String) {
    let result = rpc(harness, "tools/call", json!({ "name": tool, "arguments": arguments })).await;
    let failed = result.get("isError").and_then(Json::as_bool).unwrap_or(false);
    let text = result["content"][0]["text"].as_str().expect("a text answer").to_owned();
    (failed, text)
}

fn parsed(text: &str) -> Json {
    serde_json::from_str(text).expect("a JSON answer")
}

async fn order_count(harness: &Harness) -> u64 {
    let (failed, text) = call(
        harness,
        "count_rows",
        json!({ "connection_id": harness.ids.readable.to_string(), "table": "orders" }),
    )
    .await;
    assert!(!failed, "{text}");
    parsed(&text)["row_count"].as_u64().expect("a count")
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_request_without_the_token_or_off_the_path_is_refused() {
    let harness = harness().await;
    let port = harness.server.address().port();
    let body = json!({ "jsonrpc": "2.0", "id": 1, "method": "tools/list" }).to_string();

    let anonymous = send(port, "/mcp", &MCP_HEADERS[1..], &body).await;
    let mut wrong = MCP_HEADERS;
    wrong[0] = ("Authorization", "Bearer tp_guess");
    let guessed = send(port, "/mcp", &wrong, &body).await;
    let elsewhere = send(port, "/other", &MCP_HEADERS, &body).await;

    assert_eq!(anonymous.status, 401);
    assert!(
        anonymous.headers.contains("www-authenticate: bearer"),
        "{}",
        anonymous.headers
    );
    assert_eq!(guessed.status, 401);
    assert_eq!(elsewhere.status, 404);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_foreign_host_or_a_browser_origin_is_refused() {
    let harness = harness().await;
    let port = harness.server.address().port();
    let body = json!({ "jsonrpc": "2.0", "id": 1, "method": "tools/list" }).to_string();

    let mut rebound = MCP_HEADERS.to_vec();
    rebound.push(("Host", "attacker.example"));
    let mut browser = MCP_HEADERS.to_vec();
    browser.push(("Origin", "https://attacker.example"));

    assert_eq!(send(port, "/mcp", &rebound, &body).await.status, 403);
    assert_eq!(send(port, "/mcp", &browser, &body).await.status, 403);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn initialize_names_the_server_and_lists_every_tool() {
    let harness = harness().await;

    let info = rpc(
        &harness,
        "initialize",
        json!({
            "protocolVersion": "2025-06-18",
            "capabilities": {},
            "clientInfo": { "name": "test", "version": "1" },
        }),
    )
    .await;
    let tools = rpc(&harness, "tools/list", json!({})).await;

    assert_eq!(info["serverInfo"]["name"], "tablepro");
    assert!(
        info["instructions"]
            .as_str()
            .is_some_and(|text| text.contains("list_connections"))
    );
    let names: Vec<&str> = tools["tools"]
        .as_array()
        .expect("tools")
        .iter()
        .filter_map(|tool| tool["name"].as_str())
        .collect();
    assert_eq!(names.len(), 9, "{names:?}");
    assert!(names.contains(&"execute_query"));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_blocked_connection_is_not_listed_and_does_not_exist() {
    let harness = harness().await;

    let (failed, text) = call(&harness, "list_connections", json!({})).await;
    let (blocked_failed, blocked) = call(
        &harness,
        "describe_table",
        json!({ "connection_id": harness.ids.blocked.to_string(), "table": "orders" }),
    )
    .await;

    assert!(!failed, "{text}");
    let listed = parsed(&text);
    let names: Vec<&str> = listed["connections"]
        .as_array()
        .expect("connections")
        .iter()
        .filter_map(|connection| connection["name"].as_str())
        .collect();
    assert_eq!(names, ["Closed", "Locked", "Readable", "Writable"]);
    let closed = &listed["connections"][0];
    assert_eq!(closed["is_open"], false);
    assert_eq!(closed["external_access"], "read_only");
    assert_eq!(listed["connections"][1]["safe_mode"], "read_only");
    assert!(blocked_failed);
    assert!(blocked.starts_with("not_found:"), "{blocked}");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_read_runs_and_answers_with_its_rows() {
    let harness = harness().await;

    let (failed, text) = call(
        &harness,
        "execute_query",
        json!({
            "connection_id": harness.ids.readable.to_string(),
            "query": "SELECT id, status FROM orders ORDER BY id",
            "max_rows": 2,
        }),
    )
    .await;

    assert!(!failed, "{text}");
    let answer = parsed(&text);
    let set = &answer["result_sets"][0];
    assert_eq!(
        set["rows"],
        json!([{ "id": 1, "status": "open" }, { "id": 2, "status": "open" }])
    );
    assert_eq!(set["truncated"], true);
    assert!(harness.host.asked.lock().expect("asked").is_empty());
    let recorded = harness.host.recorded.lock().expect("recorded");
    assert_eq!(recorded.len(), 1);
    assert_eq!(recorded[0].query, "SELECT id, status FROM orders ORDER BY id");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn two_statements_in_one_call_are_refused() {
    let harness = harness().await;

    let (failed, text) = call(
        &harness,
        "execute_query",
        json!({
            "connection_id": harness.ids.writable.to_string(),
            "query": "SELECT 1; DELETE FROM orders",
        }),
    )
    .await;

    assert!(failed);
    assert!(text.starts_with("invalid_argument:"), "{text}");
    assert_eq!(order_count(&harness).await, 3);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_write_where_clients_only_read_is_denied_without_asking() {
    let harness = harness().await;

    let (failed, text) = call(
        &harness,
        "execute_query",
        json!({
            "connection_id": harness.ids.readable.to_string(),
            "query": "DELETE FROM orders WHERE id = 1",
        }),
    )
    .await;

    assert!(failed);
    assert!(text.starts_with("denied:"), "{text}");
    assert!(harness.host.asked.lock().expect("asked").is_empty());
    assert_eq!(order_count(&harness).await, 3);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_write_the_user_declines_changes_nothing() {
    let harness = harness().await;
    harness.host.approves.store(false, Ordering::SeqCst);

    let (failed, text) = call(
        &harness,
        "execute_query",
        json!({
            "connection_id": harness.ids.writable.to_string(),
            "query": "DELETE FROM orders WHERE id = 1",
        }),
    )
    .await;

    assert!(failed);
    assert!(text.starts_with("user_cancelled:"), "{text}");
    let asked = harness.host.asked.lock().expect("asked").clone();
    assert_eq!(asked.len(), 1);
    assert_eq!(asked[0].sql, "DELETE FROM orders WHERE id = 1");
    assert!(!asked[0].destructive);
    assert_eq!(order_count(&harness).await, 3);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_write_the_user_approves_runs_once_and_is_recorded() {
    let harness = harness().await;
    harness.host.approves.store(true, Ordering::SeqCst);

    let (failed, text) = call(
        &harness,
        "execute_query",
        json!({
            "connection_id": harness.ids.writable.to_string(),
            "query": "DELETE FROM orders WHERE status = 'paid'",
        }),
    )
    .await;
    let (_, emptied) = call(
        &harness,
        "execute_query",
        json!({ "connection_id": harness.ids.writable.to_string(), "query": "DELETE FROM orders" }),
    )
    .await;

    assert!(!failed, "{text}");
    assert_eq!(parsed(&text)["rows_affected"], 1);
    assert!(!emptied.starts_with("denied"), "{emptied}");
    let asked = harness.host.asked.lock().expect("asked").clone();
    assert_eq!(asked.len(), 2);
    assert!(asked[1].destructive, "a DELETE without WHERE is not marked destructive");
    assert_eq!(order_count(&harness).await, 0);
    let recorded = harness.host.recorded.lock().expect("recorded");
    assert_eq!(recorded[0].rows_affected, Some(1));
    assert_eq!(recorded[0].connection_id, harness.ids.writable);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn safe_mode_read_only_refuses_a_write_a_client_may_make() {
    let harness = harness().await;
    harness.host.approves.store(true, Ordering::SeqCst);

    let (failed, text) = call(
        &harness,
        "execute_query",
        json!({
            "connection_id": harness.ids.locked.to_string(),
            "query": "UPDATE orders SET status = 'void' WHERE id = 1",
        }),
    )
    .await;

    assert!(failed);
    assert!(text.starts_with("denied:"), "{text}");
    assert!(harness.host.asked.lock().expect("asked").is_empty());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn browse_and_count_filter_and_sort_without_sql() {
    let harness = harness().await;
    let id = harness.ids.readable.to_string();

    let (failed, text) = call(
        &harness,
        "browse_table",
        json!({
            "connection_id": id,
            "table": "orders",
            "filters": [{ "column": "status", "operator": "eq", "value": "open" }],
            "sort": [{ "column": "total", "direction": "descending" }],
        }),
    )
    .await;
    let (_, counted) = call(
        &harness,
        "count_rows",
        json!({
            "connection_id": id,
            "table": "orders",
            "filters": [{ "column": "total", "operator": "between", "values": ["15", "35"] }],
        }),
    )
    .await;
    let (bad_failed, bad) = call(
        &harness,
        "browse_table",
        json!({
            "connection_id": id,
            "table": "orders",
            "filters": [{ "column": "missing", "operator": "is_null" }],
        }),
    )
    .await;

    assert!(!failed, "{text}");
    let ids: Vec<i64> = parsed(&text)["result_sets"][0]["rows"]
        .as_array()
        .expect("rows")
        .iter()
        .filter_map(|row| row["id"].as_i64())
        .collect();
    assert_eq!(ids, [2, 1]);
    assert_eq!(parsed(&counted)["row_count"], 2);
    assert!(bad_failed);
    assert!(bad.starts_with("invalid_argument:"), "{bad}");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn describe_and_ddl_name_the_table_as_defined() {
    let harness = harness().await;
    let id = harness.ids.readable.to_string();

    let (failed, described) = call(
        &harness,
        "describe_table",
        json!({ "connection_id": id, "table": "orders" }),
    )
    .await;
    let (_, ddl) = call(
        &harness,
        "get_table_ddl",
        json!({ "connection_id": id, "table": "orders" }),
    )
    .await;
    let (missing_failed, missing) = call(
        &harness,
        "describe_table",
        json!({ "connection_id": id, "table": "nowhere" }),
    )
    .await;
    let (_, tables) = call(&harness, "list_tables", json!({ "connection_id": id })).await;

    assert!(!failed, "{described}");
    let columns: Vec<(String, bool)> = parsed(&described)["columns"]
        .as_array()
        .expect("columns")
        .iter()
        .map(|column| {
            (
                column["name"].as_str().unwrap_or_default().to_owned(),
                column["is_primary_key"].as_bool().unwrap_or_default(),
            )
        })
        .collect();
    assert_eq!(
        columns,
        [
            ("id".to_owned(), true),
            ("status".to_owned(), false),
            ("total".to_owned(), false)
        ]
    );
    assert!(
        parsed(&ddl)["ddl"]
            .as_str()
            .is_some_and(|ddl| ddl.contains("CREATE TABLE")),
        "{ddl}"
    );
    // SQLite names the missing table itself; an engine that lists no
    // columns for it answers not_found.
    assert!(missing_failed);
    assert!(missing.contains("no such table: main.nowhere"), "{missing}");
    assert_eq!(parsed(&tables)["tables"][0]["name"], "orders");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_connection_not_open_or_not_saved_says_so() {
    let harness = harness().await;

    let (closed_failed, closed) = call(
        &harness,
        "list_schemas",
        json!({ "connection_id": harness.ids.closed.to_string() }),
    )
    .await;
    let (connect_failed, connect) = call(
        &harness,
        "connect",
        json!({ "connection_id": harness.ids.closed.to_string() }),
    )
    .await;
    let (unknown_failed, unknown) = call(
        &harness,
        "list_schemas",
        json!({ "connection_id": Uuid::new_v4().to_string() }),
    )
    .await;
    let (bad_failed, bad) = call(&harness, "list_schemas", json!({ "connection_id": "orders" })).await;

    assert!(closed_failed);
    assert!(closed.starts_with("not_connected:"), "{closed}");
    assert!(connect_failed);
    assert!(connect.starts_with("not_connected:"), "{connect}");
    assert!(unknown_failed);
    assert!(unknown.starts_with("not_found:"), "{unknown}");
    assert!(bad_failed);
    assert!(bad.starts_with("invalid_argument:"), "{bad}");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_replaced_token_turns_the_old_one_away() {
    let harness = harness().await;
    let port = harness.server.address().port();
    let body = json!({ "jsonrpc": "2.0", "id": 1, "method": "tools/list" }).to_string();
    let fresh = AccessToken::generate().expect("a token");
    let bearer = format!("Bearer {}", fresh.secret().expose_secret());

    harness.server.replace_token(fresh);
    let mut renewed = MCP_HEADERS;
    renewed[0] = ("Authorization", bearer.as_str());

    assert_eq!(send(port, "/mcp", &MCP_HEADERS, &body).await.status, 401);
    assert_eq!(send(port, "/mcp", &renewed, &body).await.status, 200);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_stopped_server_has_freed_its_port() {
    let Harness { _dir, server, .. } = harness().await;
    let port = server.address().port();

    server.shutdown().await;
    let rebound = tokio::net::TcpListener::bind(("127.0.0.1", port)).await;

    assert!(rebound.is_ok(), "{rebound:?}");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_write_stops_when_its_connection_closes_in_tablepro() {
    let harness = harness().await;
    harness.host.approves.store(true, Ordering::SeqCst);
    let session = harness
        .host
        .session(harness.ids.writable)
        .await
        .expect("the writable session");
    let bulk = "INSERT INTO orders (status, total) \
        WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM n WHERE x < 500000000) \
        SELECT 'bulk', x FROM n";
    let closing = async {
        while harness.host.asked.lock().expect("asked").is_empty() {
            tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        }
        tokio::time::sleep(std::time::Duration::from_millis(300)).await;
        let _ = session.begin_shutdown().await;
    };

    let ((failed, text), ()) = tokio::join!(
        call(
            &harness,
            "execute_query",
            json!({
                "connection_id": harness.ids.writable.to_string(),
                "query": bulk,
                "timeout_seconds": 300,
            }),
        ),
        closing,
    );

    assert!(failed, "{text}");
    assert!(text.starts_with("not_connected:"), "{text}");
    assert_eq!(order_count(&harness).await, 3);
}
