//! The TLS conformance suite against a MongoDB that takes only TLS, and a
//! second server beside it that takes only clients with a certificate:
//! once over a direct route, where the client library sets up TLS
//! against the system store and the CA file, and once over an SSH-style
//! forward, where the driver's relay does.

use std::net::ToSocketAddrs;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use async_trait::async_trait;
use secrecy::SecretString;
use tablepro_core::{
    ClientIdentity, ConnectOptions, Credentials, DatabaseDriver, ErrorCategory, NetworkEndpoint, TlsConfig, Transport,
    TransportError, TransportKind, TransportRoute, TransportStream, WorkspaceSettings,
};
use tablepro_driver_mongodb::MongoDriver;
use tablepro_test_fixtures::{MongoFixture, PkiFile, TestPki};
use tablepro_test_support::FaultTransport;
use tablepro_test_support::conformance::{
    ClientIdentityEngine, ConformanceFailure, TlsConformanceEngine, test_liveness,
};

use crate::support::{direct, options_over, password};

/// The certificate server has no login, so a client presents only its
/// certificate.
fn no_login() -> Credentials {
    Credentials::Password {
        username: String::new(),
        password: SecretString::from(String::new()),
    }
}

pub struct MongoTlsEngine {
    fixture: MongoFixture,
    ca: PathBuf,
    unrelated_ca: PathBuf,
}

impl MongoTlsEngine {
    async fn start_fixture() -> Result<Self, ConformanceFailure> {
        let fixture = MongoFixture::start_tls().await.map_err(ConformanceFailure::setup)?;
        let ca = fixture.pki().path(PkiFile::Ca);
        let unrelated_ca = fixture.pki().path(PkiFile::UnrelatedCa);
        Ok(Self {
            fixture,
            ca,
            unrelated_ca,
        })
    }

    fn options(&self, host: &str, port: u16, credentials: Credentials, tls: TlsConfig) -> ConnectOptions {
        let liveness = test_liveness();
        options_over(
            direct(host, port, &liveness),
            credentials,
            tls,
            WorkspaceSettings::workspace(false),
            liveness,
        )
    }

    fn certificate_port(&self) -> u16 {
        self.fixture.certificate_port().expect("the certificate server")
    }

    fn identity(&self) -> ClientIdentity {
        ClientIdentity {
            certificate: self.fixture.pki().path(PkiFile::ClientCertificate),
            key: self.fixture.pki().path(PkiFile::ClientKey),
        }
    }
}

#[async_trait]
impl TlsConformanceEngine for MongoTlsEngine {
    fn driver() -> Arc<dyn DatabaseDriver> {
        Arc::new(MongoDriver)
    }

    async fn start() -> Result<Self, ConformanceFailure> {
        Self::start_fixture().await
    }

    fn connect_options(&self, tls: TlsConfig) -> ConnectOptions {
        self.options(
            self.fixture.host(),
            self.fixture.port(),
            password(&self.fixture.password_credentials()),
            tls,
        )
    }

    fn ca_file(&self) -> &Path {
        &self.ca
    }

    fn unrelated_ca_file(&self) -> &Path {
        &self.unrelated_ca
    }

    fn served_name(&self) -> &str {
        TestPki::SERVER_NAMES[1]
    }

    /// The server reads the plaintext hello as a broken handshake and
    /// closes the connection without a reply.
    fn plaintext_rejection_category(&self) -> ErrorCategory {
        ErrorCategory::ConnectionLost
    }

    /// The client library checks each server under its own name, so the
    /// mismatch comes from reaching the server by an address the
    /// certificate does not carry.
    fn name_mismatch_connect_options(&self, tls: TlsConfig) -> ConnectOptions {
        let address = (self.fixture.host(), self.fixture.port())
            .to_socket_addrs()
            .ok()
            .and_then(|mut addresses| addresses.find(std::net::SocketAddr::is_ipv4))
            .expect("the fixture's address");
        self.options(
            &address.ip().to_string(),
            self.fixture.port(),
            password(&self.fixture.password_credentials()),
            tls,
        )
    }
}

impl ClientIdentityEngine for MongoTlsEngine {
    fn client_identity(&self) -> ClientIdentity {
        self.identity()
    }

    fn certificate_connect_options(&self, tls: TlsConfig) -> ConnectOptions {
        self.options(self.fixture.host(), self.certificate_port(), no_login(), tls)
    }
}

/// An SSH forward as the driver sees one: a Unix socket route, here to
/// the fixture's port, under the name the certificate carries, which is
/// the name the relay checks.
#[derive(Debug)]
struct NamedForward {
    service: NetworkEndpoint,
    relay: Arc<FaultTransport>,
}

impl NamedForward {
    fn to(host: &str, port: u16) -> Arc<Self> {
        let liveness = test_liveness();
        let reached = NetworkEndpoint::new(host, port).expect("an endpoint");
        let relay = FaultTransport::direct(reached, &liveness).expect("a relay");
        Arc::new(Self {
            service: NetworkEndpoint::new(TestPki::SERVER_NAMES[1], port).expect("the served name"),
            relay: Arc::new(relay),
        })
    }
}

#[async_trait]
impl Transport for NamedForward {
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

pub struct MongoForwardTlsEngine(MongoTlsEngine);

impl MongoForwardTlsEngine {
    fn forwarded(&self, port: u16, credentials: Credentials, tls: TlsConfig) -> ConnectOptions {
        let liveness = test_liveness();
        options_over(
            NamedForward::to(self.0.fixture.host(), port),
            credentials,
            tls,
            WorkspaceSettings::workspace(false),
            liveness,
        )
    }
}

#[async_trait]
impl TlsConformanceEngine for MongoForwardTlsEngine {
    fn driver() -> Arc<dyn DatabaseDriver> {
        Arc::new(MongoDriver)
    }

    async fn start() -> Result<Self, ConformanceFailure> {
        Ok(Self(MongoTlsEngine::start_fixture().await?))
    }

    fn connect_options(&self, tls: TlsConfig) -> ConnectOptions {
        self.forwarded(
            self.0.fixture.port(),
            password(&self.0.fixture.password_credentials()),
            tls,
        )
    }

    fn ca_file(&self) -> &Path {
        &self.0.ca
    }

    fn unrelated_ca_file(&self) -> &Path {
        &self.0.unrelated_ca
    }

    fn served_name(&self) -> &str {
        TestPki::SERVER_NAMES[1]
    }

    fn plaintext_rejection_category(&self) -> ErrorCategory {
        ErrorCategory::ConnectionLost
    }
}

impl ClientIdentityEngine for MongoForwardTlsEngine {
    fn client_identity(&self) -> ClientIdentity {
        self.0.identity()
    }

    fn certificate_connect_options(&self, tls: TlsConfig) -> ConnectOptions {
        self.forwarded(self.0.certificate_port(), no_login(), tls)
    }
}

mod direct_route {
    use super::MongoTlsEngine;

    tablepro_test_support::tls_conformance_suite! {
        engine: MongoTlsEngine,
        client_identity: true,
    }
}

mod forwarded {
    use super::MongoForwardTlsEngine;

    tablepro_test_support::tls_conformance_suite! {
        engine: MongoForwardTlsEngine,
        client_identity: true,
    }
}
