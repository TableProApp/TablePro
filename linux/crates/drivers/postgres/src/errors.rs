use std::error::Error as StdError;
use std::io;

use deadpool_postgres::{PoolError, TimeoutType};
use tablepro_core::{
    DriverError, LossPhase, ReadOnlyRefusal, ServerCode, ServerDiagnostics, TimeoutPhase, TlsFailure, TransportError,
};
use tokio_postgres::error::{DbError, ErrorPosition};

/// tokio-postgres prints only the kind of an error, never its cause, so
/// the kind is told apart by these exact strings.
const AUTHENTICATION_KIND: &str = "authentication error";
const TLS_KIND: &str = "error performing TLS handshake";

/// query_canceled: a cancel request or a statement timeout took effect.
pub(crate) const QUERY_CANCELED: &str = "57014";

/// What a tokio-postgres error means to the app.
pub(crate) fn map_error(error: &tokio_postgres::Error) -> DriverError {
    if let Some(carried) = carried(error) {
        return carried;
    }
    if let Some(db) = error.as_db_error() {
        return map_db_error(db);
    }
    if let Some((failure, detail)) = tablepro_net::tls::classify(error) {
        return DriverError::Tls { failure, detail };
    }
    let kind = error.to_string();
    if kind == AUTHENTICATION_KIND {
        return DriverError::auth(Some(ServerDiagnostics::new(None, describe(error))));
    }
    if kind == TLS_KIND {
        return DriverError::Tls {
            failure: TlsFailure::Other,
            detail: describe(error),
        };
    }
    if error.is_closed() || io_source(error).is_some() {
        return DriverError::ConnectionLost {
            during: LossPhase::Statement,
        };
    }
    DriverError::Protocol(describe(error))
}

/// An error from opening a connection, where a TLS failure before the
/// handshake began means the server never agreed to TLS at all.
pub(crate) fn map_connect_error(
    error: &tokio_postgres::Error,
    tls_requested: bool,
    handshake_started: bool,
) -> DriverError {
    let mapped = map_error(error);
    match mapped {
        DriverError::Tls { detail, .. } if tls_requested && !handshake_started => DriverError::Tls {
            failure: TlsFailure::ServerRefusedTls,
            detail,
        },
        DriverError::ConnectionLost { .. } => DriverError::ConnectionLost {
            during: LossPhase::Connect,
        },
        other => other,
    }
}

/// The SQLSTATEs the app acts on. Everything else is the server's own
/// answer, passed through with its diagnostics.
pub(crate) fn map_db_error(db: &DbError) -> DriverError {
    map_diagnostics(diagnostics_of(db))
}

pub(crate) fn map_diagnostics(diagnostics: ServerDiagnostics) -> DriverError {
    match diagnostics.sqlstate().unwrap_or_default() {
        "28P01" | "28000" => DriverError::auth(Some(diagnostics)),
        "25006" => DriverError::ReadOnly(ReadOnlyRefusal::server(diagnostics)),
        "55P03" => DriverError::Timeout {
            phase: TimeoutPhase::LockWait,
            server_cancelled: true,
        },
        "53300" => DriverError::Busy,
        // The server ended the session: an administrator terminated the
        // backend, or the server is shutting down.
        "57P01" | "57P02" | "57P03" => DriverError::ConnectionLost {
            during: LossPhase::Statement,
        },
        _ => DriverError::reported(diagnostics),
    }
}

pub(crate) fn diagnostics_of(db: &DbError) -> ServerDiagnostics {
    ServerDiagnostics {
        code: Some(ServerCode::SqlState(db.code().code().to_owned())),
        severity: Some(db.severity().to_owned()),
        message: db.message().to_owned(),
        detail: db.detail().map(str::to_owned),
        hint: db.hint().map(str::to_owned),
        position: match db.position() {
            Some(ErrorPosition::Original(at)) => Some(*at),
            _ => None,
        },
        where_context: db.where_().map(str::to_owned),
        schema: db.schema().map(str::to_owned),
        table: db.table().map(str::to_owned),
        column: db.column().map(str::to_owned),
        constraint: db.constraint().map(str::to_owned),
    }
}

/// The SQLSTATE of a server error, wherever the error came from.
pub(crate) fn sqlstate(error: &DriverError) -> Option<&str> {
    match error {
        DriverError::Server(diagnostics) => diagnostics.sqlstate(),
        DriverError::Auth { diagnostics } => diagnostics.as_deref().and_then(ServerDiagnostics::sqlstate),
        DriverError::ReadOnly(ReadOnlyRefusal::ServerRejected(diagnostics)) => diagnostics.sqlstate(),
        DriverError::Timeout {
            phase: TimeoutPhase::Statement,
            server_cancelled: true,
        } => Some(QUERY_CANCELED),
        DriverError::Timeout {
            phase: TimeoutPhase::LockWait,
            ..
        } => Some("55P03"),
        _ => None,
    }
}

/// What a pool refusal means. A wait that runs out means every slot is
/// busy, which is the server having no room rather than a dead link.
pub(crate) fn map_pool_error(error: &PoolError) -> DriverError {
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
        PoolError::Backend(error) => map_error(error),
        PoolError::Closed => DriverError::ConnectionLost {
            during: LossPhase::Idle,
        },
        other => DriverError::Protocol(other.to_string()),
    }
}

/// A `DriverError` that crossed deadpool's `Connect` hook, which can only
/// return a tokio-postgres error. It travels as the `io::Error` that a
/// failed stream reported, so the source chain leads back to it.
fn carried(error: &tokio_postgres::Error) -> Option<DriverError> {
    io_source(error)?.get_ref()?.downcast_ref::<DriverError>().cloned()
}

fn io_source(error: &tokio_postgres::Error) -> Option<&io::Error> {
    error.source()?.downcast_ref::<io::Error>()
}

/// The kind and its cause, which tokio-postgres keeps apart.
fn describe(error: &tokio_postgres::Error) -> String {
    match error.source() {
        Some(source) => format!("{error}: {source}"),
        None => error.to_string(),
    }
}

/// A transport error, or the loss it caused on an open stream.
pub(crate) fn transport_error(error: TransportError) -> DriverError {
    DriverError::Transport(error)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn diagnostics(code: &str, message: &str) -> ServerDiagnostics {
        ServerDiagnostics::new(Some(ServerCode::SqlState(code.to_owned())), message)
    }

    #[test]
    fn sqlstate_table() {
        type Expected = fn(&DriverError) -> bool;
        let cases: [(&str, &str, Expected); 9] = [
            ("28P01", "password authentication failed", |e| {
                matches!(e, DriverError::Auth { .. })
            }),
            ("28000", "no pg_hba.conf entry", |e| {
                matches!(e, DriverError::Auth { .. })
            }),
            ("25006", "cannot execute INSERT in a read-only transaction", |e| {
                matches!(e, DriverError::ReadOnly(ReadOnlyRefusal::ServerRejected(_)))
            }),
            // Only the call that set the timeout can tell it from a
            // cancel, so here both stay the server's own answer.
            (
                "57014",
                "canceling statement due to statement timeout",
                |e| matches!(e, DriverError::Server(d) if d.sqlstate() == Some("57014")),
            ),
            (
                "57014",
                "canceling statement due to user request",
                |e| matches!(e, DriverError::Server(d) if d.sqlstate() == Some("57014")),
            ),
            ("55P03", "canceling statement due to lock timeout", |e| {
                matches!(
                    e,
                    DriverError::Timeout {
                        phase: TimeoutPhase::LockWait,
                        ..
                    }
                )
            }),
            ("53300", "sorry, too many clients already", |e| {
                matches!(e, DriverError::Busy)
            }),
            ("57P01", "terminating connection due to administrator command", |e| {
                matches!(e, DriverError::ConnectionLost { .. })
            }),
            (
                "42P01",
                "relation does not exist",
                |e| matches!(e, DriverError::Server(d) if d.sqlstate() == Some("42P01")),
            ),
        ];
        for (code, message, expected) in cases {
            let mapped = map_diagnostics(diagnostics(code, message));
            assert!(expected(&mapped), "{code} {message}: {mapped:?}");
        }
        assert_eq!(
            sqlstate(&DriverError::Timeout {
                phase: TimeoutPhase::Statement,
                server_cancelled: true,
            }),
            Some("57014")
        );
        assert_eq!(sqlstate(&DriverError::Busy), None);
    }

    #[test]
    fn a_pool_wait_that_runs_out_is_busy() {
        assert_eq!(
            map_pool_error(&PoolError::Timeout(TimeoutType::Wait)),
            DriverError::Busy
        );
        assert!(matches!(
            map_pool_error(&PoolError::Closed),
            DriverError::ConnectionLost { .. }
        ));
    }
}
