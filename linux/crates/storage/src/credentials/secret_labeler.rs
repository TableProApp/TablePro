use tablepro_core::credentials::SecretKind;

/// Turns a secret's target into the label the keyring shows for it.
///
/// A plain function so the app can pass its translated wording without
/// this crate knowing about gettext.
pub type SecretLabeler = fn(SecretKind, &str) -> String;

/// The untranslated label, for callers that have no catalog.
pub fn english_secret_label(kind: SecretKind, target: &str) -> String {
    match kind {
        SecretKind::DatabasePassword => format!("TablePro database password for {target}"),
        SecretKind::SshPassword => format!("TablePro SSH password for {target}"),
        SecretKind::SshPassphrase => format!("TablePro SSH key passphrase for {target}"),
    }
}
