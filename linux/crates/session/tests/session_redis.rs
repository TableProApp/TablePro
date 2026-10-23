//! A Session against a real Redis through OpenSSH: the keys it lists and
//! the commands an editor sends go through the tunnel.

#![expect(
    clippy::expect_used,
    reason = "the setup helpers fail a test the way the test functions themselves do"
)]

use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use secrecy::SecretString;
use tablepro_core::credentials::CredentialInteraction;
use tablepro_core::keyspace::KeyScan;
use tablepro_core::meta::{KeyKind, ObjectKind};
use tablepro_core::{
    ConnectEnvironment, Credentials, EditorSessionOptions, LivenessPolicy, NetworkEndpoint, ResultEvent, ResultSink,
    RunEnd, RunOptions, SinkFlow, TlsConfig, UserSql, WorkspaceSettings,
};
use tablepro_driver_redis::RedisDriver;
use tablepro_session::runtime::Tasks;
use tablepro_session::{
    ConnectRequest, ConnectServices, ConnectionMetadata, Connector, DefaultDeadlines, DriverConnector,
    NoStoredCredentials, OperationError, OperationKind, RequestTarget, Session, SessionDeps,
};
use tablepro_ssh::{SshAuth, SshConfig, SshDestination, SshRuntimeCell, SshServices};
use tablepro_test_fixtures::{OpenSshFixture, RedisFixture, SshAuthVariant, SshKeyPair, TestNetwork};
use tokio_util::sync::CancellationToken;
use uuid::Uuid;

#[expect(
    clippy::disallowed_methods,
    reason = "a test runs inside its own runtime; the app passes its Tasks in"
)]
fn tasks() -> Tasks {
    Tasks::new(tokio::runtime::Handle::current())
}

/// The system ssh with a private config: no agent and a known_hosts that
/// trusts only the test's server.
async fn isolated_ssh(sshd: &OpenSshFixture, dir: &tempfile::TempDir) -> SshServices {
    let known_hosts = dir.path().join("known_hosts");
    let key = sshd.host_public_key().await.expect("the server's host key");
    std::fs::write(&known_hosts, format!("[{}]:{} {key}\n", sshd.host(), sshd.port())).expect("known_hosts");
    let config = dir.path().join("ssh_config");
    std::fs::write(
        &config,
        format!(
            "Host *\n  UserKnownHostsFile {}\n  GlobalKnownHostsFile /dev/null\n  IdentityAgent none\n  IdentitiesOnly yes\n",
            known_hosts.display()
        ),
    )
    .expect("the ssh config");
    let wrapper = dir.path().join("ssh");
    tablepro_test_support::write_executable(
        &wrapper,
        format!("#!/bin/sh\nexec ssh -F '{}' \"$@\"\n", config.display()).as_bytes(),
        0o755,
    )
    .expect("the ssh wrapper");
    SshServices {
        runtime: Arc::new(SshRuntimeCell::new(
            dir.path().join("runtime").join("app").join("app.tablepro.TablePro"),
        )),
        ssh_program: wrapper,
        ssh_keygen_program: PathBuf::from("ssh-keygen"),
        askpass_program: PathBuf::from("/nonexistent/tablepro-askpass"),
        config_file: None,
    }
}

struct Discard;

#[async_trait::async_trait]
impl ResultSink for Discard {
    async fn accept(&mut self, _event: ResultEvent) -> SinkFlow {
        SinkFlow::Continue
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn keys_list_and_commands_run_through_openssh() {
    let network = TestNetwork::new();
    let redis = RedisFixture::start_in(&network).await.expect("Redis");
    let key = SshKeyPair::generate("tablepro-redis-test").await.expect("a key pair");
    let private_key = key.private_key().to_owned();
    let sshd = OpenSshFixture::start_in(SshAuthVariant::PublicKey(key), &network)
        .await
        .expect("an OpenSSH server");
    let dir = tempfile::tempdir().expect("a temporary directory");
    let ssh = isolated_ssh(&sshd, &dir).await;
    let connector = Arc::new(DriverConnector::new(
        ConnectServices {
            environment: ConnectEnvironment::new("test"),
            ssh,
            liveness: LivenessPolicy::DESKTOP,
        },
        Arc::new(DefaultDeadlines::new(LivenessPolicy::DESKTOP)),
    ));
    let credentials = redis.password_credentials();
    let request = ConnectRequest {
        metadata: ConnectionMetadata {
            id: Uuid::new_v4(),
            name: "Redis".to_owned(),
            driver_id: "redis".to_owned(),
        },
        driver: Arc::new(RedisDriver),
        target: RequestTarget::Network {
            endpoint: NetworkEndpoint::new(redis.network_alias().expect("Redis on the network"), 6379)
                .expect("a valid endpoint"),
            ssh: Some(SshConfig {
                destination: SshDestination::new(sshd.host(), Some(sshd.port()), Some("tablepro".to_owned()))
                    .expect("a valid ssh destination"),
                jump_hosts: Vec::new(),
                auth: SshAuth::PrivateKey {
                    path: Some(private_key),
                    passphrase: None,
                },
            }),
            credentials: Credentials::Password {
                username: credentials.username.clone(),
                password: SecretString::from(credentials.password.clone()),
            },
            database: Some("2".to_owned()),
            tls: TlsConfig::disabled(),
        },
        workspace_settings: WorkspaceSettings::workspace(false),
        safe_mode: tablepro_core::SafeModeLevel::Off,
    };
    let pending = connector
        .establish(request, CredentialInteraction::Unattended, CancellationToken::new())
        .await
        .expect("an established connection");
    let session = Session::start(
        pending,
        SessionDeps {
            connector,
            credentials: Arc::new(NoStoredCredentials),
            deadlines: Arc::new(DefaultDeadlines::new(LivenessPolicy::DESKTOP)),
            tasks: tasks(),
            prompter: None,
        },
    );

    let editor = session
        .open_editor_session(EditorSessionOptions::default(), &CancellationToken::new())
        .await
        .expect("an editor session");
    let written = editor
        .run(
            UserSql::new("HSET tunnelled:hash field value"),
            RunOptions::new(CancellationToken::new()).with_deadline(Some(Duration::from_secs(30))),
            Box::new(Discard),
        )
        .await
        .expect("the run");
    let listed = session
        .run(OperationKind::Metadata, |lease, options| async move {
            lease
                .scan_keys(&KeyScan::sidebar(Some("tunnelled:*".to_owned())), options)
                .await
                .map_err(OperationError::from)
        })
        .await
        .expect("a listing");

    assert_eq!(written.end, RunEnd::Completed);
    assert_eq!(listed.keys.len(), 1);
    assert_eq!(listed.keys[0].name, "tunnelled:hash");
    assert_eq!(listed.keys[0].kind, ObjectKind::Key(KeyKind::Hash));
    let in_database = redis
        .cli(&["-n", "2", "HGET", "tunnelled:hash", "field"])
        .await
        .expect("redis-cli ran");
    assert_eq!(in_database.stdout_text().trim(), "value");
    editor.close().await;
    let report = session.begin_shutdown().await.expect("the close task");
    assert_eq!(report, tablepro_session::CloseReport::Closed);
}
