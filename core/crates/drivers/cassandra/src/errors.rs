//! scylla's errors as `DriverError`, by the CQL error code where the
//! server sent one.

use scylla::errors::{
    BrokenConnectionError, BrokenConnectionErrorKind, ConnectionError, ConnectionPoolError,
    ConnectionSetupRequestError, ConnectionSetupRequestErrorKind, DbError, ExecutionError, FrameHeaderParseError,
    MetadataError, NewSessionError, PrepareError, RequestAttemptError, UseKeyspaceError,
};
use tablepro_core::{DriverError, LossPhase, ServerCode, ServerDiagnostics, TimeoutPhase};

/// The code a CQL ERROR frame carries for `error`, from the native
/// protocol spec. A rate limit is ScyllaDB's own extension, whose code
/// the connection negotiates; it reads as Overloaded, which it is.
pub(crate) fn cql_code(error: &DbError) -> i32 {
    match error {
        DbError::ServerError => 0x0000,
        DbError::ProtocolError => 0x000A,
        DbError::AuthenticationError => 0x0100,
        DbError::Unavailable { .. } => 0x1000,
        DbError::Overloaded | DbError::RateLimitReached { .. } => 0x1001,
        DbError::IsBootstrapping => 0x1002,
        DbError::TruncateError => 0x1003,
        DbError::WriteTimeout { .. } => 0x1100,
        DbError::ReadTimeout { .. } => 0x1200,
        DbError::ReadFailure { .. } => 0x1300,
        DbError::FunctionFailure { .. } => 0x1400,
        DbError::WriteFailure { .. } => 0x1500,
        DbError::SyntaxError => 0x2000,
        DbError::Unauthorized => 0x2100,
        DbError::Invalid => 0x2200,
        DbError::ConfigError => 0x2300,
        DbError::AlreadyExists { .. } => 0x2400,
        DbError::Unprepared { .. } => 0x2500,
        DbError::Other(code) => *code,
        _ => 0x0000,
    }
}

/// What the server said, in its words and with its code.
pub(crate) fn db_error(error: &DbError, message: &str) -> DriverError {
    let message = match message.is_empty() {
        true => error.to_string(),
        false => message.to_owned(),
    };
    let diagnostics = ServerDiagnostics::new(Some(ServerCode::Cql { code: cql_code(error) }), message);
    match error {
        DbError::AuthenticationError => DriverError::auth(Some(diagnostics)),
        _ => DriverError::reported(diagnostics),
    }
}

pub(crate) fn execution_error(error: ExecutionError, during: LossPhase) -> DriverError {
    match error {
        ExecutionError::LastAttemptError(attempt) => attempt_error(attempt, during),
        ExecutionError::PrepareError(prepare) => prepare_error(prepare, during),
        ExecutionError::ConnectionPoolError(pool) => pool_error(pool, during),
        ExecutionError::RequestTimeout(_) => DriverError::Timeout {
            phase: TimeoutPhase::Statement,
            server_cancelled: false,
        },
        ExecutionError::UseKeyspaceError(error) => use_keyspace_error(error, during),
        ExecutionError::MetadataError(error) => metadata_error(error, during),
        other => DriverError::Protocol(other.to_string()),
    }
}

pub(crate) fn prepare_error(error: PrepareError, during: LossPhase) -> DriverError {
    match error {
        PrepareError::ConnectionPoolError(pool) => pool_error(pool, during),
        PrepareError::AllAttemptsFailed { first_attempt } => attempt_error(first_attempt, during),
        other => DriverError::Protocol(other.to_string()),
    }
}

pub(crate) fn attempt_error(error: RequestAttemptError, during: LossPhase) -> DriverError {
    match error {
        RequestAttemptError::DbError(db, message) => db_error(&db, &message),
        RequestAttemptError::BrokenConnectionError(broken) => broken_connection(&broken, during),
        RequestAttemptError::UnableToAllocStreamId => DriverError::ConnectionLost { during },
        other => DriverError::Protocol(other.to_string()),
    }
}

fn pool_error(error: ConnectionPoolError, during: LossPhase) -> DriverError {
    match error {
        ConnectionPoolError::Broken { last_connection_error } => connection_error(last_connection_error, during),
        _ => DriverError::ConnectionLost { during },
    }
}

pub(crate) fn use_keyspace_error(error: UseKeyspaceError, during: LossPhase) -> DriverError {
    match error {
        UseKeyspaceError::RequestError(attempt) => attempt_error(attempt, during),
        other => DriverError::server(other.to_string()),
    }
}

fn metadata_error(error: MetadataError, during: LossPhase) -> DriverError {
    match error {
        MetadataError::ConnectionPoolError(pool) => pool_error(pool, during),
        other => DriverError::Protocol(other.to_string()),
    }
}

/// A connection that could not be opened or set up: a TLS failure, the
/// server refusing the login, or the stream closing under it.
pub(crate) fn connection_error(error: ConnectionError, during: LossPhase) -> DriverError {
    match error {
        ConnectionError::ConnectTimeout => DriverError::Timeout {
            phase: TimeoutPhase::Connect,
            server_cancelled: false,
        },
        ConnectionError::IoError(io) => match tablepro_net::tls::classify(io.as_ref()) {
            Some((failure, detail)) => DriverError::Tls { failure, detail },
            None => DriverError::ConnectionLost { during },
        },
        ConnectionError::BrokenConnection(broken) => broken_connection(&broken, during),
        ConnectionError::ConnectionSetupRequestError(setup) => setup_error(setup, during),
        ConnectionError::UseKeyspaceError(error) => use_keyspace_error(error, during),
        other => DriverError::Protocol(other.to_string()),
    }
}

fn setup_error(error: ConnectionSetupRequestError, during: LossPhase) -> DriverError {
    match error.error {
        ConnectionSetupRequestErrorKind::DbError(db, message) => db_error(&db, &message),
        ConnectionSetupRequestErrorKind::MissingAuthentication => DriverError::auth(Some(ServerDiagnostics::new(
            Some(ServerCode::Cql { code: 0x0100 }),
            "the server requires a login",
        ))),
        ConnectionSetupRequestErrorKind::BrokenConnection(broken) => broken_connection(&broken, during),
        ConnectionSetupRequestErrorKind::StartAuthSessionError(error)
        | ConnectionSetupRequestErrorKind::AuthChallengeEvaluationError(error)
        | ConnectionSetupRequestErrorKind::AuthFinishError(error) => {
            DriverError::auth(Some(ServerDiagnostics::new(None, error.to_string())))
        }
        other => DriverError::Protocol(other.to_string()),
    }
}

/// A TLS failure the connection broke on, or the connection gone.
/// scylla keeps the reason a connection broke behind a type it gives no
/// `source`, so the read or write that failed is reached by its kind: a
/// TLS alert the server sent arrives as one.
fn broken_connection(error: &BrokenConnectionError, during: LossPhase) -> DriverError {
    let io = match error.downcast_ref::<BrokenConnectionErrorKind>() {
        Some(
            BrokenConnectionErrorKind::FrameHeaderParseError(
                FrameHeaderParseError::HeaderIoError(io) | FrameHeaderParseError::BodyChunkIoError(_, io),
            )
            | BrokenConnectionErrorKind::WriteError(io),
        ) => Some(io),
        _ => None,
    };
    match io.and_then(|io| tablepro_net::tls::classify(io)) {
        Some((failure, detail)) => DriverError::Tls { failure, detail },
        None => DriverError::ConnectionLost { during },
    }
}

/// A session that could not be built: its control connection's own
/// failure, which carries the login and TLS errors.
pub(crate) fn new_session_error(error: NewSessionError) -> DriverError {
    match error {
        NewSessionError::MetadataError(error) => metadata_error(error, LossPhase::Connect),
        NewSessionError::UseKeyspaceError(error) => use_keyspace_error(error, LossPhase::Connect),
        other => DriverError::Protocol(other.to_string()),
    }
}

#[cfg(test)]
mod tests {
    use tablepro_core::{ErrorCategory, TlsFailure};

    use super::*;

    #[test]
    fn a_server_error_keeps_its_code_and_words() {
        let error = db_error(&DbError::Invalid, "unconfigured table missing");

        assert_eq!(
            error,
            DriverError::reported(ServerDiagnostics::new(
                Some(ServerCode::Cql { code: 0x2200 }),
                "unconfigured table missing"
            ))
        );
        assert_eq!(error.category(), ErrorCategory::Server);
    }

    #[test]
    fn bad_credentials_are_an_authentication_failure() {
        let error = db_error(&DbError::AuthenticationError, "Username and/or password are incorrect");

        assert_eq!(error.category(), ErrorCategory::Authentication);
        assert!(error.to_string().contains("0x0100"), "{error}");
    }

    #[test]
    fn an_empty_message_says_what_the_code_means() {
        let error = db_error(&DbError::SyntaxError, "");

        assert!(error.to_string().contains("syntax error"), "{error}");
    }

    #[test]
    fn a_tls_alert_on_a_broken_connection_is_a_tls_failure() {
        let alert = std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            rustls::Error::AlertReceived(rustls::AlertDescription::CertificateRequired),
        );
        let broken = |io| {
            BrokenConnectionError::from(BrokenConnectionErrorKind::FrameHeaderParseError(
                FrameHeaderParseError::HeaderIoError(io),
            ))
        };

        assert!(matches!(
            broken_connection(&broken(alert), LossPhase::Connect),
            DriverError::Tls {
                failure: TlsFailure::HandshakeRejected,
                ..
            }
        ));
        let closed = std::io::Error::from(std::io::ErrorKind::UnexpectedEof);
        assert_eq!(
            broken_connection(&broken(closed), LossPhase::Connect),
            DriverError::ConnectionLost {
                during: LossPhase::Connect
            }
        );
    }

    #[test]
    fn every_spec_code_is_kept() {
        assert_eq!(cql_code(&DbError::Unauthorized), 0x2100);
        assert_eq!(cql_code(&DbError::Other(0x1234)), 0x1234);
        assert_eq!(cql_code(&DbError::IsBootstrapping), 0x1002);
    }
}
