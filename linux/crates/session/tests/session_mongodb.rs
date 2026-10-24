//! A Session against a real MongoDB through OpenSSH: the collections it
//! lists and the statements an editor sends go through the tunnel, to a
//! replica set member that names itself by an address the app never
//! reaches.

#![expect(
    clippy::expect_used,
    reason = "the setup helpers fail a test the way the test functions themselves do"
)]

use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use secrecy::SecretString;
use tablepro_core::credentials::CredentialInteraction;
use tablepro_core::meta::{ObjectKind, ObjectScope};
use tablepro_core::{
    ConnectEnvironment, Credentials, EditorSessionOptions, LivenessPolicy, NetworkEndpoint, ResultEvent, ResultSink,
    RunEnd, RunOptions, SinkFlow, TlsConfig, UserSql, WorkspaceSettings,
};
use tablepro_driver_mongodb::MongoDriver;
use tablepro_session::runtime::Tasks;
use tablepro_session::{
    ConnectRequest, ConnectServices, ConnectionMetadata, Connector, DefaultDeadlines, DriverConnector,
    NoStoredCredentials, OperationError, OperationKind, RequestTarget, Session, SessionDeps,
};
use tablepro_ssh::{SshAuth, SshConfig, SshDestination, SshRuntimeCell, SshServices};
use tablepro_test_fixtures::{MongoFixture, OpenSshFixture, SshAuthVariant, SshKeyPair, TestNetwork};
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

/// A connection to the replica set's member by its name on the test
/// network, which only the SSH server can resolve.
fn tunnelled_request(mongo: &MongoFixture, sshd: &OpenSshFixture, private_key: PathBuf) -> ConnectRequest {
    let credentials = mongo.password_credentials();
    ConnectRequest {
        metadata: ConnectionMetadata {
            id: Uuid::new_v4(),
            name: "MongoDB".to_owned(),
            driver_id: "mongodb".to_owned(),
        },
        driver: Arc::new(MongoDriver),
        target: RequestTarget::Network {
            endpoint: NetworkEndpoint::new(
                mongo.network_alias().expect("MongoDB on the network"),
                MongoFixture::PORT,
            )
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
            database: Some("tunnelled".to_owned()),
            tls: TlsConfig::disabled(),
            options: tablepro_core::NetworkOptions {
                auth_database: Some("admin".to_owned()),
                ..Default::default()
            },
        },
        workspace_settings: WorkspaceSettings::workspace(false),
        safe_mode: tablepro_core::SafeModeLevel::Off,
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn collections_list_and_statements_run_through_openssh() {
    let network = TestNetwork::new();
    let mongo = MongoFixture::start_in(&network).await.expect("MongoDB");
    let key = SshKeyPair::generate("tablepro-mongodb-test").await.expect("a key pair");
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
    let request = tunnelled_request(&mongo, &sshd, private_key);
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
            UserSql::new("db.getCollection('orders').insertOne({_id: 1, status: 'sent'})"),
            RunOptions::new(CancellationToken::new()).with_deadline(Some(Duration::from_secs(30))),
            Box::new(Discard),
        )
        .await
        .expect("the run");
    let listed = session
        .run(OperationKind::Metadata, |lease, options| async move {
            lease
                .list_objects(&ObjectScope::DefaultSchema, options)
                .await
                .map_err(OperationError::from)
        })
        .await
        .expect("a listing");

    assert_eq!(written.end, RunEnd::Completed);
    assert!(
        listed
            .iter()
            .any(|object| object.name == "orders" && object.kind == ObjectKind::Table),
        "{listed:?}"
    );
    let in_database = mongo
        .shell("db.getSiblingDB('tunnelled').orders.findOne({_id: 1}).status")
        .await
        .expect("mongosh ran");
    assert_eq!(in_database.stdout_text().trim(), "sent");
    editor.close().await;
    let report = session.begin_shutdown().await.expect("the close task");
    assert_eq!(report, tablepro_session::CloseReport::Closed);
}
