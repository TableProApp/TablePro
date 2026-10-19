use tablepro_storage::StorageError;

use super::files::storage_io_message;
use super::operation::task_failure_message;
use super::secret::secret_message;
use crate::services::saved_connection_error::SavedConnectionError;

/// What to tell the user about an edit, a copy or a move of a saved
/// connection that did not happen. Nothing was changed in each case, so
/// the sentence says what to fix before trying again.
pub fn saved_connection_error_message(error: &SavedConnectionError) -> String {
    match error {
        SavedConnectionError::Secret(error) => secret_message(error),
        SavedConnectionError::NotFound(_) => crate::i18n::gettext("The connection was deleted."),
        SavedConnectionError::Storage(StorageError::DocumentUnavailable(_)) => {
            crate::i18n::gettext("The saved connections could not be read, so nothing was changed.")
        }
        SavedConnectionError::Storage(error) => storage_io_message(error)
            .unwrap_or_else(|| crate::i18n::gettext("The saved connections could not be written.")),
        SavedConnectionError::Task(failure) => task_failure_message(failure),
    }
}

#[cfg(test)]
mod tests {
    use tablepro_core::credentials::SecretError;
    use uuid::Uuid;

    use super::*;

    #[test]
    fn each_failure_says_what_happened() {
        assert_eq!(
            saved_connection_error_message(&SavedConnectionError::Secret(SecretError::Locked)),
            "The keyring is locked. Unlock it and try again."
        );
        assert_eq!(
            saved_connection_error_message(&SavedConnectionError::NotFound(Uuid::nil())),
            "The connection was deleted."
        );
        assert_eq!(
            saved_connection_error_message(&SavedConnectionError::Storage(StorageError::Io {
                path: "/home/ada/.local/share/tablepro/connections.json".into(),
                source: std::io::Error::from(std::io::ErrorKind::StorageFull),
            })),
            "Could not write /home/ada/.local/share/tablepro/connections.json: the disk is full."
        );
        assert_eq!(
            saved_connection_error_message(&SavedConnectionError::Storage(StorageError::Schema(
                "the connections write task failed".to_owned(),
            ))),
            "The saved connections could not be written."
        );
    }
}
