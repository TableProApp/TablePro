use std::sync::Arc;

use tablepro_session::{ConnectSource, Session, SessionClaim};

use super::session_window_command::ConnectFailure;
use crate::ui::workspace::Workspace;

/// Which page a window shows, and what it holds for that page. The
/// claim on the session's key lives here, so leaving the page releases
/// it.
#[derive(Default)]
pub(crate) enum SessionPage {
    /// The saved connections, to pick one from.
    #[default]
    Picker,
    Connecting {
        claim: SessionClaim,
        source: ConnectSource,
    },
    ConnectFailed {
        claim: SessionClaim,
        source: ConnectSource,
        failure: ConnectFailure,
    },
    Workspace {
        claim: SessionClaim,
        session: Arc<Session>,
        workspace: Workspace,
    },
}

impl SessionPage {
    #[cfg(test)]
    pub(crate) fn name(&self) -> &'static str {
        match self {
            Self::Picker => "picker",
            Self::Connecting { .. } => "connecting",
            Self::ConnectFailed { .. } => "connect-failed",
            Self::Workspace { .. } => "workspace",
        }
    }
}

impl std::fmt::Debug for SessionPage {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Picker => f.write_str("Picker"),
            Self::Connecting { claim, .. } => f.debug_struct("Connecting").field("key", claim.key()).finish(),
            Self::ConnectFailed { claim, failure, .. } => f
                .debug_struct("ConnectFailed")
                .field("key", claim.key())
                .field("failure", failure)
                .finish(),
            Self::Workspace { claim, .. } => f.debug_struct("Workspace").field("key", claim.key()).finish(),
        }
    }
}
