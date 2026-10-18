use secrecy::SecretString;

/// The result of asking the keyring for a secret.
///
/// `NotStored` is not an error: a connection may legitimately have no
/// saved password, and the app prompts for one instead of failing.
#[derive(Debug, Clone)]
pub enum SecretLookup {
    Found(SecretString),
    NotStored,
}

impl SecretLookup {
    pub fn found(self) -> Option<SecretString> {
        match self {
            Self::Found(secret) => Some(secret),
            Self::NotStored => None,
        }
    }

    pub fn is_stored(&self) -> bool {
        matches!(self, Self::Found(_))
    }
}
