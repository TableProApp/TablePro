use std::fmt;

use crate::server_diagnostics::ServerDiagnostics;

/// Who refused a write on a read-only connection.
///
/// The app's own guard and the server's refusal read differently: one
/// is a setting the user can change here, the other is the server's
/// answer and may mean a replica or a read-only transaction.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ReadOnlyRefusal {
    ClientGuard,
    ServerRejected(Box<ServerDiagnostics>),
}

impl ReadOnlyRefusal {
    pub fn server(diagnostics: ServerDiagnostics) -> Self {
        Self::ServerRejected(Box::new(diagnostics))
    }
}

impl fmt::Display for ReadOnlyRefusal {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::ClientGuard => f.write_str("the connection is open read-only"),
            Self::ServerRejected(diagnostics) => write!(f, "the server refused the write: {diagnostics}"),
        }
    }
}
