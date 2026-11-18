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
    fn places(&self) -> Places {
        Places::PREFERENCES
    }
}

// Where an app keeps what a message sends the user to: the MCP switch and port, and the token.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Places {
    pub mcp_settings: &'static str,
    pub token_store: &'static str,
}

impl Places {
    pub const PREFERENCES: Self = Self {
        mcp_settings: "Preferences > MCP",
        token_store: "the keyring",
    };
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
    #[error("{}", keyring_unreadable(.reason, Places::PREFERENCES))]
    Keyring { reason: String },
    #[error("{}", foreign_server(*.port, Places::PREFERENCES))]
    ForeignServer { port: u16 },
    #[error("Nothing listens on port {port}.")]
    NotListening { port: u16 },
    #[error("Could not check which program answers on port {port}: {reason}")]
    Unverified { port: u16, reason: String },
}

impl HostError {
    pub fn message(&self, places: Places) -> String {
        match self {
            Self::Keyring { reason } => keyring_unreadable(reason, places),
            Self::ForeignServer { port } => foreign_server(*port, places),
            other => other.to_string(),
        }
    }

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

fn keyring_unreadable(reason: &str, places: Places) -> String {
    format!("Could not read the MCP token from {}: {reason}", places.token_store)
}

fn foreign_server(port: u16, places: Places) -> String {
    format!(
        "Another program holds port {port}, so the command did not send it TablePro's token. Quit that program, \
or pick another port in {}.",
        places.mcp_settings
    )
}
