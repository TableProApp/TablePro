use tablepro_core::ConfigError;
use thiserror::Error;

#[derive(Debug, Error)]
pub enum TlsSetupError {
    #[error(transparent)]
    Config(#[from] ConfigError),
    /// rustls refused the client certificate or its key.
    #[error("TLS setup failed: {0}")]
    Rustls(rustls::Error),
    /// TLS could not be set up for a reason other than the client
    /// certificate, as when the system trust store holds no certificate
    /// authority.
    #[error("TLS setup failed: {0}")]
    Setup(rustls::Error),
    #[error("could not encode a certificate as PEM: {0}")]
    PemEncoding(pem_rfc7468::Error),
}
