use tablepro_session::PendingSession;
use tablepro_session::connect::AttemptGeneration;
use tablepro_storage::SavedConnection;

use crate::ui::error_text::TlsRemedy;

/// What background work a window started brings back to it.
#[derive(Debug)]
pub(crate) enum SessionWindowCommand {
    /// A connect attempt ended. Its generation says which one, so a
    /// result that lands after the user moved on is discarded.
    Attempt {
        generation: AttemptGeneration,
        result: Result<Connected, AttemptError>,
    },
}

/// A connect that worked, waiting for the window to adopt it.
#[derive(Debug)]
pub(crate) struct Connected {
    pub pending: PendingSession,
    /// The saved entry it connected to, as saved, which a reconnect
    /// reads its secrets for. `None` for a file nobody saved.
    pub saved: Option<SavedConnection>,
    /// Secrets the keyring refused to keep, one sentence each.
    pub warnings: Vec<String>,
}

#[derive(Debug)]
pub(crate) enum AttemptError {
    /// The user stopped it, which needs no error.
    Cancelled,
    Failed(ConnectFailure),
}

/// What the failed page says, and the setting that would fix it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ConnectFailure {
    pub message: String,
    pub remedy: Option<TlsRemedy>,
}

impl ConnectFailure {
    pub(crate) fn new(message: String) -> Self {
        Self { message, remedy: None }
    }
}
