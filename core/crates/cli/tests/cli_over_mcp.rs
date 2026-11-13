// The command against the MCP server it talks to in the app, over real SQLite sessions.

#![expect(
    clippy::expect_used,
    reason = "the setup helpers fail a test the way the test functions themselves do"
)]

use std::collections::HashMap;
use std::ffi::OsString;
use std::path::Path;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

use async_trait::async_trait;
use secrecy::SecretString;
use tablepro_cli::{Exit, Host, HostError, Terminal};
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
use tokio_util::sync::CancellationToken;
use uuid::Uuid;

const TOKEN: &str = "tp_test_token";

#[derive(Default)]
struct App {
    sessions: Mutex<HashMap<Uuid, Arc<Session>>>,
    // What connect answers for a session that is listed but shut down: open, though every tool still finds it closed.
    reopens: Mutex<HashMap<Uuid, Arc<Session>>>,
    opens: AtomicUsize,
    approves: AtomicBool,
}

#[async_trait]
impl McpHost for App {
    async fn session(&self, id: Uuid) -> Option<Arc<Session>> {
        self.sessions.lock().expect("sessions").get(&id).cloned()
    }

    async fn open_connections(&self) -> Vec<Uuid> {
        self.sessions.lock().expect("sessions").keys().copied().collect()
    }

    async fn open(&self, connection: SavedConnection) -> OpenOutcome {
        self.opens.fetch_add(1, Ordering::SeqCst);
        match self.reopens.lock().expect("reopens").get(&connection.id) {
            Some(session) => OpenOutcome::Open(session.clone()),
            None => OpenOutcome::Closed,
        }
    }

    async fn approve(&self, _approval: WriteApproval) -> bool {
        self.approves.load(Ordering::SeqCst)
    }

    async fn record(&self, _entry: NewEntry, _dialect: Arc<dyn SqlDialect>) {}
}

struct Ids {
    readable: Uuid,
    writable: Uuid,
    blocked: Uuid,
    closed: Uuid,
    twin: Uuid,
    other_twin: Uuid,
    stale: Uuid,
}

struct Harness {
    _dir: tempfile::TempDir,
    server: McpServer,
    app: Arc<App>,
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
        query_timeout_secs: None,
        masking_rules: Vec::new(),
        auth_mode: tablepro_core::AuthMode::Password,
        ssh: None,
        last_opened_at: None,
        color: None,
        group_id: None,
        order: 0,
        tags: Vec::new(),
        icon: None,
        options: Default::default(),
    }
}

async fn open_session(dir: &Path, file: &Path, id: Uuid, create: bool) -> Arc<Session> {
    let connector = Arc::new(DriverConnector::new(
        ConnectServices {
            environment: ConnectEnvironment::new("test"),
            ssh: Arc::new(SshServices {
                runtime: Arc::new(SshRuntimeCell::new(dir.join("runtime"))),
                ssh_program: "ssh".into(),
                ssh_keygen_program: "ssh-keygen".into(),
                askpass_program: "/nonexistent/tablepro-askpass".into(),
                config_file: None,
            }),
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
        workspace_settings: WorkspaceSettings::workspace(false),
        safe_mode: SafeModeLevel::Off,
        masking: Default::default(),
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
            tasks: Tasks::new(tokio::runtime::Handle::current()),
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
        "CREATE TABLE orders (id INTEGER PRIMARY KEY, status TEXT NOT NULL, note TEXT)",
        "INSERT INTO orders (status, note) VALUES ('open', NULL), ('open', ''), ('paid', 'a, \"b\"')",
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
        blocked: Uuid::new_v4(),
        closed: Uuid::new_v4(),
        twin: Uuid::new_v4(),
        other_twin: Uuid::new_v4(),
        stale: Uuid::new_v4(),
    };
    let writable = open_session(dir.path(), &file, ids.writable, true).await;
    seed(&writable).await;
    let readable = open_session(dir.path(), &file, ids.readable, false).await;
    let blocked = open_session(dir.path(), &file, ids.blocked, false).await;
    let stale = open_session(dir.path(), &file, ids.stale, false).await;
    let _ = stale.begin_shutdown().await;
    let app = Arc::new(App::default());
    app.sessions.lock().expect("sessions").extend([
        (ids.writable, writable),
        (ids.readable, readable),
        (ids.blocked, blocked),
        (ids.stale, stale.clone()),
    ]);
    app.reopens.lock().expect("reopens").insert(ids.stale, stale);
    let paths = StoragePaths::under(dir.path(), "tablepro-test", "app.tablepro.TablePro.Test");
    let store = ConnectionStore::new(&paths);
    for connection in [
        saved(ids.readable, "Readable", &file, ExternalAccess::ReadOnly),
        saved(ids.writable, "Writable", &file, ExternalAccess::ReadWrite),
        saved(ids.blocked, "Blocked", &file, ExternalAccess::Blocked),
        saved(ids.closed, "Closed", &file, ExternalAccess::ReadOnly),
        saved(ids.twin, "Twin", &file, ExternalAccess::ReadOnly),
        saved(ids.other_twin, "twin", &file, ExternalAccess::ReadOnly),
        saved(ids.stale, "Stale", &file, ExternalAccess::ReadOnly),
    ] {
        store.upsert_blocking(connection).expect("a saved connection");
    }
    let token = AccessToken::from_secret(SecretString::from(TOKEN.to_owned())).expect("a token");
    let context = ToolContext {
        host: app.clone(),
        connections: store,
    };
    let tasks = Tasks::new(tokio::runtime::Handle::current());
    let server = McpServer::start(0, token, context, "0.0.0-test", &tasks)
        .await
        .expect("a listening server");
    Harness {
        _dir: dir,
        server,
        app,
        ids,
    }
}

#[derive(Clone)]
struct Machine {
    port: u16,
    token: Option<String>,
    running: bool,
    enabled: bool,
    terminal: Terminal,
}

impl Machine {
    fn of(harness: &Harness) -> Self {
        Self {
            port: harness.server.address().port(),
            token: Some(TOKEN.to_owned()),
            running: true,
            enabled: true,
            terminal: Terminal::default(),
        }
    }

    fn in_a_terminal(self) -> Self {
        Self {
            terminal: Terminal {
                stdin: true,
                stdout: true,
                stderr: true,
            },
            ..self
        }
    }
}

impl Host for Machine {
    fn app_version(&self) -> String {
        "0.0.0-test".to_owned()
    }

    fn app_running(&self) -> bool {
        self.running
    }

    fn server_enabled(&self) -> Result<bool, HostError> {
        Ok(self.enabled)
    }

    fn server_port(&self) -> Result<u16, HostError> {
        Ok(self.port)
    }

    // The port's owner is the host's to check, and the Linux host's own tests cover it.
    fn verify_peer(&self, _peer: std::net::SocketAddr, _local: std::net::SocketAddr) -> Result<(), HostError> {
        Ok(())
    }

    fn token(&self) -> Result<Option<String>, HostError> {
        Ok(self.token.clone())
    }

    fn terminal(&self) -> Terminal {
        self.terminal
    }
}

struct Ran {
    exit: Exit,
    out: String,
    err: String,
}

// The command builds a runtime of its own, which a thread already running one may not do.
async fn tablepro(machine: Machine, words: &[&str]) -> Ran {
    let args: Vec<OsString> = std::iter::once("tablepro")
        .chain(words.iter().copied())
        .map(OsString::from)
        .collect();
    tokio::task::spawn_blocking(move || {
        let (mut out, mut err) = (Vec::new(), Vec::new());
        let exit = tablepro_cli::run(args, &machine, &mut out, &mut err);
        Ran {
            exit,
            out: String::from_utf8(out).expect("UTF-8 output"),
            err: String::from_utf8(err).expect("UTF-8 errors"),
        }
    })
    .await
    .expect("the command ran")
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn connections_lists_what_clients_may_use() {
    let harness = harness().await;

    let ran = tablepro(Machine::of(&harness), &["connections", "--format", "jsonl"]).await;

    assert_eq!(ran.exit, Exit::Success, "{}", ran.err);
    let readable = format!(
        r#"{{"name":"Readable","id":"{}","type":"sqlite"}}"#,
        harness.ids.readable
    );
    assert!(ran.out.lines().any(|line| line == readable), "{}", ran.out);
    assert!(!ran.out.contains("Blocked"), "{}", ran.out);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_query_into_a_pipe_prints_csv() {
    let harness = harness().await;

    let ran = tablepro(
        Machine::of(&harness),
        &[
            "query",
            "-c",
            "Readable",
            "SELECT id, status, note FROM orders ORDER BY id",
        ],
    )
    .await;

    assert_eq!(ran.exit, Exit::Success, "{}", ran.err);
    assert_eq!(
        ran.out,
        "id,status,note\n1,open,\n2,open,\"\"\n3,paid,\"a, \"\"b\"\"\"\n"
    );
    assert!(ran.err.is_empty(), "{}", ran.err);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_query_on_a_terminal_prints_a_table_and_the_name_matches_in_any_case() {
    let harness = harness().await;

    let ran = tablepro(
        Machine::of(&harness).in_a_terminal(),
        &["query", "-c", "readable", "SELECT id, status FROM orders WHERE id = 1"],
    )
    .await;

    assert_eq!(ran.exit, Exit::Success, "{}", ran.err);
    assert_eq!(ran.out, "id | status\n---+-------\n1  | open\n");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_limit_cuts_the_rows_and_says_so() {
    let harness = harness().await;

    let ran = tablepro(
        Machine::of(&harness),
        &[
            "query",
            "-c",
            "Readable",
            "--limit",
            "1",
            "--format",
            "json",
            "SELECT id FROM orders ORDER BY id",
        ],
    )
    .await;

    assert_eq!(ran.exit, Exit::Success, "{}", ran.err);
    assert_eq!(ran.out, "[\n  {\"id\":1}\n]\n");
    assert_eq!(ran.err, "tablepro: Showing the first row. Pass --limit to change it.\n");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_hidden_or_unknown_connection_is_a_usage_error_by_name_and_by_id() {
    let harness = harness().await;
    let blocked = harness.ids.blocked.to_string();

    for connection in ["Blocked", blocked.as_str(), "Nowhere"] {
        let ran = tablepro(Machine::of(&harness), &["query", "-c", connection, "SELECT 1"]).await;
        assert_eq!(ran.exit, Exit::Usage, "{connection}: {}", ran.err);
        assert!(ran.err.contains("No connection named"), "{}", ran.err);
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn two_names_alike_ask_for_an_id() {
    let harness = harness().await;

    let ran = tablepro(Machine::of(&harness), &["query", "-c", "TWIN", "SELECT 1"]).await;

    assert_eq!(ran.exit, Exit::Usage, "{}", ran.err);
    assert!(ran.err.contains(&harness.ids.twin.to_string()), "{}", ran.err);
    assert!(ran.err.contains(&harness.ids.other_twin.to_string()), "{}", ran.err);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_closed_connection_is_opened_only_from_a_terminal() {
    let harness = harness().await;

    let script = tablepro(Machine::of(&harness), &["query", "-c", "Closed", "SELECT 1"]).await;
    let person = tablepro(
        Machine::of(&harness).in_a_terminal(),
        &["query", "-c", "Closed", "SELECT 1"],
    )
    .await;

    assert_eq!(script.exit, Exit::Failure, "{}", script.err);
    assert!(script.err.contains("is not open in TablePro"), "{}", script.err);
    // The test app never opens a connection, so the attempt fails as a refused password would.
    assert_eq!(person.exit, Exit::Failure, "{}", person.err);
    assert!(
        person.err.starts_with("tablepro: Opening “Closed” in TablePro."),
        "{}",
        person.err
    );
    assert!(person.err.contains("did not open"), "{}", person.err);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_tool_that_still_finds_the_connection_closed_after_connect_stops_after_one_retry() {
    let harness = harness().await;

    let script = tablepro(Machine::of(&harness), &["tables", "-c", "Stale"]).await;
    let opened_by_script = harness.app.opens.load(Ordering::SeqCst);
    let person = tablepro(Machine::of(&harness).in_a_terminal(), &["tables", "-c", "Stale"]).await;

    assert_eq!(script.exit, Exit::Failure, "{}", script.err);
    assert!(script.err.contains("call connect to open it"), "{}", script.err);
    assert_eq!(opened_by_script, 0);
    assert_eq!(person.exit, Exit::Failure, "{}", person.err);
    assert!(
        person.err.starts_with("tablepro: Opening “Stale” in TablePro."),
        "{}",
        person.err
    );
    assert!(person.err.ends_with("call connect to open it\n"), "{}", person.err);
    assert_eq!(harness.app.opens.load(Ordering::SeqCst), 1);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_statement_that_may_write_is_never_sent_twice() {
    let harness = harness().await;

    let ran = tablepro(
        Machine::of(&harness).in_a_terminal(),
        &["query", "-c", "Stale", "SELECT 1"],
    )
    .await;

    assert_eq!(ran.exit, Exit::Failure, "{}", ran.err);
    assert!(ran.err.contains("call connect to open it"), "{}", ran.err);
    assert_eq!(harness.app.opens.load(Ordering::SeqCst), 0);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn tool_failures_keep_their_exit_status() {
    let harness = harness().await;
    let cases: [(&[&str], Exit); 4] = [
        (&["query", "-c", "Readable", "SELECT 1; SELECT 2"], Exit::Usage),
        (&["query", "-c", "Readable", "DELETE FROM orders"], Exit::Refused),
        (&["query", "-c", "Writable", "DELETE FROM orders"], Exit::Refused),
        (&["query", "-c", "Readable", "SELECT * FROM missing"], Exit::Failure),
    ];

    for (words, exit) in cases {
        let ran = tablepro(Machine::of(&harness), words).await;
        assert_eq!(ran.exit, exit, "{words:?}: {}", ran.err);
        assert!(ran.err.starts_with("tablepro: "), "{}", ran.err);
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn read_only_refuses_a_write_on_a_writable_connection() {
    let harness = harness().await;
    harness.app.approves.store(true, Ordering::SeqCst);

    let ran = tablepro(
        Machine::of(&harness),
        &["query", "-c", "Writable", "--read-only", "DELETE FROM orders"],
    )
    .await;

    assert_eq!(ran.exit, Exit::Refused, "{}", ran.err);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_approved_write_says_how_many_rows_it_changed() {
    let harness = harness().await;
    harness.app.approves.store(true, Ordering::SeqCst);

    let ran = tablepro(
        Machine::of(&harness),
        &["query", "-c", "Writable", "UPDATE orders SET note = 'x' WHERE id = 1"],
    )
    .await;

    assert_eq!(ran.exit, Exit::Success, "{}", ran.err);
    assert!(ran.out.is_empty(), "{}", ran.out);
    assert_eq!(ran.err, "1 row affected.\n");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_changed_token_is_refused_and_a_closed_port_is_unreachable() {
    let harness = harness().await;
    let changed = Machine {
        token: Some("tp_other".to_owned()),
        ..Machine::of(&harness)
    };
    let free = std::net::TcpListener::bind("127.0.0.1:0").expect("a free port");
    let closed_port = free.local_addr().expect("an address").port();
    drop(free);
    let silent = Machine {
        port: closed_port,
        ..Machine::of(&harness)
    };

    let refused = tablepro(changed, &["connections"]).await;
    let unreachable = tablepro(silent, &["connections"]).await;

    assert_eq!(refused.exit, Exit::Refused, "{}", refused.err);
    assert!(refused.err.contains("token changed"), "{}", refused.err);
    assert_eq!(unreachable.exit, Exit::Failure, "{}", unreachable.err);
    assert!(unreachable.err.contains("does not answer"), "{}", unreachable.err);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn tables_and_describe_read_the_schema() {
    let harness = harness().await;

    let tables = tablepro(Machine::of(&harness), &["tables", "-c", "Readable"]).await;
    let columns = tablepro(Machine::of(&harness), &["describe", "-c", "Readable", "orders"]).await;
    let ddl = tablepro(
        Machine::of(&harness),
        &["describe", "-c", "Readable", "--ddl", "orders"],
    )
    .await;

    assert_eq!(tables.exit, Exit::Success, "{}", tables.err);
    assert!(tables.out.starts_with("name,schema,kind\n"), "{}", tables.out);
    assert!(tables.out.contains("orders,"), "{}", tables.out);
    assert_eq!(columns.exit, Exit::Success, "{}", columns.err);
    assert!(
        columns.out.starts_with("name,data_type,is_nullable,is_primary_key"),
        "{}",
        columns.out
    );
    assert!(columns.out.contains("\nstatus,TEXT,false,false"), "{}", columns.out);
    assert_eq!(ddl.exit, Exit::Success, "{}", ddl.err);
    assert!(ddl.out.contains("CREATE TABLE"), "{}", ddl.out);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn export_writes_the_tables_data() {
    let harness = harness().await;

    let ran = tablepro(
        Machine::of(&harness),
        &["export", "-c", "Readable", "--format", "csv", "orders"],
    )
    .await;

    assert_eq!(ran.exit, Exit::Success, "{}", ran.err);
    assert!(ran.out.contains("paid"), "{}", ran.out);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn status_is_ready_when_a_command_would_run() {
    let harness = harness().await;

    let ran = tablepro(Machine::of(&harness), &["status", "--format", "csv"]).await;

    assert_eq!(ran.exit, Exit::Success, "{}", ran.err);
    assert_eq!(
        ran.out.lines().nth(1),
        Some(
            format!(
                "0.0.0-test,true,true,{},true,0.0.0-test,true",
                harness.server.address().port()
            )
            .as_str()
        )
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn exports_and_ddl_escape_terminal_controls_and_preserve_pipe_bytes() {
    let harness = harness().await;
    harness.app.approves.store(true, Ordering::SeqCst);
    let text = "\u{1b}]52;c;eA==\u{7}\u{1b}[2J";
    let sql = format!("CREATE TABLE controls (value TEXT DEFAULT '{text}')");
    let created = tablepro(Machine::of(&harness), &["query", "-c", "Writable", &sql]).await;
    assert_eq!(created.exit, Exit::Success, "{}", created.err);
    let inserted = tablepro(
        Machine::of(&harness),
        &["query", "-c", "Writable", "INSERT INTO controls DEFAULT VALUES"],
    )
    .await;
    assert_eq!(inserted.exit, Exit::Success, "{}", inserted.err);

    for arguments in [
        vec!["export", "-c", "Readable", "--format", "csv", "controls"],
        vec!["export", "-c", "Readable", "--format", "sql", "controls"],
        vec!["describe", "-c", "Readable", "--ddl", "controls"],
    ] {
        let piped = tablepro(Machine::of(&harness), &arguments).await;
        let terminal = tablepro(Machine::of(&harness).in_a_terminal(), &arguments).await;
        assert_eq!(piped.exit, Exit::Success, "{}", piped.err);
        assert_eq!(terminal.exit, Exit::Success, "{}", terminal.err);
        assert!(piped.out.contains(text), "{:?}", piped.out);
        assert_eq!(
            terminal.out,
            piped.out.replace('\u{1b}', "\\x1B").replace('\u{7}', "\\x07")
        );
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn delimited_queries_escape_terminal_controls_and_preserve_pipe_bytes() {
    let harness = harness().await;
    for format in ["csv", "tsv"] {
        let words = [
            "query",
            "-c",
            "Readable",
            "--format",
            format,
            "SELECT char(27) || ']52;c;eA==' || char(7) || char(27) || '[2J' AS value",
        ];
        let piped = tablepro(Machine::of(&harness), &words).await;
        let terminal = tablepro(Machine::of(&harness).in_a_terminal(), &words).await;
        assert_eq!(piped.exit, Exit::Success, "{}", piped.err);
        assert_eq!(terminal.exit, Exit::Success, "{}", terminal.err);
        assert_eq!(piped.out, "value\n\u{1b}]52;c;eA==\u{7}\u{1b}[2J\n");
        assert_eq!(terminal.out, "value\n\\x1B]52;c;eA==\\x07\\x1B[2J\n");
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn json_queries_round_trip_controls_on_terminals_and_in_pipes() {
    let harness = harness().await;
    let value = "\u{7f}\u{85}\u{1b}";
    for format in ["json", "jsonl"] {
        let words = [
            "query",
            "-c",
            "Readable",
            "--format",
            format,
            "SELECT char(127) || char(133) || char(27) AS value",
        ];
        let piped = tablepro(Machine::of(&harness), &words).await;
        let terminal = tablepro(Machine::of(&harness).in_a_terminal(), &words).await;
        assert_eq!(piped.exit, Exit::Success, "{}", piped.err);
        assert_eq!(terminal.exit, Exit::Success, "{}", terminal.err);
        let decoded: serde_json::Value = serde_json::from_str(&terminal.out).expect("valid JSON");
        let row = if format == "json" { &decoded[0] } else { &decoded };
        assert_eq!(row["value"], value);
        assert_eq!(terminal.out, piped.out);
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn json_exports_round_trip_controls_on_terminals_and_in_pipes() {
    let harness = harness().await;
    harness.app.approves.store(true, Ordering::SeqCst);
    for sql in [
        "CREATE TABLE controls (value TEXT)",
        "INSERT INTO controls VALUES (char(127) || char(133) || char(27))",
    ] {
        let ran = tablepro(Machine::of(&harness), &["query", "-c", "Writable", sql]).await;
        assert_eq!(ran.exit, Exit::Success, "{}", ran.err);
    }
    let words = ["export", "-c", "Readable", "--format", "json", "controls"];
    let piped = tablepro(Machine::of(&harness), &words).await;
    let terminal = tablepro(Machine::of(&harness).in_a_terminal(), &words).await;
    assert_eq!(piped.exit, Exit::Success, "{}", piped.err);
    assert_eq!(terminal.exit, Exit::Success, "{}", terminal.err);
    let decoded: serde_json::Value = serde_json::from_str(&terminal.out).expect("valid JSON");
    assert_eq!(decoded[0]["value"], "\u{7f}\u{85}\u{1b}");
    assert_eq!(terminal.out, piped.out);
}
