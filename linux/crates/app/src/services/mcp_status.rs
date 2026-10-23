use tablepro_core::credentials::SecretError;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum McpStatus {
    Off,
    Starting,
    Running { port: u16 },
    Failed(McpFailure),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum McpFailure {
    PortInUse(u16),
    Listen {
        port: u16,
        kind: std::io::ErrorKind,
    },
    Keyring(SecretError),
    NoRandomness,
    /// The work panicked or the runtime went away; the detail is for the
    /// log.
    Interrupted(String),
}

impl McpStatus {
    pub fn port(&self) -> Option<u16> {
        match self {
            Self::Running { port } => Some(*port),
            _ => None,
        }
    }
}

impl From<tablepro_mcp::StartError> for McpFailure {
    fn from(error: tablepro_mcp::StartError) -> Self {
        match error {
            tablepro_mcp::StartError::PortInUse(port) => Self::PortInUse(port),
            tablepro_mcp::StartError::Listen { port, source } => {
                tracing::warn!(%source, port, "the MCP server could not listen");
                Self::Listen {
                    port,
                    kind: source.kind(),
                }
            }
        }
    }
}

impl From<tablepro_mcp::ObtainError> for McpFailure {
    fn from(error: tablepro_mcp::ObtainError) -> Self {
        match error {
            tablepro_mcp::ObtainError::Keyring(error) => Self::Keyring(error),
            tablepro_mcp::ObtainError::Random(_) => Self::NoRandomness,
        }
    }
}
