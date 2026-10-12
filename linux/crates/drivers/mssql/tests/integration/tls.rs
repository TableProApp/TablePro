//! The TLS conformance suite against SQL Server, and the classification
//! cases its text-based TLS errors have to get right.
//!
//! The fixture forces encryption with a certificate the test CA issued
//! for `localhost` and `db.tablepro.test`.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use async_trait::async_trait;
use drivers_mssql::MssqlDriver;
use tablepro_core::{
    ConnectOptions, DatabaseDriver, DriverError, ErrorCategory, TlsConfig, TlsFailure, TlsMode, WorkspaceSettings,
};
use tablepro_test_fixtures::{MssqlFixture, PkiFile, TestPki};
use tablepro_test_support::conformance::{ConformanceFailure, TlsConformanceEngine, test_liveness};

use crate::support::{dial, direct, options_over, password, start};

pub struct MssqlTlsEngine {
    fixture: MssqlFixture,
    ca: PathBuf,
    unrelated_ca: PathBuf,
}

#[async_trait]
impl TlsConformanceEngine for MssqlTlsEngine {
    fn driver() -> Arc<dyn DatabaseDriver> {
        Arc::new(MssqlDriver)
    }

    async fn start() -> Result<Self, ConformanceFailure> {
        let fixture = MssqlFixture::start().await.map_err(ConformanceFailure::setup)?;
        let ca = fixture.pki().path(PkiFile::Ca);
        let unrelated_ca = fixture.pki().path(PkiFile::UnrelatedCa);
        Ok(Self {
            fixture,
            ca,
            unrelated_ca,
        })
    }

    fn connect_options(&self, tls: TlsConfig) -> ConnectOptions {
        tls_options(&self.fixture, tls)
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

    /// A login that offers no encryption to a server forcing it fails in
    /// the handshake the server insists on.
    fn plaintext_rejection_category(&self) -> ErrorCategory {
        ErrorCategory::Tls
    }
}

mod suite {
    use super::MssqlTlsEngine;

    tablepro_test_support::tls_conformance_suite! {
        engine: MssqlTlsEngine,
        client_identity: false,
    }
}

fn tls_options(fixture: &MssqlFixture, tls: TlsConfig) -> ConnectOptions {
    let liveness = test_liveness();
    options_over(
        direct(fixture.host(), fixture.port(), &liveness),
        password(&fixture.password_credentials()),
        tls,
        WorkspaceSettings::workspace(false),
        liveness,
    )
}

fn verify_full(fixture: &MssqlFixture, ca: Option<PkiFile>, server_name: &str) -> TlsConfig {
    TlsConfig {
        mode: TlsMode::VerifyFull,
        ca_file: ca.map(|file| fixture.pki().path(file)),
        client_identity: None,
        server_name: Some(server_name.to_owned()),
    }
}

fn failure(outcome: &Result<Arc<dyn tablepro_core::Connection>, DriverError>) -> Option<TlsFailure> {
    match outcome {
        Err(DriverError::Tls { failure, .. }) => Some(*failure),
        _ => None,
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn verify_full_with_ca_ok() {
    let fixture = start().await;
    let tls = verify_full(&fixture, Some(PkiFile::Ca), TestPki::SERVER_NAMES[1]);

    let connection = dial(tls_options(&fixture, tls)).await.expect("a verified connection");

    connection
        .probe(crate::support::within(crate::support::CALL))
        .await
        .expect("a probe");
    connection.close().await.expect("a close");
}

/// The test CA is in no system store, so the system roots alone do not
/// reach the server's certificate.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn without_ca_unknown_issuer() {
    let fixture = start().await;
    let tls = verify_full(&fixture, None, TestPki::SERVER_NAMES[1]);

    let outcome = dial(tls_options(&fixture, tls)).await;

    assert_eq!(
        failure(&outcome),
        Some(TlsFailure::UnknownIssuer),
        "{:?}",
        outcome.err()
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn disable_against_forced_encryption_server_requires_tls() {
    let fixture = start().await;

    let outcome = dial(tls_options(&fixture, TlsConfig::disabled())).await;

    assert_eq!(
        failure(&outcome),
        Some(TlsFailure::ServerRequiresTls),
        "{:?}",
        outcome.err()
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn name_mismatch_classified() {
    let fixture = start().await;
    let tls = verify_full(&fixture, Some(PkiFile::Ca), "wrong.tablepro.test");

    let outcome = dial(tls_options(&fixture, tls)).await;

    assert_eq!(failure(&outcome), Some(TlsFailure::NameMismatch), "{:?}", outcome.err());
}
