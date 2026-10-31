//! What a connection that runs user SQL only to read refuses beyond what
//! SQLite's read-only open does. A read-only connection can still attach
//! another file, and `VACUUM INTO` writes a copy of the database through
//! an attach of its own; a pragma such as `foreign_keys` or
//! `hard_heap_limit` changes the connection or the process, and SQLite
//! applies it while compiling, so `EXPLAIN PRAGMA` does too.

use std::ffi::{CStr, c_char, c_int, c_void};

use sqlx::sqlite::SqliteConnection as SqlxConnection;
use sqlx::{AssertSqlSafe, Executor as _, SqlSafeStr as _};
use tablepro_core::sql_syntax::sqlite_pragma_reports;
use tablepro_core::{BusyReason, DriverError, ReadOnlyRefusal};

use crate::errors::map_error;

/// Allow no attached database and check every statement prepared from
/// now on.
pub(crate) async fn install(connection: &mut SqlxConnection) -> Result<(), DriverError> {
    let mut handle = connection.lock_handle().await.map_err(map_error)?;
    let raw = handle.as_raw_handle().as_ptr();
    // SAFETY: `raw` comes from the locked handle, so the connection is
    // open and nothing runs on it meanwhile. The callback takes no user
    // data.
    let code = unsafe {
        libsqlite3_sys::sqlite3_limit(raw, libsqlite3_sys::SQLITE_LIMIT_ATTACHED, 0);
        libsqlite3_sys::sqlite3_set_authorizer(raw, Some(authorize), std::ptr::null_mut())
    };
    match code {
        libsqlite3_sys::SQLITE_OK => Ok(()),
        code => Err(DriverError::Protocol(format!(
            "SQLite refused the read guard with code {code}"
        ))),
    }
}

/// Refuse text SQLite reads as more than one statement: sqlx runs every
/// statement a text holds, and what judged it saw one.
///
/// sqlx compiles the whole text first, on its own worker and with the
/// call's busy handler, so a lock is waited out where a stop can end it,
/// the schema is loaded, and a refused pragma or a syntax error ends the
/// read here. The count then prepares on this thread with no busy
/// handler: with the schema loaded there is no lock to wait for, and a
/// wait here would hold up the task that delivers the stop. The caller
/// installs its busy handler again.
pub(crate) async fn refuse_more_than_one(connection: &mut SqlxConnection, sql: &str) -> Result<(), DriverError> {
    (&mut *connection)
        .prepare(AssertSqlSafe(sql.to_owned()).into_sql_str())
        .await
        .map_err(map_error)?;
    let mut handle = connection.lock_handle().await.map_err(map_error)?;
    let raw = handle.as_raw_handle().as_ptr();
    // SAFETY: `raw` is the locked, open connection.
    unsafe { libsqlite3_sys::sqlite3_busy_timeout(raw, 0) };
    let mut rest = sql.as_bytes();
    let mut statements = 0usize;
    while !rest.is_empty() {
        let length = c_int::try_from(rest.len())
            .map_err(|_| DriverError::Protocol("the statement is too long for SQLite".to_owned()))?;
        let mut statement = std::ptr::null_mut();
        let mut tail: *const c_char = std::ptr::null();
        // SAFETY: `raw` is the locked, open connection; `rest` outlives
        // the call and `length` is its length, so SQLite reads inside it
        // and points `tail` into it. A prepared statement is finalized
        // before the next prepare.
        let code = unsafe {
            let code = libsqlite3_sys::sqlite3_prepare_v2(raw, rest.as_ptr().cast(), length, &mut statement, &mut tail);
            if !statement.is_null() {
                libsqlite3_sys::sqlite3_finalize(statement);
            }
            code
        };
        match code {
            libsqlite3_sys::SQLITE_OK => {}
            libsqlite3_sys::SQLITE_BUSY | libsqlite3_sys::SQLITE_LOCKED => {
                return Err(DriverError::Busy(BusyReason::FileLocked));
            }
            // sqlx compiled the same text a moment ago, so only a schema
            // another connection changed in between gets here; the run
            // reports SQLite's own error.
            _ => return Ok(()),
        }
        if !statement.is_null() {
            statements += 1;
        }
        if statements > 1 {
            return Err(DriverError::ReadOnly(ReadOnlyRefusal::ClientGuard));
        }
        // SAFETY: SQLite sets `tail` to a point inside `rest` or to its end.
        let consumed = usize::try_from(unsafe { tail.offset_from(rest.as_ptr().cast()) }).unwrap_or(0);
        if consumed == 0 {
            break;
        }
        rest = rest.get(consumed..).unwrap_or_default();
    }
    Ok(())
}

/// SQLite's authorizer: no ATTACH, and a pragma only when it reports.
unsafe extern "C" fn authorize(
    _data: *mut c_void,
    action: c_int,
    first: *const c_char,
    _second: *const c_char,
    _database: *const c_char,
    _trigger: *const c_char,
) -> c_int {
    match action {
        libsqlite3_sys::SQLITE_ATTACH => libsqlite3_sys::SQLITE_DENY,
        libsqlite3_sys::SQLITE_PRAGMA if first.is_null() => libsqlite3_sys::SQLITE_DENY,
        libsqlite3_sys::SQLITE_PRAGMA => {
            // SAFETY: SQLite hands the pragma's name as a NUL-terminated
            // string that stays valid for the call.
            let name = unsafe { CStr::from_ptr(first) };
            match name.to_str().is_ok_and(sqlite_pragma_reports) {
                true => libsqlite3_sys::SQLITE_OK,
                false => libsqlite3_sys::SQLITE_DENY,
            }
        }
        _ => libsqlite3_sys::SQLITE_OK,
    }
}
