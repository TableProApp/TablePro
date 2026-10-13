//! `VerifyFull` trusts a CA the system store holds, as PostgreSQL and
//! ClickHouse do, and not only the roots compiled into sqlx.
//!
//! rustls-native-certs reads the system store from `SSL_CERT_FILE` when
//! it is set, so the test points it at a file it fills with the
//! fixture's CA. The variable is process-wide, which is why this is a
//! test binary of its own with one test, and why it is set before the
//! runtime starts any thread.

#![expect(
    clippy::expect_used,
    reason = "the setup helpers fail a test the way the test functions themselves do"
)]

use std::path::Path;
use std::sync::Arc;

use async_trait::async_trait;
use drivers_mysql::MysqlDriver;
use secrecy::SecretString;
use tablepro_core::{
    ConnectEnvironment, ConnectOptions, ConnectTarget, Credentials, DatabaseDriver, DriverError, NetworkEndpoint,
    NetworkTarget, TlsConfig, TlsFailure, TlsMode, Transport, TransportError, TransportKind, TransportRoute,
    TransportStream, WorkspaceSettings,
};
use tablepro_test_fixtures::{MysqlFixture, MysqlFlavour, PkiFile, TestPki};
use tablepro_test_support::FaultTransport;
use tablepro_test_support::conformance::test_liveness;
use tokio_util::sync::CancellationToken;

#[test]
#[ignore = "requires docker"]
fn verify_full_trusts_a_ca_in_the_system_store() {
    let store = tempfile::tempdir().expect("a directory");
    let system_store = store.path().join("system-store.pem");
    // SAFETY: no other thread exists yet to read the environment.
    unsafe { std::env::set_var("SSL_CERT_FILE", &system_store) };
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .build()
        .expect("a runtime");

    runtime.block_on(async {
        let fixture = MysqlFixture::start(MysqlFlavour::Mysql)
            .await
            .expect("a TLS-only server");

        std::fs::write(&system_store, "").expect("an empty store");
        let untrusted = MysqlDriver
            .connect(verified_without_ca_file(&fixture), CancellationToken::new())
            .await;
        assert!(
            matches!(
                &untrusted,
                Err(DriverError::Tls {
                    failure: TlsFailure::UnknownIssuer,
                    ..
                })
            ),
            "a CA in neither the store nor the CA file was trusted: {:?}",
            untrusted.err()
        );

        trust(&fixture.pki().path(PkiFile::Ca), &system_store);
        let trusted = MysqlDriver
            .connect(verified_without_ca_file(&fixture), CancellationToken::new())
            .await
            .expect("the system store's CA is trusted");
        trusted.close().await.expect("a close");
    });
}

fn trust(ca: &Path, system_store: &Path) {
    std::fs::copy(ca, system_store).expect("the CA in the store");
}

/// Through a forward, so the certificate's name is checked against the
/// override rather than the address the container is reached at.
fn verified_without_ca_file(fixture: &MysqlFixture) -> ConnectOptions {
    let liveness = test_liveness();
    let credentials = fixture.password_credentials();
    ConnectOptions {
        target: ConnectTarget::Network(NetworkTarget {
            transport: SocketForward::to(fixture),
            credentials: Credentials::Password {
                username: credentials.username.clone(),
                password: SecretString::from(credentials.password.clone()),
            },
            database: Some(fixture.database().to_owned()),
            tls: TlsConfig {
                mode: TlsMode::VerifyFull,
                ca_file: None,
                client_identity: None,
                server_name: Some(TestPki::SERVER_NAMES[1].to_owned()),
            },
        }),
        workspace_settings: WorkspaceSettings::workspace(false),
        liveness,
        environment: ConnectEnvironment::new("test"),
    }
}

/// An SSH forward as the driver sees one: a Unix socket that leads to
/// the service.
#[derive(Debug)]
struct SocketForward {
    relay: Arc<FaultTransport>,
}

impl SocketForward {
    fn to(fixture: &MysqlFixture) -> Arc<Self> {
        let service = NetworkEndpoint::new(fixture.host(), fixture.port()).expect("an endpoint");
        let relay = FaultTransport::direct(service, &test_liveness()).expect("a relay");
        Arc::new(Self { relay: Arc::new(relay) })
    }
}

#[async_trait]
impl Transport for SocketForward {
    fn service_endpoint(&self) -> &NetworkEndpoint {
        self.relay.service_endpoint()
    }

    fn kind(&self) -> TransportKind {
        TransportKind::SshForward {
            destination: "bastion.tablepro.test".to_owned(),
        }
    }

    fn route(&self) -> TransportRoute {
        self.relay.route()
    }

    async fn open(&self) -> Result<Box<dyn TransportStream>, TransportError> {
        self.relay.open().await
    }

    async fn reroute(&self, endpoint: NetworkEndpoint) -> Result<Arc<dyn Transport>, TransportError> {
        self.relay.reroute(endpoint).await
    }

    async fn explain_closed_stream(&self) -> Option<TransportError> {
        None
    }
}
