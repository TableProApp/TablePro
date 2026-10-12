use tablepro_core::{Credentials, FileEndpoint, NetworkEndpoint, TlsConfig, TransportClass};
use tablepro_ssh::SshConfig;

/// Where a connect request goes and how it logs in.
#[derive(Debug, Clone)]
#[expect(
    clippy::large_enum_variant,
    reason = "one per connect request; inline fields keep every match on the network target direct"
)]
pub enum RequestTarget {
    Network {
        endpoint: NetworkEndpoint,
        ssh: Option<SshConfig>,
        credentials: Credentials,
        database: Option<String>,
        tls: TlsConfig,
    },
    File(FileEndpoint),
}

impl RequestTarget {
    /// The same target as a reconnect must reach it. A file that was
    /// created on the first connect is opened, not created again.
    pub fn for_reconnect(&self) -> Self {
        match self {
            Self::File(endpoint) => Self::File(endpoint.for_reopen()),
            network @ Self::Network { .. } => network.clone(),
        }
    }

    pub fn transport_class(&self) -> Option<TransportClass> {
        match self {
            Self::Network { ssh: Some(_), .. } => Some(TransportClass::SshForward),
            Self::Network { ssh: None, .. } => Some(TransportClass::DirectTcp),
            Self::File(_) => None,
        }
    }
}
