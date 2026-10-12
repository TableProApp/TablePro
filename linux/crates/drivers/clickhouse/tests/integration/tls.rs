//! The TLS conformance suite against ClickHouse's HTTPS port, and the
//! TLS cases only an HTTP engine has.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use async_trait::async_trait;
use drivers_clickhouse::ClickhouseDriver;
use secrecy::SecretString;
use tablepro_core::{
    ClientIdentity, ConnectOptions, Credentials, DatabaseDriver, DriverError, ErrorCategory, TlsConfig, TlsFailure,
    TlsMode, WorkspaceSettings,
};
use tablepro_test_fixtures::{ClickHouseFixture, PkiFile, TestPki};
use tablepro_test_support::conformance::{
    ClientIdentityEngine, ConformanceFailure, TlsConformanceEngine, test_liveness,
};
use tokio_util::sync::CancellationToken;

use crate::support::{CALL, direct, options_over, password, start, within};

pub struct ClickHouseTlsEngine {
    fixture: ClickHouseFixture,
    ca: PathBuf,
    unrelated_ca: PathBuf,
}

impl ClickHouseTlsEngine {
    fn options(&self, port: u16, credentials: Credentials, tls: TlsConfig) -> ConnectOptions {
        let liveness = test_liveness();
        options_over(
            direct(self.fixture.host(), port, &liveness),
            credentials,
            tls,
            WorkspaceSettings::workspace(false),
            liveness,
        )
    }
}

#[async_trait]
impl TlsConformanceEngine for ClickHouseTlsEngine {
    fn driver() -> Arc<dyn DatabaseDriver> {
        Arc::new(ClickhouseDriver)
    }

    async fn start() -> Result<Self, ConformanceFailure> {
        let fixture = ClickHouseFixture::start().await.map_err(ConformanceFailure::setup)?;
        let ca = fixture.pki().path(PkiFile::Ca);
        let unrelated_ca = fixture.pki().path(PkiFile::UnrelatedCa);
        Ok(Self {
            fixture,
            ca,
            unrelated_ca,
        })
    }

    fn connect_options(&self, tls: TlsConfig) -> ConnectOptions {
        self.options(
            self.fixture.https_port(),
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

    /// Plain HTTP to the HTTPS port fails the server's handshake, and it
    /// closes the connection without an HTTP answer.
    fn plaintext_rejection_category(&self) -> ErrorCategory {
        ErrorCategory::ConnectionLost
    }
}

impl ClientIdentityEngine for ClickHouseTlsEngine {
    fn client_identity(&self) -> ClientIdentity {
        ClientIdentity {
            certificate: self.fixture.pki().path(PkiFile::ClientCertificate),
            key: self.fixture.pki().path(PkiFile::ClientKey),
        }
    }

    fn certificate_connect_options(&self, tls: TlsConfig) -> ConnectOptions {
        let credentials = self.fixture.certificate_credentials();
        self.options(
            self.fixture.https_port(),
            Credentials::Password {
                username: credentials.username,
                password: SecretString::from(credentials.password),
            },
            tls,
        )
    }
}

mod suite {
    use super::ClickHouseTlsEngine;

    tablepro_test_support::tls_conformance_suite! {
        engine: ClickHouseTlsEngine,
        client_identity: true,
    }
}

fn verify_full(ca: &Path, server_name: &str) -> TlsConfig {
    TlsConfig {
        mode: TlsMode::VerifyFull,
        ca_file: Some(ca.to_owned()),
        client_identity: None,
        server_name: Some(server_name.to_owned()),
    }
}

async fn connect(options: ConnectOptions) -> Result<Arc<dyn tablepro_core::Connection>, DriverError> {
    ClickhouseDriver.connect(options, CancellationToken::new()).await
}

#[tokio::test]
#[ignore = "requires docker"]
async fn https_verify_full_ok() {
    let fixture = start().await;
    let liveness = test_liveness();
    let options = options_over(
        direct(fixture.host(), fixture.https_port(), &liveness),
        password(&fixture.password_credentials()),
        verify_full(&fixture.pki().path(PkiFile::Ca), TestPki::SERVER_NAMES[1]),
        WorkspaceSettings::workspace(false),
        liveness,
    );

    let connection = connect(options).await.expect("a verified connection");

    connection
        .probe(within(CALL))
        .await
        .expect("the server answers over TLS");
    assert!(connection.server_info().version.starts_with("25."));
    connection.close().await.expect("a close");
}

#[tokio::test]
#[ignore = "requires docker"]
async fn name_mismatch() {
    let fixture = start().await;
    let liveness = test_liveness();
    let options = options_over(
        direct(fixture.host(), fixture.https_port(), &liveness),
        password(&fixture.password_credentials()),
        verify_full(&fixture.pki().path(PkiFile::Ca), "wrong.tablepro.test"),
        WorkspaceSettings::workspace(false),
        liveness,
    );

    let outcome = connect(options).await;

    assert!(
        matches!(
            outcome,
            Err(DriverError::Tls {
                failure: TlsFailure::NameMismatch,
                ..
            })
        ),
        "a certificate for another name gave {:?}",
        outcome.err()
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn http_port_with_https_server_refused() {
    let fixture = start().await;
    let liveness = test_liveness();
    let tls = TlsConfig {
        mode: TlsMode::Require,
        ..TlsConfig::disabled()
    };
    let options = options_over(
        direct(fixture.host(), fixture.http_port(), &liveness),
        password(&fixture.password_credentials()),
        tls,
        WorkspaceSettings::workspace(false),
        liveness,
    );

    let outcome = connect(options).await;

    assert!(
        matches!(&outcome, Err(error) if error.category() == ErrorCategory::Tls),
        "TLS to the plain HTTP port gave {:?}",
        outcome.err()
    );
}
