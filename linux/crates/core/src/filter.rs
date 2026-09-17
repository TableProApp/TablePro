//! The per-table WHERE clause the browse filter builds.
//!
//! The dialog hands over a `FilterSet` and `build_filter` turns it
//! into SQL through the connection's own dialect. Every value the user
//! typed is parsed against the column's type and bound, so a filter is
//! a comparison rather than a string spliced into the query.
//!
//! Rules join under one top-level combinator. Nested groups are out of
//! scope: a user who needs a boolean tree has the SQL editor.

use serde::{Deserialize, Serialize};
use thiserror::Error;

/// One operator in a filter rule. Operator names are user-visible in
/// the dialog (the dropdown labels live next to this enum in the UI
/// layer) but the SQL each one emits is locked here.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FilterOp {
    Eq,
    NotEq,
    Lt,
    LtEq,
    Gt,
    GtEq,
    /// `LIKE '%value%'` — wildcards added by the builder so the user
    /// can type plain text without escaping.
    Contains,
    /// `LIKE 'value%'`.
    StartsWith,
    /// `LIKE '%value'`.
    EndsWith,
    /// Raw `LIKE` — user supplies their own `%` / `_`.
    Like,
    NotLike,
    /// Postgres `ILIKE`; falls back to plain `LIKE` on MySQL / SQLite
    /// where collation typically already case-insensitives ASCII.
    Ilike,
    IsNull,
    IsNotNull,
    /// Value is `FilterValue::List`; one placeholder per element.
    In,
    NotIn,
    /// Value is `FilterValue::Pair(lo, hi)`; emits `BETWEEN lo AND hi`.
    Between,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", content = "value", rename_all = "snake_case")]
pub enum FilterValue {
    Single(String),
    Pair(String, String),
    List(Vec<String>),
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct FilterRule {
    pub column: String,
    pub op: FilterOp,
    /// `None` for `IsNull` / `IsNotNull`; required for everything else.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub value: Option<FilterValue>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum Combinator {
    #[default]
    And,
    Or,
}

#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct FilterSet {
    #[serde(default)]
    pub combinator: Combinator,
    #[serde(default)]
    pub rules: Vec<FilterRule>,
    /// Raw SQL fragment appended after the structured rules with the
    /// configured combinator. Lets the user reach for expressions the
    /// rule editor doesn't model — `LENGTH(name) > 10`,
    /// `created_at::date = CURRENT_DATE`, JSON `@>` containment, etc.
    /// Emitted verbatim with no quoting / parameterisation. There is
    /// no SQL-injection boundary here: the user already has the
    /// connection (they can drop tables via the SQL editor); raw
    /// filter is a power feature, not an untrusted-input vector.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub extra_sql: Option<String>,
}

impl FilterSet {
    /// Empty when there are no rules AND no raw SQL fragment. The
    /// caller (fetch_browse_page) skips WHERE entirely in this case.
    pub fn is_empty(&self) -> bool {
        self.rules.is_empty() && extra_is_blank(self.extra_sql.as_deref())
    }
    pub fn len(&self) -> usize {
        self.rules.len() + usize::from(!extra_is_blank(self.extra_sql.as_deref()))
    }
}

fn extra_is_blank(extra: Option<&str>) -> bool {
    extra.map(|s| s.trim().is_empty()).unwrap_or(true)
}

#[derive(Debug, Error)]
pub enum BuildFilterError {
    #[error("filter rule references unknown column: {0}")]
    UnknownColumn(String),
    #[error("rule on column {column}: {message}")]
    InvalidValue { column: String, message: String },
    #[error("operator {0:?} requires a value")]
    MissingValue(FilterOp),
    #[error("BETWEEN requires both bounds")]
    BetweenMissingBound,
    #[error("IN list cannot be empty")]
    EmptyInList,
    #[error("operator {op:?} cannot use the supplied value shape")]
    WrongValueShape { op: FilterOp },
    #[error("rule on column {column}: {source}")]
    Parse {
        column: String,
        #[source]
        source: crate::edit::EditParseError,
    },
    #[error(transparent)]
    Bind(#[from] crate::dialect::BindError),
    #[error("operator {op:?} does not apply to column {column}")]
    OperatorNotAllowed { column: String, op: FilterOp },
}

fn require_single(rule: &FilterRule) -> Result<&String, BuildFilterError> {
    match rule.value.as_ref() {
        Some(FilterValue::Single(s)) => Ok(s),
        Some(_) => Err(BuildFilterError::WrongValueShape { op: rule.op }),
        None => Err(BuildFilterError::MissingValue(rule.op)),
    }
}

fn require_pair(rule: &FilterRule) -> Result<(&String, &String), BuildFilterError> {
    match rule.value.as_ref() {
        Some(FilterValue::Pair(a, b)) => {
            if a.trim().is_empty() || b.trim().is_empty() {
                return Err(BuildFilterError::BetweenMissingBound);
            }
            Ok((a, b))
        }
        Some(_) => Err(BuildFilterError::WrongValueShape { op: rule.op }),
        None => Err(BuildFilterError::MissingValue(rule.op)),
    }
}

fn require_list(rule: &FilterRule) -> Result<&Vec<String>, BuildFilterError> {
    match rule.value.as_ref() {
        Some(FilterValue::List(l)) => Ok(l),
        Some(_) => Err(BuildFilterError::WrongValueShape { op: rule.op }),
        None => Err(BuildFilterError::MissingValue(rule.op)),
    }
}

// ---------------------------------------------------------------
// Dialect-driven filter building (contract v2).
// ---------------------------------------------------------------

/// Which operators make sense for a column, in the order the dropdown
/// lists them.
///
/// Driven by the column's kind rather than its type name, so a new
/// engine spelling never needs a new branch here. A binary column gets
/// only the null tests: there is no text form of a blob to compare.
pub fn operators_for(kind: crate::column::ColumnKind) -> &'static [FilterOp] {
    use crate::column::ColumnKind;

    const NULL_ONLY: &[FilterOp] = &[FilterOp::IsNull, FilterOp::IsNotNull];
    const COMPARISON: &[FilterOp] = &[
        FilterOp::Eq,
        FilterOp::NotEq,
        FilterOp::Lt,
        FilterOp::LtEq,
        FilterOp::Gt,
        FilterOp::GtEq,
        FilterOp::Between,
        FilterOp::In,
        FilterOp::NotIn,
        FilterOp::IsNull,
        FilterOp::IsNotNull,
    ];
    const TEXTUAL: &[FilterOp] = &[
        FilterOp::Eq,
        FilterOp::NotEq,
        FilterOp::Contains,
        FilterOp::StartsWith,
        FilterOp::EndsWith,
        FilterOp::Like,
        FilterOp::NotLike,
        FilterOp::Ilike,
        FilterOp::In,
        FilterOp::NotIn,
        FilterOp::IsNull,
        FilterOp::IsNotNull,
    ];
    const EQUALITY: &[FilterOp] = &[
        FilterOp::Eq,
        FilterOp::NotEq,
        FilterOp::In,
        FilterOp::NotIn,
        FilterOp::IsNull,
        FilterOp::IsNotNull,
    ];

    match kind {
        ColumnKind::Binary | ColumnKind::Array | ColumnKind::Geometry => NULL_ONLY,
        ColumnKind::Text(_) | ColumnKind::Json | ColumnKind::Enumeration | ColumnKind::Set | ColumnKind::Other => {
            TEXTUAL
        }
        // An interval is ordered, so it compares rather than matching
        // as text.
        ColumnKind::Integer(_)
        | ColumnKind::Decimal
        | ColumnKind::Float(_)
        | ColumnKind::Date
        | ColumnKind::Time
        | ColumnKind::Timestamp
        | ColumnKind::Interval => COMPARISON,
        ColumnKind::Boolean | ColumnKind::Uuid | ColumnKind::BitString | ColumnKind::Network => EQUALITY,
    }
}

/// The WHERE clause for a filter set, and the parameters it binds.
///
/// `None` means there is nothing to filter by, so the caller leaves the
/// keyword out entirely. Every value the user typed is bound; only
/// `extra_sql`, which the user wrote as SQL on purpose, is appended
/// verbatim.
pub fn build_filter(
    dialect: &dyn crate::dialect::SqlDialect,
    columns: &[crate::column::ColumnInfo],
    filter: &FilterSet,
    first_ordinal: usize,
) -> Result<Option<(String, Vec<crate::statement::BoundParam>)>, BuildFilterError> {
    if filter.is_empty() {
        return Ok(None);
    }

    let mut clauses = Vec::with_capacity(filter.len());
    let mut params = Vec::new();
    for rule in &filter.rules {
        let column = columns
            .iter()
            .find(|column| column.name == rule.column)
            .ok_or_else(|| BuildFilterError::UnknownColumn(rule.column.clone()))?;
        if !operators_for(column.column_type.kind()).contains(&rule.op) {
            return Err(BuildFilterError::OperatorNotAllowed {
                column: rule.column.clone(),
                op: rule.op,
            });
        }
        clauses.push(rule_sql(dialect, column, rule, first_ordinal, &mut params)?);
    }
    if let Some(extra) = filter.extra_sql.as_deref().map(str::trim).filter(|sql| !sql.is_empty()) {
        clauses.push(format!("({extra})"));
    }

    let joiner = match filter.combinator {
        Combinator::And => " AND ",
        Combinator::Or => " OR ",
    };
    Ok(Some((clauses.join(joiner), params)))
}

fn rule_sql(
    dialect: &dyn crate::dialect::SqlDialect,
    column: &crate::column::ColumnInfo,
    rule: &FilterRule,
    first_ordinal: usize,
    params: &mut Vec<crate::statement::BoundParam>,
) -> Result<String, BuildFilterError> {
    use crate::dialect::LikeForm;

    let column_sql = dialect.quote_identifier(&column.name);
    match rule.op {
        // A null test has no value to bind, so it never takes a marker.
        FilterOp::IsNull => return Ok(format!("{column_sql} IS NULL")),
        FilterOp::IsNotNull => return Ok(format!("{column_sql} IS NOT NULL")),
        _ => {}
    }

    match rule.op {
        FilterOp::Eq | FilterOp::NotEq | FilterOp::Lt | FilterOp::LtEq | FilterOp::Gt | FilterOp::GtEq => {
            let text = require_single(rule)?;
            let marker = bind_typed(dialect, column, text, first_ordinal, params)?;
            Ok(format!("{column_sql} {} {marker}", comparison_operator(rule.op)))
        }
        FilterOp::Contains | FilterOp::StartsWith | FilterOp::EndsWith => {
            let text = require_single(rule)?;
            // The app is building the pattern, so what the user typed
            // is data: a search for "50%" must not match everything.
            let escaped = dialect.escape_like_text(text);
            let pattern = match rule.op {
                FilterOp::Contains => format!("%{escaped}%"),
                FilterOp::StartsWith => format!("{escaped}%"),
                _ => format!("%{escaped}"),
            };
            let marker = bind_pattern(dialect, pattern, first_ordinal, params)?;
            Ok(dialect.like_predicate(&column_sql, &marker, LikeForm::contains()))
        }
        FilterOp::Like | FilterOp::NotLike => {
            // The user typed the wildcards, so they stay.
            let marker = bind_pattern(dialect, require_single(rule)?.clone(), first_ordinal, params)?;
            let form = LikeForm::raw(rule.op == FilterOp::NotLike);
            Ok(dialect.like_predicate(&column_sql, &marker, form))
        }
        FilterOp::Ilike => {
            let marker = bind_pattern(dialect, require_single(rule)?.clone(), first_ordinal, params)?;
            Ok(dialect.like_predicate(&column_sql, &marker, LikeForm::insensitive(false)))
        }
        FilterOp::In | FilterOp::NotIn => {
            let list = require_list(rule)?;
            if list.is_empty() {
                return Err(BuildFilterError::EmptyInList);
            }
            let mut markers = Vec::with_capacity(list.len());
            for text in list {
                markers.push(bind_typed(dialect, column, text, first_ordinal, params)?);
            }
            let keyword = match rule.op {
                FilterOp::In => "IN",
                _ => "NOT IN",
            };
            Ok(format!("{column_sql} {keyword} ({})", markers.join(", ")))
        }
        FilterOp::Between => {
            let (low, high) = require_pair(rule)?;
            if low.trim().is_empty() || high.trim().is_empty() {
                return Err(BuildFilterError::BetweenMissingBound);
            }
            let low = bind_typed(dialect, column, low, first_ordinal, params)?;
            let high = bind_typed(dialect, column, high, first_ordinal, params)?;
            Ok(format!("{column_sql} BETWEEN {low} AND {high}"))
        }
        FilterOp::IsNull | FilterOp::IsNotNull => unreachable!("handled above"),
    }
}

fn comparison_operator(op: FilterOp) -> &'static str {
    match op {
        FilterOp::Eq => "=",
        FilterOp::NotEq => "<>",
        FilterOp::Lt => "<",
        FilterOp::LtEq => "<=",
        FilterOp::Gt => ">",
        _ => ">=",
    }
}

/// Bind text as the column's own type, so a number compares as a
/// number rather than as its decimal spelling.
fn bind_typed(
    dialect: &dyn crate::dialect::SqlDialect,
    column: &crate::column::ColumnInfo,
    text: &str,
    first_ordinal: usize,
    params: &mut Vec<crate::statement::BoundParam>,
) -> Result<String, BuildFilterError> {
    let value =
        crate::edit::parse_filter_text(text, &column.column_type).map_err(|source| BuildFilterError::Parse {
            column: column.name.clone(),
            source,
        })?;
    let placeholder = dialect.placeholder(
        first_ordinal + params.len(),
        value,
        crate::dialect::BindTarget::Column(column),
    )?;
    if let Some(param) = placeholder.param {
        params.push(param);
    }
    Ok(placeholder.sql)
}

fn bind_pattern(
    dialect: &dyn crate::dialect::SqlDialect,
    pattern: String,
    first_ordinal: usize,
    params: &mut Vec<crate::statement::BoundParam>,
) -> Result<String, BuildFilterError> {
    let placeholder = dialect.placeholder(
        first_ordinal + params.len(),
        crate::value::Value::Text(pattern),
        crate::dialect::BindTarget::Pattern,
    )?;
    if let Some(param) = placeholder.param {
        params.push(param);
    }
    Ok(placeholder.sql)
}

#[cfg(test)]
mod dialect_filter_tests {
    use crate::column::{
        CatalogType, ColumnDefault, ColumnInfo, ColumnKind, ColumnType, IntegerKind, ReadForm, SqlTypeExpr, TextKind,
    };
    use crate::dialect::TestDialect;
    use crate::value::Value;

    use super::*;

    fn column(name: &str, kind: ColumnKind) -> ColumnInfo {
        ColumnInfo {
            name: name.to_owned(),
            column_type: ColumnType::new(
                SqlTypeExpr::from_catalog_text("t"),
                kind,
                CatalogType::Unknown,
                false,
                ReadForm::Native,
            ),
            nullable: true,
            primary_key: false,
            is_auto_increment: false,
            is_generated: false,
            default: ColumnDefault::None,
            comment: None,
        }
    }

    fn columns() -> Vec<ColumnInfo> {
        vec![
            column("name", ColumnKind::Text(TextKind::Variable)),
            column("age", ColumnKind::Integer(IntegerKind::I32)),
            column("photo", ColumnKind::Binary),
        ]
    }

    fn rule(column: &str, op: FilterOp, value: Option<FilterValue>) -> FilterSet {
        FilterSet {
            combinator: Combinator::And,
            rules: vec![FilterRule {
                column: column.to_owned(),
                op,
                value,
            }],
            extra_sql: None,
        }
    }

    fn single(column: &str, op: FilterOp, text: &str) -> FilterSet {
        rule(column, op, Some(FilterValue::Single(text.to_owned())))
    }

    fn build(set: &FilterSet) -> Result<Option<(String, Vec<crate::statement::BoundParam>)>, BuildFilterError> {
        build_filter(&TestDialect::exact(), &columns(), set, 1)
    }

    #[test]
    fn build_filter_skips_where_for_empty_set() {
        assert!(build(&FilterSet::default()).expect("an empty set").is_none());
    }

    #[test]
    fn contains_escapes_through_dialect() {
        let (sql, params) = build(&single("name", FilterOp::Contains, "50%"))
            .expect("the filter")
            .expect("a clause");

        assert_eq!(sql, r#""name" LIKE $1 ESCAPE '\'"#);
        assert_eq!(
            params[0].value(),
            &Value::Text(r"%50\%%".to_owned()),
            "the user's percent was treated as a wildcard"
        );
    }

    #[test]
    fn like_is_raw_and_unescaped() {
        let (sql, params) = build(&single("name", FilterOp::Like, "a%b"))
            .expect("the filter")
            .expect("a clause");

        assert_eq!(sql, r#""name" LIKE $1"#, "a user-typed pattern got an ESCAPE clause");
        assert_eq!(params[0].value(), &Value::Text("a%b".to_owned()));
    }

    #[test]
    fn ilike_uses_insensitive_form() {
        let (sql, _) = build(&single("name", FilterOp::Ilike, "abc"))
            .expect("the filter")
            .expect("a clause");

        assert_eq!(sql, r#""name" ILIKE $1"#);
    }

    #[test]
    fn in_list_marker_per_element() {
        let set = rule(
            "age",
            FilterOp::In,
            Some(FilterValue::List(vec!["1".to_owned(), "2".to_owned(), "3".to_owned()])),
        );

        let (sql, params) = build(&set).expect("the filter").expect("a clause");

        assert_eq!(sql, r#""age" IN ($1, $2, $3)"#);
        assert_eq!(params.len(), 3);
        assert_eq!(params[2].value(), &Value::Int(3));
    }

    #[test]
    fn an_empty_in_list_is_an_error() {
        let set = rule("age", FilterOp::In, Some(FilterValue::List(Vec::new())));

        assert!(matches!(
            build(&set).expect_err("an empty list"),
            BuildFilterError::EmptyInList
        ));
    }

    #[test]
    fn between_rejects_blank_bound() {
        let set = rule(
            "age",
            FilterOp::Between,
            Some(FilterValue::Pair("1".to_owned(), "  ".to_owned())),
        );

        assert!(matches!(
            build(&set).expect_err("a blank bound"),
            BuildFilterError::BetweenMissingBound
        ));
    }

    #[test]
    fn operator_not_allowed_for_bytes() {
        let error = build(&single("photo", FilterOp::Contains, "ff")).expect_err("text search on a blob");

        assert!(
            matches!(error, BuildFilterError::OperatorNotAllowed { .. }),
            "{error:?}"
        );
        // The null tests still apply, because a blob can be absent.
        assert!(build(&rule("photo", FilterOp::IsNull, None)).is_ok());
    }

    #[test]
    fn operators_for_interval_are_comparison_not_text() {
        let interval = operators_for(ColumnKind::Interval);

        assert!(interval.contains(&FilterOp::Between), "{interval:?}");
        assert!(interval.contains(&FilterOp::Lt), "{interval:?}");
        assert!(!interval.contains(&FilterOp::Contains), "{interval:?}");
    }

    #[test]
    fn a_value_that_is_not_of_the_columns_type_is_reported_before_the_server_sees_it() {
        let error = build(&single("age", FilterOp::Eq, "seven")).expect_err("text in a number column");

        assert!(matches!(error, BuildFilterError::Parse { .. }), "{error:?}");
    }

    #[test]
    fn a_null_test_binds_nothing() {
        let (sql, params) = build(&rule("name", FilterOp::IsNull, None))
            .expect("the filter")
            .expect("a clause");

        assert_eq!(sql, r#""name" IS NULL"#);
        assert!(params.is_empty(), "a null test bound a parameter");
    }

    #[test]
    fn raw_sql_is_joined_with_the_rules_and_never_bound() {
        let set = FilterSet {
            combinator: Combinator::Or,
            rules: vec![FilterRule {
                column: "age".to_owned(),
                op: FilterOp::Gt,
                value: Some(FilterValue::Single("18".to_owned())),
            }],
            extra_sql: Some("length(name) > 3".to_owned()),
        };

        let (sql, params) = build(&set).expect("the filter").expect("a clause");

        assert_eq!(sql, r#""age" > $1 OR (length(name) > 3)"#);
        assert_eq!(params.len(), 1);
    }

    #[test]
    fn a_rule_on_a_column_the_table_lost_is_an_error() {
        let error = build(&single("gone", FilterOp::Eq, "1")).expect_err("a missing column");

        assert!(matches!(error, BuildFilterError::UnknownColumn(_)), "{error:?}");
    }
}
