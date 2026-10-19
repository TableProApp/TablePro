use tablepro_core::credentials::SecretError;

/// The toast for a secret the keyring would not keep. The connection
/// still works; the user is asked for the secret next time.
pub(crate) fn not_saved_message(error: &SecretError) -> String {
    match error {
        SecretError::ServiceUnavailable { .. } => crate::i18n::gettext(
            "No keyring is running, so the password was not saved. It will be asked for next time.",
        ),
        SecretError::PortalUnavailable { .. } => crate::i18n::gettext(
            "The secret portal is unavailable, so the password was not saved. It will be asked for next time.",
        ),
        SecretError::Locked | SecretError::UnlockDismissed => crate::i18n::gettext(
            "The keyring stayed locked, so the password was not saved. It will be asked for next time.",
        ),
        SecretError::Backend {
            service_message: Some(message),
            ..
        } => crate::i18n::gettext_f(
            "The keyring did not save the password: {reason}",
            &[("reason", message)],
        ),
        SecretError::Backend { .. } | SecretError::InvalidEncoding => {
            crate::i18n::gettext("The keyring did not save the password.")
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_message_says_what_happened_in_words_not_the_error_text() {
        let locked = not_saved_message(&SecretError::UnlockDismissed);
        let backend = not_saved_message(&SecretError::Backend {
            detail: "DBus error service error org.freedesktop.Secret.Error.NoSuchObject".to_owned(),
            service_message: Some("No such collection".to_owned()),
        });
        let silent = not_saved_message(&SecretError::Backend {
            detail: "DBus error Item/Collection was deleted, can no longer be used".to_owned(),
            service_message: None,
        });

        assert!(locked.contains("password was not saved"), "{locked}");
        assert!(!locked.contains(&SecretError::UnlockDismissed.to_string()), "{locked}");
        assert_eq!(backend, "The keyring did not save the password: No such collection");
        assert_eq!(silent, "The keyring did not save the password.");
    }
}
