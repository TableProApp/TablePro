use sqlx::sqlite::SqliteConnection as SqlxConnection;
use tablepro_core::DriverError;

use crate::errors::map_error;

// SQLite parses every CREATE statement of a file when it reads the schema, and the catalog reads parse each again, so
// a crafted file's statement is capped far past any real table's, below SQLite's 1 GB default (sqlite.org/limits.html).
// A schema with a longer one does not open: SQLite reports it malformed.
pub(crate) const MAX_STATEMENT_BYTES: i32 = 10_000_000;

pub(crate) async fn install(connection: &mut SqlxConnection) -> Result<(), DriverError> {
    let mut handle = connection.lock_handle().await.map_err(map_error)?;
    let raw = handle.as_raw_handle();
    // SAFETY: `raw` comes from the locked handle, so the connection is open and nothing runs on it meanwhile.
    unsafe {
        libsqlite3_sys::sqlite3_limit(
            raw.as_ptr(),
            libsqlite3_sys::SQLITE_LIMIT_SQL_LENGTH,
            MAX_STATEMENT_BYTES,
        )
    };
    Ok(())
}
