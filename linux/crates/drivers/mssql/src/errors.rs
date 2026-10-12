use deadpool::managed::{PoolError, TimeoutType};
use tablepro_core::{DriverError, LossPhase, ReadOnlyRefusal, ServerCode, ServerDiagnostics, TimeoutPhase};
use tiberius::error::Error;

use crate::tds_message::TdsMessage;
use crate::tls_config::tls_failure;

/// tiberius reports a connection whose wire state it can no longer
/// trust, after a write cut short or a response left half read, as a
/// protocol error with this phrase.
const UNUSABLE: &str = "can no longer be used";

/// What a tiberius error means to the app.
pub(crate) fn map_error(error: Error) -> DriverError {
    match error {
        Error::Io { .. } => DriverError::ConnectionLost {
            during: LossPhase::Statement,
        },
        Error::Tls(detail) => DriverError::Tls {
            failure: tls_failure(&detail),
            detail,
        },
        Error::Server(token) => server_error(&TdsMessage::from(&token)),
        #[cfg(feature = "kerberos")]
        Error::Gssapi(detail) => DriverError::IntegratedAuth(detail),
        Error::Routing { host, port } => {
            DriverError::Protocol(format!("the server asked for the login to go to {host}:{port}"))
        }
        Error::Protocol(text) if text.contains(UNUSABLE) => DriverError::ConnectionLost {
            during: LossPhase::Statement,
        },
        other => DriverError::Protocol(other.to_string()),
    }
}

/// The TDS error numbers the app acts on. Everything else is the
/// server's own answer, passed through with its diagnostics.
pub(crate) fn server_error(message: &TdsMessage) -> DriverError {
    let diagnostics = message.diagnostics();
    match message.number {
        // Login failed, untrusted domain, and an account locked, expired
        // or due a password change.
        18456 | 18452 | 18486 | 18487 | 18488 => DriverError::auth(Some(diagnostics)),
        3906 => DriverError::ReadOnly(ReadOnlyRefusal::server(diagnostics)),
        1222 => DriverError::Timeout {
            phase: TimeoutPhase::LockWait,
            server_cancelled: true,
        },
        // The server's user connection limit.
        17809 => DriverError::Busy,
        _ => DriverError::reported(diagnostics),
    }
}

/// The TDS error number behind a driver error, wherever it ended up.
pub(crate) fn tds_number(error: &DriverError) -> Option<u32> {
    let diagnostics: &ServerDiagnostics = match error {
        DriverError::Server(diagnostics) => diagnostics,
        DriverError::Auth {
            diagnostics: Some(diagnostics),
        } => diagnostics,
        DriverError::ReadOnly(ReadOnlyRefusal::ServerRejected(diagnostics)) => diagnostics,
        _ => return None,
    };
    match diagnostics.code {
        Some(ServerCode::Tds { number, .. }) => Some(number),
        _ => None,
    }
}

/// Whether the connection the error came from is gone or out of step
/// with the server, so it must not run anything else.
pub(crate) fn ends_connection(error: &DriverError) -> bool {
    matches!(
        error,
        DriverError::ConnectionLost { .. } | DriverError::Transport(_) | DriverError::Protocol(_)
    )
}

/// What a pool refusal means. A wait that runs out means every slot is
/// busy, which is the server having no room rather than a dead link.
pub(crate) fn map_pool_error(error: PoolError<DriverError>) -> DriverError {
    match error {
        PoolError::Timeout(TimeoutType::Wait) => DriverError::Busy,
        PoolError::Timeout(TimeoutType::Create) => DriverError::Timeout {
            phase: TimeoutPhase::Login,
            server_cancelled: false,
        },
        PoolError::Timeout(TimeoutType::Recycle) => DriverError::Timeout {
            phase: TimeoutPhase::Probe,
            server_cancelled: false,
        },
        PoolError::Backend(error) => error,
        PoolError::Closed => DriverError::ConnectionLost {
            during: LossPhase::Idle,
        },
        other => DriverError::Protocol(other.to_string()),
    }
}

#[cfg(test)]
mod tests {
    use tablepro_core::{ErrorCategory, TlsFailure};

    use super::*;

    fn message(number: u32, text: &str) -> TdsMessage {
        TdsMessage {
            number,
            state: 1,
            class: 16,
            message: text.to_owned(),
            procedure: String::new(),
            line: 1,
        }
    }

    #[test]
    fn tds_number_table() {
        type Expected = fn(&DriverError) -> bool;
        let cases: [(u32, &str, Expected); 8] = [
            (18456, "Login failed for user 'sa'.", |e| {
                matches!(e, DriverError::Auth { .. })
            }),
            (18488, "Login failed. The password must be changed.", |e| {
                matches!(e, DriverError::Auth { .. })
            }),
            (
                3906,
                "Failed to update database because the database is read-only.",
                |e| matches!(e, DriverError::ReadOnly(ReadOnlyRefusal::ServerRejected(_))),
            ),
            (1222, "Lock request time out period exceeded.", |e| {
                matches!(
                    e,
                    DriverError::Timeout {
                        phase: TimeoutPhase::LockWait,
                        server_cancelled: true
                    }
                )
            }),
            (
                17809,
                "Could not connect because the maximum number of user connections",
                |e| matches!(e, DriverError::Busy),
            ),
            (208, "Invalid object name 't'.", |e| matches!(e, DriverError::Server(_))),
            (1205, "Transaction was deadlocked", |e| {
                matches!(e, DriverError::Server(_))
            }),
            (
                3903,
                "The ROLLBACK TRANSACTION request has no corresponding BEGIN TRANSACTION.",
                |e| matches!(e, DriverError::Server(_)),
            ),
        ];
        for (number, text, expected) in cases {
            let mapped = server_error(&message(number, text));
            assert!(expected(&mapped), "{number}: {mapped:?}");
            if !matches!(mapped, DriverError::Timeout { .. } | DriverError::Busy) {
                assert_eq!(tds_number(&mapped), Some(number), "{number} kept its number");
            }
        }
    }

    #[test]
    fn diagnostics_carry_the_tds_triple_line_and_procedure() {
        let mut sent = message(547, "The INSERT statement conflicted with the FOREIGN KEY constraint");
        sent.procedure = "usp_save".to_owned();
        sent.line = 12;

        let diagnostics = sent.diagnostics();

        assert_eq!(
            diagnostics.code,
            Some(ServerCode::Tds {
                number: 547,
                state: 1,
                class: 16
            })
        );
        assert_eq!(diagnostics.where_context.as_deref(), Some("usp_save"));
        assert_eq!(diagnostics.detail.as_deref(), Some("line 12"));
        assert_eq!(diagnostics.severity.as_deref(), Some("16"));
    }

    #[test]
    fn a_connection_tiberius_will_not_reuse_is_lost() {
        let poisoned = Error::Protocol(
            "connection was left in an inconsistent state by a cancelled write and can no longer be used; open a new connection"
                .into(),
        );

        assert!(matches!(map_error(poisoned), DriverError::ConnectionLost { .. }));
        let io = Error::Io {
            kind: tiberius::error::IoErrorKind::ConnectionReset,
            message: "connection reset by peer".to_owned(),
        };
        assert_eq!(map_error(io).category(), ErrorCategory::ConnectionLost);
    }

    #[test]
    fn a_rustls_rejection_is_a_typed_tls_failure() {
        let mapped = map_error(Error::Tls(
            "the server's certificate was rejected during the TLS handshake: invalid peer certificate: UnknownIssuer."
                .to_owned(),
        ));

        assert!(matches!(
            mapped,
            DriverError::Tls {
                failure: TlsFailure::UnknownIssuer,
                ..
            }
        ));
    }

    #[cfg(feature = "kerberos")]
    #[test]
    fn a_gssapi_failure_is_classified_instead_of_reported_as_an_internal_error() {
        let error = map_error(Error::Gssapi("No Kerberos credentials available".to_owned()));

        assert!(matches!(error, DriverError::IntegratedAuth(detail) if detail.contains("No Kerberos")));
    }

    #[test]
    fn a_pool_wait_that_runs_out_is_busy() {
        assert_eq!(map_pool_error(PoolError::Timeout(TimeoutType::Wait)), DriverError::Busy);
        assert!(matches!(
            map_pool_error(PoolError::Closed),
            DriverError::ConnectionLost { .. }
        ));
        assert_eq!(
            map_pool_error(PoolError::Backend(DriverError::Cancelled)),
            DriverError::Cancelled
        );
    }
}
