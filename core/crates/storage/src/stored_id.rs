use sqlx::Row;
use sqlx::sqlite::SqliteRow;
use uuid::Uuid;

use crate::error::StorageError;

// The store keeps a record id or a reference to one as lower-case UUID text (core ADR 0052).
pub(crate) fn uuid_column(row: &SqliteRow, column: &str) -> Result<Uuid, StorageError> {
    let text: String = row.try_get(column)?;
    parsed(column, &text)
}

pub(crate) fn optional_uuid_column(row: &SqliteRow, column: &str) -> Result<Option<Uuid>, StorageError> {
    let text: Option<String> = row.try_get(column)?;
    text.map(|text| parsed(column, &text)).transpose()
}

fn parsed(column: &str, text: &str) -> Result<Uuid, StorageError> {
    Uuid::parse_str(text).map_err(|_| StorageError::Schema(format!("{column} is not a UUID")))
}
