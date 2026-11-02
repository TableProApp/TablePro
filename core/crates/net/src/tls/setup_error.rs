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

impl TlsSetupError {
    /// A name for the variant that stays the same across releases, for
    /// a caller outside Rust, such as another platform's UI, that words the error itself. The variant's fields are its parameters.
    pub fn code(&self) -> &'static str {
        match self {
            Self::Config(..) => "tls_setup.config",
            Self::ClientIdentity(..) => "tls_setup.client_identity",
            Self::Rustls(..) => "tls_setup.rustls",
            Self::PemEncoding(..) => "tls_setup.pem_encoding",
        }
    }
}
