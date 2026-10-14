use thiserror::Error;

use crate::workspace::WorkspaceSaveError;

/// What was stored for a deleted connection and could not be removed.
/// None of it undoes the delete: nothing can reach it any more.
#[derive(Debug, Default)]
pub struct DeletionReport {
    pub purge_failures: Vec<PurgeFailure>,
}

impl DeletionReport {
    pub fn is_complete(&self) -> bool {
        self.purge_failures.is_empty()
    }
}

#[derive(Debug, Error)]
pub enum PurgeFailure {
    #[error(transparent)]
    Workspace(WorkspaceSaveError),
    #[error("could not delete the saved queries: {0}")]
    SavedQueries(String),
    #[error("could not delete the query history: {0}")]
    History(String),
    /// The history database never opened, so what it holds for the
    /// connection stays there.
    #[error("the query history is not available")]
    HistoryUnavailable,
}
