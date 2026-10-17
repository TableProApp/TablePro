use tablepro_core::ConfigError;
use thiserror::Error;

#[derive(Debug, Error)]
pub enum TlsSetupError {
    #[error(transparent)]
    Config(#[from] ConfigError),
    /// rustls refused the client certificate and key, as when the key
    /// is not the certificate's.
    #[error("the client certificate cannot be used: {0}")]
    ClientIdentity(rustls::Error),
    /// Anything else rustls refused while the config was built, such as
    /// a system trust store it could not load.
    #[error("TLS setup failed: {0}")]
    Rustls(#[from] rustls::Error),
    #[error("could not encode a certificate as PEM: {0}")]
    PemEncoding(pem_rfc7468::Error),
}
