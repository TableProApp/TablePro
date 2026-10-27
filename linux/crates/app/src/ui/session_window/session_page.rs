use std::sync::Arc;

use tablepro_session::{ConnectAttempts, ConnectSource, Session, SessionClaim, SessionKey};

use super::session_window_command::ConnectFailure;
use crate::ui::workspace::{Workspace, WorkspaceShell};

/// A session the window holds, with the claim on its key and the
/// workspace that shows it.
pub(crate) struct OpenSession {
    pub(crate) claim: SessionClaim,
    pub(crate) session: Arc<Session>,
    pub(crate) workspace: Workspace,
}

/// A connect running while the window shows its sessions, whose
/// session joins them once it works.
pub(crate) struct BackgroundConnect {
    pub(crate) claim: SessionClaim,
    pub(crate) source: ConnectSource,
    /// Which result is this connect's: a key connected again after it
    /// was stopped starts its count over, so the generation alone could
    /// take the stopped one's late reply for its own.
    pub(crate) serial: u64,
    /// Its own attempts, so connects beside each other run at once and
    /// stopping one cancels only it.
    pub(crate) attempts: ConnectAttempts,
}

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
    /// The shell, and every session the window holds, in the order they
    /// opened. Never empty: the last disconnect returns to the picker.
    Workspace {
        shell: WorkspaceShell,
        sessions: Vec<OpenSession>,
    },
}

impl SessionPage {
    /// The key the page holds a claim on: the session in front's, on
    /// the workspace.
    pub(crate) fn key(&self) -> Option<&SessionKey> {
        match self {
            Self::Picker => None,
            Self::Connecting { claim, .. } | Self::ConnectFailed { claim, .. } => Some(claim.key()),
            Self::Workspace { .. } => self.front().map(|open| open.claim.key()),
        }
    }

    /// The session the shell has in front, or the newest.
    pub(crate) fn front(&self) -> Option<&OpenSession> {
        let Self::Workspace { shell, sessions } = self else {
            return None;
        };
        let front = shell.front();
        sessions
            .iter()
            .find(|open| Some(&open.workspace) == front.as_ref())
            .or_else(|| sessions.last())
    }

    /// The open session under `key`.
    pub(crate) fn session(&self, key: &SessionKey) -> Option<&OpenSession> {
        match self {
            Self::Workspace { sessions, .. } => sessions.iter().find(|open| open.claim.key() == key),
            _ => None,
        }
    }

    /// Every session the window holds.
    pub(crate) fn sessions(&self) -> &[OpenSession] {
        match self {
            Self::Workspace { sessions, .. } => sessions,
            _ => &[],
        }
    }

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
            Self::Workspace { sessions, .. } => f
                .debug_list()
                .entries(sessions.iter().map(|open| open.claim.key()))
                .finish(),
        }
    }
}
