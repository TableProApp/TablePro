use std::time::Duration;
use tablepro_transport::TransportError;

pub const BACKOFF_INITIAL: Duration = Duration::from_secs(5);
const BACKOFF_MAX: Duration = Duration::from_secs(60);

pub fn was_cancelled(token: Option<&tokio_util::sync::CancellationToken>) -> bool {
    token.is_some_and(tokio_util::sync::CancellationToken::is_cancelled)
}

pub fn is_permanent_failure(error: &TransportError) -> bool {
    use tablepro_core::DriverError;
    match error {
        TransportError::Driver(driver) => {
            matches!(
                driver,
                DriverError::AuthFailed
                    | DriverError::Tls(_)
                    | DriverError::IntegratedAuth(_)
                    | DriverError::PolicyDenied(_)
                    | DriverError::Unsupported(_)
            ) || matches!(driver, DriverError::Query { sqlstate: Some(state), .. } if state.starts_with("28") || state == "3D000")
        }
        TransportError::Keyring(_)
        | TransportError::Secret(_)
        | TransportError::IntegratedAuthUnsupported(_)
        | TransportError::LocalSocketUnsupported(_)
        | TransportError::LocalSocketWithSsh
        | TransportError::LocalSocketWithTls
        | TransportError::InvalidLocalSocket(_)
        | TransportError::SystemSshUnavailableInSandbox => true,
        TransportError::HostKeyRefused(_) | TransportError::HostKeyChanged(_) | TransportError::HostKeyRevoked(_) => {
            true
        }
        TransportError::AuditWriteFailed(_) => true,
        TransportError::Ssh(_)
        | TransportError::SshTimeout(_)
        | TransportError::Cancelled
        | TransportError::DatabaseTimeout { .. } => false,
    }
}

pub fn next_delay(prev: Duration) -> Duration {
    std::cmp::min(prev.saturating_mul(2), BACKOFF_MAX)
}

#[cfg(test)]
mod failure_tests {
    use super::*;
    #[test]
    fn a_connect_is_cancelled_only_when_its_token_was_cancelled() {
        let token = tokio_util::sync::CancellationToken::new();
        assert!(!was_cancelled(None));
        assert!(!was_cancelled(Some(&token)));
        token.cancel();
        assert!(was_cancelled(Some(&token)));
    }

    use tablepro_core::DriverError;
    use tablepro_storage::KeyringFailure;

    #[test]
    fn wrong_credentials_tls_and_configuration_are_permanent() {
        for error in [
            TransportError::Driver(DriverError::AuthFailed),
            TransportError::Driver(DriverError::Tls("bad certificate".into())),
            TransportError::Driver(DriverError::IntegratedAuth("no ticket".into())),
            TransportError::Driver(DriverError::PolicyDenied("blocked".into())),
            TransportError::Keyring(KeyringFailure::Locked),
            TransportError::IntegratedAuthUnsupported("sqlite".into()),
            TransportError::LocalSocketWithSsh,
            TransportError::HostKeyRefused("unknown".into()),
            TransportError::HostKeyChanged("changed".into()),
            TransportError::HostKeyRevoked("revoked".into()),
            TransportError::AuditWriteFailed("journal unavailable".into()),
        ] {
            assert!(is_permanent_failure(&error), "{error} should stop a reconnect");
        }
    }

    #[test]
    fn a_server_that_refuses_the_login_or_the_database_is_not_retried() {
        for sqlstate in ["28P01", "28000", "3D000"] {
            let error = TransportError::Driver(DriverError::Query {
                message: "refused".into(),
                sqlstate: Some(sqlstate.into()),
                position: None,
            });
            assert!(is_permanent_failure(&error), "{sqlstate} must stop a reconnect");
        }
        let busy = TransportError::Driver(DriverError::Query {
            message: "too many connections".into(),
            sqlstate: Some("53300".into()),
            position: None,
        });
        assert!(!is_permanent_failure(&busy), "a busy server is worth retrying");
    }

    #[test]
    fn a_server_that_is_down_or_slow_is_worth_retrying() {
        for error in [
            TransportError::Driver(DriverError::ConnectionRefused),
            TransportError::Driver(DriverError::Disconnected),
            TransportError::Driver(DriverError::TimedOut),
            TransportError::Ssh("connection reset".into()),
            TransportError::SshTimeout("connection timeout".into()),
            TransportError::Cancelled,
            TransportError::DatabaseTimeout { seconds: 30 },
        ] {
            assert!(!is_permanent_failure(&error), "{error} should keep retrying");
        }
    }
}

#[cfg(test)]
mod backoff_tests {
    use super::*;
    #[test]
    fn backoff_doubles_until_capped() {
        let mut d = BACKOFF_INITIAL;
        assert_eq!(d, Duration::from_secs(5));
        d = next_delay(d);
        assert_eq!(d, Duration::from_secs(10));
        d = next_delay(d);
        assert_eq!(d, Duration::from_secs(20));
        d = next_delay(d);
        assert_eq!(d, Duration::from_secs(40));
        d = next_delay(d);
        assert_eq!(d, BACKOFF_MAX);
        d = next_delay(d);
        assert_eq!(d, BACKOFF_MAX);
    }
    #[test]
    fn backoff_saturates_without_overflow() {
        assert_eq!(next_delay(Duration::MAX), BACKOFF_MAX);
    }
}
