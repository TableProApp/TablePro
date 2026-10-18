use tablepro_core::credentials::{SecretError, SecretKind};
use thiserror::Error;

/// Why the keyring could not supply a secret a connection needs.
#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum KeyringError {
    /// Nothing is stored. Never turned into an empty secret: that would
    /// reach the server and come back as a misleading login failure.
    #[error("no {} is stored for this connection", kind_text(*.kind))]
    SecretNotStored { kind: SecretKind },
    #[error("the {} could not be read from the keyring: {error}", kind_text(*.kind))]
    Secret { kind: SecretKind, error: SecretError },
}

impl KeyringError {
    pub fn kind(&self) -> SecretKind {
        match self {
            Self::SecretNotStored { kind } | Self::Secret { kind, .. } => *kind,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum CredentialError {
    #[error(transparent)]
    Keyring(#[from] KeyringError),
    /// The user dismissed the prompt.
    #[error("the credential prompt was cancelled")]
    Cancelled,
}

fn kind_text(kind: SecretKind) -> &'static str {
    match kind {
        SecretKind::DatabasePassword => "database password",
        SecretKind::SshPassword => "SSH password",
        SecretKind::SshPassphrase => "SSH key passphrase",
    }
}
