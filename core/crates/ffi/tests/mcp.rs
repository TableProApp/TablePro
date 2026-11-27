#![cfg(feature = "engines")]
#![expect(
    clippy::unwrap_used,
    reason = "the setup helpers fail a test the way the test functions themselves do"
)]

use std::collections::HashMap;
use std::ffi::OsString;
use std::net::TcpListener;
use std::path::Path;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use secrecy::{ExposeSecret, SecretString};
use tablepro_cli::{Exit, Host, HostError, Terminal};
use tablepro_ffi::{
    ConnectionRecord, ConnectionSecrets, Core, DatabaseSession, ExternalAccessTag, FileOpenRequest, HostConfig,
    HostSecretError, HostSecrets, McpAppHost, McpListener, McpService, McpStatusTag, McpWriteRequest, RunListener,
    RunOutcome, RunSettings, SafeModeTag, SecretItemTag, SecretKindTag, TlsModeTag, TlsSettings, mcp_address,
};

const WAIT: Duration = Duration::from_secs(20);

#[derive(Clone, Default)]
struct MemorySecrets {
    items: Arc<Mutex<HashMap<SecretItemTag, String>>>,
}

impl HostSecrets for MemorySecrets {
    fn load(&self, _: String, _: SecretKindTag) -> Result<Option<SecretString>, HostSecretError> {
        Ok(None)
    }

    fn store(&self, _: String, _: SecretKindTag, _: SecretString, _: String) -> Result<(), HostSecretError> {
        Ok(())
    }

    fn relabel(&self, _: String, _: SecretKindTag, _: String) -> Result<(), HostSecretError> {
        Ok(())
    }

    fn delete(&self, _: String, _: SecretKindTag) -> Result<(), HostSecretError> {
        Ok(())
    }

    fn delete_connection(&self, _: String) -> Result<(), HostSecretError> {
        Ok(())
    }

    fn load_item(&self, item: SecretItemTag) -> Result<Option<SecretString>, HostSecretError> {
        Ok(self.items.lock().unwrap().get(&item).cloned().map(SecretString::from))
    }

    fn store_item(&self, item: SecretItemTag, secret: SecretString) -> Result<(), HostSecretError> {
        self.items
            .lock()
            .unwrap()
            .insert(item, secret.expose_secret().to_owned());
        Ok(())
    }

    fn delete_item(&self, item: SecretItemTag) -> Result<(), HostSecretError> {
        self.items.lock().unwrap().remove(&item);
        Ok(())
    }
}

struct Quiet;

impl RunListener for Quiet {
    fn events_pending(&self) {}
}

impl McpListener for Quiet {
    fn changed(&self) {}
}

// The app's side: it opens a connection a client asks for on a thread of its own, and answers each write as told.
#[derive(Default)]
struct Windows {
    core: Mutex<Option<Arc<Core>>>,
    opened: Mutex<Vec<Arc<DatabaseSession>>>,
    connecting: AtomicBool,
    opens: AtomicUsize,
    approve: AtomicBool,
    asked: Mutex<Vec<McpWriteRequest>>,
}

struct App(Arc<Windows>);

impl McpAppHost for App {
    fn open_connection(&self, connection_id: String) -> bool {
        self.0.opens.fetch_add(1, Ordering::SeqCst);
        let Some(core) = self.0.core.lock().unwrap().clone() else {
            return false;
        };
        self.0.connecting.store(true, Ordering::SeqCst);
        let windows = self.0.clone();
        std::thread::spawn(move || {
            let runtime = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .unwrap();
            let session = runtime.block_on(connect(&core, connection_id));
            windows.opened.lock().unwrap().push(session);
            windows.connecting.store(false, Ordering::SeqCst);
        });
        true
    }

    fn is_connecting(&self, _connection_id: String) -> bool {
        self.0.connecting.load(Ordering::SeqCst)
    }

    fn approve(&self, request: McpWriteRequest) -> bool {
        self.0.asked.lock().unwrap().push(request);
        self.0.approve.load(Ordering::SeqCst)
    }

    fn withdraw(&self, _request_id: u64) {}
}

// The command as a terminal or a script runs it, against the server the test started.
#[derive(Clone)]
struct Shell {
    port: u16,
    token: String,
    terminal: bool,
}

impl Host for Shell {
    fn app_version(&self) -> String {
        "test".to_owned()
    }

    fn app_running(&self) -> bool {
        true
    }

    fn server_enabled(&self) -> Result<bool, HostError> {
        Ok(true)
    }

    fn server_port(&self) -> Result<u16, HostError> {
        Ok(self.port)
    }

    fn verify_peer(&self, _peer: std::net::SocketAddr, _local: std::net::SocketAddr) -> Result<(), HostError> {
        Ok(())
    }

    fn token(&self) -> Result<Option<String>, HostError> {
        Ok(Some(self.token.clone()))
    }

    fn terminal(&self) -> Terminal {
        Terminal {
            stdin: self.terminal,
            stdout: self.terminal,
            stderr: self.terminal,
        }
    }
}

struct Ran {
    exit: Exit,
    out: String,
    err: String,
}

// The command builds a runtime of its own, which a thread already running one may not do.
fn tablepro(shell: &Shell, words: &[&str]) -> Ran {
    let shell = shell.clone();
    let args: Vec<OsString> = std::iter::once("tablepro")
        .chain(words.iter().copied())
        .map(OsString::from)
        .collect();
    std::thread::spawn(move || {
        let (mut out, mut err) = (Vec::new(), Vec::new());
        let exit = tablepro_cli::run(args, &shell, &mut out, &mut err);
        Ran {
            exit,
            out: String::from_utf8(out).unwrap(),
            err: String::from_utf8(err).unwrap(),
        }
    })
    .join()
    .unwrap()
}

const SHOP: &str = "CREATE TABLE customers (id INTEGER PRIMARY KEY, name TEXT NOT NULL); \
    CREATE TABLE audit (id INTEGER PRIMARY KEY, note TEXT); \
    INSERT INTO customers (id, name) VALUES (1, 'Ada Lovelace')";

fn core(dir: &Path, secrets: MemorySecrets) -> Arc<Core> {
    Core::new(
        HostConfig {
            client_version: "test".to_owned(),
            storage_dir: Some(dir.join("storage").display().to_string()),
        },
        Box::new(secrets),
    )
    .unwrap()
}

async fn make_shop(core: &Core, path: &Path) {
    let session = core
        .open_file(
            FileOpenRequest {
                path: path.display().to_string(),
                driver_id: None,
                read_only: false,
                create: true,
            },
            None,
        )
        .await
        .unwrap();
    let editor = session.open_editor(None, None).await.unwrap();
    let run = editor.run(SHOP.to_owned(), RunSettings::default(), Box::new(Quiet));
    assert!(matches!(run.outcome().await.unwrap(), RunOutcome::Completed { .. }));
    editor.close().await.unwrap();
    session.close().await.unwrap();
}

fn record(name: &str, path: &Path, access: Option<ExternalAccessTag>) -> ConnectionRecord {
    ConnectionRecord {
        id: String::new(),
        name: name.to_owned(),
        driver_id: "sqlite".to_owned(),
        host: String::new(),
        port: 0,
        database: path.display().to_string(),
        username: String::new(),
        integrated_auth: false,
        tls: TlsSettings {
            mode: TlsModeTag::Disable,
            ca_file: None,
            client_certificate: None,
            client_key: None,
            server_name: None,
        },
        ssh: None,
        safe_mode: SafeModeTag::Silent,
        query_timeout_secs: None,
        color: None,
        group_id: None,
        last_opened_ms: None,
        tags: Vec::new(),
        ai_policy: None,
        external_access: access,
        project_id: None,
        icon: None,
        order: 0,
    }
}

async fn save(core: &Core, record: ConnectionRecord) -> String {
    core.library()
        .unwrap()
        .save(record, ConnectionSecrets::default())
        .await
        .unwrap()
        .id
}

async fn connect(core: &Core, id: String) -> Arc<DatabaseSession> {
    core.connect_saved(
        id,
        None,
        ConnectionSecrets::default(),
        ConnectionSecrets::default(),
        None,
        None,
    )
    .await
    .unwrap()
}

fn free_port() -> u16 {
    TcpListener::bind(("127.0.0.1", 0))
        .unwrap()
        .local_addr()
        .unwrap()
        .port()
}

async fn settled(service: &McpService) -> McpStatusTag {
    let deadline = Instant::now() + WAIT;
    loop {
        let status = service.status();
        if !matches!(status, McpStatusTag::Starting { .. }) || Instant::now() > deadline {
            return status;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}

struct Harness {
    _dir: tempfile::TempDir,
    core: Arc<Core>,
    windows: Arc<Windows>,
    service: Arc<McpService>,
    shell: Shell,
}

// A running server over a shop file saved three times: as Read Only, Read & Write and Blocked.
async fn harness() -> (Harness, [String; 3]) {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("shop.sqlite");
    let core = core(dir.path(), MemorySecrets::default());
    make_shop(&core, &path).await;
    let ids = [
        save(&core, record("Shop", &path, None)).await,
        save(&core, record("Writable", &path, Some(ExternalAccessTag::ReadWrite))).await,
        save(&core, record("Hidden", &path, Some(ExternalAccessTag::Blocked))).await,
    ];
    let windows = Arc::new(Windows::default());
    *windows.core.lock().unwrap() = Some(core.clone());
    let service = core
        .mcp_server(Box::new(App(windows.clone())), Box::new(Quiet))
        .unwrap();
    let port = free_port();
    service.apply(true, port);
    assert_eq!(settled(&service).await, McpStatusTag::Running { port });
    let token = service.access_token().await.unwrap().expose_secret().to_owned();
    let harness = Harness {
        _dir: dir,
        core,
        windows,
        service,
        shell: Shell {
            port,
            token,
            terminal: false,
        },
    };
    (harness, ids)
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_command_reaches_a_connection_the_app_has_open_and_never_a_blocked_one() {
    let (harness, [shop, _, hidden]) = harness().await;
    let _shop = connect(&harness.core, shop.clone()).await;
    let _hidden = connect(&harness.core, hidden.clone()).await;

    let listed = tablepro(&harness.shell, &["connections", "--format", "json"]);
    let queried = tablepro(&harness.shell, &["query", "-c", "Shop", "SELECT name FROM customers"]);
    let refused = tablepro(&harness.shell, &["query", "-c", "Hidden", "SELECT 1"]);

    assert_eq!(listed.exit, Exit::Success, "{}", listed.err);
    assert!(listed.out.contains(&shop), "{}", listed.out);
    assert!(!listed.out.contains(&hidden), "{}", listed.out);
    assert!(!listed.out.contains("Hidden"), "{}", listed.out);
    assert_eq!(queried.exit, Exit::Success, "{}", queried.err);
    assert_eq!(queried.out, "name\nAda Lovelace\n");
    assert_eq!(refused.exit, Exit::Usage, "{}", refused.err);
    let history = harness.core.history().await.unwrap();
    let recorded = history
        .search("customers".to_owned(), Some(shop), None, None, 10)
        .await
        .unwrap();
    assert_eq!(recorded.entries.len(), 1);
    assert_eq!(recorded.entries[0].sql, "SELECT name FROM customers");
    let seen = harness.service.seen_clients();
    assert!(seen.iter().any(|client| client.name == "tablepro-cli"), "{seen:?}");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_command_lists_the_project_the_app_shows_from_the_next_call() {
    let (harness, [shop, writable, _]) = harness().await;
    let library = harness.core.library().unwrap();
    let acme = library.create_project("Acme".to_owned(), None).await.unwrap();
    library
        .move_to_project(vec![shop.clone()], Some(acme.id.clone()))
        .await
        .unwrap();
    let list = || tablepro(&harness.shell, &["connections", "--format", "json"]).out;

    let before = list();
    harness.service.set_active_project(Some(acme.id.clone())).unwrap();
    let scoped = list();
    library.delete_project(acme.id.clone()).await.unwrap();
    let deleted = list();
    harness.service.set_active_project(None).unwrap();
    let cleared = list();
    let malformed = harness.service.set_active_project(Some("acme".to_owned())).unwrap_err();

    assert!(before.contains(&shop) && before.contains(&writable), "{before}");
    assert!(scoped.contains(&shop) && !scoped.contains(&writable), "{scoped}");
    assert!(
        deleted.contains(&writable),
        "a project that is gone is all connections: {deleted}"
    );
    assert!(cleared.contains(&shop) && cleared.contains(&writable), "{cleared}");
    assert_eq!(malformed.code(), "library.invalid_id");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_write_runs_only_once_the_app_approves_it() {
    let (harness, [shop, writable, _]) = harness().await;
    let _shop = connect(&harness.core, shop).await;
    let _writable = connect(&harness.core, writable.clone()).await;
    let insert = "INSERT INTO audit (note) VALUES ('from a client')";

    let read_only = tablepro(&harness.shell, &["query", "-c", "Shop", insert]);
    let declined = tablepro(&harness.shell, &["query", "-c", "Writable", insert]);
    harness.windows.approve.store(true, Ordering::SeqCst);
    let approved = tablepro(&harness.shell, &["query", "-c", "Writable", insert]);
    let counted = tablepro(
        &harness.shell,
        &["query", "-c", "Shop", "SELECT count(*) AS n FROM audit"],
    );

    assert_eq!(read_only.exit, Exit::Refused, "{}", read_only.err);
    assert_eq!(declined.exit, Exit::Refused, "{}", declined.err);
    assert_eq!(approved.exit, Exit::Success, "{}", approved.err);
    assert_eq!(counted.out, "n\n1\n");
    let asked = harness.windows.asked.lock().unwrap().clone();
    assert_eq!(asked.len(), 2, "{asked:?}");
    assert_eq!(asked[0].connection_id, writable);
    assert_eq!(asked[0].connection_name, "Writable");
    assert_eq!(asked[0].sql, insert);
    assert_eq!(asked[0].database, None);
    assert!(!asked[0].destructive);
    assert_ne!(asked[0].id, asked[1].id);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_connection_a_terminal_asks_for_is_opened_through_the_app() {
    let (harness, _) = harness().await;
    let terminal = Shell {
        terminal: true,
        ..harness.shell.clone()
    };

    let script = tablepro(&harness.shell, &["query", "-c", "Shop", "SELECT name FROM customers"]);
    let person = tablepro(&terminal, &["query", "-c", "Shop", "SELECT name FROM customers"]);

    assert_eq!(script.exit, Exit::Failure, "{}", script.err);
    assert_eq!(person.exit, Exit::Success, "{}", person.err);
    assert!(person.out.contains("Ada Lovelace"), "{}", person.out);
    assert_eq!(harness.windows.opens.load(Ordering::SeqCst), 1);
    assert_eq!(harness.windows.opened.lock().unwrap().len(), 1);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_token_outlives_a_stop_and_a_new_one_turns_the_old_away() {
    let (harness, [shop, _, _]) = harness().await;
    let _shop = connect(&harness.core, shop).await;
    let port = harness.shell.port;

    harness.service.apply(false, port);
    assert_eq!(settled(&harness.service).await, McpStatusTag::Off);
    let deadline = Instant::now() + WAIT;
    while TcpListener::bind(("127.0.0.1", port)).is_err() {
        assert!(Instant::now() < deadline, "the port stayed taken");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    harness.service.apply(true, port);
    assert_eq!(settled(&harness.service).await, McpStatusTag::Running { port });
    let kept = harness.service.access_token().await.unwrap();
    harness.service.regenerate_token().await.unwrap();
    let replaced = harness.service.access_token().await.unwrap();
    let old = tablepro(&harness.shell, &["connections"]);
    let new = tablepro(
        &Shell {
            token: replaced.expose_secret().to_owned(),
            ..harness.shell.clone()
        },
        &["connections"],
    );

    assert_eq!(kept.expose_secret(), harness.shell.token);
    assert_ne!(replaced.expose_secret(), harness.shell.token);
    assert_eq!(old.exit, Exit::Refused, "{}", old.err);
    assert_eq!(new.exit, Exit::Success, "{}", new.err);
    harness.service.stop().await;
    assert_eq!(harness.service.status(), McpStatusTag::Off);
    assert!(TcpListener::bind(("127.0.0.1", port)).is_ok());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_port_another_program_holds_is_reported_and_a_retry_runs() {
    let (harness, _) = harness().await;
    let taken = TcpListener::bind(("127.0.0.1", 0)).unwrap();
    let port = taken.local_addr().unwrap().port();

    harness.service.apply(true, port);
    let failed = settled(&harness.service).await;
    drop(taken);
    harness.service.apply(true, port);

    match failed {
        McpStatusTag::Failed {
            port: failed_port,
            error,
        } => {
            assert_eq!(failed_port, port);
            assert_eq!(error.code, "mcp.port_in_use");
        }
        other => panic!("expected a failure, got {other:?}"),
    }
    assert_eq!(settled(&harness.service).await, McpStatusTag::Running { port });
    assert_eq!(mcp_address(port), format!("http://127.0.0.1:{port}/mcp"));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_saved_connection_keeps_the_external_clients_level_it_was_given() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("shop.sqlite");
    let core = core(dir.path(), MemorySecrets::default());
    let library = core.library().unwrap();

    let new = library
        .save(record("shop", &path, None), ConnectionSecrets::default())
        .await
        .unwrap();
    let blocked = library
        .save(
            ConnectionRecord {
                external_access: Some(ExternalAccessTag::Blocked),
                ..new.clone()
            },
            ConnectionSecrets::default(),
        )
        .await
        .unwrap();
    let kept = library
        .save(
            ConnectionRecord {
                external_access: None,
                name: "shop (prod)".to_owned(),
                ..blocked.clone()
            },
            ConnectionSecrets::default(),
        )
        .await
        .unwrap();

    assert_eq!(new.external_access, Some(ExternalAccessTag::ReadOnly));
    assert_eq!(blocked.external_access, Some(ExternalAccessTag::Blocked));
    assert_eq!(kept.external_access, Some(ExternalAccessTag::Blocked));
}
