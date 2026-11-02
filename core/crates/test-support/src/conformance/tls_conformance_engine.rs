use std::path::Path;
use std::sync::Arc;

use async_trait::async_trait;
use tablepro_core::{ConnectOptions, DatabaseDriver, ErrorCategory, TlsConfig};

use crate::conformance::ConformanceFailure;

/// What a driver's integration target supplies so the TLS suite can run
/// against a server that accepts only TLS.
#[async_trait]
pub trait TlsConformanceEngine: Send + Sync + Sized + 'static {
    fn driver() -> Arc<dyn DatabaseDriver>;

    /// Start a TLS-only server from the test fixtures.
    async fn start() -> Result<Self, ConformanceFailure>;

    /// Options for the password principal on the server's mapped port.
    fn connect_options(&self, tls: TlsConfig) -> ConnectOptions;

    fn ca_file(&self) -> &Path;

    fn unrelated_ca_file(&self) -> &Path;

    /// A name on the server certificate, sent as the TLS server name
    /// where the driver lets one be set on a direct route.
    fn served_name(&self) -> &str;

    /// What a plaintext connect to this server fails with.
    fn plaintext_rejection_category(&self) -> ErrorCategory;

    /// Options that reach the server under a name its certificate does
    /// not carry. An engine that cannot override the server name on a
    /// direct route targets an address that is not on the certificate
    /// instead.
    fn name_mismatch_connect_options(&self, tls: TlsConfig) -> ConnectOptions {
        let tls = TlsConfig {
            server_name: Some("wrong.tablepro.test".to_owned()),
            ..tls
        };
        self.connect_options(tls)
    }
}
