//! The TLS conformance suite against a Redis that takes only TLS, and a
//! second one beside it that takes only clients with a certificate.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use secrecy::SecretString;
use tablepro_core::{
    ClientIdentity, ConnectOptions, Credentials, DatabaseDriver, ErrorCategory, TlsConfig, WorkspaceSettings,
};
use tablepro_driver_redis::RedisDriver;
use tablepro_test_fixtures::{PkiFile, RedisFixture, TestPki};
use tablepro_test_support::conformance::{
    ClientIdentityEngine, ConformanceFailure, TlsConformanceEngine, test_liveness,
};

use crate::support::{direct, options_over, password};

pub struct RedisTlsEngine {
    fixture: RedisFixture,
    ca: PathBuf,
    unrelated_ca: PathBuf,
}

impl RedisTlsEngine {
    fn options(&self, port: u16, credentials: Credentials, tls: TlsConfig) -> ConnectOptions {
        let liveness = test_liveness();
        options_over(
            direct(self.fixture.host(), port, &liveness),
            credentials,
            None,
            tls,
            WorkspaceSettings::workspace(false),
            liveness,
        )
    }
}

#[async_trait::async_trait]
impl TlsConformanceEngine for RedisTlsEngine {
    fn driver() -> Arc<dyn DatabaseDriver> {
        Arc::new(RedisDriver)
    }

    async fn start() -> Result<Self, ConformanceFailure> {
        let fixture = RedisFixture::start_tls().await.map_err(ConformanceFailure::setup)?;
        let ca = fixture.pki().path(PkiFile::Ca);
        let unrelated_ca = fixture.pki().path(PkiFile::UnrelatedCa);
        Ok(Self {
            fixture,
            ca,
            unrelated_ca,
        })
    }

    fn connect_options(&self, tls: TlsConfig) -> ConnectOptions {
        self.options(self.fixture.port(), password(&self.fixture.password_credentials()), tls)
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

    /// The server reads the plaintext login as a broken handshake and
    /// closes the connection without a reply.
    fn plaintext_rejection_category(&self) -> ErrorCategory {
        ErrorCategory::ConnectionLost
    }
}

impl ClientIdentityEngine for RedisTlsEngine {
    fn client_identity(&self) -> ClientIdentity {
        ClientIdentity {
            certificate: self.fixture.pki().path(PkiFile::ClientCertificate),
            key: self.fixture.pki().path(PkiFile::ClientKey),
        }
    }

    /// Redis maps no certificate to a user: the server beside the first
    /// takes only a client that presents one, as its default user.
    fn certificate_connect_options(&self, tls: TlsConfig) -> ConnectOptions {
        let port = self.fixture.certificate_port().expect("the certificate server");
        let credentials = Credentials::Password {
            username: String::new(),
            password: SecretString::from(String::new()),
        };
        self.options(port, credentials, tls)
    }
}

mod suite {
    use super::RedisTlsEngine;

    tablepro_test_support::tls_conformance_suite! {
        engine: RedisTlsEngine,
        client_identity: true,
    }
}
