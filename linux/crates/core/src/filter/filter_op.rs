use serde::{Deserialize, Serialize};

/// One operator in a filter rule. The dropdown labels live in the UI;
/// the SQL each one emits is decided by `build_filter`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FilterOp {
    Eq,
    NotEq,
    Lt,
    LtEq,
    Gt,
    GtEq,
    /// The builder adds the wildcards and escapes the user's own, so
    /// plain text matches as typed.
    Contains,
    StartsWith,
    EndsWith,
    /// The user's own pattern, wildcards and all.
    Like,
    NotLike,
    /// Case-insensitive LIKE, spelled however the engine spells it.
    Ilike,
    IsNull,
    IsNotNull,
    /// Value is `FilterValue::List`; one marker per element.
    In,
    NotIn,
    /// Value is `FilterValue::Pair(low, high)`.
    Between,
}
