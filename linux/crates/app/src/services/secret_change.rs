use secrecy::SecretString;

/// What an edit does to one of a saved connection's stored secrets.
#[derive(Debug, Clone, Default)]
pub enum SecretChange {
    /// Leave whatever the keyring holds, which may be nothing.
    #[default]
    Keep,
    Replace(SecretString),
    /// The edited connection no longer logs in with it, or the user
    /// asked not to keep it.
    Remove,
}
