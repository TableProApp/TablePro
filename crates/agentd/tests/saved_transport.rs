#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Duration;

use async_trait::async_trait;
use drivers_sqlite::SqliteDriver;
use tablepro_agentd::DaemonProvider;
use tablepro_core::{
    AuthMode, ConnectOptions, Connection, DatabaseDriver, DriverError, DriverRegistry, Environment, TlsMode,
};
use tablepro_mcp::ConnectionProvider;
use tablepro_policy::{AuditState, DenyApprovalSink, PolicyConfig, Principal};
use tablepro_storage::{AuditJournal, SavedConnection, SavedSshAuth, SavedSshConfig, save_connections};
use uuid::Uuid;

static ENV_LOCK: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

struct CountingDriver {
    dials: Arc<AtomicUsize>,
}

#[async_trait]
impl DatabaseDriver for CountingDriver {
    fn id(&self) -> &'static str {
        "postgres"
    }
    fn display_name(&self) -> &'static str {
        "Counting"
    }
    fn default_port(&self) -> u16 {
        5432
    }
    async fn connect(&self, _opts: ConnectOptions) -> Result<Box<dyn Connection>, DriverError> {
        self.dials.fetch_add(1, Ordering::SeqCst);
        Err(DriverError::Unsupported("counting driver never connects".into()))
    }
}

struct SuccessfulCountingDriver {
    dials: Arc<AtomicUsize>,
}

#[async_trait]
impl DatabaseDriver for SuccessfulCountingDriver {
    fn id(&self) -> &'static str {
        "sqlite"
    }
    fn display_name(&self) -> &'static str {
        "SQLite"
    }
    fn default_port(&self) -> u16 {
        0
    }
    fn is_file_based(&self) -> bool {
        true
    }
    async fn connect(&self, opts: ConnectOptions) -> Result<Box<dyn Connection>, DriverError> {
        self.dials.fetch_add(1, Ordering::SeqCst);
        tokio::time::sleep(Duration::from_millis(50)).await;
        SqliteDriver.connect(opts).await
    }
}

struct ParallelDriver {
    arrivals: Arc<tokio::sync::Barrier>,
}

#[async_trait]
impl DatabaseDriver for ParallelDriver {
    fn id(&self) -> &'static str {
        "sqlite"
    }
    fn display_name(&self) -> &'static str {
        "SQLite"
    }
    fn default_port(&self) -> u16 {
        0
    }
    fn is_file_based(&self) -> bool {
        true
    }
    async fn connect(&self, opts: ConnectOptions) -> Result<Box<dyn Connection>, DriverError> {
        self.arrivals.wait().await;
        SqliteDriver.connect(opts).await
    }
}

fn saved_with_bastion(host: &str, bastion_port: u16) -> SavedConnection {
    SavedConnection {
        id: Uuid::new_v4(),
        name: "Tunnelled warehouse".into(),
        driver_id: "postgres".into(),
        host: host.into(),
        port: 5432,
        socket_dir: None,
        database: "warehouse".into(),
        username: "reader".into(),
        use_tls: false,
        tls_mode: Some(TlsMode::VerifyFull),
        tls_root_cert: None,
        tls_client_cert: None,
        tls_client_key: None,
        read_only: true,
        auth_mode: AuthMode::Password,
        environment: Environment::Prod,
        ssh: Some(SavedSshConfig {
            hop_id: uuid::Uuid::new_v4(),
            credential_revision: 0,
            host: "127.0.0.1".into(),
            port: bastion_port,
            username: "jump".into(),
            auth: SavedSshAuth::PrivateKey {
                path: PathBuf::from("/nonexistent/id_ed25519"),
                has_passphrase: false,
            },
            jump: None,
            client: Default::default(),
            agent: false,
        }),
        last_opened_at: None,
        connect_timeout_secs: None,
        query_timeout_secs: None,
    }
}

fn saved_sqlite(path: &std::path::Path) -> SavedConnection {
    std::fs::File::create(path).expect("an empty SQLite database file");
    SavedConnection {
        id: Uuid::new_v4(),
        name: "Local database".into(),
        driver_id: "sqlite".into(),
        host: String::new(),
        port: 0,
        socket_dir: None,
        database: path.to_string_lossy().into_owned(),
        username: String::new(),
        use_tls: false,
        tls_mode: Some(TlsMode::Disabled),
        tls_root_cert: None,
        tls_client_cert: None,
        tls_client_key: None,
        read_only: true,
        auth_mode: AuthMode::Password,
        environment: Environment::Local,
        ssh: None,
        last_opened_at: None,
        connect_timeout_secs: None,
        query_timeout_secs: None,
    }
}

fn provider(dials: Arc<AtomicUsize>, journal: &tempfile::TempDir) -> DaemonProvider {
    let mut registry = DriverRegistry::new();
    registry.register(Arc::new(CountingDriver { dials }));
    let audit =
        AuditJournal::open_validated(journal.path().join("audit.jsonl")).expect("open a temporary audit journal");
    DaemonProvider::new(
        Arc::new(registry),
        Arc::new(PolicyConfig::default()),
        Arc::new(audit),
        Arc::new(AuditState::new()),
        Arc::new(DenyApprovalSink),
    )
}

fn agent() -> Principal {
    Principal::Agent {
        token: "token".into(),
        client: None,
        model: None,
    }
}

#[tokio::test]
#[ignore = "requires a running Secret Service; scripts/test-secret-service.sh provides one"]
async fn a_saved_ssh_hop_is_used_instead_of_dialling_the_database_directly() {
    let _environment = ENV_LOCK.lock().await;
    let config = tempfile::TempDir::new().expect("temporary config directory");
    let journal = tempfile::TempDir::new().expect("temporary journal directory");
    let keys = tempfile::TempDir::new().expect("temporary key directory");
    // SAFETY: the storage crate resolves saved connections from this variable
    // and the test process owns it for the duration of this test binary.
    unsafe { std::env::set_var("XDG_CONFIG_HOME", config.path()) };

    let key_path = keys.path().join("id_ed25519");
    std::fs::write(&key_path, b"not-a-real-ssh-key").expect("write a dummy private key for material hashing");
    let mut saved = saved_with_bastion("127.0.0.1", 1);
    if let Some(ssh) = saved.ssh.as_mut() {
        ssh.auth = SavedSshAuth::PrivateKey {
            path: key_path,
            has_passphrase: false,
        };
    }
    let connection_id = saved.id;
    save_connections(&[saved]).await.expect("save the fixture connection");

    let dials = Arc::new(AtomicUsize::new(0));
    let provider = provider(dials.clone(), &journal);

    let error = provider
        .connection(connection_id, agent())
        .await
        .err()
        .expect("an unreachable bastion must fail the connection");

    assert!(
        error.starts_with("ssh:"),
        "the failure must come from the tunnel, not the database: {error}"
    );
    assert_eq!(
        dials.load(Ordering::SeqCst),
        0,
        "a connection configured to reach the database through a bastion must never dial it directly"
    );
}

#[tokio::test]
async fn concurrent_requests_share_one_session_creation() {
    let _environment = ENV_LOCK.lock().await;
    let config = tempfile::TempDir::new().expect("temporary config directory");
    let journal = tempfile::TempDir::new().expect("temporary journal directory");
    let database = tempfile::TempDir::new().expect("temporary database directory");
    unsafe { std::env::set_var("XDG_CONFIG_HOME", config.path()) };

    let saved = saved_sqlite(&database.path().join("agentd.sqlite"));
    let connection_id = saved.id;
    save_connections(&[saved]).await.expect("save the fixture connection");

    let dials = Arc::new(AtomicUsize::new(0));
    let mut registry = DriverRegistry::new();
    registry.register(Arc::new(SuccessfulCountingDriver { dials: dials.clone() }));
    let audit =
        AuditJournal::open_validated(journal.path().join("audit.jsonl")).expect("open a temporary audit journal");
    let provider = DaemonProvider::new(
        Arc::new(registry),
        Arc::new(PolicyConfig::default()),
        Arc::new(audit),
        Arc::new(AuditState::new()),
        Arc::new(DenyApprovalSink),
    );

    let (first, second) = tokio::join!(
        provider.connection(connection_id, agent()),
        provider.connection(connection_id, agent())
    );

    first.expect("first guarded connection");
    second.expect("second guarded connection");
    assert_eq!(dials.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn different_session_ids_can_connect_in_parallel() {
    let _environment = ENV_LOCK.lock().await;
    let config = tempfile::TempDir::new().expect("temporary config directory");
    let journal = tempfile::TempDir::new().expect("temporary journal directory");
    let database = tempfile::TempDir::new().expect("temporary database directory");
    unsafe { std::env::set_var("XDG_CONFIG_HOME", config.path()) };

    let first_saved = saved_sqlite(&database.path().join("first.sqlite"));
    let second_saved = saved_sqlite(&database.path().join("second.sqlite"));
    let first_id = first_saved.id;
    let second_id = second_saved.id;
    save_connections(&[first_saved, second_saved])
        .await
        .expect("save the fixture connections");

    let mut registry = DriverRegistry::new();
    registry.register(Arc::new(ParallelDriver {
        arrivals: Arc::new(tokio::sync::Barrier::new(2)),
    }));
    let audit =
        AuditJournal::open_validated(journal.path().join("audit.jsonl")).expect("open a temporary audit journal");
    let provider = DaemonProvider::new(
        Arc::new(registry),
        Arc::new(PolicyConfig::default()),
        Arc::new(audit),
        Arc::new(AuditState::new()),
        Arc::new(DenyApprovalSink),
    );

    let result = tokio::time::timeout(Duration::from_secs(1), async {
        tokio::join!(
            provider.connection(first_id, agent()),
            provider.connection(second_id, agent())
        )
    })
    .await
    .expect("different session IDs must not block each other");

    result.0.expect("first guarded connection");
    result.1.expect("second guarded connection");
}
