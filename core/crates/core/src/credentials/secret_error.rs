use thiserror::Error;

/// Why a keyring operation failed.
///
/// These are distinguished because the app acts on each differently:
/// a dismissed unlock is the user's choice, a locked keyring can be
/// retried, and a missing service means secrets cannot be saved at all.
#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum SecretError {
    #[error("the secret service is unavailable: {detail}")]
    ServiceUnavailable { detail: String },
    #[error("the secret portal is unavailable: {detail}")]
    PortalUnavailable { detail: String },
    #[error("the keyring is locked")]
    Locked,
    #[error("the unlock prompt was dismissed")]
    UnlockDismissed,
    #[error("the stored secret is not valid UTF-8")]
    InvalidEncoding,
    /// A failure the app has no step for. `detail` is oo7's English text
    /// for the log; `service_message` is what the Secret Service itself
    /// answered, when the failure is its reply.
    #[error("the secret service reported: {detail}")]
    Backend {
        detail: String,
        service_message: Option<String>,
    },
}

impl SecretError {
    /// Whether trying again could work. A dismissed prompt and a locked
    /// keyring both clear once the user unlocks; a missing service does
    /// not.
    pub fn is_retryable(&self) -> bool {
        matches!(self, Self::Locked | Self::UnlockDismissed)
    }
}
