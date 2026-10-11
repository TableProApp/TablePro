#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
//! `establish` refuses several combinations before it ever dials. Each
//! one exists because the alternative silently weakens a guarantee the
//! user asked for, so the refusals are as much a part of the contract
//! as the successful path.

use std::path::PathBuf;

use tablepro_transport::TransportError;

use async_trait::async_trait;
use tablepro_core::{AuthMode, ConnectOptions, Connection, DatabaseDriver, DriverError, TlsConfig, TlsMode};
use tablepro_ssh::{SshAuth, SshConfig};

struct FakeDriver {
    integrated_auth: bool,
    local_socket: bool,
    client_tls_auth: bool,
}

impl FakeDriver {
    fn plain() -> Self {
        Self {
            integrated_auth: false,
            local_socket: false,
            client_tls_auth: false,
        }
    }

    fn with_local_socket() -> Self {
        Self {
            integrated_auth: false,
            local_socket: true,
            client_tls_auth: false,
        }
    }

    fn with_client_tls_auth() -> Self {
        Self {
            integrated_auth: false,
            local_socket: false,
            client_tls_auth: true,
        }
    }
}

#[async_trait]
impl DatabaseDriver for FakeDriver {
    fn id(&self) -> &'static str {
        "fake"
    }

    fn display_name(&self) -> &'static str {
        "Fake"
    }

    fn default_port(&self) -> u16 {
        5432
    }

    fn supports_integrated_auth(&self) -> bool {
        self.integrated_auth
    }

    fn supports_local_socket(&self) -> bool {
        self.local_socket
    }

    fn supports_client_tls_auth(&self) -> bool {
        self.client_tls_auth
    }

    async fn connect(&self, _opts: ConnectOptions) -> Result<Box<dyn Connection>, DriverError> {
        panic!("a refused connection must never reach the driver");
    }
}

fn options() -> ConnectOptions {
    ConnectOptions {
        host: "db.example".into(),
        port: 5432,
        database: "app".into(),
        username: "postgres".into(),
        tls: TlsConfig::disabled(),
        ..Default::default()
    }
}

fn socket_options() -> ConnectOptions {
    ConnectOptions {
        local_socket_dir: Some(PathBuf::from("/run/postgresql")),
        ..options()
    }
}

fn hop() -> SshConfig {
    SshConfig {
        host: "bastion.example".into(),
        port: 22,
        username: "jump".into(),
        auth: SshAuth::Password {
            password: secrecy::SecretString::new("unused".to_string().into()),
        },
    }
}

/// `establish` returns an opened connection on success, and neither a
/// boxed `Connection` nor an `SshTunnel` is `Debug`, so the refusal has
/// to be unwrapped by hand rather than with `expect_err`.
async fn refusal(
    driver: &dyn DatabaseDriver,
    opts: ConnectOptions,
    ssh: Option<Vec<SshConfig>>,
    what: &str,
) -> TransportError {
    let environment = tablepro_transport::SshEnvironment::builtin(tablepro_ssh::UnknownHostKey::Learn);
    match tablepro_transport::establish(
        driver,
        opts,
        ssh.map(tablepro_transport::SshRoute::Builtin),
        &environment,
    )
    .await
    {
        Ok(_) => panic!("{what}"),
        Err(error) => error,
    }
}

#[tokio::test]
async fn integrated_authentication_is_refused_by_a_driver_that_cannot_do_it() {
    let error = refusal(
        &FakeDriver::plain(),
        ConnectOptions {
            auth_mode: AuthMode::Kerberos,
            ..options()
        },
        None,
        "a driver without integrated auth must refuse it",
    )
    .await;
    assert!(
        format!("{error}").contains("Fake"),
        "the message must name the driver: {error}"
    );
}

#[tokio::test]
async fn a_partial_client_tls_identity_is_refused_before_driver_dispatch() {
    let directory = tempfile::tempdir().unwrap();
    let cert = directory.path().join("client.crt");
    std::fs::write(&cert, b"certificate").unwrap();
    let error = refusal(
        &FakeDriver::with_client_tls_auth(),
        ConnectOptions {
            tls: TlsConfig {
                mode: TlsMode::VerifyFull,
                client_cert: Some(cert),
                ..TlsConfig::disabled()
            },
            ..options()
        },
        None,
        "a client certificate without its private key must be refused",
    )
    .await;
    assert!(error.to_string().contains("both a certificate and a private key"));
}

#[tokio::test]
async fn client_tls_auth_refuses_modes_that_can_fall_back_to_plaintext() {
    let directory = tempfile::tempdir().unwrap();
    let cert = directory.path().join("client.crt");
    let key = directory.path().join("client.key");
    std::fs::write(&cert, b"certificate").unwrap();
    std::fs::write(&key, b"private key").unwrap();
    let error = refusal(
        &FakeDriver::with_client_tls_auth(),
        ConnectOptions {
            tls: TlsConfig {
                mode: TlsMode::Prefer,
                client_cert: Some(cert),
                client_key: Some(key),
                ..TlsConfig::disabled()
            },
            ..options()
        },
        None,
        "mTLS must not use a mode that permits plaintext fallback",
    )
    .await;
    assert!(error.to_string().contains("cannot fall back to plaintext"));
}

#[tokio::test]
async fn a_driver_without_client_tls_auth_refuses_configured_identity() {
    let directory = tempfile::tempdir().unwrap();
    let cert = directory.path().join("client.crt");
    let key = directory.path().join("client.key");
    std::fs::write(&cert, b"certificate").unwrap();
    std::fs::write(&key, b"private key").unwrap();
    let error = refusal(
        &FakeDriver::plain(),
        ConnectOptions {
            tls: TlsConfig {
                mode: TlsMode::VerifyFull,
                client_cert: Some(cert),
                client_key: Some(key),
                ..TlsConfig::disabled()
            },
            ..options()
        },
        None,
        "a driver without mTLS support must not silently ignore credentials",
    )
    .await;
    assert!(error.to_string().contains("does not support TLS client authentication"));
}

#[tokio::test]
async fn a_local_socket_is_refused_by_a_driver_that_cannot_do_it() {
    let error = refusal(
        &FakeDriver::plain(),
        socket_options(),
        None,
        "a driver without local-socket support must refuse one",
    )
    .await;
    assert!(matches!(error, TransportError::LocalSocketUnsupported(_)), "{error:?}");
}

#[tokio::test]
async fn a_local_socket_cannot_be_combined_with_ssh() {
    let error = refusal(
        &FakeDriver::with_local_socket(),
        socket_options(),
        Some(vec![hop()]),
        "a forwarded socket and a local socket are different transports",
    )
    .await;
    assert!(matches!(error, TransportError::LocalSocketWithSsh), "{error:?}");
}

#[tokio::test]
async fn a_local_socket_cannot_be_combined_with_tls() {
    let error = refusal(
        &FakeDriver::with_local_socket(),
        ConnectOptions {
            tls: TlsConfig {
                mode: TlsMode::VerifyFull,
                ..TlsConfig::disabled()
            },
            ..socket_options()
        },
        None,
        "a Unix socket has no certificate to verify, so asking for one must not be ignored",
    )
    .await;
    assert!(matches!(error, TransportError::LocalSocketWithTls), "{error:?}");
}

#[tokio::test]
async fn a_relative_socket_directory_is_refused() {
    let error = refusal(
        &FakeDriver::with_local_socket(),
        ConnectOptions {
            local_socket_dir: Some(PathBuf::from("relative/path")),
            ..options()
        },
        None,
        "a relative socket path depends on the process working directory",
    )
    .await;
    assert!(matches!(error, TransportError::InvalidLocalSocket(_)), "{error:?}");
}

#[tokio::test]
async fn a_zero_socket_port_is_refused() {
    let error = refusal(
        &FakeDriver::with_local_socket(),
        ConnectOptions {
            port: 0,
            ..socket_options()
        },
        None,
        "the socket file name is derived from the port",
    )
    .await;
    assert!(matches!(error, TransportError::InvalidLocalSocket(_)), "{error:?}");
}

#[tokio::test]
async fn an_empty_jump_chain_is_refused_rather_than_treated_as_a_direct_connection() {
    let error = refusal(
        &FakeDriver::plain(),
        options(),
        Some(Vec::new()),
        "an empty chain must not silently become a direct dial",
    )
    .await;
    assert!(format!("{error}").contains("chain"), "{error}");
}

#[tokio::test]
async fn every_enabled_tls_mode_is_refused_on_a_local_socket_before_dialing() {
    for mode in [TlsMode::Require, TlsMode::VerifyCa, TlsMode::VerifyFull] {
        let mut opts = socket_options();
        opts.tls.mode = mode;
        let error = refusal(&FakeDriver::with_local_socket(), opts, None, "TLS must not be ignored").await;
        assert!(
            matches!(error, TransportError::LocalSocketWithTls),
            "{mode:?}: {error:?}"
        );
    }
}

#[tokio::test]
async fn missing_and_regular_file_socket_paths_are_refused_before_dialing() {
    let dir = tempfile::tempdir().unwrap();
    let regular = dir.path().join("regular");
    std::fs::write(&regular, "not a socket directory").unwrap();
    for path in [dir.path().join("missing"), regular] {
        let opts = ConnectOptions {
            local_socket_dir: Some(path),
            ..options()
        };
        let error = refusal(&FakeDriver::with_local_socket(), opts, None, "invalid socket directory").await;
        assert!(matches!(error, TransportError::InvalidLocalSocket(_)), "{error:?}");
    }
}
