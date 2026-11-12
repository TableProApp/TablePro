//! The TLS conformance suite against a TLS-only node of each server.

use std::marker::PhantomData;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use async_trait::async_trait;
use tablepro_core::{
    ClientIdentity, ConnectOptions, Credentials, DatabaseDriver, ErrorCategory, TlsConfig, WorkspaceSettings,
};
use tablepro_driver_cassandra::CassandraDriver;
use tablepro_test_fixtures::{CassandraFixture, CassandraTls, PkiFile, TestPki};
use tablepro_test_support::conformance::{
    ClientIdentityEngine, ConformanceFailure, TlsConformanceEngine, test_liveness,
};

use crate::support::{CassandraServer, ScyllaServer, Server, direct, options_over, password};

/// A node that takes TLS only. `IDENTITY` asks every client for a
/// certificate, for the one case that needs it: neither server can ask
/// one role for a certificate and not another.
pub struct CqlTlsEngine<S: Server, const IDENTITY: bool> {
    fixture: CassandraFixture,
    ca: PathBuf,
    unrelated_ca: PathBuf,
    server_certificate: PathBuf,
    server: PhantomData<S>,
}

impl<S: Server, const IDENTITY: bool> CqlTlsEngine<S, IDENTITY> {
    fn from_fixture(fixture: CassandraFixture) -> Self {
        let ca = fixture.pki().path(PkiFile::Ca);
        let unrelated_ca = fixture.pki().path(PkiFile::UnrelatedCa);
        let server_certificate = fixture.pki().path(PkiFile::ServerCertificate);
        Self {
            fixture,
            ca,
            unrelated_ca,
            server_certificate,
            server: PhantomData,
        }
    }

    fn options(&self, credentials: Credentials, tls: TlsConfig) -> ConnectOptions {
        let liveness = test_liveness();
        options_over(
            direct(self.fixture.host(), self.fixture.port(), &liveness),
            credentials,
            tls,
            WorkspaceSettings::workspace(false),
            liveness,
        )
    }
}

#[async_trait]
impl<S: Server, const IDENTITY: bool> TlsConformanceEngine for CqlTlsEngine<S, IDENTITY> {
    fn driver() -> Arc<dyn DatabaseDriver> {
        Arc::new(CassandraDriver)
    }

    async fn start() -> Result<Self, ConformanceFailure> {
        let tls = match IDENTITY {
            true => CassandraTls::ClientCertificate,
            false => CassandraTls::Required,
        };
        CassandraFixture::start_with(S::FLAVOUR, tls, None)
            .await
            .map(Self::from_fixture)
            .map_err(ConformanceFailure::setup)
    }

    // The self-signed case presents no client certificate, so even the
    // identity engine's node asks for none.
    async fn start_self_signed() -> Result<Self, ConformanceFailure> {
        CassandraFixture::start_self_signed(S::FLAVOUR, CassandraTls::Required)
            .await
            .map(Self::from_fixture)
            .map_err(ConformanceFailure::setup)
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

    fn server_certificate_file(&self) -> &Path {
        &self.server_certificate
    }

    fn served_name(&self) -> &str {
        TestPki::SERVER_NAMES[1]
    }

    /// A plaintext STARTUP fails the node's handshake, which closes the
    /// connection without a CQL answer, then completes the driver's own
    /// TLS handshake.
    fn plaintext_rejection_category(&self) -> ErrorCategory {
        ErrorCategory::Tls
    }
}

impl<S: Server> ClientIdentityEngine for CqlTlsEngine<S, true> {
    fn client_identity(&self) -> ClientIdentity {
        ClientIdentity {
            certificate: self.fixture.pki().path(PkiFile::ClientCertificate),
            key: self.fixture.pki().path(PkiFile::ClientKey),
        }
    }

    fn certificate_connect_options(&self, tls: TlsConfig) -> ConnectOptions {
        self.options(password(&self.fixture.certificate_credentials()), tls)
    }
}

mod cassandra_suite {
    use super::{CassandraServer, CqlTlsEngine};

    tablepro_test_support::tls_conformance_suite! {
        engine: CqlTlsEngine<CassandraServer, false>,
        identity_engine: CqlTlsEngine<CassandraServer, true>,
        client_identity: true,
    }
}

mod scylla_suite {
    use super::{CqlTlsEngine, ScyllaServer};

    tablepro_test_support::tls_conformance_suite! {
        engine: CqlTlsEngine<ScyllaServer, false>,
        identity_engine: CqlTlsEngine<ScyllaServer, true>,
        client_identity: true,
    }
}
