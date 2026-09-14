use tablepro_core::ConfigError;
use thiserror::Error;

#[derive(Debug, Error)]
pub enum TlsSetupError {
    #[error(transparent)]
    Config(#[from] ConfigError),
    #[error("TLS setup failed: {0}")]
    Rustls(#[from] rustls::Error),
    #[error("could not encode a certificate as PEM: {0}")]
    PemEncoding(pem_rfc7468::Error),
}
