use serde::{Deserialize, Serialize};

use super::FilterOp;

/// One condition in the filter strip, as the user typed it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct FilterRule {
    pub column: String,
    pub op: FilterOp,
    /// `None` for the null tests; required for everything else.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub value: Option<FilterValue>,
}

/// The text a rule compares against, before it is parsed as the
/// column's type.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", content = "value", rename_all = "snake_case")]
pub enum FilterValue {
    Single(String),
    Pair(String, String),
    List(Vec<String>),
}
