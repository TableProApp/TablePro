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

impl DeletionError {
    /// What the user is told about the delete of `name`.
    pub fn summary(&self, name: &str) -> String {
        match self {
            Self::Secrets(_) => {
                crate::i18n::gettext("The stored passwords could not be deleted, so the connection was kept.")
            }
            Self::Entry(_) => crate::i18n::gettext_f(
                "“{name}” is still listed, but its stored passwords were deleted. Connecting will ask for them.",
                &[("name", name)],
            ),
            Self::Interrupted(_) => crate::i18n::gettext_f("“{name}” could not be deleted", &[("name", name)]),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_kept_entry_says_its_passwords_are_gone() {
        let kept = DeletionError::Entry(StorageError::Schema("read-only".to_owned()));

        let said = kept.summary("Prod");

        assert!(said.contains("“Prod” is still listed"), "{said}");
        assert!(said.contains("passwords were deleted"), "{said}");
    }

    #[test]
    fn an_interrupted_delete_says_nothing_was_deleted() {
        let said = DeletionError::Interrupted(TaskFailure::Aborted).summary("Prod");

        assert_eq!(said, "“Prod” could not be deleted");
    }
}
