//! What each tool takes. Unknown fields are refused rather than
//! ignored, so a misspelt argument fails instead of being dropped.

use schemars::JsonSchema;
use serde::Deserialize;

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
pub struct SchemaArgs {
    #[schemars(description = "A connection id from list_connections.")]
    pub connection_id: String,
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
    #[schemars(description = "Rows to keep per result set, 1 to 1000. Defaults to 100.")]
    pub max_rows: Option<u32>,
    #[schemars(description = "Seconds before the statement is stopped, 1 to 300. Defaults to 30.")]
    pub timeout_seconds: Option<u32>,
}

#[derive(Debug, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct FilterArg {
    #[schemars(description = "The column name, unquoted.")]
    pub column: String,
    pub operator: FilterOperator,
    #[schemars(description = "The value to compare with, as text. Not used by is_null, is_not_null, in, not_in and between.")]
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
