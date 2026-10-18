//! SQLite result codes as the app's errors.
//!
//! SQLite reports an extended result code whose low byte is the primary
//! one, and the primary code is what these branches turn on.

use std::path::Path;

use sqlx::error::DatabaseError;
use sqlx::sqlite::SqliteError;
use tablepro_core::{DriverError, LossPhase, ReadOnlyRefusal, ServerCode, ServerDiagnostics};

pub(crate) const SQLITE_ERROR: i32 = 1;
pub(crate) const SQLITE_BUSY: i32 = 5;
pub(crate) const SQLITE_LOCKED: i32 = 6;
pub(crate) const SQLITE_READONLY: i32 = 8;
pub(crate) const SQLITE_INTERRUPT: i32 = 9;
pub(crate) const SQLITE_IOERR: i32 = 10;
pub(crate) const SQLITE_CANTOPEN: i32 = 14;
pub(crate) const SQLITE_CONSTRAINT: i32 = 19;
pub(crate) const SQLITE_NOTADB: i32 = 26;
pub(crate) const SQLITE_CONSTRAINT_FOREIGNKEY: i32 = 787;

/// An error from a statement on an open connection.
///
/// An interrupt is left as the server error it is: only the call that
/// raised the interrupt knows whether it meant a cancel or a deadline,
/// so `OwnedCalls` and the editor session turn it into one.
pub(crate) fn map_error(error: sqlx::Error) -> DriverError {
    match error {
        sqlx::Error::Database(database) => match database.try_downcast_ref::<SqliteError>() {
            Some(sqlite) => server_error(sqlite),
            None => DriverError::server(database.message().to_owned()),
        },
        sqlx::Error::Io(_) | sqlx::Error::WorkerCrashed => DriverError::ConnectionLost {
            during: LossPhase::Statement,
        },
        // The one workspace connection is held by a longer call, so the
        // file is busy rather than gone.
        sqlx::Error::PoolTimedOut => DriverError::Busy,
        sqlx::Error::PoolClosed => DriverError::ConnectionLost {
            during: LossPhase::Idle,
        },
        sqlx::Error::ColumnDecode { index, source } => DriverError::Decode {
            column: index,
            detail: source.to_string(),
        },
        other => DriverError::Protocol(other.to_string()),
    }
}

/// An error while opening `path`, where the file itself is usually the
/// answer.
pub(crate) fn map_open_error(error: sqlx::Error, path: &Path) -> DriverError {
    let primary = match &error {
        sqlx::Error::Database(database) => database.try_downcast_ref::<SqliteError>().map(primary_code),
        _ => None,
    };
    match primary {
        Some(SQLITE_CANTOPEN) => cannot_open(path),
        Some(SQLITE_NOTADB) => DriverError::NotADatabase {
            path: path.to_path_buf(),
        },
        _ => map_error(error),
    }
}

/// SQLite says only that it could not open the file. Whether the file
/// is there tells a moved database apart from one the user may not
/// read.
pub(crate) fn cannot_open(path: &Path) -> DriverError {
    match std::fs::symlink_metadata(path) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => DriverError::FileNotFound {
            path: path.to_path_buf(),
        },
        _ => DriverError::FileAccessDenied {
            path: path.to_path_buf(),
        },
    }
}

fn server_error(sqlite: &SqliteError) -> DriverError {
    let diagnostics = diagnostics_of(sqlite);
    match primary_code(sqlite) {
        SQLITE_BUSY | SQLITE_LOCKED => DriverError::Busy,
        SQLITE_READONLY => DriverError::ReadOnly(ReadOnlyRefusal::server(diagnostics)),
        _ => DriverError::reported(diagnostics),
    }
}

fn diagnostics_of(sqlite: &SqliteError) -> ServerDiagnostics {
    let extended = extended_code(sqlite);
    ServerDiagnostics::new(
        Some(ServerCode::Sqlite {
            primary: extended & 0xff,
            extended,
        }),
        sqlite.message().to_owned(),
    )
}

fn extended_code(sqlite: &SqliteError) -> i32 {
    sqlite
        .code()
        .and_then(|code| code.parse::<i32>().ok())
        .unwrap_or(SQLITE_ERROR)
}

fn primary_code(sqlite: &SqliteError) -> i32 {
    extended_code(sqlite) & 0xff
}

/// The primary SQLite code behind an error, where it is a server error
/// that kept its code.
pub(crate) fn primary_of(error: &DriverError) -> Option<i32> {
    match error {
        DriverError::Server(diagnostics) => match diagnostics.code {
            Some(ServerCode::Sqlite { primary, .. }) => Some(primary),
            _ => None,
        },
        _ => None,
    }
}

/// Whether the error is SQLite reporting that a progress handler
/// stopped the statement.
pub(crate) fn is_interrupt(error: &DriverError) -> bool {
    primary_of(error) == Some(SQLITE_INTERRUPT)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cantopen_distinguishes_missing_and_denied() {
        let directory = tempfile::tempdir().unwrap();
        let missing = directory.path().join("moved.sqlite3");
        let present = directory.path().join("locked.sqlite3");
        std::fs::write(&present, b"").unwrap();

        assert_eq!(cannot_open(&missing), DriverError::FileNotFound { path: missing });
        assert_eq!(cannot_open(&present), DriverError::FileAccessDenied { path: present });
    }

    #[test]
    fn an_interrupt_is_recognised_by_its_primary_code() {
        let interrupted = DriverError::reported(ServerDiagnostics::new(
            Some(ServerCode::Sqlite {
                primary: SQLITE_INTERRUPT,
                extended: SQLITE_INTERRUPT,
            }),
            "interrupted",
        ));

        assert!(is_interrupt(&interrupted));
        assert!(!is_interrupt(&DriverError::Cancelled));
        assert_eq!(primary_of(&DriverError::server("no code")), None);
    }
}
