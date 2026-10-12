use tablepro_core::{DriverError, ErrorCategory, SshFailure, TransportError};

/// Why a connection attempt will not succeed on a retry.
///
/// Each of these needs the user to change something, so the monitor
/// parks instead of burning a backoff loop against a password that is
/// wrong or a host key that changed.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FailureCause {
    Authentication,
    Tls,
    Configuration,
    HostKeyUnknown,
    HostKeyChanged,
    HostKeyRevoked,
}

impl FailureCause {
    /// The cause when retrying the same request cannot help, `None`
    /// when it can. Host keys are told apart because each needs a
    /// different review from the user.
    pub fn of(error: &DriverError) -> Option<Self> {
        if let DriverError::Transport(TransportError::Ssh(failure)) = error {
            match failure {
                SshFailure::HostKeyUnknown { .. } => return Some(Self::HostKeyUnknown),
                SshFailure::HostKeyChanged { .. } => return Some(Self::HostKeyChanged),
                SshFailure::HostKeyRevoked { .. } => return Some(Self::HostKeyRevoked),
                _ => {}
            }
        }
        match error.category() {
            ErrorCategory::Authentication => Some(Self::Authentication),
            ErrorCategory::Tls => Some(Self::Tls),
            ErrorCategory::Configuration => Some(Self::Configuration),
            ErrorCategory::Network
            | ErrorCategory::ReadOnly
            | ErrorCategory::Server
            | ErrorCategory::Interrupted
            | ErrorCategory::Timeout
            | ErrorCategory::ConnectionLost
            | ErrorCategory::WriteOutcome
            | ErrorCategory::File
            | ErrorCategory::Busy
            | ErrorCategory::Internal => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use tablepro_core::{ConfigError, LossPhase};

    use super::*;

    fn ssh(failure: SshFailure) -> DriverError {
        DriverError::Transport(TransportError::Ssh(failure))
    }

    #[test]
    fn host_keys_are_their_own_causes() {
        let unknown = ssh(SshFailure::HostKeyUnknown {
            host: "bastion".to_owned(),
            algorithm: "ED25519".to_owned(),
            sha256_fingerprint: "SHA256:abc".to_owned(),
            trust_allowed: true,
            declined: true,
        });
        let revoked = ssh(SshFailure::HostKeyRevoked {
            host: "bastion".to_owned(),
            detail: "listed".to_owned(),
        });

        assert_eq!(FailureCause::of(&unknown), Some(FailureCause::HostKeyUnknown));
        assert_eq!(FailureCause::of(&revoked), Some(FailureCause::HostKeyRevoked));
    }

    #[test]
    fn categories_that_need_the_user_park_and_the_rest_retry() {
        assert_eq!(
            FailureCause::of(&DriverError::auth(None)),
            Some(FailureCause::Authentication)
        );
        assert_eq!(
            FailureCause::of(&DriverError::Config(ConfigError::DatabaseRequired)),
            Some(FailureCause::Configuration)
        );
        assert_eq!(
            FailureCause::of(&ssh(SshFailure::InteractionCancelled)),
            Some(FailureCause::Authentication),
            "an unanswered prompt needs someone at the keyboard"
        );
        assert_eq!(
            FailureCause::of(&DriverError::ConnectionLost {
                during: LossPhase::Idle
            }),
            None
        );
        assert_eq!(FailureCause::of(&DriverError::Busy), None);
    }
}
