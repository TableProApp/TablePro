//! Whether a connection is inside a transaction.
//!
//! sqlx tracks only the transactions it began itself and keeps its own
//! flag crate-private, so a BEGIN the user typed in the editor is
//! invisible to it. SQLite's own answer is `sqlite3_get_autocommit`.
//! This is the crate's one unsafe call, an interim until sqlx exposes
//! the state on `LockedSqliteHandle`.

use sqlx::sqlite::LockedSqliteHandle;

/// True when no transaction is open.
pub(crate) fn is_autocommit(handle: &mut LockedSqliteHandle<'_>) -> bool {
    let raw = handle.as_raw_handle();
    // SAFETY: `raw` comes from the locked handle, and the lock guard is
    // held for the whole call, so the connection is open and sqlx's
    // worker thread makes no call on it meanwhile. The function only
    // reads a flag of the connection.
    unsafe { libsqlite3_sys::sqlite3_get_autocommit(raw.as_ptr()) != 0 }
}
