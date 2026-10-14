use tablepro_core::credentials::SecretError;
use tablepro_session::runtime::TaskFailure;
use tablepro_storage::StorageError;
use thiserror::Error;

/// Why a saved connection is still there after a delete.
#[derive(Debug, Error)]
pub enum DeletionError {
    /// The keyring kept the connection's secrets, so the entry was kept
    /// too: a secret with no entry would be orphaned in the keyring.
    #[error("the stored passwords could not be deleted: {0}")]
    Secrets(SecretError),
    /// The secrets are gone but the entry is not. It still connects
    /// once the user types its passwords.
    #[error("the connection could not be removed from the list: {0}")]
    Entry(StorageError),
    #[error("the delete did not finish: {0}")]
    Interrupted(TaskFailure),
}
