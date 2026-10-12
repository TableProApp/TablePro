use tablepro_core::{DriverError, ErrorCategory};

use super::FailureCause;

/// What a health probe found.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ProbeOutcome {
    Healthy,
    /// The connection answered, just not yet. It is alive, so this
    /// counts as healthy for the monitor's purposes.
    Busy,
    /// No answer in time. One of these is a hiccup; several in a row
    /// mean the connection is gone.
    Unresponsive,
    Lost,
    /// The server answered by refusing. Retrying the probe will not
    /// change that, but the connection itself is still up.
    Rejected(FailureCause),
}

impl ProbeOutcome {
    pub fn classify(result: Result<(), DriverError>) -> Self {
        let Err(error) = result else {
            return Self::Healthy;
        };
        if let Some(cause) = FailureCause::of(&error) {
            return Self::Rejected(cause);
        }
        match error.category() {
            ErrorCategory::Busy => Self::Busy,
            ErrorCategory::ConnectionLost | ErrorCategory::Network | ErrorCategory::File => Self::Lost,
            ErrorCategory::Timeout
            | ErrorCategory::Server
            | ErrorCategory::Internal
            | ErrorCategory::Interrupted
            | ErrorCategory::ReadOnly
            | ErrorCategory::WriteOutcome => Self::Unresponsive,
            ErrorCategory::Authentication => Self::Rejected(FailureCause::Authentication),
            ErrorCategory::Tls => Self::Rejected(FailureCause::Tls),
            ErrorCategory::Configuration => Self::Rejected(FailureCause::Configuration),
        }
    }
}

#[cfg(test)]
mod tests {
    use tablepro_core::{LossPhase, NetworkEndpoint, SshFailure, TimeoutPhase, TransportError};

    use super::*;

    #[test]
    fn classify_follows_the_error_category() {
        let refused = DriverError::Transport(TransportError::Refused {
            endpoint: NetworkEndpoint::new("db", 5432).unwrap(),
        });
        let changed = DriverError::Transport(TransportError::Ssh(SshFailure::HostKeyChanged {
            host: "bastion".to_owned(),
            algorithm: "ED25519".to_owned(),
            sha256_fingerprint: "SHA256:abc".to_owned(),
            known_hosts: "/home/u/.ssh/known_hosts".into(),
            line: 3,
        }));

        assert_eq!(ProbeOutcome::classify(Ok(())), ProbeOutcome::Healthy);
        assert_eq!(ProbeOutcome::classify(Err(DriverError::Busy)), ProbeOutcome::Busy);
        assert_eq!(
            ProbeOutcome::classify(Err(DriverError::Timeout {
                phase: TimeoutPhase::Probe,
                server_cancelled: false
            })),
            ProbeOutcome::Unresponsive
        );
        assert_eq!(
            ProbeOutcome::classify(Err(DriverError::server("boom"))),
            ProbeOutcome::Unresponsive
        );
        assert_eq!(
            ProbeOutcome::classify(Err(DriverError::ConnectionLost {
                during: LossPhase::Idle
            })),
            ProbeOutcome::Lost
        );
        assert_eq!(ProbeOutcome::classify(Err(refused)), ProbeOutcome::Lost);
        assert_eq!(
            ProbeOutcome::classify(Err(DriverError::auth(None))),
            ProbeOutcome::Rejected(FailureCause::Authentication)
        );
        assert_eq!(
            ProbeOutcome::classify(Err(changed)),
            ProbeOutcome::Rejected(FailureCause::HostKeyChanged)
        );
    }
}
