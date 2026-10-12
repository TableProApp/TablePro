use tablepro_core::credentials::SecretError;

/// The toast for a secret the keyring would not keep. The connection
/// still works; the user is asked for the secret next time.
pub(crate) fn not_saved_message(error: &SecretError) -> String {
    crate::i18n::gettext_f(
        "Password not saved in the keyring: {reason}",
        &[("reason", &error.to_string())],
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_message_names_the_reason() {
        let message = not_saved_message(&SecretError::UnlockDismissed);

        assert!(message.contains("Password not saved in the keyring"), "{message}");
        assert!(message.contains("dismissed"), "{message}");
    }
}
