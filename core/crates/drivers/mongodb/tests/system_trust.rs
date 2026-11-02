//! `VerifyFull` trusts a CA the system store holds on both of the
//! driver's TLS paths: a direct route, where the client library reads the
//! driver's bundle of the system store and the CA file, and a forward,
//! where the driver's relay checks the server with the platform verifier.
//! The client library on its own trusts only the roots compiled into it.
//!
//! The system store is read from `SSL_CERT_FILE` when it is set, so the
//! test points it at a file it fills with the fixture's CA. The variable
//! is process-wide, which is why this is a test binary of its own with
//! one test, and why it is set before the runtime starts any thread.
//!
//! The direct route checks the server under the fixture's host name, so
//! that name must be on the test certificate: `localhost` in CI, or
//! `db.tablepro.test` through `TESTCONTAINERS_HOST_OVERRIDE` where Docker
//! answers on another address.

#![expect(
    clippy::expect_used,
    reason = "the setup helpers fail a test the way the test functions themselves do"
)]

use std::path::Path;
use std::sync::Arc;

use async_trait::async_trait;
use secrecy::SecretString;
use tablepro_core::{
    ConnectEnvironment, ConnectOptions, ConnectTarget, Credentials, DatabaseDriver, DriverError, NetworkEndpoint,
    NetworkOptions, NetworkTarget, TlsConfig, TlsFailure, TlsMode, Transport, TransportError, TransportKind,
    TransportRoute, TransportStream, WorkspaceSettings,
};
use tablepro_driver_mongodb::MongoDriver;
use tablepro_net::DirectTcpTransport;
use tablepro_test_fixtures::{MongoFixture, PkiFile, TestPki};
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
        let fixture = MongoFixture::start_tls().await.expect("a TLS-only server");

        std::fs::write(&system_store, "").expect("an empty store");
        for (route, options) in routes(&fixture) {
            let untrusted = MongoDriver.connect(options, CancellationToken::new()).await;
            assert!(
                matches!(
                    &untrusted,
                    Err(DriverError::Tls {
                        failure: TlsFailure::UnknownIssuer,
                        ..
                    })
                ),
                "{route}: a CA in neither the store nor the CA file was trusted: {:?}",
                untrusted.err()
            );
        }

        trust(&fixture.pki().path(PkiFile::Ca), &system_store);
        for (route, options) in routes(&fixture) {
            let trusted = MongoDriver
                .connect(options, CancellationToken::new())
                .await
                .unwrap_or_else(|error| panic!("{route}: the system store's CA is not trusted: {error:?}"));
            trusted.close().await.expect("a close");
        }
    });
}

fn trust(ca: &Path, system_store: &Path) {
    std::fs::copy(ca, system_store).expect("the CA in the store");
}

fn routes(fixture: &MongoFixture) -> [(&'static str, ConnectOptions); 2] {
    let liveness = test_liveness();
    let endpoint = NetworkEndpoint::new(fixture.host(), fixture.port()).expect("an endpoint");
    let direct: Arc<dyn Transport> = Arc::new(DirectTcpTransport::new(endpoint, &liveness));
    [
        (
            "forwarded",
            verified_without_ca_file(fixture, SocketForward::to(fixture)),
        ),
        ("direct", verified_without_ca_file(fixture, direct)),
    ]
}

fn verified_without_ca_file(fixture: &MongoFixture, transport: Arc<dyn Transport>) -> ConnectOptions {
    let credentials = fixture.password_credentials();
    ConnectOptions {
        target: ConnectTarget::Network(NetworkTarget {
            transport,
            credentials: Credentials::Password {
                username: credentials.username.clone(),
                password: SecretString::from(credentials.password.clone()),
            },
            database: None,
            tls: TlsConfig {
                mode: TlsMode::VerifyFull,
                ca_file: None,
                client_identity: None,
                server_name: None,
            },
            options: NetworkOptions::default(),
        }),
        workspace_settings: WorkspaceSettings::workspace(false),
        liveness: test_liveness(),
        environment: ConnectEnvironment::new("test"),
    }
}

/// An SSH forward as the driver sees one: a Unix socket that leads to the
/// service, reached under a name on the certificate.
#[derive(Debug)]
struct SocketForward {
    service: NetworkEndpoint,
    relay: Arc<FaultTransport>,
}

impl SocketForward {
    fn to(fixture: &MongoFixture) -> Arc<Self> {
        let reached = NetworkEndpoint::new(fixture.host(), fixture.port()).expect("an endpoint");
        let relay = FaultTransport::direct(reached, &test_liveness()).expect("a relay");
        Arc::new(Self {
            service: NetworkEndpoint::new(TestPki::SERVER_NAMES[1], fixture.port()).expect("the served name"),
            relay: Arc::new(relay),
        })
    }
}

#[async_trait]
impl Transport for SocketForward {
    fn service_endpoint(&self) -> &NetworkEndpoint {
        &self.service
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
