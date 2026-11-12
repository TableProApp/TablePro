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
        SavedConnectionError::TagNotFound(_) => crate::i18n::gettext("The tag was deleted."),
        SavedConnectionError::Storage(StorageError::TagNameTaken) => crate::i18n::gettext("Another tag has that name."),
        SavedConnectionError::Storage(StorageError::GroupNotFound { .. }) => {
            crate::i18n::gettext("The group was deleted.")
        }
        SavedConnectionError::Storage(StorageError::GroupNameTaken { name }) => {
            crate::i18n::gettext_f("A group named “{name}” is already there.", &[("name", name.as_str())])
        }
        SavedConnectionError::Storage(StorageError::GroupCycle { .. }) => {
            crate::i18n::gettext("A group cannot move into one of its own subgroups.")
        }
        SavedConnectionError::Storage(StorageError::GroupTooDeep { max }) => crate::i18n::ngettext_f(
            "Groups can be nested only {max} level deep.",
            "Groups can be nested only {max} levels deep.",
            *max,
            &[("max", &max.to_string())],
        ),
        SavedConnectionError::Storage(StorageError::GroupExists { .. }) => {
            crate::i18n::gettext("That group already exists.")
        }
        SavedConnectionError::Storage(StorageError::ConnectionNotFound { .. }) => {
            crate::i18n::gettext("The connection was deleted.")
        }
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
        assert_eq!(
            saved_connection_error_message(&SavedConnectionError::Storage(StorageError::TagNameTaken)),
            "Another tag has that name."
        );
        assert_eq!(
            saved_connection_error_message(&SavedConnectionError::TagNotFound(Uuid::nil())),
            "The tag was deleted."
        );
        assert_eq!(
            saved_connection_error_message(&SavedConnectionError::Storage(StorageError::GroupNotFound {
                id: Uuid::nil()
            })),
            "The group was deleted."
        );
    }

    #[test]
    fn each_library_failure_says_what_happened() {
        let storage = |error: StorageError| saved_connection_error_message(&SavedConnectionError::Storage(error));

        assert_eq!(
            storage(StorageError::GroupNameTaken {
                name: "Work".to_owned()
            }),
            "A group named “Work” is already there."
        );
        assert_eq!(
            storage(StorageError::GroupCycle { id: Uuid::nil() }),
            "A group cannot move into one of its own subgroups."
        );
        assert_eq!(
            storage(StorageError::GroupTooDeep { max: 3 }),
            "Groups can be nested only 3 levels deep."
        );
        assert_eq!(
            storage(StorageError::GroupTooDeep { max: 1 }),
            "Groups can be nested only 1 level deep."
        );
        assert_eq!(
            storage(StorageError::GroupExists { id: Uuid::nil() }),
            "That group already exists."
        );
        assert_eq!(
            storage(StorageError::ConnectionNotFound { id: Uuid::nil() }),
            "The connection was deleted."
        );
    }
}
