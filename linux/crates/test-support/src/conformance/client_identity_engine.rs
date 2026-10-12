use tablepro_core::{ClientIdentity, ConnectOptions, TlsConfig};

use crate::conformance::TlsConformanceEngine;

/// A TLS engine whose server can require a client certificate.
pub trait ClientIdentityEngine: TlsConformanceEngine {
    fn client_identity(&self) -> ClientIdentity;

    /// Options for the principal the certificate authenticates, which on
    /// every engine is a different user from the password principal.
    fn certificate_connect_options(&self, tls: TlsConfig) -> ConnectOptions;
}
