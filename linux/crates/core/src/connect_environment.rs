/// The name the app gives itself to a server, which shows up in the
/// server's own session lists (`pg_stat_activity`, `sys.dm_exec_sessions`)
/// so an administrator can tell which sessions are ours.
pub const APPLICATION_NAME: &str = "TablePro";

/// What a driver needs to know about the app itself, rather than about
/// the connection.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConnectEnvironment {
    /// The app's version, reported next to `APPLICATION_NAME` where the
    /// protocol has room for one.
    pub client_version: String,
}

impl ConnectEnvironment {
    pub fn new(client_version: impl Into<String>) -> Self {
        Self {
            client_version: client_version.into(),
        }
    }
}
