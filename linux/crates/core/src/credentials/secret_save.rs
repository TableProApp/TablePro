use secrecy::SecretString;

use super::SecretKind;

/// One secret to store, with the label the keyring shows the user.
#[derive(Debug, Clone)]
pub struct SecretSave {
    pub kind: SecretKind,
    pub secret: SecretString,
    pub label: String,
}
