//! DuckDB's errors as the app's.
//!
//! DuckDB numbers nothing: every message starts with the kind of error,
//! as in "Constraint Error: ...", and the kind is what these branches
//! turn on. The C API's own code is always the same failure flag.

use std::path::Path;

use tablepro_core::{BusyReason, DriverError, LossPhase, ReadOnlyRefusal, ServerCode, ServerDiagnostics};

const INTERRUPT: &str = "INTERRUPT";

/// A message split into its kind and the rest, where it has a kind.
fn split_kind(message: &str) -> (Option<&str>, &str) {
    match message.split_once(" Error: ") {
        Some((kind, rest)) if !kind.is_empty() && kind.len() <= 40 && !kind.contains('\n') => (Some(kind), rest),
        _ => (None, message),
    }
}

/// An error from a statement, or from DuckDB around one.
pub(crate) fn map_error(error: duckdb::Error) -> DriverError {
    match error {
        duckdb::Error::DuckDBFailure(_, Some(message)) => from_message(&message),
        duckdb::Error::DuckDBFailure(failure, None) => DriverError::server(failure.to_string()),
        duckdb::Error::FromSqlConversionFailure(index, kind, detail) => DriverError::Decode {
            column: index.to_string(),
            detail: format!("{kind}: {detail}"),
        },
        duckdb::Error::Utf8Error(detail) => DriverError::Decode {
            column: String::new(),
            detail: detail.to_string(),
        },
        duckdb::Error::NulError(_) => DriverError::server("the SQL holds a NUL character"),
        other => DriverError::Protocol(other.to_string()),
    }
}

/// What DuckDB said, classified by its kind.
pub(crate) fn from_message(message: &str) -> DriverError {
    let (kind, rest) = split_kind(message);
    let diagnostics = ServerDiagnostics::new(
        kind.map(|kind| ServerCode::DuckDb {
            error_type: kind.to_owned(),
        }),
        rest,
    );
    match kind {
        Some("FATAL") => DriverError::ConnectionLost {
            during: LossPhase::Statement,
        },
        Some("Invalid Input") if rest.contains("read-only mode") => {
            DriverError::ReadOnly(ReadOnlyRefusal::server(diagnostics))
        }
        Some("TransactionContext") if rest.contains("read-only mode") => {
            DriverError::ReadOnly(ReadOnlyRefusal::server(diagnostics))
        }
        // A database that hit a fatal error refuses everything after it.
        _ if rest.contains("database has been invalidated") => DriverError::ConnectionLost {
            during: LossPhase::Statement,
        },
        _ => DriverError::reported(diagnostics),
    }
}

/// An error while opening `path`, where the file itself is usually the
/// answer.
pub(crate) fn map_open_error(error: duckdb::Error, path: &Path) -> DriverError {
    let duckdb::Error::DuckDBFailure(_, Some(message)) = &error else {
        return map_error(error);
    };
    let (kind, rest) = split_kind(message);
    match kind {
        Some("IO") if rest.contains("Could not set lock on file") => DriverError::Busy(BusyReason::FileLocked),
        Some("IO") if rest.contains("not a valid DuckDB database file") => DriverError::NotADatabase {
            path: path.to_path_buf(),
        },
        Some("IO") if rest.contains("Permission denied") => DriverError::FileAccessDenied {
            path: path.to_path_buf(),
        },
        _ => map_error(error),
    }
}

/// Whether the error is DuckDB stopping a statement it was told to
/// interrupt.
pub(crate) fn is_interrupt(error: &DriverError) -> bool {
    match error {
        DriverError::Server(diagnostics) => matches!(
            &diagnostics.code,
            Some(ServerCode::DuckDb { error_type }) if error_type == INTERRUPT
        ),
        DriverError::RolledBack { source, .. } => is_interrupt(source),
        _ => false,
    }
}

/// The error a stopped statement ends with, for a stop that came before
/// the statement was sent.
pub(crate) fn interrupted() -> DriverError {
    from_message("INTERRUPT Error: Interrupted!")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_message_keeps_its_kind_as_the_code() {
        let error = from_message("Constraint Error: PRIMARY KEY or UNIQUE constraint violation: duplicate key \"1\"");

        let DriverError::Server(diagnostics) = error else {
            panic!("not a server error: {error:?}");
        };
        assert_eq!(
            diagnostics.code,
            Some(ServerCode::DuckDb {
                error_type: "Constraint".to_owned()
            })
        );
        assert_eq!(
            diagnostics.message,
            "PRIMARY KEY or UNIQUE constraint violation: duplicate key \"1\""
        );
    }

    #[test]
    fn a_write_on_a_read_only_database_is_the_servers_refusal() {
        let attached = from_message(
            "Invalid Input Error: Cannot execute statement of type \"INSERT\" on database \"ro\" which is attached in read-only mode!",
        );
        let transaction = from_message(
            "TransactionContext Error: Cannot write to database \"ro\" - transaction is launched in read-only mode",
        );

        assert!(matches!(
            attached,
            DriverError::ReadOnly(ReadOnlyRefusal::ServerRejected(_))
        ));
        assert!(matches!(
            transaction,
            DriverError::ReadOnly(ReadOnlyRefusal::ServerRejected(_))
        ));
    }

    #[test]
    fn an_interrupt_is_told_apart_from_other_errors() {
        assert!(is_interrupt(&interrupted()));
        assert!(is_interrupt(&DriverError::RolledBack {
            statement_index: 0,
            source: Box::new(interrupted()),
        }));
        assert!(!is_interrupt(&from_message(
            "Parser Error: syntax error at end of input"
        )));
        assert!(!is_interrupt(&DriverError::Cancelled));
    }

    #[test]
    fn a_message_without_a_kind_is_kept_whole() {
        let DriverError::Server(diagnostics) = from_message("something odd") else {
            panic!("not a server error");
        };
        assert_eq!(diagnostics.code, None);
        assert_eq!(diagnostics.message, "something odd");
    }

    #[test]
    fn opening_a_file_names_what_is_wrong_with_it() {
        let path = Path::new("/srv/data.duckdb");
        let failure =
            |message: &str| duckdb::Error::DuckDBFailure(duckdb::ffi::Error::new(1), Some(message.to_owned()));

        assert_eq!(
            map_open_error(
                failure("IO Error: Could not set lock on file \"/srv/data.duckdb\": Conflicting lock is held"),
                path
            ),
            DriverError::Busy(BusyReason::FileLocked)
        );
        assert_eq!(
            map_open_error(
                failure("IO Error: The file \"/srv/data.duckdb\" exists, but it is not a valid DuckDB database file!"),
                path
            ),
            DriverError::NotADatabase {
                path: path.to_path_buf()
            }
        );
        assert!(matches!(
            map_open_error(failure("FATAL Error: something broke"), path),
            DriverError::ConnectionLost { .. }
        ));
    }
}
