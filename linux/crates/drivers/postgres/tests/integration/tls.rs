//! The TLS conformance suite against PostgreSQL, and the TLS cases only
//! PostgreSQL has.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use async_trait::async_trait;
use drivers_postgres::PgDriver;
use secrecy::SecretString;
use tablepro_core::{
    ClientIdentity, ConnectOptions, Credentials, DatabaseDriver, DriverError, ErrorCategory, TlsConfig, TlsFailure,
    TlsMode, WorkspaceSettings,
};
use tablepro_net::tls::build_client_config;
use tablepro_test_fixtures::{HbaMode, PkiAlgorithm, PkiFile, PostgresFixture, TestPki};
use tablepro_test_support::conformance::{
    ClientIdentityEngine, ConformanceFailure, TlsConformanceEngine, test_liveness,
};
use tokio_postgres::config::{ChannelBinding, SslMode};
use tokio_postgres_rustls::MakeRustlsConnect;
use tokio_util::sync::CancellationToken;

use crate::support::{direct, options_over, password, start};

pub struct PgTlsEngine {
    fixture: PostgresFixture,
    ca: PathBuf,
    unrelated_ca: PathBuf,
}

impl PgTlsEngine {
    fn options(&self, credentials: Credentials, tls: TlsConfig) -> ConnectOptions {
        let liveness = test_liveness();
        options_over(
            direct(self.fixture.host(), self.fixture.port(), &liveness),
            credentials,
            self.fixture.database(),
            tls,
            WorkspaceSettings::workspace(false),
            liveness,
        )
    }
}

#[async_trait]
impl TlsConformanceEngine for PgTlsEngine {
    fn driver() -> Arc<dyn DatabaseDriver> {
        Arc::new(PgDriver)
    }

    async fn start() -> Result<Self, ConformanceFailure> {
        let fixture = PostgresFixture::start(HbaMode::ClientCertificate)
            .await
            .map_err(ConformanceFailure::setup)?;
        let ca = fixture.pki().path(PkiFile::Ca);
        let unrelated_ca = fixture.pki().path(PkiFile::UnrelatedCa);
        Ok(Self {
            fixture,
            ca,
            unrelated_ca,
        })
    }

    fn connect_options(&self, tls: TlsConfig) -> ConnectOptions {
        self.options(password(&self.fixture.password_credentials()), tls)
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

    /// `hostnossl all all all reject` answers a plaintext login with
    /// FATAL 28000, "no pg_hba.conf entry ... no encryption".
    fn plaintext_rejection_category(&self) -> ErrorCategory {
        ErrorCategory::Authentication
    }
}

impl ClientIdentityEngine for PgTlsEngine {
    fn client_identity(&self) -> ClientIdentity {
        ClientIdentity {
            certificate: self.fixture.pki().path(PkiFile::ClientCertificate),
            key: self.fixture.pki().path(PkiFile::ClientKey),
        }
    }

    fn certificate_connect_options(&self, tls: TlsConfig) -> ConnectOptions {
        let credentials = Credentials::Password {
            username: TestPki::CLIENT_COMMON_NAME.to_owned(),
            password: SecretString::from(String::new()),
        };
        self.options(credentials, tls)
    }
}

mod suite {
    use super::PgTlsEngine;

    tablepro_test_support::tls_conformance_suite! {
        engine: PgTlsEngine,
        client_identity: true,
    }
}

/// A server with TLS off answers the SSLRequest with 'N', and the driver
/// says the server refused TLS rather than that a handshake failed.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn server_without_ssl_reports_server_refused_tls() {
    let fixture = start().await;
    let liveness = test_liveness();
    let tls = TlsConfig {
        mode: TlsMode::Require,
        ..TlsConfig::disabled()
    };
    let options = options_over(
        direct(fixture.host(), fixture.port(), &liveness),
        password(&fixture.password_credentials()),
        fixture.database(),
        tls,
        WorkspaceSettings::workspace(false),
        liveness,
    );

    let outcome = PgDriver.connect(options, CancellationToken::new()).await;

    assert!(
        matches!(
            &outcome,
            Err(DriverError::Tls {
                failure: TlsFailure::ServerRefusedTls,
                ..
            })
        ),
        "got {:?}",
        outcome.err()
    );
}

/// TLS that checks nothing about the certificate, so the cases below
/// test channel binding alone.
fn unverified() -> TlsConfig {
    TlsConfig {
        mode: TlsMode::Require,
        ..TlsConfig::disabled()
    }
}

async fn start_with_pki(algorithm: PkiAlgorithm) -> PostgresFixture {
    PostgresFixture::start_with_pki(HbaMode::HostSslOnly, algorithm)
        .await
        .expect("a TLS-only server")
}

/// A login through the TLS stack the driver uses, with the client's
/// channel binding set. The driver's own connections always prefer it,
/// so requiring it takes a client of the test's own.
async fn login_with_channel_binding(
    fixture: &PostgresFixture,
    binding: ChannelBinding,
) -> Result<(), tokio_postgres::Error> {
    let client_config = build_client_config(&unverified())
        .expect("a TLS setup")
        .expect("a TLS client config");
    let credentials = fixture.password_credentials();
    let mut config = tokio_postgres::Config::new();
    config
        .host(fixture.host())
        .port(fixture.port())
        .user(&credentials.username)
        .password(&credentials.password)
        .dbname(fixture.database())
        .ssl_mode(SslMode::Require)
        .channel_binding(binding);
    let (client, connection) = config.connect(MakeRustlsConnect::new((*client_config).clone())).await?;
    let driving = tokio::spawn(connection);
    let answered = client.simple_query("SELECT 1").await.map(|_| ());
    drop(client);
    let _ = driving.await;
    answered
}

/// The server hashes its certificate with the hash its signature names,
/// SHA-256 or SHA-384, and the client's binding has to match it.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn channel_binding_require_with_rsa_sha256_and_ecdsa_p384() {
    for algorithm in [PkiAlgorithm::RsaSha256, PkiAlgorithm::EcdsaP384Sha384] {
        let fixture = start_with_pki(algorithm).await;

        let outcome = login_with_channel_binding(&fixture, ChannelBinding::Require).await;

        assert!(outcome.is_ok(), "{algorithm:?}: {outcome:?}");
    }
}

/// tls-server-end-point names no hash for an Ed25519 signature, so a
/// client that requires binding gives up before the password is sent,
/// and the driver, which only prefers it, logs in without.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn ed25519_cert_require_fails_prefer_connects() {
    let fixture = start_with_pki(PkiAlgorithm::Ed25519).await;

    let required = login_with_channel_binding(&fixture, ChannelBinding::Require).await;
    let liveness = test_liveness();
    let options = options_over(
        direct(fixture.host(), fixture.port(), &liveness),
        password(&fixture.password_credentials()),
        fixture.database(),
        unverified(),
        WorkspaceSettings::workspace(false),
        liveness,
    );
    let preferred = PgDriver.connect(options, CancellationToken::new()).await;

    // tokio-postgres keeps the reason in the source, not the message.
    let refused_for_binding = required.as_ref().is_err_and(|error| {
        std::error::Error::source(error).is_some_and(|cause| cause.to_string().contains("channel binding"))
    });
    assert!(refused_for_binding, "{required:?}");
    let connection = preferred.expect("a login that only prefers channel binding");
    connection.close().await.expect("a close");
}
