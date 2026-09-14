use std::path::PathBuf;

use thiserror::Error;

use crate::{CertificateFileProblem, TransportClass};

#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum ConfigError {
    #[error("the host is empty")]
    EmptyHost,

    #[error("the host contains spaces or control characters")]
    InvalidHost,

    #[error("the port must be between 1 and 65535")]
    InvalidPort,

    #[error("the path must be absolute")]
    RelativePath,

    #[error("this TLS mode is not supported")]
    UnsupportedTlsMode,

    #[error("a CA file needs TLS turned on and a driver that accepts one")]
    CaFileUnsupported,

    #[error("a client certificate needs TLS turned on and a driver that accepts one")]
    ClientIdentityUnsupported,

    #[error("a client certificate needs both a certificate file and a key file")]
    ClientIdentityIncomplete,

    #[error("CA file {}: {problem}", .path.display())]
    CaFile {
        path: PathBuf,
        problem: CertificateFileProblem,
    },

    #[error("the TLS server name is not a valid DNS name or IP address")]
    InvalidServerName,

    #[error("a TLS server name override is not supported over {route}")]
    ServerNameOverrideUnsupported { route: TransportClass },

    #[error("this authentication method is not supported")]
    AuthModeUnsupported,

    #[error("a database name is required")]
    DatabaseRequired,
}
