use std::fmt;
use std::sync::Arc;

use tablepro_core::Connection;
use tablepro_ssh::SshSession;

/// A connection and the SSH session it runs through, if any.
///
/// The connection's transport already holds the SSH session; it is kept
/// here as well so the monitor can watch the master exit without asking
/// the driver.
pub struct EstablishedConnection {
    pub connection: Arc<dyn Connection>,
    pub ssh_session: Option<Arc<SshSession>>,
}

impl fmt::Debug for EstablishedConnection {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("EstablishedConnection")
            .field("server", self.connection.server_info())
            .field("ssh", &self.ssh_session.as_ref().map(|session| session.destination()))
            .finish()
    }
}
