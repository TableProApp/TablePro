#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
use std::path::PathBuf;

use tablepro_core::{AuthMode, Environment, TlsMode, Transport};
use tablepro_ssh::SshAuth;
use tablepro_storage::{SavedConnection, SavedSshAuth, SavedSshConfig};
use tablepro_transport::{SshRoute, connect_options_for, saved_ssh_route};
use uuid::Uuid;

fn saved(tls_mode: Option<TlsMode>, use_tls: bool) -> SavedConnection {
    SavedConnection {
        id: Uuid::new_v4(),
        name: "Warehouse".into(),
        driver_id: "postgres".into(),
        host: "db.corp.example".into(),
        port: 5432,
        socket_dir: None,
        database: "warehouse".into(),
        username: "reader".into(),
        use_tls,
        tls_mode,
        tls_root_cert: None,
        tls_client_cert: None,
        tls_client_key: None,
        read_only: false,
        auth_mode: AuthMode::Kerberos,
        environment: Environment::Prod,
        ssh: None,
        last_opened_at: None,
        connect_timeout_secs: None,
        query_timeout_secs: None,
    }
}

fn hop(host: &str, port: u16, username: &str, jump: Option<SavedSshConfig>) -> SavedSshConfig {
    SavedSshConfig {
        hop_id: uuid::Uuid::new_v4(),
        credential_revision: 0,
        host: host.into(),
        port,
        username: username.into(),
        auth: SavedSshAuth::PrivateKey {
            path: PathBuf::from("/home/user/.ssh/id_ed25519"),
            has_passphrase: false,
        },
        jump: jump.map(Box::new),
        client: Default::default(),
        agent: false,
    }
}

#[tokio::test]
async fn a_direct_connection_carries_no_tunnel_state() {
    let connection = saved(Some(TlsMode::VerifyFull), false);
    let opts = connect_options_for(&connection).await.expect("build connect options");

    assert_eq!(opts.host, "db.corp.example");
    assert_eq!(opts.port, 5432);
    assert_eq!(opts.tls.mode, TlsMode::VerifyFull);
    assert!(opts.service_endpoint.is_none());
    assert!(opts.forwarded_socket_dir.is_none());
    assert_eq!(
        opts.transport(),
        Transport::Tcp {
            host: "db.corp.example",
            port: 5432
        }
    );
    assert!(saved_ssh_route(&connection).await.expect("no ssh chain").is_none());
}

#[tokio::test]
async fn file_connections_do_not_require_secret_service() {
    let mut connection = saved(None, false);
    connection.driver_id = "sqlite".into();
    connection.auth_mode = AuthMode::Password;
    connection.username.clear();
    connection.database = "/tmp/tablepro.db".into();

    let opts = connect_options_for(&connection).await.expect("build file options");

    assert_eq!(opts.database, "/tmp/tablepro.db");
}

#[tokio::test]
async fn saved_client_certificate_and_key_reach_the_driver_options() {
    let mut connection = saved(Some(TlsMode::VerifyFull), false);
    connection.tls_client_cert = Some(PathBuf::from("/etc/bookie/client.crt"));
    connection.tls_client_key = Some(PathBuf::from("/etc/bookie/client.key"));

    let opts = connect_options_for(&connection).await.expect("build mTLS options");

    assert_eq!(opts.tls.client_cert, connection.tls_client_cert);
    assert_eq!(opts.tls.client_key, connection.tls_client_key);
}

#[tokio::test]
async fn a_saved_certificate_authority_reaches_the_driver() {
    let mut connection = saved(Some(TlsMode::VerifyFull), false);
    connection.tls_root_cert = Some(PathBuf::from("/etc/tablepro/corp-ca.crt"));

    let opts = connect_options_for(&connection).await.expect("build connect options");

    assert_eq!(opts.tls.mode, TlsMode::VerifyFull);
    assert_eq!(
        opts.tls.root_cert.as_deref(),
        Some(std::path::Path::new("/etc/tablepro/corp-ca.crt"))
    );
}

#[tokio::test]
async fn a_saved_local_socket_reaches_gui_and_agent_connection_options() {
    let mut connection = saved(Some(TlsMode::Disabled), false);
    connection.socket_dir = Some(PathBuf::from("/run/postgresql"));

    let opts = connect_options_for(&connection).await.expect("build connect options");

    assert_eq!(opts.local_socket_dir, connection.socket_dir);
    assert!(matches!(
        opts.transport(),
        Transport::Socket {
            origin: tablepro_core::SocketOrigin::Local,
            ..
        }
    ));
}

#[tokio::test]
async fn a_connection_without_a_certificate_authority_uses_the_system_trust_store() {
    let opts = connect_options_for(&saved(Some(TlsMode::VerifyFull), false))
        .await
        .expect("build connect options");
    assert!(opts.tls.root_cert.is_none());
}

#[tokio::test]
async fn a_legacy_tls_flag_still_means_full_verification() {
    let opts = connect_options_for(&saved(None, true))
        .await
        .expect("build connect options");
    assert_eq!(opts.tls.mode, TlsMode::VerifyFull);
}

#[tokio::test]
async fn a_jump_chain_resolves_in_hop_order() {
    let mut connection = saved(Some(TlsMode::VerifyFull), false);
    connection.ssh = Some(hop(
        "bastion.corp.example",
        22,
        "jump",
        Some(hop("inner.corp.example", 2222, "inner", None)),
    ));

    let Some(SshRoute::Builtin(chain)) = saved_ssh_route(&connection).await.expect("resolve chain") else {
        panic!("a built-in ssh chain is configured");
    };

    assert_eq!(chain.len(), 2);
    assert_eq!(chain[0].host, "bastion.corp.example");
    assert_eq!(chain[0].port, 22);
    assert_eq!(chain[0].username, "jump");
    assert_eq!(chain[1].host, "inner.corp.example");
    assert_eq!(chain[1].port, 2222);
    assert!(matches!(chain[0].auth, SshAuth::PrivateKey { .. }));
}

#[tokio::test]
async fn a_tunnelled_connection_still_starts_from_the_database_hostname() {
    let mut connection = saved(Some(TlsMode::VerifyFull), false);
    connection.ssh = Some(hop("bastion.corp.example", 22, "jump", None));

    let opts = connect_options_for(&connection).await.expect("build connect options");

    assert_eq!(
        opts.host, "db.corp.example",
        "the tunnel is applied by establish, not by option assembly"
    );
    assert!(opts.forwarded_socket_dir.is_none());
}

#[tokio::test]
async fn an_openssh_connection_becomes_a_single_destination_and_refuses_a_saved_jump_chain() {
    let mut connection = saved(Some(TlsMode::VerifyFull), false);
    let mut single = hop("bastion.corp.example", 2222, "deploy", None);
    single.client = tablepro_storage::SshClient::OpenSsh;
    connection.ssh = Some(single.clone());

    let Some(SshRoute::OpenSsh(config)) = saved_ssh_route(&connection).await.expect("resolve route") else {
        panic!("an OpenSSH route is configured");
    };
    assert_eq!(config.destination.host(), "bastion.corp.example");
    assert_eq!(config.destination.port(), Some(2222));
    assert_eq!(config.destination.user(), Some("deploy"));
    assert!(config.jump_hosts.is_empty());

    single.jump = Some(Box::new(hop("inner.corp.example", 22, "inner", None)));
    connection.ssh = Some(single);
    let error = saved_ssh_route(&connection)
        .await
        .err()
        .expect("a saved jump chain is refused");
    assert!(error.to_string().contains("ProxyJump"), "{error}");
}

#[tokio::test]
async fn an_agent_hop_uses_the_agent_on_either_client_and_needs_no_keyring() {
    let mut connection = saved(Some(TlsMode::VerifyFull), false);
    let mut agent_hop = hop("bastion.corp.example", 22, "deploy", None);
    agent_hop.agent = true;
    connection.ssh = Some(agent_hop.clone());

    let Some(SshRoute::Builtin(chain)) = saved_ssh_route(&connection).await.expect("resolve route") else {
        panic!("a built-in route is configured");
    };
    assert!(matches!(chain[0].auth, SshAuth::Agent));

    agent_hop.client = tablepro_storage::SshClient::OpenSsh;
    connection.ssh = Some(agent_hop);
    let Some(SshRoute::OpenSsh(config)) = saved_ssh_route(&connection).await.expect("resolve route") else {
        panic!("an OpenSSH route is configured");
    };
    assert!(matches!(config.auth, tablepro_ssh::openssh::OpenSshAuth::Agent));
}

#[tokio::test]
async fn explicit_tls_modes_override_both_legacy_flags_without_losing_connection_fields() {
    for mode in [
        TlsMode::Disabled,
        TlsMode::Require,
        TlsMode::VerifyCa,
        TlsMode::VerifyFull,
    ] {
        for legacy in [false, true] {
            let mut connection = saved(Some(mode), legacy);
            connection.port = 6543;
            connection.connect_timeout_secs = Some(17);
            connection.database = "warehouse 東京".into();
            connection.username = "reader@example.test".into();
            connection.tls_root_cert = Some(PathBuf::from("/tmp/corp ca.pem"));
            let opts = connect_options_for(&connection).await.unwrap();
            assert_eq!(opts.tls.mode, mode);
            assert_eq!(opts.tls.root_cert, connection.tls_root_cert);
            assert_eq!(opts.host, connection.host);
            assert_eq!(opts.port, 6543);
            assert_eq!(opts.database, "warehouse 東京");
            assert_eq!(opts.username, "reader@example.test");
            assert_eq!(opts.auth_mode, AuthMode::Kerberos);
            assert_eq!(opts.connect_timeout_secs, Some(17));
            assert!(opts.service_endpoint.is_none());
            assert!(opts.forwarded_socket_dir.is_none());
        }
    }
}
