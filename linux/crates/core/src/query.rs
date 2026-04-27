use chrono::{DateTime, NaiveDate, NaiveDateTime, NaiveTime, Utc};
use rust_decimal::Decimal;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TableInfo {
    pub schema: Option<String>,
    pub name: String,
}

/// Secondary-index metadata for a table. `primary` is set on the
/// auto-PK index returned by the catalog query so the UI can render
/// it as read-only (the PK is owned by the column definition, not
/// by an editable index entry).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct IndexInfo {
    pub name: String,
    pub columns: Vec<String>,
    pub unique: bool,
    pub primary: bool,
}

/// Foreign-key constraint metadata. `on_delete` / `on_update` carry
/// the referential action as a normalised SQL keyword string
/// ("RESTRICT", "CASCADE", "SET NULL", "SET DEFAULT", "NO ACTION").
/// `None` means the driver returned a value we don't recognise — the
/// UI displays it as a dim-label "—" and the DDL builder omits the
/// clause so the database picks its default.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ForeignKeyInfo {
    pub name: String,
    pub columns: Vec<String>,
    pub ref_schema: Option<String>,
    pub ref_table: String,
    pub ref_columns: Vec<String>,
    pub on_delete: Option<String>,
    pub on_update: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ColumnInfo {
    pub name: String,
    pub data_type: String,
    pub nullable: bool,
    pub primary_key: bool,
    /// True for `SERIAL` / `BIGSERIAL` / `IDENTITY` (PG), `AUTO_INCREMENT`
    /// (MySQL), `INTEGER PRIMARY KEY` / `AUTOINCREMENT` (SQLite). Used by
    /// the inline-insert UX to skip these columns from the user-facing
    /// draft form (DB assigns the value on commit).
    #[serde(default)]
    pub is_auto_increment: bool,
    /// Server-side default expression as raw text (e.g. `now()`,
    /// `gen_random_uuid()`, `'pending'`). When the user leaves a cell
    /// empty in a draft row and the column has a default, omit the
    /// column from the INSERT so the server applies its default.
    #[serde(default)]
    pub default_value: Option<String>,
    /// True for `GENERATED ALWAYS AS ...` columns. Always read-only;
    /// excluded from INSERT and UPDATE.
    #[serde(default)]
    pub is_generated: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum Value {
    Null,
    Bool(bool),
    Int(i64),
    Float(f64),
    Text(String),
    Bytes(Vec<u8>),
    Date(NaiveDate),
    Time(NaiveTime),
    DateTime(NaiveDateTime),
    TimestampTz(DateTime<Utc>),
    Decimal(Decimal),
    Uuid(Uuid),
    Json(serde_json::Value),
}

/// Default upper bound on rows materialized by an arbitrary SQL `query` call.
/// Pagination via `fetch_rows` uses its caller-supplied `limit` and is not capped here.
pub const MAX_QUERY_ROWS: usize = 10_000;

#[derive(Debug, Clone)]
pub struct QueryResult {
    pub columns: Vec<ColumnInfo>,
    pub rows: Vec<Vec<Value>>,
    pub truncated: bool,
}

#[derive(Debug, Clone, Copy)]
pub struct ExecResult {
    pub rows_affected: u64,
}
