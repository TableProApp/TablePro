use chrono::{DateTime, NaiveDate, NaiveDateTime, NaiveTime, Utc};
use rust_decimal::Decimal;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TableInfo {
    pub schema: Option<String>,
    pub name: String,
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
