use std::ptr::NonNull;

use libsqlite3_sys::{sqlite3, sqlite3_interrupt};
use sqlx::Sqlite;
use sqlx::pool::PoolConnection;
use tablepro_core::DriverError;

/// A pointer to the open SQLite database, used only to call
/// `sqlite3_interrupt`. SQLite documents that call as safe from a thread
/// other than the one running the statement, which is what makes a Stop
/// possible at all: sqlx runs each connection's statements on its own
/// worker thread, so while a statement runs nothing else can borrow the
/// connection.
///
/// The handle never leaves the operation that made it, and that
/// operation holds the `PoolConnection` throughout, so the database
/// cannot be closed while a handle to it exists.
pub(crate) struct InterruptHandle {
    database: NonNull<sqlite3>,
}

unsafe impl Send for InterruptHandle {}
unsafe impl Sync for InterruptHandle {}

impl InterruptHandle {
    pub(crate) async fn of(connection: &mut PoolConnection<Sqlite>) -> Result<Self, DriverError> {
        let mut handle = connection
            .lock_handle()
            .await
            .map_err(|error| DriverError::Internal(format!("sqlite connection is unusable: {error}")))?;
        Ok(Self {
            database: handle.as_raw_handle(),
        })
    }

    /// Asks SQLite to abort the statement running on this database. The
    /// statement fails with `SQLITE_INTERRUPT`. A statement waiting on a
    /// database lock is aborted too, which a progress handler cannot do.
    pub(crate) fn interrupt(&self) {
        unsafe {
            sqlite3_interrupt(self.database.as_ptr());
        }
    }
}
