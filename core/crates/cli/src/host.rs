use std::io::IsTerminal;
use std::net::SocketAddr;

// Each app reads these its own way: Linux from GSettings, the keyring and the session bus.
pub trait Host {
    fn app_version(&self) -> String;
    fn app_running(&self) -> bool;
    fn server_enabled(&self) -> Result<bool, HostError>;
    fn server_port(&self) -> Result<u16, HostError>;
    // Another user can bind the port before TablePro does, so the token goes only to a listener this one confirms.
    fn verify_peer(&self, peer: SocketAddr, local: SocketAddr) -> Result<(), HostError>;
    // Read only: a token made here would be one the running server never accepts.
    fn token(&self) -> Result<Option<String>, HostError>;
    fn terminal(&self) -> Terminal;
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Terminal {
    pub stdin: bool,
    pub stdout: bool,
    pub stderr: bool,
}

impl Terminal {
    pub fn detect() -> Self {
        Self {
            stdin: std::io::stdin().is_terminal(),
            stdout: std::io::stdout().is_terminal(),
            stderr: std::io::stderr().is_terminal(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum HostError {
    #[error("Could not read TablePro's settings: {reason}")]
    Settings { reason: String },
    #[error("Could not read the MCP token from the keyring: {reason}")]
    Keyring { reason: String },
    #[error(
        "Another program holds port {port}, so the command did not send it TablePro's token. Quit that program, or pick another port in Preferences > MCP."
    )]
    ForeignServer { port: u16 },
    #[error("Nothing listens on port {port}.")]
    NotListening { port: u16 },
    #[error("Could not check which program answers on port {port}: {reason}")]
    Unverified { port: u16, reason: String },
}

impl HostError {
    pub fn code(&self) -> &'static str {
        match self {
            Self::Settings { .. } => "cli.settings_unreadable",
            Self::Keyring { .. } => "cli.keyring_unreadable",
            Self::ForeignServer { .. } => "cli.foreign_server",
            Self::NotListening { .. } => "cli.not_listening",
            Self::Unverified { .. } => "cli.server_unverified",
        }
    }
}
