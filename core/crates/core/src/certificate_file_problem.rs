use thiserror::Error;

/// What is wrong with a CA, certificate or key file. The PEM and
/// certificate parsers report in English only, so their messages are not
/// kept; the I/O error's kind is.
#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum CertificateFileProblem {
    #[error("the file could not be read: {kind}")]
    Unreadable { kind: std::io::ErrorKind },

    #[error("it is not a regular file")]
    NotRegularFile,

    #[error("the file is larger than {} KiB", limit_bytes / 1024)]
    TooLarge { limit_bytes: usize },

    #[error("the file contains no certificates")]
    NoCertificates,

    #[error("a certificate is invalid")]
    InvalidCertificate,

    #[error("the file contains {count} certificates, but only one is allowed")]
    MultipleCertificates { count: usize },

    #[error("the file contains no private key")]
    NoPrivateKey,

    #[error("the private key is invalid")]
    InvalidPrivateKey,
}

impl CertificateFileProblem {
    /// A name for the variant that stays the same across releases, for
    /// a caller outside Rust, such as another platform's UI, that words the error itself. The variant's fields are its parameters.
    pub fn code(&self) -> &'static str {
        match self {
            Self::Unreadable { .. } => "certificate_file.unreadable",
            Self::NotRegularFile => "certificate_file.not_regular_file",
            Self::TooLarge { .. } => "certificate_file.too_large",
            Self::NoCertificates => "certificate_file.no_certificates",
            Self::InvalidCertificate => "certificate_file.invalid_certificate",
            Self::MultipleCertificates { .. } => "certificate_file.multiple_certificates",
            Self::NoPrivateKey => "certificate_file.no_private_key",
            Self::InvalidPrivateKey => "certificate_file.invalid_private_key",
        }
    }
}
