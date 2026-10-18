use std::error::Error as StdError;
use std::io;

use deadpool::managed::{PoolError, TimeoutType};
use sqlx::mysql::MySqlDatabaseError;
use tablepro_core::{
    DriverError, LossPhase, NetworkEndpoint, ReadOnlyRefusal, ServerCode, ServerDiagnostics, TimeoutPhase, TlsFailure,
    TransportError,
};

use crate::flavour::MySqlFlavour;

/// ER_ACCESS_DENIED_ERROR.
pub(crate) const ACCESS_DENIED: u16 = 1045;
/// ER_CON_COUNT_ERROR.
pub(crate) const TOO_MANY_CONNECTIONS: u16 = 1040;
/// ER_LOCK_WAIT_TIMEOUT.
pub(crate) const LOCK_WAIT_TIMEOUT: u16 = 1205;
/// ER_QUERY_INTERRUPTED, what KILL QUERY makes the statement fail with.
pub(crate) const QUERY_INTERRUPTED: u16 = 1317;
/// ER_CANT_EXECUTE_IN_READ_ONLY_TRANSACTION.
pub(crate) const READ_ONLY_TRANSACTION: u16 = 1792;
/// ER_WARNING_NOT_COMPLETE_ROLLBACK: a table that cannot roll back was
/// written inside the transaction.
pub(crate) const INCOMPLETE_ROLLBACK: u16 = 1196;
/// ER_UNSUPPORTED_PS: the server parsed the statement and cannot run it
/// as a prepared statement.
pub(crate) const UNSUPPORTED_PS: u16 = 1295;
/// MySQL's ER_QUERY_TIMEOUT for `max_execution_time`.
pub(crate) const MYSQL_QUERY_TIMEOUT: u16 = 3024;
/// MariaDB's ER_STATEMENT_TIMEOUT for `max_statement_time`.
pub(crate) const MARIADB_STATEMENT_TIMEOUT: u16 = 1969;
/// ER_SECURE_TRANSPORT_REQUIRED under `require_secure_transport`, which
/// MariaDB took over with MySQL's number.
pub(crate) const SECURE_TRANSPORT_REQUIRED: u16 = 3159;
/// ER_SERVER_SHUTDOWN.
const SERVER_SHUTDOWN: u16 = 1053;
/// MariaDB's ER_CONNECTION_KILLED.
const MARIADB_CONNECTION_KILLED: u16 = 1927;
/// MySQL's ER_CLIENT_INTERACTION_TIMEOUT, sent before the server closes
/// an idle session.
const MYSQL_CLIENT_INTERACTION_TIMEOUT: u16 = 4031;

/// What a sqlx error on an open connection means to the app.
/// No reply came, so what was sent may or may not have run. A timeout
/// the server enforced is its reply.
pub(crate) fn reply_lost(error: &DriverError) -> bool {
    matches!(
        error,
        DriverError::ConnectionLost { .. }
            | DriverError::Transport(_)
            | DriverError::Timeout {
                server_cancelled: false,
                ..
            }
    )
}

pub(crate) fn map_error(error: &sqlx::Error, flavour: MySqlFlavour) -> DriverError {
    map_with(error, Some(flavour))
}

/// What a failed connect means. The flavour is not known before the
/// login, so the numbers either server uses are both read.
pub(crate) fn map_connect_error(error: &sqlx::Error, endpoint: &NetworkEndpoint) -> DriverError {
    match error {
        sqlx::Error::Io(io) => match tablepro_net::tls::classify(io) {
            Some((failure, detail)) => DriverError::Tls { failure, detail },
            None => connect_io_error(io, endpoint),
        },
        other => match map_with(other, None) {
            DriverError::ConnectionLost { .. } => DriverError::ConnectionLost {
                during: LossPhase::Connect,
            },
            mapped => mapped,
        },
    }
}

fn map_with(error: &sqlx::Error, flavour: Option<MySqlFlavour>) -> DriverError {
    match error {
        sqlx::Error::Database(database) => match database.try_downcast_ref::<MySqlDatabaseError>() {
            Some(mysql) => classify_number(diagnostics_of(mysql), flavour),
            None => DriverError::server(database.message().to_owned()),
        },
        // A TLS failure after the handshake reached rustls surfaces as an
        // I/O error carrying the rustls error.
        sqlx::Error::Io(io) => match tablepro_net::tls::classify(io) {
            Some((failure, detail)) => DriverError::Tls { failure, detail },
            None => DriverError::ConnectionLost {
                during: LossPhase::Statement,
            },
        },
        sqlx::Error::Tls(tls) => tls_error(tls.as_ref()),
        sqlx::Error::PoolTimedOut => DriverError::Busy,
        sqlx::Error::PoolClosed | sqlx::Error::WorkerCrashed => DriverError::ConnectionLost {
            during: LossPhase::Idle,
        },
        sqlx::Error::ColumnDecode { index, source } => DriverError::Decode {
            column: index.clone(),
            detail: source.to_string(),
        },
        other => DriverError::Protocol(other.to_string()),
    }
}

/// A TLS error with no rustls error behind it is sqlx's own refusal,
/// which it raises when the server does not offer TLS at all.
fn tls_error(error: &(dyn StdError + 'static)) -> DriverError {
    match tablepro_net::tls::classify(error) {
        Some((failure, detail)) => DriverError::Tls { failure, detail },
        None => DriverError::Tls {
            failure: TlsFailure::ServerRefusedTls,
            detail: error.to_string(),
        },
    }
}

/// An I/O error before the login finished: one the route itself raised
/// is a transport failure, one after the server answered is a lost
/// connection.
fn connect_io_error(io: &io::Error, endpoint: &NetworkEndpoint) -> DriverError {
    match io.kind() {
        io::ErrorKind::ConnectionRefused => DriverError::Transport(TransportError::Refused {
            endpoint: endpoint.clone(),
        }),
        io::ErrorKind::TimedOut => DriverError::Transport(TransportError::Timeout {
            phase: TimeoutPhase::Connect,
        }),
        io::ErrorKind::UnexpectedEof | io::ErrorKind::ConnectionReset | io::ErrorKind::BrokenPipe => {
            DriverError::ConnectionLost {
                during: LossPhase::Connect,
            }
        }
        _ => DriverError::Transport(TransportError::Unreachable {
            endpoint: endpoint.clone(),
            detail: io.to_string(),
        }),
    }
}

pub(crate) fn diagnostics_of(mysql: &MySqlDatabaseError) -> ServerDiagnostics {
    ServerDiagnostics::new(
        Some(ServerCode::MySql {
            number: mysql.number(),
            sqlstate: mysql.code().map(str::to_owned),
        }),
        mysql.message().to_owned(),
    )
}

/// The error numbers the app acts on. `None` reads both servers' numbers,
/// for an error that came before the server said which it is.
pub(crate) fn classify_number(diagnostics: ServerDiagnostics, flavour: Option<MySqlFlavour>) -> DriverError {
    let number = match &diagnostics.code {
        Some(ServerCode::MySql { number, .. }) => *number,
        _ => return DriverError::reported(diagnostics),
    };
    let mysql = flavour != Some(MySqlFlavour::MariaDb);
    let mariadb = flavour != Some(MySqlFlavour::MySql);
    match number {
        ACCESS_DENIED => DriverError::auth(Some(diagnostics)),
        READ_ONLY_TRANSACTION => DriverError::ReadOnly(ReadOnlyRefusal::server(diagnostics)),
        QUERY_INTERRUPTED => DriverError::Cancelled,
        LOCK_WAIT_TIMEOUT => DriverError::Timeout {
            phase: TimeoutPhase::LockWait,
            server_cancelled: true,
        },
        TOO_MANY_CONNECTIONS => DriverError::Busy,
        MYSQL_QUERY_TIMEOUT if mysql => statement_timeout(),
        MARIADB_STATEMENT_TIMEOUT if mariadb => statement_timeout(),
        SECURE_TRANSPORT_REQUIRED => requires_tls(diagnostics),
        SERVER_SHUTDOWN => DriverError::ConnectionLost {
            during: LossPhase::Statement,
        },
        MARIADB_CONNECTION_KILLED if mariadb => DriverError::ConnectionLost {
            during: LossPhase::Statement,
        },
        MYSQL_CLIENT_INTERACTION_TIMEOUT if mysql => DriverError::ConnectionLost {
            during: LossPhase::Idle,
        },
        _ => DriverError::reported(diagnostics),
    }
}

fn statement_timeout() -> DriverError {
    DriverError::Timeout {
        phase: TimeoutPhase::Statement,
        server_cancelled: true,
    }
}

fn requires_tls(diagnostics: ServerDiagnostics) -> DriverError {
    DriverError::Tls {
        failure: TlsFailure::ServerRequiresTls,
        detail: diagnostics.to_string(),
    }
}

/// The server's error number, where the error is one the server sent.
pub(crate) fn server_number(error: &DriverError) -> Option<u16> {
    let diagnostics = match error {
        DriverError::Server(diagnostics) => diagnostics.as_ref(),
        DriverError::Auth { diagnostics } => diagnostics.as_deref()?,
        DriverError::ReadOnly(ReadOnlyRefusal::ServerRejected(diagnostics)) => diagnostics.as_ref(),
        _ => return None,
    };
    match diagnostics.code {
        Some(ServerCode::MySql { number, .. }) => Some(number),
        _ => None,
    }
}

/// A pool refusal. A wait that runs out means every slot is busy, which
/// is the server having no room rather than a dead link.
pub(crate) fn map_pool_error(error: &PoolError<DriverError>) -> DriverError {
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
        PoolError::Backend(error) => error.clone(),
        PoolError::Closed => DriverError::ConnectionLost {
            during: LossPhase::Idle,
        },
        other => DriverError::Protocol(other.to_string()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn numbered(number: u16) -> ServerDiagnostics {
        ServerDiagnostics::new(
            Some(ServerCode::MySql {
                number,
                sqlstate: Some("HY000".to_owned()),
            }),
            "message",
        )
    }

    fn is_statement_timeout(error: &DriverError) -> bool {
        matches!(
            error,
            DriverError::Timeout {
                phase: TimeoutPhase::Statement,
                server_cancelled: true
            }
        )
    }

    #[test]
    fn code_table_per_flavour() {
        for flavour in [Some(MySqlFlavour::MySql), Some(MySqlFlavour::MariaDb), None] {
            let classify = |number| classify_number(numbered(number), flavour);
            assert!(matches!(classify(ACCESS_DENIED), DriverError::Auth { .. }));
            assert!(matches!(
                classify(READ_ONLY_TRANSACTION),
                DriverError::ReadOnly(ReadOnlyRefusal::ServerRejected(_))
            ));
            assert_eq!(classify(QUERY_INTERRUPTED), DriverError::Cancelled);
            assert!(matches!(
                classify(LOCK_WAIT_TIMEOUT),
                DriverError::Timeout {
                    phase: TimeoutPhase::LockWait,
                    ..
                }
            ));
            assert_eq!(classify(TOO_MANY_CONNECTIONS), DriverError::Busy);
            assert!(matches!(classify(1146), DriverError::Server(_)), "{flavour:?}");
        }

        let mysql = |number| classify_number(numbered(number), Some(MySqlFlavour::MySql));
        let mariadb = |number| classify_number(numbered(number), Some(MySqlFlavour::MariaDb));
        assert!(is_statement_timeout(&mysql(MYSQL_QUERY_TIMEOUT)));
        assert!(!is_statement_timeout(&mysql(MARIADB_STATEMENT_TIMEOUT)));
        assert!(is_statement_timeout(&mariadb(MARIADB_STATEMENT_TIMEOUT)));
        assert!(!is_statement_timeout(&mariadb(MYSQL_QUERY_TIMEOUT)));
        for classify in [mysql, mariadb] {
            assert!(matches!(
                classify(SECURE_TRANSPORT_REQUIRED),
                DriverError::Tls {
                    failure: TlsFailure::ServerRequiresTls,
                    ..
                }
            ));
        }
        let unknown = |number| classify_number(numbered(number), None);
        assert!(is_statement_timeout(&unknown(MYSQL_QUERY_TIMEOUT)));
        assert!(is_statement_timeout(&unknown(MARIADB_STATEMENT_TIMEOUT)));
    }

    #[test]
    fn an_io_failure_on_an_open_connection_is_a_lost_connection() {
        let error = sqlx::Error::Io(io::Error::from(io::ErrorKind::BrokenPipe));

        assert_eq!(
            map_error(&error, MySqlFlavour::MySql),
            DriverError::ConnectionLost {
                during: LossPhase::Statement
            }
        );
    }

    #[test]
    fn a_refused_connect_names_the_endpoint_it_tried() {
        let endpoint = NetworkEndpoint::new("db.internal", 3306).expect("an endpoint");
        let error = sqlx::Error::Io(io::Error::from(io::ErrorKind::ConnectionRefused));

        assert_eq!(
            map_connect_error(&error, &endpoint),
            DriverError::Transport(TransportError::Refused { endpoint })
        );
    }

    #[test]
    fn a_tls_refusal_without_a_rustls_error_is_the_server_refusing_tls() {
        let error = sqlx::Error::Tls("server does not support TLS".into());

        assert!(matches!(
            map_error(&error, MySqlFlavour::MariaDb),
            DriverError::Tls {
                failure: TlsFailure::ServerRefusedTls,
                ..
            }
        ));
    }

    #[test]
    fn the_server_number_survives_classification() {
        let error = classify_number(numbered(1146), Some(MySqlFlavour::MySql));

        assert_eq!(server_number(&error), Some(1146));
        assert_eq!(server_number(&DriverError::Cancelled), None);
    }
}
