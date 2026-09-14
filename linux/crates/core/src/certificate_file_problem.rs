use thiserror::Error;

#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum CertificateFileProblem {
    #[error("the file could not be read: {detail}")]
    Unreadable { detail: String },

    #[error("the file contains no certificates")]
    NoCertificates,

    #[error("a certificate is invalid: {detail}")]
    InvalidCertificate { detail: String },

    #[error("the file contains {count} certificates, but only one is allowed")]
    MultipleCertificates { count: usize },

    #[error("the file contains no private key")]
    NoPrivateKey,

    #[error("the private key is invalid: {detail}")]
    InvalidPrivateKey { detail: String },
}
