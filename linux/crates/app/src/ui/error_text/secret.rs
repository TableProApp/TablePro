/// What to tell the user about a keyring failure. Each variant maps to
/// a different next step, so they are not collapsed into one sentence.
pub(super) fn secret_message(error: &tablepro_core::credentials::SecretError) -> String {
    use tablepro_core::credentials::SecretError;

    match error {
        SecretError::ServiceUnavailable { .. } => crate::i18n::gettext(
            "No keyring is running, so saved passwords cannot be read. Start a keyring, or enter the password by hand.",
        ),
        SecretError::PortalUnavailable { .. } => crate::i18n::gettext(
            "The secret portal is unavailable, so saved passwords cannot be read inside the sandbox.",
        ),
        SecretError::Locked => crate::i18n::gettext("The keyring is locked. Unlock it and try again."),
        SecretError::UnlockDismissed => {
            crate::i18n::gettext("The keyring stayed locked because the unlock prompt was dismissed.")
        }
        SecretError::InvalidEncoding => {
            crate::i18n::gettext("The stored password is not readable text. Enter it again to replace it.")
        }
        SecretError::Backend { detail } => {
            crate::i18n::gettext_f("The keyring reported: {detail}", &[("detail", detail)])
        }
    }
}
