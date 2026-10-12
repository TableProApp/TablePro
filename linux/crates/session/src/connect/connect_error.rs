use tablepro_core::{DriverError, ErrorCategory};
use tablepro_storage::{CredentialError, KeyringError};
use thiserror::Error;

use crate::health::FailureCause;
use crate::runtime::TaskPanic;

/// Why a connect attempt produced no session.
#[derive(Debug, Clone, PartialEq, Error)]
pub enum ConnectError {
    #[error(transparent)]
    Driver(#[from] DriverError),
    #[error(transparent)]
    Keyring(#[from] KeyringError),
    #[error("the {0} driver is not available")]
    UnknownDriver(String),
    #[error("cancelled")]
    Cancelled,
    #[error("the connect task panicked: {0}")]
    Panicked(TaskPanic),
}

impl From<CredentialError> for ConnectError {
    fn from(error: CredentialError) -> Self {
        match error {
            CredentialError::Keyring(error) => Self::Keyring(error),
            CredentialError::Cancelled => Self::Cancelled,
        }
    }
}

impl ConnectError {
    /// The cause to park on when retrying cannot help, `None` when a
    /// retry on a backoff might.
    ///
    /// A missing or unreadable secret needs the user, so it parks as an
    /// authentication failure; so does a file that is gone.
    pub fn failure_cause(&self) -> Option<FailureCause> {
        match self {
            Self::Driver(error) if error.category() == ErrorCategory::File => Some(FailureCause::Configuration),
            Self::Driver(error) => FailureCause::of(error),
            Self::Keyring(_) => Some(FailureCause::Authentication),
            Self::UnknownDriver(_) => Some(FailureCause::Configuration),
            Self::Cancelled | Self::Panicked(_) => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;

    use tablepro_core::credentials::SecretKind;
    use tablepro_core::{LossPhase, SshFailure, TransportError};

    use super::*;

    #[test]
    fn missing_secrets_and_files_park_and_losses_retry() {
        let not_stored = ConnectError::Keyring(KeyringError::SecretNotStored {
            kind: SecretKind::DatabasePassword,
        });
        let gone = ConnectError::Driver(DriverError::FileNotFound {
            path: PathBuf::from("/srv/app.db"),
        });
        let lost = ConnectError::Driver(DriverError::ConnectionLost {
            during: LossPhase::Connect,
        });
        let unanswered = ConnectError::Driver(DriverError::Transport(TransportError::Ssh(
            SshFailure::InteractionCancelled,
        )));

        assert_eq!(not_stored.failure_cause(), Some(FailureCause::Authentication));
        assert_eq!(gone.failure_cause(), Some(FailureCause::Configuration));
        assert_eq!(unanswered.failure_cause(), Some(FailureCause::Authentication));
        assert_eq!(lost.failure_cause(), None);
        assert_eq!(
            ConnectError::UnknownDriver("oracle".to_owned()).failure_cause(),
            Some(FailureCause::Configuration)
        );
    }

    #[test]
    fn a_cancelled_prompt_is_a_cancelled_connect() {
        assert_eq!(ConnectError::from(CredentialError::Cancelled), ConnectError::Cancelled);
    }
}
