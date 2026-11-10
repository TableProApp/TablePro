//! What each tool takes. Unknown fields are refused rather than
//! ignored, so a misspelt argument fails instead of being dropped.

#![expect(
    clippy::disallowed_types,
    reason = "the JsonSchema derive builds each schema in a serde_json::Map; a schema's key order means nothing"
)]

use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

const DATABASE: &str = "Another of the connection's databases, one TablePro already has open beside the connection \
(Open Database… in its window). Omit it for the connection's own database.";

#[derive(Debug, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct NoArgs {}

#[derive(Debug, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ConnectionArgs {
    #[schemars(description = "A connection id from list_connections.")]
    pub connection_id: String,
}

#[derive(Debug, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct DatabaseArgs {
    #[schemars(description = "A connection id from list_connections.")]
    pub connection_id: String,
    #[schemars(description = DATABASE)]
    pub database: Option<String>,
}

#[derive(Debug, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct SchemaArgs {
    #[schemars(description = "A connection id from list_connections.")]
    pub connection_id: String,
    #[schemars(description = DATABASE)]
    pub database: Option<String>,
    #[schemars(description = "The schema to list. Omit it for the connection's default schema.")]
    pub schema: Option<String>,
}

#[derive(Debug, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct TableArgs {
    #[schemars(description = "A connection id from list_connections.")]
    pub connection_id: String,
    #[schemars(description = "The table or view name, unquoted.")]
    pub table: String,
    #[schemars(description = DATABASE)]
    pub database: Option<String>,
    #[schemars(description = "The table's schema. Omit it for the connection's default schema.")]
    pub schema: Option<String>,
}

#[derive(Debug, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct BrowseArgs {
    #[schemars(description = "A connection id from list_connections.")]
    pub connection_id: String,
    #[schemars(description = "The table or view name, unquoted.")]
    pub table: String,
    #[schemars(description = "The table's schema. Omit it for the connection's default schema.")]
    pub schema: Option<String>,
    #[serde(default)]
    #[schemars(description = "Conditions on columns, joined by logic.")]
    pub filters: Vec<FilterArg>,
    #[schemars(description = "How the filters combine. Defaults to and.")]
    pub logic: Option<Logic>,
    #[serde(default)]
    #[schemars(description = "Columns to sort by, in order.")]
    pub sort: Vec<SortArg>,
    #[schemars(description = "Rows to return, 1 to 1000. Defaults to 100.")]
    pub limit: Option<u32>,
}

#[derive(Debug, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct CountArgs {
    #[schemars(description = "A connection id from list_connections.")]
    pub connection_id: String,
    #[schemars(description = "The table or view name, unquoted.")]
    pub table: String,
    #[schemars(description = "The table's schema. Omit it for the connection's default schema.")]
    pub schema: Option<String>,
    #[serde(default)]
    #[schemars(description = "Conditions on columns, joined by logic.")]
    pub filters: Vec<FilterArg>,
    #[schemars(description = "How the filters combine. Defaults to and.")]
    pub logic: Option<Logic>,
}

#[derive(Debug, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct QueryArgs {
    #[schemars(description = "A connection id from list_connections.")]
    pub connection_id: String,
    #[schemars(
        description = "One SQL statement, or one batch on SQL Server, in the connection's own dialect. 100 KB at most."
    )]
    pub query: String,
    #[schemars(description = DATABASE)]
    pub database: Option<String>,
    #[serde(default)]
    #[schemars(
        description = "Refuse the statement unless it only reads, whatever the connection's External Clients level. Defaults to false."
    )]
    pub read_only: bool,
    #[schemars(description = "Rows to keep per result set, 1 to 1000. Defaults to 100.")]
    pub max_rows: Option<u32>,
    #[schemars(description = "Seconds before the statement is stopped, 1 to 300. Defaults to 30.")]
    pub timeout_seconds: Option<u32>,
}

#[derive(Debug, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ExportArgs {
    #[schemars(description = "A connection id from list_connections.")]
    pub connection_id: String,
    #[schemars(
        description = "csv: a header row, then one line per row. json: an array of objects. sql: one INSERT per row, in the connection's own dialect."
    )]
    pub format: ExportFormat,
    #[schemars(description = "The tables or views to export, unquoted, 1 to 20.")]
    pub tables: Vec<String>,
    #[schemars(description = DATABASE)]
    pub database: Option<String>,
    #[schemars(description = "The tables' schema. Omit it for the connection's default schema.")]
    pub schema: Option<String>,
    #[schemars(description = "Rows to export per table, 1 to 1000. Defaults to 100.")]
    pub max_rows: Option<u32>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum ExportFormat {
    Csv,
    Json,
    Sql,
}

#[derive(Debug, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct FilterArg {
    #[schemars(description = "The column name, unquoted.")]
    pub column: String,
    pub operator: FilterOperator,
    #[schemars(
        description = "The value to compare with, as text. Not used by is_null, is_not_null, in, not_in and between."
    )]
    pub value: Option<String>,
    #[schemars(description = "The list for in and not_in, or the low and high bounds for between.")]
    pub values: Option<Vec<String>>,
}

/// The filter strip's operators. `like` and `not_like` take the
/// pattern as written; `contains`, `starts_with` and `ends_with` match
/// the text as typed.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum FilterOperator {
    Eq,
    NotEq,
    Lt,
    LtEq,
    Gt,
    GtEq,
    Contains,
    StartsWith,
    EndsWith,
    Like,
    NotLike,
    Ilike,
    IsNull,
    IsNotNull,
    In,
    NotIn,
    Between,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum Logic {
    And,
    Or,
}

#[derive(Debug, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct SortArg {
    #[schemars(description = "The column name, unquoted.")]
    pub column: String,
    #[schemars(description = "Defaults to ascending.")]
    pub direction: Option<Direction>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum Direction {
    Ascending,
    Descending,
}
