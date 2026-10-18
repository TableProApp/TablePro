use std::path::PathBuf;

use super::*;

pub(crate) fn key_hop(host: &str) -> SavedSshConfig {
    SavedSshConfig {
        hop_id: Uuid::new_v4(),
        credential_revision: 0,
        host: host.into(),
        port: 22,
        username: "svc".into(),
        auth: SavedSshAuth::PrivateKey {
            path: "/home/svc/.ssh/id_ed25519".into(),
            has_passphrase: false,
        },
        jump: None,
        client: Default::default(),
        agent: false,
    }
}

fn networked_saved(driver_id: &str, auth_mode: AuthMode) -> SavedConnection {
    SavedConnection {
        id: Uuid::new_v4(),
        name: "networked".into(),
        driver_id: driver_id.into(),
        host: "db.example".into(),
        port: 5432,
        socket_dir: None,
        socket_path: None,
        database: "app".into(),
        username: "svc".into(),
        use_tls: false,
        tls_mode: None,
        tls_root_cert: None,
        tls_client_cert: None,
        tls_client_key: None,
        read_only: false,
        auth_mode,
        environment: Environment::Local,
        ssh: None,
        last_opened_at: None,
        connect_timeout_secs: None,
        query_timeout_secs: None,
    }
}

#[test]
fn only_password_auth_on_a_networked_engine_loads_a_database_password() {
    assert!(loads_database_password(&networked_saved(
        "postgres",
        AuthMode::Password
    )));
    assert!(!loads_database_password(&networked_saved(
        "postgres",
        AuthMode::Kerberos
    )));
    assert!(!loads_database_password(&networked_saved("sqlite", AuthMode::Password)));
    assert!(!loads_database_password(&networked_saved("duckdb", AuthMode::Password)));
}

#[tokio::test]
async fn connect_options_carry_the_saved_tls_and_socket_fields() {
    let mut saved = networked_saved("postgres", AuthMode::Kerberos);
    saved.tls_mode = Some(TlsMode::VerifyCa);
    saved.tls_root_cert = Some(PathBuf::from("/etc/ssl/ca.pem"));
    saved.tls_client_cert = Some(PathBuf::from("/etc/ssl/client.pem"));
    saved.tls_client_key = Some(PathBuf::from("/etc/ssl/client.key"));
    saved.socket_dir = Some(PathBuf::from("/run/postgresql"));
    saved.socket_path = Some(PathBuf::from("/run/postgresql/.s.PGSQL.5432"));
    saved.connect_timeout_secs = Some(7);
    saved.read_only = true;
    let opts = connect_options_for(&saved).await.unwrap();
    assert_eq!(opts.host, "db.example");
    assert_eq!(opts.port, 5432);
    assert_eq!(opts.database, "app");
    assert_eq!(opts.username, "svc");
    assert_eq!(opts.tls.mode, TlsMode::VerifyCa);
    assert_eq!(opts.tls.root_cert, Some(PathBuf::from("/etc/ssl/ca.pem")));
    assert_eq!(opts.tls.client_cert, Some(PathBuf::from("/etc/ssl/client.pem")));
    assert_eq!(opts.tls.client_key, Some(PathBuf::from("/etc/ssl/client.key")));
    assert_eq!(opts.local_socket_dir, Some(PathBuf::from("/run/postgresql")));
    assert_eq!(
        opts.local_socket_path,
        Some(PathBuf::from("/run/postgresql/.s.PGSQL.5432"))
    );
    assert_eq!(opts.connect_timeout_secs, Some(7));
    assert!(opts.read_only);
}

struct ClientTlsDriver {
    supported: bool,
}

#[async_trait::async_trait]
impl DatabaseDriver for ClientTlsDriver {
    fn id(&self) -> &'static str {
        "client-tls"
    }
    fn display_name(&self) -> &'static str {
        "Client TLS"
    }
    fn default_port(&self) -> u16 {
        5432
    }
    fn supports_client_tls_auth(&self) -> bool {
        self.supported
    }
    async fn connect(&self, _opts: ConnectOptions) -> Result<Box<dyn Connection>, DriverError> {
        Err(DriverError::Unsupported("test driver".into()))
    }
}

fn client_tls_opts(cert: Option<PathBuf>, key: Option<PathBuf>, mode: TlsMode) -> ConnectOptions {
    ConnectOptions {
        tls: TlsConfig {
            mode,
            client_cert: cert,
            client_key: key,
            ..TlsConfig::disabled()
        },
        ..Default::default()
    }
}

#[test]
fn client_tls_identity_is_refused_unless_the_driver_and_mode_allow_it() {
    let directory = tempfile::tempdir().unwrap();
    let cert = directory.path().join("client.pem");
    let key = directory.path().join("client.key");
    std::fs::write(&cert, b"cert").unwrap();
    std::fs::write(&key, b"key").unwrap();
    let supported = ClientTlsDriver { supported: true };
    let refused = ClientTlsDriver { supported: false };

    assert!(validate_client_tls_auth(&supported, &client_tls_opts(None, None, TlsMode::Disabled)).is_ok());
    let only_cert = client_tls_opts(Some(cert.clone()), None, TlsMode::VerifyFull);
    assert!(
        validate_client_tls_auth(&supported, &only_cert)
            .unwrap_err()
            .to_string()
            .contains("requires both")
    );
    let both = || client_tls_opts(Some(cert.clone()), Some(key.clone()), TlsMode::VerifyFull);
    assert!(validate_client_tls_auth(&supported, &both()).is_ok());
    assert!(
        validate_client_tls_auth(&refused, &both())
            .unwrap_err()
            .to_string()
            .contains("does not support")
    );
    for mode in [TlsMode::Disabled, TlsMode::Prefer] {
        let plaintext_capable = client_tls_opts(Some(cert.clone()), Some(key.clone()), mode);
        assert!(
            validate_client_tls_auth(&supported, &plaintext_capable)
                .unwrap_err()
                .to_string()
                .contains("cannot fall back")
        );
    }
}

#[test]
fn client_tls_files_must_be_regular_and_at_most_one_mebibyte() {
    let directory = tempfile::tempdir().unwrap();
    let key = directory.path().join("client.key");
    std::fs::write(&key, b"key").unwrap();
    let supported = ClientTlsDriver { supported: true };
    let limit = 1024 * 1024;

    let at_limit = directory.path().join("at-limit.pem");
    std::fs::write(&at_limit, vec![b'x'; limit]).unwrap();
    assert!(
        validate_client_tls_auth(
            &supported,
            &client_tls_opts(Some(at_limit), Some(key.clone()), TlsMode::VerifyFull)
        )
        .is_ok()
    );

    let over = directory.path().join("over-limit.pem");
    std::fs::write(&over, vec![b'x'; limit + 1]).unwrap();
    let error = validate_client_tls_auth(
        &supported,
        &client_tls_opts(Some(over), Some(key.clone()), TlsMode::VerifyFull),
    )
    .unwrap_err();
    assert!(error.to_string().contains("no larger than 1 MiB"), "{error}");

    let not_a_file = validate_client_tls_auth(
        &supported,
        &client_tls_opts(Some(directory.path().to_path_buf()), Some(key), TlsMode::VerifyFull),
    )
    .unwrap_err();
    assert!(not_a_file.to_string().contains("regular files"), "{not_a_file}");
}

#[tokio::test]
async fn only_hop_zero_may_use_a_legacy_password_and_keys_are_not_refused() {
    let refusal = "only hop 0 can";
    let id = Uuid::new_v4();
    let mut legacy_jump = key_hop("jump.example");
    legacy_jump.auth = SavedSshAuth::Password;
    legacy_jump.credential_revision = 0;
    let refused = resolve_saved_ssh_hop(id, &legacy_jump, 1).await.unwrap_err();
    assert!(refused.to_string().contains(refusal), "{refused}");

    let mut legacy_first = legacy_jump.clone();
    let first = resolve_saved_ssh_hop(id, &legacy_first, 0)
        .await
        .err()
        .map(|e| e.to_string());
    assert!(
        !first.unwrap_or_default().contains(refusal),
        "hop 0 password is not a refusal"
    );

    legacy_first.credential_revision = 1;
    let revisioned = resolve_saved_ssh_hop(id, &legacy_first, 1)
        .await
        .err()
        .map(|e| e.to_string());
    assert!(
        !revisioned.unwrap_or_default().contains(refusal),
        "a revisioned hop is not refused"
    );
}

#[tokio::test]
async fn an_absent_or_legacy_jump_passphrase_is_decided_without_the_keyring() {
    let id = Uuid::new_v4();
    let first = key_hop("first.example");
    assert!(saved_ssh_passphrase(id, &first, 0, false).await.unwrap().is_none());
    let first_legacy = saved_ssh_passphrase(id, &first, 0, true)
        .await
        .err()
        .map(|e| e.to_string());
    assert!(
        !first_legacy
            .unwrap_or_default()
            .contains("cannot be assigned to jump hop"),
        "hop 0 may keep a legacy passphrase"
    );
    let jump = key_hop("jump.example");
    let legacy = saved_ssh_passphrase(id, &jump, 1, true).await.unwrap_err();
    assert!(
        legacy.to_string().contains("cannot be assigned to jump hop 1"),
        "{legacy}"
    );
    assert!(saved_ssh_passphrase(id, &jump, 1, false).await.unwrap().is_none());
}

#[test]
fn the_crypto_provider_is_installed_for_rustls() {
    install_crypto_provider();
    assert!(rustls::crypto::CryptoProvider::get_default().is_some());
}
