//! The TLS conformance suite against MySQL and MariaDB, and the TLS cases
//! of the socket route an SSH forward takes.

use std::marker::PhantomData;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use async_trait::async_trait;
use drivers_mysql::MysqlDriver;
use tablepro_core::{
    ClientIdentity, ConnectOptions, DatabaseDriver, DriverError, ErrorCategory, NetworkEndpoint, TlsConfig, TlsFailure,
    TlsMode, Transport, TransportError, TransportKind, TransportRoute, TransportStream, WorkspaceSettings,
};
use tablepro_test_fixtures::{MysqlFixture, MysqlFlavour, MysqlOptions, PkiFile, TestPki};
use tablepro_test_support::FaultTransport;
use tablepro_test_support::conformance::{
    ClientIdentityEngine, ConformanceFailure, TlsConformanceEngine, test_liveness,
};
use tokio_util::sync::CancellationToken;

use crate::conformance_engine::{Mariadb114, Mysql84, Server};
use crate::support::{FLAVOURS, direct, options_over, password, run_ok, session, start_with, text};

/// The name to dial so the certificate's `localhost` matches: the
/// fixture may report the loopback by address.
fn certified_host(host: &str) -> &str {
    match host {
        "127.0.0.1" | "::1" => TestPki::SERVER_NAMES[0],
        other => other,
    }
}

pub struct MySqlTlsEngine<S> {
    fixture: MysqlFixture,
    ca: PathBuf,
    unrelated_ca: PathBuf,
    server: PhantomData<S>,
}

impl<S: Server> MySqlTlsEngine<S> {
    fn options_to(&self, host: &str, credentials: tablepro_core::Credentials, tls: TlsConfig) -> ConnectOptions {
        let liveness = test_liveness();
        options_over(
            direct(host, self.fixture.port(), &liveness),
            credentials,
            self.fixture.database(),
            tls,
            WorkspaceSettings::workspace(false),
            liveness,
        )
    }
}

#[async_trait]
impl<S: Server> TlsConformanceEngine for MySqlTlsEngine<S> {
    fn driver() -> Arc<dyn DatabaseDriver> {
        Arc::new(MysqlDriver)
    }

    async fn start() -> Result<Self, ConformanceFailure> {
        let fixture = MysqlFixture::start(S::FLAVOUR)
            .await
            .map_err(ConformanceFailure::setup)?;
        let ca = fixture.pki().path(PkiFile::Ca);
        let unrelated_ca = fixture.pki().path(PkiFile::UnrelatedCa);
        Ok(Self {
            fixture,
            ca,
            unrelated_ca,
            server: PhantomData,
        })
    }

    fn connect_options(&self, tls: TlsConfig) -> ConnectOptions {
        let host = certified_host(self.fixture.host());
        self.options_to(host, password(&self.fixture.password_credentials()), tls)
    }

    fn ca_file(&self) -> &Path {
        &self.ca
    }

    fn unrelated_ca_file(&self) -> &Path {
        &self.unrelated_ca
    }

    fn served_name(&self) -> &str {
        TestPki::SERVER_NAMES[0]
    }

    /// The password user is created REQUIRE SSL. MySQL checks that with
    /// the credentials and answers 1045; MariaDB checks
    /// `require_secure_transport` first and answers 3159.
    fn plaintext_rejection_category(&self) -> ErrorCategory {
        match S::FLAVOUR {
            MysqlFlavour::Mysql => ErrorCategory::Authentication,
            MysqlFlavour::Mariadb => ErrorCategory::Tls,
        }
    }

    /// The name sqlx verifies is the host it dials, so a mismatch is the
    /// server's address, which the certificate does not carry.
    fn name_mismatch_connect_options(&self, tls: TlsConfig) -> ConnectOptions {
        self.options_to("127.0.0.1", password(&self.fixture.password_credentials()), tls)
    }
}

impl<S: Server> ClientIdentityEngine for MySqlTlsEngine<S> {
    fn client_identity(&self) -> ClientIdentity {
        ClientIdentity {
            certificate: self.fixture.pki().path(PkiFile::ClientCertificate),
            key: self.fixture.pki().path(PkiFile::ClientKey),
        }
    }

    fn certificate_connect_options(&self, tls: TlsConfig) -> ConnectOptions {
        let host = certified_host(self.fixture.host());
        self.options_to(host, password(&self.fixture.certificate_credentials()), tls)
    }
}

mod mysql_suite {
    use super::{MySqlTlsEngine, Mysql84};

    tablepro_test_support::tls_conformance_suite! {
        engine: MySqlTlsEngine<Mysql84>,
        client_identity: true,
    }
}

mod mariadb_suite {
    use super::{Mariadb114, MySqlTlsEngine};

    tablepro_test_support::tls_conformance_suite! {
        engine: MySqlTlsEngine<Mariadb114>,
        client_identity: true,
    }
}

/// An SSH forward as the driver sees one: a Unix socket that leads to
/// the service. The socket is a private relay to the server's port, so
/// the server sees TCP as it would through sshd.
#[derive(Debug)]
struct SocketForward {
    relay: Arc<FaultTransport>,
}

impl SocketForward {
    fn to(fixture: &MysqlFixture) -> Arc<Self> {
        let liveness = test_liveness();
        let service = NetworkEndpoint::new(certified_host(fixture.host()), fixture.port()).expect("an endpoint");
        let relay = FaultTransport::direct(service, &liveness).expect("a relay");
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

fn over_socket(fixture: &MysqlFixture, tls: TlsConfig) -> ConnectOptions {
    options_over(
        SocketForward::to(fixture),
        password(&fixture.password_credentials()),
        fixture.database(),
        tls,
        WorkspaceSettings::workspace(false),
        test_liveness(),
    )
}

/// The TLS version the session negotiated, empty without TLS. Asked on
/// an editor session, whose connection takes the same route.
async fn ssl_version(connection: &dyn tablepro_core::Connection) -> String {
    let session = session(connection).await;
    let events = run_ok(session.as_ref(), "SHOW SESSION STATUS LIKE 'Ssl_version'").await;
    session.close().await;
    events
        .rows()
        .first()
        .and_then(|row| row.get(1))
        .map(text)
        .expect("the Ssl_version row")
}

fn verify_full(fixture: &MysqlFixture, server_name: Option<&str>) -> TlsConfig {
    TlsConfig {
        mode: TlsMode::VerifyFull,
        ca_file: Some(fixture.pki().path(PkiFile::Ca)),
        client_identity: None,
        server_name: server_name.map(str::to_owned),
    }
}

/// Through a forward the dial goes to a socket path, so the name TLS
/// checks is the service's own, or the override when one is given.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn verify_identity_through_ssh_socket_with_server_name() {
    for flavour in FLAVOURS {
        let fixture = MysqlFixture::start(flavour).await.expect("a TLS-only server");

        let named = MysqlDriver
            .connect(
                over_socket(&fixture, verify_full(&fixture, Some(TestPki::SERVER_NAMES[1]))),
                CancellationToken::new(),
            )
            .await
            .expect("the override's name is on the certificate");
        assert!(ssl_version(named.as_ref()).await.starts_with("TLS"), "{flavour:?}");
        named.close().await.expect("a close");

        let wrong = MysqlDriver
            .connect(
                over_socket(&fixture, verify_full(&fixture, Some("wrong.tablepro.test"))),
                CancellationToken::new(),
            )
            .await;
        assert!(
            matches!(
                &wrong,
                Err(DriverError::Tls {
                    failure: TlsFailure::NameMismatch,
                    ..
                })
            ),
            "{flavour:?}: {:?}",
            wrong.err()
        );
    }
}

/// The upgrade to TLS happens on the socket stream itself: the server
/// reports a cipher for the session.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn tls_upgrade_happens_over_socket() {
    for flavour in FLAVOURS {
        let fixture = MysqlFixture::start(flavour).await.expect("a TLS-only server");
        let required = TlsConfig {
            mode: TlsMode::Require,
            ..TlsConfig::disabled()
        };

        let connection = MysqlDriver
            .connect(over_socket(&fixture, required), CancellationToken::new())
            .await
            .expect("a TLS connection over the socket");

        let version = ssl_version(connection.as_ref()).await;
        assert!(version.starts_with("TLS"), "{flavour:?}: {version:?}");
        connection.close().await.expect("a close");
    }
}

/// With TLS off, caching_sha2_password's full authentication encrypts
/// the password with the server's RSA key: sqlx sends it in the clear
/// only over TLS, and a socket path does not count as secure.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn disabled_mode_uses_rsa_not_cleartext() {
    let fixture = start_with(MysqlOptions::new(MysqlFlavour::Mysql).allowing_plaintext()).await;

    let connection = MysqlDriver
        .connect(over_socket(&fixture, TlsConfig::disabled()), CancellationToken::new())
        .await
        .expect("a plaintext login over RSA");

    assert_eq!(
        ssl_version(connection.as_ref()).await,
        "",
        "the session is not encrypted"
    );
    connection.close().await.expect("a close");
}

/// A login with no TLS requirement of its own meets the server's
/// `require_secure_transport`, which both servers report as 3159.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn disabled_against_require_secure_transport() {
    for flavour in FLAVOURS {
        let fixture = MysqlFixture::start(flavour).await.expect("a TLS-only server");
        let liveness = test_liveness();
        let options = options_over(
            direct(fixture.host(), fixture.port(), &liveness),
            password(&fixture.root_credentials()),
            fixture.database(),
            TlsConfig::disabled(),
            WorkspaceSettings::workspace(false),
            liveness,
        );

        let outcome = MysqlDriver.connect(options, CancellationToken::new()).await;

        assert!(
            matches!(
                &outcome,
                Err(DriverError::Tls {
                    failure: TlsFailure::ServerRequiresTls,
                    ..
                })
            ),
            "{flavour:?}: {:?}",
            outcome.err()
        );
    }
}

/// A CA that did not issue the server's certificate is named as such.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn unknown_issuer_classified() {
    let fixture = MysqlFixture::start(MysqlFlavour::Mysql)
        .await
        .expect("a TLS-only server");
    let tls = TlsConfig {
        ca_file: Some(fixture.pki().path(PkiFile::UnrelatedCa)),
        ..verify_full(&fixture, None)
    };

    let outcome = MysqlDriver
        .connect(over_socket(&fixture, tls), CancellationToken::new())
        .await;

    assert!(
        matches!(
            &outcome,
            Err(DriverError::Tls {
                failure: TlsFailure::UnknownIssuer,
                ..
            })
        ),
        "{:?}",
        outcome.err()
    );
}
