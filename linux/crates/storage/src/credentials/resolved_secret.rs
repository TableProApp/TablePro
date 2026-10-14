use secrecy::SecretString;
use tablepro_core::credentials::SecretSave;

/// A secret ready to log in with.
#[derive(Debug, Clone)]
pub struct ResolvedSecret {
    pub secret: SecretString,
    /// Set when the user typed the secret and asked for it to be kept.
    /// The caller stores it once the login it was typed for works.
    pub remember: Option<SecretSave>,
    /// The user typed it into a prompt, rather than the keyring or the
    /// request supplying it.
    pub typed: bool,
}

impl ResolvedSecret {
    pub(super) fn known(secret: SecretString) -> Self {
        Self {
            secret,
            remember: None,
            typed: false,
        }
    }
}
