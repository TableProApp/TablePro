#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use std::sync::Arc;

use drivers_postgres::PgDriver;
use tablepro_agentd::DaemonProvider;
use tablepro_core::{AuthMode, DriverRegistry, Environment, TlsMode};
use tablepro_mcp::ConnectionProvider;
use tablepro_policy::{AuditState, DenyApprovalSink, PolicyConfig, Principal};
use tablepro_release_tests::Fixture;
use tablepro_storage::{
    AuditJournal, SavedConnection, SavedSshAuth, SavedSshConfig, delete_connection, delete_password, save_connections,
    store_password,
};
use uuid::Uuid;

fn saved_connection(fixture: &Fixture, id: Uuid, cert: Option<&str>, key: Option<&str>) -> SavedConnection {
    let materials = fixture.ca_cert.parent().expect("fixture materials directory");
    SavedConnection {
        id,
        name: "agentd mTLS fixture".into(),
        driver_id: "postgres".into(),
        host: fixture.proxy_host.clone(),
        port: fixture.proxy_port,
        socket_dir: None,
        database: fixture.database.clone(),
        username: "tablepro_mtls".into(),
        use_tls: true,
        tls_mode: Some(TlsMode::VerifyFull),
        tls_root_cert: Some(fixture.ca_cert.clone()),
        tls_client_cert: cert.map(|name| materials.join(name)),
        tls_client_key: key.map(|name| materials.join(name)),
        read_only: true,
        auth_mode: AuthMode::Password,
        environment: Environment::Local,
        ssh: None,
        last_opened_at: None,
        connect_timeout_secs: None,
        query_timeout_secs: None,
    }
}

async fn provider(journal_dir: &tempfile::TempDir) -> DaemonProvider {
    let mut registry = DriverRegistry::new();
    registry.register(Arc::new(PgDriver));
    let journal = Arc::new(
        AuditJournal::open_validated(journal_dir.path().join("agentd-mtls.jsonl")).expect("open agentd audit journal"),
    );
    DaemonProvider::new(
        Arc::new(registry),
        Arc::new(PolicyConfig::default()),
        journal,
        Arc::new(AuditState::new()),
        Arc::new(DenyApprovalSink),
    )
}

fn principal() -> Principal {
    Principal::Agent {
        token: "mtls-fixture-token".into(),
        client: Some("mtls-test".into()),
        model: None,
    }
}

#[tokio::test]
#[ignore = "requires the postgres release fixture and Secret Service"]
async fn agentd_uses_a_saved_client_certificate_for_the_database_session() {
    let fixture = Fixture::from_env();
    let id = Uuid::new_v4();
    let saved = saved_connection(&fixture, id, Some("client.crt"), Some("client.key"));
    save_connections(std::slice::from_ref(&saved))
        .await
        .expect("save agentd mTLS connection");
    store_password(id, &fixture.password, "agentd mTLS fixture")
        .await
        .expect("store fixture password in Secret Service");

    let journal_dir = tempfile::tempdir().expect("temporary journal directory");
    let provider = provider(&journal_dir).await;
    let connection = provider
        .connection(id, principal())
        .await
        .expect("agentd must assemble saved client identity and establish mTLS");
    let result = connection
        .query("SELECT count(*) FROM release_items")
        .await
        .expect("mTLS-backed agentd session must execute a query");
    assert_eq!(result.rows.len(), 1);

    drop(connection);
    delete_connection(id).await.expect("delete fixture connection");
    delete_password(id).await.expect("delete fixture password");
}

#[tokio::test]
#[ignore = "requires the postgres release fixture and Secret Service"]
async fn agentd_refuses_a_saved_client_certificate_from_an_untrusted_authority() {
    let fixture = Fixture::from_env();
    let id = Uuid::new_v4();
    let saved = saved_connection(&fixture, id, Some("wrong-client.crt"), Some("wrong-client.key"));
    save_connections(std::slice::from_ref(&saved))
        .await
        .expect("save agentd mTLS connection");
    store_password(id, &fixture.password, "agentd mTLS fixture")
        .await
        .expect("store fixture password in Secret Service");

    let journal_dir = tempfile::tempdir().expect("temporary journal directory");
    let provider = provider(&journal_dir).await;
    let error = match provider.connection(id, principal()).await {
        Ok(_) => panic!("agentd must fail closed for an untrusted client identity"),
        Err(error) => error,
    };
    assert!(!error.is_empty(), "agentd must report why the mTLS session was refused");

    delete_connection(id).await.expect("delete fixture connection");
    delete_password(id).await.expect("delete fixture password");
}

#[tokio::test]
#[ignore = "requires the postgres release fixture and Secret Service"]
async fn agentd_uses_a_saved_client_certificate_through_its_saved_ssh_route() {
    let fixture = Fixture::from_env();
    // Learn the deterministic fixture host key before exercising agentd's
    // production Refuse policy for unknown keys.
    drop(fixture.open_tunnel().await);

    let id = Uuid::new_v4();
    let mut saved = saved_connection(&fixture, id, Some("client.crt"), Some("client.key"));
    saved.host = fixture.database_hostname.clone();
    saved.port = fixture.database_port;
    saved.ssh = Some(SavedSshConfig {
        hop_id: uuid::Uuid::new_v4(),
        credential_revision: 0,
        host: fixture.ssh_host.clone(),
        port: fixture.ssh_port,
        username: fixture.ssh_username.clone(),
        auth: SavedSshAuth::PrivateKey {
            path: fixture.ssh_key.clone(),
            has_passphrase: false,
        },
        jump: None,
        client: Default::default(),
        agent: false,
    });
    save_connections(std::slice::from_ref(&saved))
        .await
        .expect("save agentd mTLS SSH connection");
    store_password(id, &fixture.password, "agentd mTLS SSH fixture")
        .await
        .expect("store fixture password in Secret Service");

    let journal_dir = tempfile::tempdir().expect("temporary journal directory");
    let provider = provider(&journal_dir).await;
    let connection = provider
        .connection(id, principal())
        .await
        .expect("agentd must preserve saved mTLS identity through its SSH route");
    let result = connection
        .query("SELECT count(*) FROM release_items")
        .await
        .expect("mTLS-backed agentd SSH session must execute a query");
    assert_eq!(result.rows.len(), 1);

    drop(connection);
    delete_connection(id).await.expect("delete fixture connection");
    delete_password(id).await.expect("delete fixture password");
}
