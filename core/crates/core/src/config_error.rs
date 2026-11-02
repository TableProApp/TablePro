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

    #[error("a CA file needs Verify full and a driver that accepts one")]
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

    #[error("client certificate file {}: {problem}", .path.display())]
    ClientIdentityFile {
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

    /// A key-value engine numbers its databases.
    #[error("the database must be a number from 0")]
    DatabaseNumber,

    /// A seed list names every server of a cluster, and an SSH forward
    /// reaches one host.
    #[error("a DNS seed list cannot be reached through an SSH tunnel")]
    SeedListOverSsh,

    #[error("this connection option is not supported by the driver")]
    NetworkOptionUnsupported,
}

impl ConfigError {
    /// A name for the variant that stays the same across releases, for
    /// a caller outside Rust, such as another platform's UI, that words the error itself. The variant's fields are its parameters.
    pub fn code(&self) -> &'static str {
        match self {
            Self::EmptyHost => "config.empty_host",
            Self::InvalidHost => "config.invalid_host",
            Self::InvalidPort => "config.invalid_port",
            Self::RelativePath => "config.relative_path",
            Self::UnsupportedTlsMode => "config.unsupported_tls_mode",
            Self::CaFileUnsupported => "config.ca_file_unsupported",
            Self::ClientIdentityUnsupported => "config.client_identity_unsupported",
            Self::ClientIdentityIncomplete => "config.client_identity_incomplete",
            Self::CaFile { .. } => "config.ca_file",
            Self::ClientIdentityFile { .. } => "config.client_identity_file",
            Self::InvalidServerName => "config.invalid_server_name",
            Self::ServerNameOverrideUnsupported { .. } => "config.server_name_override_unsupported",
            Self::AuthModeUnsupported => "config.auth_mode_unsupported",
            Self::DatabaseRequired => "config.database_required",
            Self::DatabaseNumber => "config.database_number",
            Self::SeedListOverSsh => "config.seed_list_over_ssh",
            Self::NetworkOptionUnsupported => "config.network_option_unsupported",
        }
    }
}
