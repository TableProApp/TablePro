/// What to tell the user about a keyring failure. Each variant maps to
/// a different next step, so they are not collapsed into one sentence.
pub(super) fn secret_message(error: &tablepro_core::credentials::SecretError) -> String {
    use tablepro_core::credentials::SecretError;

    match error {
        SecretError::ServiceUnavailable { .. } => crate::i18n::gettext(
            "No keyring is running, so saved passwords cannot be read. Start a keyring, or enter the password by hand.",
        ),
        SecretError::PortalUnavailable { .. } => crate::i18n::gettext(
            "The secret portal is unavailable, so saved passwords cannot be read inside the sandbox. Check that xdg-desktop-portal and a keyring are running, or enter the password by hand.",
        ),
        SecretError::Locked => crate::i18n::gettext("The keyring is locked. Unlock it and try again."),
        SecretError::UnlockDismissed => {
            crate::i18n::gettext("The keyring stayed locked because the unlock prompt was dismissed.")
        }
        SecretError::InvalidEncoding => {
            crate::i18n::gettext("The stored password is not readable text. Enter it again to replace it.")
        }
        SecretError::Backend {
            detail,
            service_message,
        } => {
            // oo7's text is never shown, so the log is the only place it goes.
            tracing::warn!(%detail, "the keyring failed");
            match service_message {
                Some(message) => crate::i18n::gettext_f("The keyring reported: {detail}", &[("detail", message)]),
                None => crate::i18n::gettext("The keyring failed without giving a reason."),
            }
        }
    }
}
