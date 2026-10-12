//! A Session against a real PostgreSQL, directly and through OpenSSH.

#![expect(
    clippy::expect_used,
    reason = "the setup helpers fail a test the way the test functions themselves do"
)]

use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use drivers_postgres::{PgDriver, WORKSPACE_POOL_MAX_SIZE};
use secrecy::SecretString;
use tablepro_core::credentials::CredentialInteraction;
use tablepro_core::statement::{Statement, StatementBuilder};
use tablepro_core::{
    CallOptions, ConnectEnvironment, ConnectOptions, ConnectTarget, Connection, Credentials, DatabaseDriver,
    DriverError, LivenessPolicy, NetworkEndpoint, NetworkTarget, RowLimit, TlsConfig, Value, WorkspaceSettings,
};
use tablepro_net::DirectTcpTransport;
use tablepro_session::runtime::Tasks;
use tablepro_session::{
    ConnectRequest, ConnectServices, ConnectionLease, ConnectionMetadata, Connector, DefaultDeadlines, DriverConnector,
    MonitorSignal, NoStoredCredentials, OperationError, OperationKind, PendingSession, RequestTarget, Session,
    SessionDeps, SessionHealth,
};
use tablepro_ssh::{SshAuth, SshConfig, SshDestination, SshRuntimeCell, SshServices};
use tablepro_test_fixtures::{
    FixtureCredentials, HbaMode, OpenSshFixture, PostgresFixture, SshAuthVariant, SshKeyPair, TestNetwork,
};
use tokio_util::sync::CancellationToken;
use uuid::Uuid;

const WAIT: Duration = Duration::from_secs(60);

/// The test runtime's handle. A test is already inside its runtime, so
/// this is where taking the ambient handle is correct.
#[expect(
    clippy::disallowed_methods,
    reason = "a test runs inside its own runtime; the app passes its Tasks in"
)]
fn tasks() -> Tasks {
    Tasks::new(tokio::runtime::Handle::current())
}

fn statement(sql: &str) -> Statement {
    let mut builder = StatementBuilder::new();
    builder.push_sql(sql);
    builder.finish()
}

fn password(credentials: &FixtureCredentials) -> Credentials {
    Credentials::Password {
        username: credentials.username.clone(),
        password: SecretString::from(credentials.password.clone()),
    }
}

/// SSH services that run the system client with a private config: no
/// agent, a throwaway known_hosts, and new host keys accepted, so no
/// prompt is ever raised.
struct IsolatedSsh {
    _dir: tempfile::TempDir,
    services: SshServices,
}

fn isolated_ssh() -> IsolatedSsh {
    let dir = tempfile::tempdir().expect("a temporary directory");
    let config = dir.path().join("ssh_config");
    std::fs::write(
        &config,
        format!(
            "Host *\n  UserKnownHostsFile {}\n  GlobalKnownHostsFile /dev/null\n  StrictHostKeyChecking accept-new\n  IdentityAgent none\n  IdentitiesOnly yes\n",
            dir.path().join("known_hosts").display()
        ),
    )
    .expect("the ssh config");
    let wrapper = dir.path().join("ssh");
    std::fs::write(
        &wrapper,
        format!("#!/bin/sh\nexec ssh -F '{}' \"$@\"\n", config.display()),
    )
    .expect("the ssh wrapper");
    std::fs::set_permissions(&wrapper, std::fs::Permissions::from_mode(0o755)).expect("an executable wrapper");
    let runtime = dir.path().join("runtime");
    std::fs::create_dir(&runtime).expect("the runtime directory");
    let services = SshServices {
        runtime: Arc::new(SshRuntimeCell::new(runtime)),
        ssh_program: wrapper,
        ssh_keygen_program: PathBuf::from("ssh-keygen"),
        askpass_program: PathBuf::from("/nonexistent/tablepro-askpass"),
    };
    IsolatedSsh { _dir: dir, services }
}

fn connector(ssh: SshServices) -> Arc<DriverConnector> {
    Arc::new(DriverConnector::new(
        ConnectServices {
            environment: ConnectEnvironment::new("test"),
            ssh,
            liveness: LivenessPolicy::DESKTOP,
        },
        Arc::new(DefaultDeadlines::new(LivenessPolicy::DESKTOP)),
    ))
}

fn request(target: RequestTarget) -> ConnectRequest {
    ConnectRequest {
        metadata: ConnectionMetadata {
            id: Uuid::new_v4(),
            name: "PostgreSQL".to_owned(),
            driver_id: "postgres".to_owned(),
        },
        driver: Arc::new(PgDriver),
        target,
        workspace_settings: WorkspaceSettings::workspace(false),
    }
}

fn direct_target(fixture: &PostgresFixture) -> RequestTarget {
    RequestTarget::Network {
        endpoint: NetworkEndpoint::new(fixture.host(), fixture.port()).expect("a valid endpoint"),
        ssh: None,
        credentials: password(&fixture.password_credentials()),
        database: Some(fixture.database().to_owned()),
        tls: TlsConfig::disabled(),
    }
}

async fn establish(connector: &Arc<DriverConnector>, request: ConnectRequest) -> PendingSession {
    connector
        .establish(request, CredentialInteraction::Unattended, CancellationToken::new())
        .await
        .expect("an established connection")
}

fn start(connector: Arc<DriverConnector>, pending: PendingSession) -> Arc<Session> {
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

async fn scalar(session: &Session, kind: OperationKind, sql: &str) -> Result<Value, OperationError> {
    let sql = sql.to_owned();
    session
        .run(kind, |lease: ConnectionLease, options: CallOptions| {
            let statement = statement(&sql);
            async move {
                let result = lease.query_bound(&statement, RowLimit::EDITOR_DEFAULT, options).await?;
                Ok(result
                    .rows
                    .into_iter()
                    .next()
                    .and_then(|row| row.into_iter().next())
                    .unwrap_or(Value::Null))
            }
        })
        .await
}

/// A connection of its own, outside the session, for setup and for
/// pulling the rug out from under the session.
async fn admin(fixture: &PostgresFixture) -> Arc<dyn Connection> {
    let liveness = LivenessPolicy::DESKTOP;
    let endpoint = NetworkEndpoint::new(fixture.host(), fixture.port()).expect("a valid endpoint");
    let options = ConnectOptions {
        target: ConnectTarget::Network(NetworkTarget {
            transport: Arc::new(DirectTcpTransport::new(endpoint, &liveness)),
            credentials: password(&fixture.password_credentials()),
            database: Some(fixture.database().to_owned()),
            tls: TlsConfig::disabled(),
        }),
        workspace_settings: WorkspaceSettings::workspace(false),
        liveness,
        environment: ConnectEnvironment::new("test-admin"),
    };
    PgDriver
        .connect(options, CancellationToken::new())
        .await
        .expect("an admin connection")
}

fn within(limit: Duration) -> CallOptions {
    CallOptions::new(Some(tokio::time::Instant::now() + limit), CancellationToken::new())
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn pg_terminate_backend_next_query_succeeds() {
    let fixture = PostgresFixture::start(HbaMode::Password).await.expect("PostgreSQL");
    let connector = connector(isolated_ssh().services);
    let session = start(
        connector.clone(),
        establish(&connector, request(direct_target(&fixture))).await,
    );
    assert_eq!(
        scalar(&session, OperationKind::Metadata, "SELECT 1").await,
        Ok(Value::Int(1))
    );
    let admin = admin(&fixture).await;

    admin
        .query_bound(
            &statement(
                "SELECT count(pg_terminate_backend(pid)) FROM pg_stat_activity \
                 WHERE application_name = 'TablePro' AND pid <> pg_backend_pid() \
                 AND backend_type = 'client backend'",
            ),
            RowLimit::EDITOR_DEFAULT,
            within(WAIT),
        )
        .await
        .expect("the backends were terminated");
    let first = scalar(&session, OperationKind::Metadata, "SELECT 2").await;
    let next = scalar(&session, OperationKind::Metadata, "SELECT 3").await;

    // A terminated backend is one dead pooled connection, not a dead
    // link: the pool verifies on recycle and replaces it.
    assert_eq!(next, Ok(Value::Int(3)), "the session did not recover: first {first:?}");
    tokio::time::sleep(Duration::from_secs(1)).await;
    assert_eq!(*session.health().borrow(), SessionHealth::Online);
    let report = session.begin_shutdown().await.expect("the close task");
    assert_eq!(report, tablepro_session::CloseReport::Closed);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn saturated_pool_operation_busy_probe_ok_stays_online() {
    let fixture = PostgresFixture::start(HbaMode::Password).await.expect("PostgreSQL");
    let connector = connector(isolated_ssh().services);
    let session = start(
        connector.clone(),
        establish(&connector, request(direct_target(&fixture))).await,
    );
    let generation = *session.link_changes().borrow();

    let sleepers: Vec<_> = (0..WORKSPACE_POOL_MAX_SIZE)
        .map(|_| {
            let session = session.clone();
            tasks().spawn_task(async move { scalar(&session, OperationKind::Page, "SELECT pg_sleep(12)::text").await })
        })
        .collect();
    tokio::time::sleep(Duration::from_secs(2)).await;
    let crowded = scalar(&session, OperationKind::Count, "SELECT 1").await;
    session.signal(MonitorSignal::ProbeRequested { generation });
    tokio::time::sleep(Duration::from_secs(2)).await;

    assert_eq!(crowded, Err(OperationError::Driver(DriverError::Busy)));
    assert_eq!(*session.health().borrow(), SessionHealth::Online);
    assert_eq!(
        *session.link_changes().borrow(),
        generation,
        "a busy pool was treated as lost"
    );
    for sleeper in sleepers {
        assert!(sleeper.await.expect("the sleeper task").is_ok());
    }
    assert_eq!(
        scalar(&session, OperationKind::Count, "SELECT 4").await,
        Ok(Value::Int(4))
    );
}

fn ssh_target(sshd: &OpenSshFixture, postgres: &PostgresFixture, key: &Path) -> RequestTarget {
    let postgres_host = postgres.network_alias().expect("PostgreSQL on the test network");
    RequestTarget::Network {
        endpoint: NetworkEndpoint::new(postgres_host, 5432).expect("a valid endpoint"),
        ssh: Some(SshConfig {
            destination: SshDestination::new(sshd.host(), Some(sshd.port()), Some("tablepro".to_owned()))
                .expect("a valid ssh destination"),
            jump_hosts: Vec::new(),
            auth: SshAuth::PrivateKey {
                path: Some(key.to_owned()),
                passphrase: None,
            },
        }),
        credentials: password(&postgres.password_credentials()),
        database: Some(postgres.database().to_owned()),
        tls: TlsConfig::disabled(),
    }
}

fn process_alive(pid: u32) -> bool {
    Path::new(&format!("/proc/{pid}")).exists()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn session_through_openssh_reconnects_after_the_master_dies() {
    let network = TestNetwork::new();
    let postgres = PostgresFixture::start_in(HbaMode::Password, &network)
        .await
        .expect("PostgreSQL");
    let key = SshKeyPair::generate("tablepro-session-test").await.expect("a key pair");
    let private_key = key.private_key().to_owned();
    let sshd = OpenSshFixture::start_in(SshAuthVariant::PublicKey(key), &network)
        .await
        .expect("an OpenSSH server");
    let ssh = isolated_ssh();
    let connector = connector(ssh.services.clone());

    let pending = establish(&connector, request(ssh_target(&sshd, &postgres, &private_key))).await;
    let first_master = pending
        .established()
        .ssh_session
        .as_ref()
        .and_then(|session| session.master_pid())
        .expect("an ssh master");
    let session = start(connector, pending);
    assert_eq!(
        scalar(&session, OperationKind::Metadata, "SELECT current_database()").await,
        Ok(Value::Text(postgres.database().to_owned()))
    );
    let mut changes = session.link_changes();

    let killed = std::process::Command::new("kill")
        .arg(first_master.to_string())
        .status()
        .expect("kill ran");
    assert!(killed.success());
    tokio::time::timeout(WAIT, changes.changed())
        .await
        .expect("the monitor reconnected in time")
        .expect("the link is still there");

    assert_eq!(changes.borrow().get(), 1);
    assert!(!process_alive(first_master));
    assert_eq!(
        scalar(&session, OperationKind::Metadata, "SELECT 5").await,
        Ok(Value::Int(5))
    );
    assert_eq!(*session.health().borrow(), SessionHealth::Online);
    let report = session.begin_shutdown().await.expect("the close task");
    assert_eq!(report, tablepro_session::CloseReport::Closed);
}
