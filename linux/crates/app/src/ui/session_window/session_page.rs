use std::sync::Arc;

use tablepro_session::{ConnectSource, Session, SessionClaim, SessionKey};
use tablepro_storage::CredentialDemand;
use tokio_util::sync::CancellationToken;

use super::session_window_command::ConnectFailure;
use crate::ui::workspace::Workspace;

/// A session the window holds, with the claim on its key and the
/// workspace that shows it.
pub(crate) struct OpenSession {
    pub(crate) claim: SessionClaim,
    pub(crate) session: Arc<Session>,
    pub(crate) workspace: Workspace,
}

/// A connect the window runs, its first one included. Its result
/// carries `id`, so a result for one the window stopped or started
/// again finds nothing and is closed.
pub(crate) struct PendingConnect {
    pub(crate) id: u64,
    pub(crate) claim: SessionClaim,
    pub(crate) source: ConnectSource,
    pub(crate) cancel: CancellationToken,
    /// What the connect asks beyond the stored secrets, kept for the
    /// connect that follows the question about its file.
    pub(crate) demand: CredentialDemand,
}

/// A connect that failed while the window had nothing else to show,
/// which keeps its claim for the failed page's ways on.
pub(crate) struct FailedConnect {
    pub(crate) claim: SessionClaim,
    pub(crate) source: ConnectSource,
    pub(crate) failure: ConnectFailure,
}

/// The key a connect from `source` claims.
pub(crate) fn source_key(source: &ConnectSource) -> SessionKey {
    match source {
        ConnectSource::Saved(saved) => SessionKey::Saved(saved.id),
        ConnectSource::Intent(intent) => intent.key.clone(),
        ConnectSource::File(identity) => SessionKey::File(identity.uri.clone()),
    }
}

/// What the window shows, worked out from what it holds: its sessions,
/// else the failed connect, else its first connect, else the picker.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum SessionPage {
    Picker,
    /// The first of the window's connects, by its id.
    Connecting(u64),
    Failed,
    Shell,
}

impl SessionPage {
    #[cfg(test)]
    pub(crate) fn name(self) -> &'static str {
        match self {
            Self::Picker => "picker",
            Self::Connecting(_) => "connecting",
            Self::Failed => "connect-failed",
            Self::Shell => "workspace",
        }
    }
}
