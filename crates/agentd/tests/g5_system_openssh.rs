#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use std::process::Command;
use std::sync::Arc;

use drivers_postgres::PgDriver;
use tablepro_agentd::DaemonProvider;
use tablepro_core::{AuthMode, DriverRegistry, Environment, TlsMode};
use tablepro_mcp::ConnectionProvider;
use tablepro_policy::{AuditEvent, AuditState, AuditTransportOutcome, DenyApprovalSink, PolicyConfig, Principal};
use tablepro_release_tests::Fixture;
use tablepro_ssh::openssh::UnattendedPrompter;
use tablepro_storage::{
    AuditJournal, SavedConnection, SavedSshAuth, SavedSshConfig, SshClient, delete_connection, delete_password,
    save_connections, store_password,
};
use uuid::Uuid;

fn saved_connection(fixture: &Fixture, id: Uuid) -> SavedConnection {
    SavedConnection {
        id,
        name: "G5 system OpenSSH fixture".into(),
        driver_id: "postgres".into(),
        host: fixture.database_hostname.clone(),
        port: fixture.database_port,
        socket_dir: None,
        database: fixture.database.clone(),
        username: fixture.username.clone(),
        use_tls: true,
        tls_mode: Some(TlsMode::VerifyFull),
        tls_root_cert: Some(fixture.ca_cert.clone()),
        tls_client_cert: None,
        tls_client_key: None,
        read_only: true,
        auth_mode: AuthMode::Password,
        environment: Environment::Prod,
        ssh: Some(SavedSshConfig {
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
            client: SshClient::OpenSsh,
            agent: false,
        }),
        last_opened_at: None,
        connect_timeout_secs: None,
        query_timeout_secs: None,
    }
}

fn pretrust_fixture_host(fixture: &Fixture, known_hosts: &std::path::Path) {
    let scan = Command::new("ssh-keyscan")
        .args(["-T", "5", "-p"])
        .arg(fixture.ssh_port.to_string())
        .arg(&fixture.ssh_host)
        .output()
        .expect("system ssh-keyscan is available with OpenSSH");
    assert!(
        scan.status.success() && !scan.stdout.is_empty(),
        "ssh-keyscan could not read the fixture host key: {}",
        String::from_utf8_lossy(&scan.stderr)
    );
    std::fs::write(known_hosts, scan.stdout).expect("write the independently pretrusted fixture key");
    let host_pattern = format!("[{}]:{}", fixture.ssh_host, fixture.ssh_port);
    let lookup = Command::new("ssh-keygen")
        .arg("-F")
        .arg(&host_pattern)
        .arg("-f")
        .arg(known_hosts)
        .output()
        .expect("system ssh-keygen is available with OpenSSH");
    assert!(
        lookup.status.success(),
        "pretrusted key file does not match expected SSH endpoint {host_pattern}: {}",
        String::from_utf8_lossy(&lookup.stdout)
    );
    let direct = Command::new("ssh")
        .args(["-F"])
        .arg(known_hosts.with_file_name("ssh_config"))
        .args(["-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-p"])
        .arg(fixture.ssh_port.to_string())
        .args(["-i"])
        .arg(&fixture.ssh_key)
        .args(["-l", &fixture.ssh_username, &fixture.ssh_host, "true"])
        .output()
        .expect("system ssh is available with OpenSSH");
    assert!(
        direct.status.success(),
        "system OpenSSH did not accept the pretrusted fixture host: {}",
        String::from_utf8_lossy(&direct.stderr)
    );
}

async fn transport_events(journal: &AuditJournal) -> Vec<AuditEvent> {
    journal
        .recent(10_000)
        .await
        .expect("read audit events")
        .into_iter()
        .filter(|event| event.transport_attempt.is_some())
        .collect()
}

#[tokio::test]
#[ignore = "requires the postgres release fixture, Secret Service, system OpenSSH, and tablepro-askpass"]
async fn agentd_refuses_without_learning_an_unknown_system_openssh_key_then_queries_after_trust() {
    let fixture = Fixture::from_env();
    let id = Uuid::new_v4();
    let saved = saved_connection(&fixture, id);
    save_connections(std::slice::from_ref(&saved))
        .await
        .expect("save disposable fixture connection");
    store_password(id, &fixture.password, "G5 system OpenSSH fixture")
        .await
        .expect("store fixture database password in isolated Secret Service");

    let journal_dir = tempfile::tempdir().expect("temporary agentd fixture directory");
    let known_hosts = journal_dir.path().join("known_hosts");
    let ssh_config = journal_dir.path().join("ssh_config");
    std::fs::write(
        &ssh_config,
        format!(
            "Host *\n  UserKnownHostsFile {}\n  GlobalKnownHostsFile /dev/null\n  IdentityAgent none\n  IdentitiesOnly yes\n",
            known_hosts.display()
        ),
    )
    .expect("write isolated system OpenSSH config");
    let journal_path = journal_dir.path().join("agentd-g5.jsonl");
    let journal =
        Arc::new(AuditJournal::open_validated(journal_path.clone()).expect("open isolated agent audit journal"));
    let mut registry = DriverRegistry::new();
    registry.register(Arc::new(PgDriver));
    let mut openssh = tablepro_transport::system_openssh(Arc::new(UnattendedPrompter))
        .await
        .expect("production system OpenSSH setup and askpass helper");
    let system_ssh = openssh.context.ssh_program.clone();
    let wrapper = journal_dir.path().join("ssh-isolated");
    std::fs::write(
        &wrapper,
        format!(
            "#!/bin/sh\nif [ \"$1\" = \"-M\" ]; then\n  exec '{}' -F '{}' \"$@\"\nfi\nexec '{}' \"$@\"\n",
            system_ssh.display(),
            ssh_config.display(),
            system_ssh.display()
        ),
    )
    .expect("write system OpenSSH test wrapper");
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&wrapper, std::fs::Permissions::from_mode(0o700))
            .expect("make system OpenSSH test wrapper executable");
    }
    openssh.context.ssh_program = wrapper;
    let provider = DaemonProvider::new(
        Arc::new(registry),
        Arc::new(PolicyConfig::default()),
        journal.clone(),
        Arc::new(AuditState::new()),
        Arc::new(DenyApprovalSink),
    )
    .with_system_openssh(openssh);

    assert!(
        !known_hosts.exists(),
        "the unknown-host case starts without trusted keys"
    );

    let refused = provider
        .connection(
            id,
            Principal::Agent {
                token: "g5-fixture-token".into(),
                client: Some("g5-test".into()),
                model: None,
            },
        )
        .await;
    let error = refused.err().expect("unattended unknown host key must be refused");
    assert!(error.contains("not known"), "expected host-key refusal, got: {error}");
    assert!(
        !known_hosts.exists(),
        "the unattended refusal must not learn the SSH host key"
    );
    let first_attempt = transport_events(&journal).await;
    assert_eq!(
        first_attempt.len(),
        1,
        "one terminal event for the refused connection attempt"
    );
    assert_eq!(
        first_attempt[0].transport_attempt.expect("transport metadata").outcome,
        AuditTransportOutcome::HostKeyRefused
    );
    assert_eq!(
        first_attempt[0].terminal_status,
        tablepro_policy::AuditTerminalStatus::Denied
    );

    let mismatch_key = journal_dir.path().join("mismatch_key");
    let generated = Command::new("ssh-keygen")
        .args(["-q", "-t", "ed25519", "-N", ""])
        .arg("-f")
        .arg(&mismatch_key)
        .output()
        .expect("ssh-keygen is available");
    assert!(
        generated.status.success(),
        "could not create a disposable wrong host key"
    );
    let public_key = std::fs::read_to_string(mismatch_key.with_extension("pub")).expect("read generated public key");
    std::fs::write(
        &known_hosts,
        format!("[{}]:{} {}", fixture.ssh_host, fixture.ssh_port, public_key),
    )
    .expect("write wrong key to isolated known_hosts");
    let changed = provider
        .connection(
            id,
            Principal::Agent {
                token: "g5-fixture-token".into(),
                client: Some("g5-test".into()),
                model: None,
            },
        )
        .await
        .err()
        .expect("a changed system OpenSSH host key must be refused");
    assert!(
        changed.contains("changed"),
        "expected changed host-key refusal, got: {changed}"
    );
    let attempts = transport_events(&journal).await;
    assert_eq!(attempts.len(), 2, "each refused attempt gets one terminal event");
    assert_eq!(
        attempts[1].transport_attempt.expect("transport metadata").outcome,
        AuditTransportOutcome::HostKeyChanged
    );

    pretrust_fixture_host(&fixture, &known_hosts);
    let trusted_key = std::fs::read(&known_hosts).expect("read the pretrusted fixture key");
    let connection = provider
        .connection(
            id,
            Principal::Agent {
                token: "g5-fixture-token".into(),
                client: Some("g5-test".into()),
                model: None,
            },
        )
        .await
        .expect("pretrusted system OpenSSH host reaches a guarded database connection");
    let result = connection
        .query("SELECT count(*) FROM release_items")
        .await
        .expect("guarded query through the actual agentd system OpenSSH provider");
    assert_eq!(result.rows.len(), 1);
    assert_eq!(
        std::fs::read(&known_hosts).expect("read known_hosts after trusted connection"),
        trusted_key,
        "the trusted connection must not rewrite the host-key file"
    );
    let attempts = transport_events(&journal).await;
    assert_eq!(attempts.len(), 3, "one transport event for each connect attempt");
    assert_eq!(
        attempts[2].transport_attempt.expect("transport metadata").outcome,
        AuditTransportOutcome::Connected
    );
    for event in &attempts {
        match &event.principal {
            Principal::Agent { token, .. } => assert_ne!(token, "g5-fixture-token"),
            Principal::Human { .. } => panic!("the daemon must retain the caller principal kind"),
        }
    }

    drop(connection);
    delete_connection(id).await.expect("remove disposable saved connection");
    delete_password(id).await.expect("remove disposable fixture password");
}
