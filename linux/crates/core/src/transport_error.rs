use thiserror::Error;

use crate::{ErrorCategory, NetworkEndpoint, SshFailure, TimeoutPhase};

#[derive(Debug, Clone, PartialEq, Eq, Error)]
#[non_exhaustive]
pub enum TransportError {
    #[error("could not resolve {host}: {detail}")]
    NameResolution { host: String, detail: String },

    #[error("{endpoint} refused the connection")]
    Refused { endpoint: NetworkEndpoint },

    #[error("could not reach {endpoint}: {detail}")]
    Unreachable { endpoint: NetworkEndpoint, detail: String },

    #[error("timed out during {phase}")]
    Timeout { phase: TimeoutPhase },

    #[error(transparent)]
    Ssh(#[from] SshFailure),
}

impl TransportError {
    pub fn category(&self) -> ErrorCategory {
        match self {
            Self::NameResolution { .. } | Self::Refused { .. } | Self::Unreachable { .. } => ErrorCategory::Network,
            Self::Timeout { .. } => ErrorCategory::Timeout,
            Self::Ssh(failure) => failure.category(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn assert_send_sync_error<E: std::error::Error + Send + Sync + 'static>() {}

    #[test]
    fn is_send_sync_error() {
        assert_send_sync_error::<TransportError>();
    }

    #[test]
    fn category_follows_the_variant_and_delegates_ssh() {
        let endpoint = NetworkEndpoint::new("db.example.com", 5432).unwrap();
        let cases = [
            (
                TransportError::NameResolution {
                    host: "db.example.com".to_owned(),
                    detail: "no such host".to_owned(),
                },
                ErrorCategory::Network,
            ),
            (
                TransportError::Refused {
                    endpoint: endpoint.clone(),
                },
                ErrorCategory::Network,
            ),
            (
                TransportError::Unreachable {
                    endpoint,
                    detail: "no route to host".to_owned(),
                },
                ErrorCategory::Network,
            ),
            (
                TransportError::Timeout {
                    phase: TimeoutPhase::Connect,
                },
                ErrorCategory::Timeout,
            ),
            (
                TransportError::Ssh(SshFailure::InteractionCancelled),
                ErrorCategory::Authentication,
            ),
        ];
        for (error, expected) in cases {
            assert_eq!(error.category(), expected, "{error:?}");
        }
    }
}
