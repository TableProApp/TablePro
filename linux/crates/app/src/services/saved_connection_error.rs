use tablepro_core::credentials::SecretError;
use tablepro_session::runtime::TaskFailure;
use tablepro_storage::StorageError;
use uuid::Uuid;

/// Why an edit, a copy or a move of a saved connection did not happen.
#[derive(Debug, thiserror::Error)]
pub enum SavedConnectionError {
    #[error(transparent)]
    Storage(#[from] StorageError),
    #[error(transparent)]
    Secret(#[from] SecretError),
    /// Deleted, here or in another window, since it was shown.
    #[error("no saved connection has the id {0}")]
    NotFound(Uuid),
    #[error(transparent)]
    Task(#[from] TaskFailure),
}
