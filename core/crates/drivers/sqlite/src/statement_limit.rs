use sqlx::Row;
use sqlx::sqlite::{SqliteConnection as SqlxConnection, SqliteRow};
use tablepro_core::{CatalogBudget, DriverError};

use crate::errors::map_error;

// SQLite parses every CREATE statement of a file when it reads the schema, and the catalog reads parse each again, so
// a crafted file's statement is capped far past any real table's, below SQLite's 1 GB default (sqlite.org/limits.html).
// A schema with a longer one does not open: SQLite reports it malformed.
pub(crate) const MAX_STATEMENT_BYTES: i32 = 10_000_000;

// SQLite parses a stored CREATE text only to its statement's end and ignores the rest, which a crafted file can make as
// long as any value, so every read that parses one takes it only up to the cap: `capped` selects it as `sql`, NULL past
// the cap, beside `sql_too_long`, and `stored_sql` reads the two.
pub(crate) fn capped(column: &str) -> String {
    let bytes = byte_length(column);
    format!(
        "CASE WHEN {bytes} <= {MAX_STATEMENT_BYTES} THEN {column} END AS sql, \
         {bytes} > {MAX_STATEMENT_BYTES} AS sql_too_long"
    )
}

// From SQLite 3.43, octet_length of a column takes the length from the record without reading the value. An older
// library, which a Linux distribution can ship, reads it whole through the CAST.
pub(crate) fn byte_length(column: &str) -> String {
    // SAFETY: the call takes no arguments and returns a constant of the linked library.
    match unsafe { libsqlite3_sys::sqlite3_libversion_number() } >= 3_043_000 {
        true => format!("octet_length({column})"),
        false => format!("length(CAST({column} AS BLOB))"),
    }
}

pub(crate) fn stored_sql(row: &SqliteRow) -> Result<Option<String>, DriverError> {
    if row.try_get::<Option<i64>, _>("sql_too_long").map_err(map_error)? == Some(1) {
        return Err(DriverError::CatalogTooLarge {
            limit_bytes: u64::try_from(MAX_STATEMENT_BYTES).unwrap_or(u64::MAX),
        });
    }
    row.try_get("sql").map_err(map_error)
}

// sqlparser holds up to about 420 bytes for each byte it parses, measured on an IN list of one-digit numbers, so a parse
// of stored text has to fit beside what the read holds.
const PARSED_BYTES_PER_BYTE: usize = 512;

pub(crate) fn parse_fits(budget: &CatalogBudget, text: &str) -> Result<(), DriverError> {
    budget.fits(text.len().saturating_mul(PARSED_BYTES_PER_BYTE))
}

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
