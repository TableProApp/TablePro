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
use tablepro_test_fixtures::{HbaMode, PkiFile, PostgresFixture, TestPki};
use tablepro_test_support::conformance::{
    ClientIdentityEngine, ConformanceFailure, TlsConformanceEngine, test_liveness,
};
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
