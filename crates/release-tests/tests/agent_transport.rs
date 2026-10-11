#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
use std::sync::Arc;

use tablepro_core::{AuthMode, Connection, TlsMode};
use tablepro_policy::{AuditState, AuditTransportOutcome, Principal};
use tablepro_release_tests::Fixture;
use tablepro_ssh::SshConfig;
use tablepro_storage::AuditJournal;
use tablepro_transport::{TransportAuditContext, establish};

use drivers_postgres::PgDriver;

fn verifying_options(fixture: &Fixture) -> tablepro_core::ConnectOptions {
    tablepro_core::ConnectOptions {
        host: fixture.database_hostname.clone(),
        port: fixture.database_port,
        database: fixture.database.clone(),
        username: fixture.username.clone(),
        password: secrecy::SecretString::new(fixture.password.clone().into()),
        tls: tablepro_core::TlsConfig {
            mode: TlsMode::VerifyFull,
            root_cert: Some(fixture.ca_cert.clone()),
            ..Default::default()
        },
        auth_mode: AuthMode::Password,
        service_endpoint: None,
        local_socket_dir: None,
        forwarded_socket_dir: None,
        application_name: None,
        connect_timeout_secs: None,
        read_only: false,
    }
}

fn chain(fixture: &Fixture) -> Vec<SshConfig> {
    vec![fixture.ssh_config()]
}

#[tokio::test]
#[ignore = "requires the postgres release fixture"]
async fn the_shared_transport_verifies_the_database_hostname_through_the_bastion() {
    let fixture = Fixture::from_env();
    let (connection, tunnel) = establish(
        &PgDriver,
        verifying_options(&fixture),
        Some(tablepro_transport::SshRoute::Builtin(chain(&fixture))),
        &tablepro_transport::SshEnvironment::builtin(tablepro_ssh::UnknownHostKey::Learn),
    )
    .await
    .expect("a tunnelled VerifyFull session");
    let tunnel = tunnel.expect("an ssh chain must produce a tunnel");
    assert!(
        tunnel.socket_dir().is_some(),
        "a verifying PostgreSQL session must be forwarded over a private unix socket"
    );

    let result = connection
        .query("SELECT count(*) FROM release_items")
        .await
        .expect("query over the tunnelled session");
    assert_eq!(result.rows.len(), 1);
}

#[tokio::test]
#[ignore = "requires the postgres release fixture"]
async fn a_tunnelled_connection_fails_closed_when_the_bastion_is_unreachable() {
    let fixture = Fixture::from_env();
    let mut hop = fixture.ssh_config();
    hop.port = 1;

    let error = establish(
        &PgDriver,
        verifying_options(&fixture),
        Some(tablepro_transport::SshRoute::Builtin(vec![hop])),
        &tablepro_transport::SshEnvironment::builtin(tablepro_ssh::UnknownHostKey::Learn),
    )
    .await
    .err()
    .expect("an unreachable bastion must fail the connection");

    assert!(
        error.to_string().starts_with("ssh:"),
        "the failure must come from the tunnel: {error}"
    );
}

#[tokio::test]
#[ignore = "requires the postgres release fixture"]
async fn a_direct_session_and_a_tunnelled_session_reach_the_same_database() {
    let fixture = Fixture::from_env();
    let direct: Arc<dyn Connection> = Arc::from(fixture.connect_verified().await);
    let (tunnelled, _tunnel) = establish(
        &PgDriver,
        verifying_options(&fixture),
        Some(tablepro_transport::SshRoute::Builtin(chain(&fixture))),
        &tablepro_transport::SshEnvironment::builtin(tablepro_ssh::UnknownHostKey::Learn),
    )
    .await
    .expect("a tunnelled VerifyFull session");

    direct
        .execute("CREATE TABLE IF NOT EXISTS agent_transport_probe (note text)")
        .await
        .expect("create the probe table");
    direct
        .execute("INSERT INTO agent_transport_probe VALUES ('through the bastion')")
        .await
        .expect("insert a probe row");

    let seen = tunnelled
        .query("SELECT note FROM agent_transport_probe")
        .await
        .expect("read the probe row over the tunnel");
    assert_eq!(seen.rows.len(), 1);

    direct
        .execute("DROP TABLE agent_transport_probe")
        .await
        .expect("drop the probe table");
}

#[tokio::test]
#[ignore = "requires the postgres release fixture"]
async fn shared_transport_records_builtin_unknown_and_changed_host_key_refusals() {
    let fixture = Fixture::from_env();
    let known_hosts = tablepro_ssh::default_known_hosts_path().expect("a known_hosts path must be resolvable");
    let backup = known_hosts.with_extension("bak-refuse-test");
    if known_hosts.exists() {
        std::fs::rename(&known_hosts, &backup).expect("set aside any already-learned host keys");
    }
    assert!(
        !known_hosts.exists(),
        "the refusal case must start from an empty known_hosts file"
    );

    let audit_dir = tempfile::tempdir().expect("isolated audit directory");
    let journal = Arc::new(
        AuditJournal::open_validated(audit_dir.path().join("transport-audit.jsonl"))
            .expect("open isolated audit journal"),
    );
    let state = Arc::new(AuditState::new());
    let environment = tablepro_transport::SshEnvironment::builtin(tablepro_ssh::UnknownHostKey::Refuse).with_audit(
        TransportAuditContext::new(
            journal.clone(),
            state,
            Principal::human_gui(),
            uuid::Uuid::new_v4(),
            "built-in refusal fixture",
            tablepro_core::Environment::Local,
            "postgres",
        ),
    );
    let first = establish(
        &PgDriver,
        verifying_options(&fixture),
        Some(tablepro_transport::SshRoute::Builtin(chain(&fixture))),
        &environment,
    )
    .await;

    let known_hosts_written = known_hosts.exists();
    let error = first.err().expect("an unknown host key must be refused, not learned");
    assert!(matches!(error, tablepro_transport::TransportError::HostKeyRefused(_)));
    assert!(
        !known_hosts_written,
        "refusing an unknown host key must not write a known_hosts file"
    );
    let events = journal.recent(10).await.expect("read audit journal");
    assert_eq!(events.len(), 1);
    assert_eq!(
        events[0].transport_attempt.expect("transport event").outcome,
        AuditTransportOutcome::HostKeyRefused
    );

    let wrong_key = known_hosts.with_file_name("i5-wrong-host-key");
    let generated = std::process::Command::new("ssh-keygen")
        .args(["-q", "-t", "ed25519", "-N", ""])
        .arg("-f")
        .arg(&wrong_key)
        .output()
        .expect("ssh-keygen is available");
    assert!(generated.status.success());
    let public_key = std::fs::read_to_string(wrong_key.with_extension("pub")).expect("read wrong public key");
    std::fs::create_dir_all(known_hosts.parent().expect("known_hosts parent")).expect("create config directory");
    std::fs::write(
        &known_hosts,
        format!("[{}]:{} {}", fixture.ssh_host, fixture.ssh_port, public_key),
    )
    .expect("write wrong key to test known_hosts");
    let changed = establish(
        &PgDriver,
        verifying_options(&fixture),
        Some(tablepro_transport::SshRoute::Builtin(chain(&fixture))),
        &environment,
    )
    .await
    .err()
    .expect("a changed host key must be refused");
    assert!(matches!(changed, tablepro_transport::TransportError::HostKeyChanged(_)));
    let events = journal.recent(10).await.expect("read audit journal");
    assert_eq!(events.len(), 2, "one terminal record per builtin SSH attempt");
    assert_eq!(
        events[1].transport_attempt.expect("transport event").outcome,
        AuditTransportOutcome::HostKeyChanged
    );
    std::fs::remove_file(&known_hosts).expect("remove the disposable mismatched host key");
    let _ = std::fs::remove_file(&wrong_key);
    let _ = std::fs::remove_file(wrong_key.with_extension("pub"));
    if backup.exists() {
        std::fs::rename(&backup, &known_hosts).expect("restore the original known_hosts file");
    }
}
