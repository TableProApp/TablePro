//! Per-table WHERE-clause builder used by the Browse-tab filter UI.
//!
//! The dialog (in `crates/app`) constructs a `FilterSet` from the
//! user's input and hands it to `build_filter_where`, which:
//!
//! 1. Looks each rule's column up in the supplied schema.
//! 2. Coerces user-typed strings to typed `Value`s per the column's
//!    `data_type` (so `"42"` against an int column binds as
//!    `Value::Int(42)`, not `Value::Text("42")`).
//! 3. Emits a parameterised SQL fragment using the per-driver
//!    placeholder dialect (`$N` for PG, `?` for MySQL/SQLite) and a
//!    parallel `Vec<Value>` ready for `Connection::query_params`.
//!
//! Rules are joined by a single top-level combinator (AND / OR).
//! Nested groups are intentionally out of scope; users who need
//! arbitrary boolean trees drop to the SQL editor.
//!
//! Identifier quoting and placeholder dialect both flow through
//! `sql_dialect::quote_ident` / `sql_dialect::placeholder_for` so the
//! filter builder doesn't carry its own per-driver knowledge.

use chrono::{DateTime, NaiveDate, NaiveDateTime, NaiveTime, Utc};
use rust_decimal::Decimal;
use serde::{Deserialize, Serialize};
use thiserror::Error;
use uuid::Uuid;

use crate::query::{ColumnInfo, Value};
use crate::sql_dialect::{placeholder_for, quote_ident};

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

/// Build the `WHERE` SQL fragment + bound parameters from a
/// `FilterSet` against a column schema.
///
/// Returns `Ok(None)` for an empty rule list so callers can skip the
/// `WHERE` keyword entirely. Identifiers are quoted via
/// `sql_dialect::quote_ident`; placeholders via
/// `sql_dialect::placeholder_for`. User-typed strings are coerced
/// through the same parser the inline-edit path uses, so binding
/// types are correct for the driver and never round-trip through
/// `Value::Text`.
pub fn build_filter_where(
    driver_id: &str,
    columns: &[ColumnInfo],
    set: &FilterSet,
) -> Result<Option<(String, Vec<Value>)>, BuildFilterError> {
    let extra = set.extra_sql.as_deref().map(str::trim).filter(|s| !s.is_empty());
    if set.rules.is_empty() && extra.is_none() {
        return Ok(None);
    }
    let mut params: Vec<Value> = Vec::new();
    let mut placeholder_idx: usize = 0;
    let mut clauses: Vec<String> = Vec::with_capacity(set.rules.len() + 1);
    for rule in &set.rules {
        let col = columns
            .iter()
            .find(|c| c.name == rule.column)
            .ok_or_else(|| BuildFilterError::UnknownColumn(rule.column.clone()))?;
        let clause = build_rule_sql(driver_id, col, rule, &mut placeholder_idx, &mut params)?;
        clauses.push(clause);
    }
    if let Some(raw) = extra {
        // Wrap in parens so the raw fragment can't accidentally
        // re-bind operator precedence with the structured rules.
        // The user types `a OR b`, we emit `(... AND (a OR b))` and
        // the OR stays scoped to their fragment.
        clauses.push(format!("({raw})"));
    }
    let joiner = match set.combinator {
        Combinator::And => " AND ",
        Combinator::Or => " OR ",
    };
    let sql = match clauses.as_slice() {
        [only] => only.clone(),
        _ => format!("({})", clauses.join(joiner)),
    };
    Ok(Some((sql, params)))
}

fn bind_comparison(
    driver_id: &str,
    col: &ColumnInfo,
    col_sql: &str,
    rule: &FilterRule,
    op_sql: &str,
    placeholder_idx: &mut usize,
    params: &mut Vec<Value>,
) -> Result<String, BuildFilterError> {
    let raw = require_single(rule)?;
    let value = parse_value_for(col, raw)?;
    let ph = placeholder_for(driver_id, *placeholder_idx);
    *placeholder_idx += 1;
    params.push(value);
    Ok(format!("{col_sql} {op_sql} {ph}"))
}

/// Case-sensitive on all drivers. The user picks Ilike explicitly when
/// they want case-insensitive matching.
fn bind_like_pattern(
    driver_id: &str,
    col_sql: &str,
    rule: &FilterRule,
    pattern: impl FnOnce(&str) -> String,
    placeholder_idx: &mut usize,
    params: &mut Vec<Value>,
) -> Result<String, BuildFilterError> {
    let raw = require_single(rule)?;
    let ph = placeholder_for(driver_id, *placeholder_idx);
    *placeholder_idx += 1;
    params.push(Value::Text(pattern(&escape_like(raw))));
    Ok(format!("{col_sql} LIKE {ph}"))
}

fn build_rule_sql(
    driver_id: &str,
    col: &ColumnInfo,
    rule: &FilterRule,
    placeholder_idx: &mut usize,
    params: &mut Vec<Value>,
) -> Result<String, BuildFilterError> {
    let col_sql = quote_ident(driver_id, &col.name);
    match rule.op {
        FilterOp::IsNull => Ok(format!("{col_sql} IS NULL")),
        FilterOp::IsNotNull => Ok(format!("{col_sql} IS NOT NULL")),

        FilterOp::Eq => bind_comparison(driver_id, col, &col_sql, rule, "=", placeholder_idx, params),
        FilterOp::NotEq => bind_comparison(driver_id, col, &col_sql, rule, "<>", placeholder_idx, params),
        FilterOp::Lt => bind_comparison(driver_id, col, &col_sql, rule, "<", placeholder_idx, params),
        FilterOp::LtEq => bind_comparison(driver_id, col, &col_sql, rule, "<=", placeholder_idx, params),
        FilterOp::Gt => bind_comparison(driver_id, col, &col_sql, rule, ">", placeholder_idx, params),
        FilterOp::GtEq => bind_comparison(driver_id, col, &col_sql, rule, ">=", placeholder_idx, params),

        FilterOp::Contains => bind_like_pattern(
            driver_id,
            &col_sql,
            rule,
            |escaped| format!("%{escaped}%"),
            placeholder_idx,
            params,
        ),
        FilterOp::StartsWith => bind_like_pattern(
            driver_id,
            &col_sql,
            rule,
            |escaped| format!("{escaped}%"),
            placeholder_idx,
            params,
        ),
        FilterOp::EndsWith => bind_like_pattern(
            driver_id,
            &col_sql,
            rule,
            |escaped| format!("%{escaped}"),
            placeholder_idx,
            params,
        ),

        FilterOp::Like | FilterOp::NotLike => {
            let raw = require_single(rule)?;
            let ph = placeholder_for(driver_id, *placeholder_idx);
            *placeholder_idx += 1;
            params.push(Value::Text(raw.clone()));
            let kw = if matches!(rule.op, FilterOp::Like) {
                "LIKE"
            } else {
                "NOT LIKE"
            };
            Ok(format!("{col_sql} {kw} {ph}"))
        }

        FilterOp::Ilike => {
            let raw = require_single(rule)?;
            let ph = placeholder_for(driver_id, *placeholder_idx);
            *placeholder_idx += 1;
            params.push(Value::Text(raw.clone()));
            // PG has native ILIKE. MySQL's default `utf8mb4_general_ci`
            // collation already lowercases ASCII for LIKE; SQLite's
            // LIKE is ASCII-case-insensitive by default. Mapping
            // ILIKE→LIKE on the latter two is the closest equivalent
            // without a dialect-specific function call.
            let op_sql = if driver_id == "postgres" { "ILIKE" } else { "LIKE" };
            Ok(format!("{col_sql} {op_sql} {ph}"))
        }

        FilterOp::Between => {
            let (lo, hi) = require_pair(rule)?;
            let lo_v = parse_value_for(col, lo)?;
            let hi_v = parse_value_for(col, hi)?;
            let ph_lo = placeholder_for(driver_id, *placeholder_idx);
            *placeholder_idx += 1;
            params.push(lo_v);
            let ph_hi = placeholder_for(driver_id, *placeholder_idx);
            *placeholder_idx += 1;
            params.push(hi_v);
            Ok(format!("{col_sql} BETWEEN {ph_lo} AND {ph_hi}"))
        }

        FilterOp::In | FilterOp::NotIn => {
            let list = require_list(rule)?;
            if list.is_empty() {
                return Err(BuildFilterError::EmptyInList);
            }
            let mut placeholders: Vec<String> = Vec::with_capacity(list.len());
            for raw in list {
                let parsed = parse_value_for(col, raw)?;
                placeholders.push(placeholder_for(driver_id, *placeholder_idx));
                *placeholder_idx += 1;
                params.push(parsed);
            }
            let kw = if matches!(rule.op, FilterOp::In) {
                "IN"
            } else {
                "NOT IN"
            };
            Ok(format!("{col_sql} {kw} ({})", placeholders.join(", ")))
        }
    }
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

/// Escape a string for safe inclusion inside a `LIKE` pattern.
/// Backslash escapes `%` and `_` so a literal `50%` searches for
/// exactly that text rather than matching anything ending in `50`.
fn escape_like(s: &str) -> String {
    s.replace('\\', "\\\\").replace('%', "\\%").replace('_', "\\_")
}

fn parse_value_for(col: &ColumnInfo, text: &str) -> Result<Value, BuildFilterError> {
    let kind = classify(&col.data_type.to_ascii_lowercase());
    let trimmed = text.trim();
    match kind {
        Kind::Text | Kind::Json => Ok(Value::Text(text.to_string())),
        Kind::Bytes => Err(BuildFilterError::InvalidValue {
            column: col.name.clone(),
            message: "bytes columns can't be filtered by text input".into(),
        }),
        Kind::Bool => parse_bool(trimmed)
            .map(Value::Bool)
            .ok_or_else(|| invalid(col, "boolean", trimmed)),
        Kind::Int => trimmed
            .parse::<i64>()
            .map(Value::Int)
            .map_err(|_| invalid(col, "integer", trimmed)),
        Kind::Float => trimmed
            .parse::<f64>()
            .map(Value::Float)
            .map_err(|_| invalid(col, "number", trimmed)),
        Kind::Decimal => trimmed
            .parse::<Decimal>()
            .map(Value::Decimal)
            .map_err(|_| invalid(col, "decimal", trimmed)),
        Kind::Date => NaiveDate::parse_from_str(trimmed, "%Y-%m-%d")
            .map(Value::Date)
            .map_err(|_| invalid(col, "YYYY-MM-DD", trimmed)),
        Kind::Time => NaiveTime::parse_from_str(trimmed, "%H:%M:%S")
            .or_else(|_| NaiveTime::parse_from_str(trimmed, "%H:%M:%S%.f"))
            .map(Value::Time)
            .map_err(|_| invalid(col, "HH:MM:SS", trimmed)),
        Kind::DateTime => parse_naive_datetime(trimmed)
            .map(Value::DateTime)
            .ok_or_else(|| invalid(col, "YYYY-MM-DD HH:MM:SS", trimmed)),
        Kind::TimestampTz => DateTime::parse_from_rfc3339(trimmed)
            .map(|d| Value::TimestampTz(d.with_timezone(&Utc)))
            .map_err(|_| invalid(col, "RFC 3339 timestamp", trimmed)),
        Kind::Uuid => Uuid::parse_str(trimmed)
            .map(Value::Uuid)
            .map_err(|_| invalid(col, "UUID", trimmed)),
    }
}

fn invalid(col: &ColumnInfo, expected: &str, got: &str) -> BuildFilterError {
    BuildFilterError::InvalidValue {
        column: col.name.clone(),
        message: format!("expected {expected}, got {got:?}"),
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Kind {
    Text,
    Bool,
    Int,
    Float,
    Decimal,
    Date,
    Time,
    DateTime,
    TimestampTz,
    Uuid,
    Json,
    Bytes,
}

/// Coarse type classifier. Mirrors `ui::browse_tab::classify_type`
/// but lives here so core's filter builder doesn't reach back into
/// the app crate. Both classifiers must stay in sync; the type-name
/// landscape they cover is identical.
fn classify(lower: &str) -> Kind {
    if lower == "tinyint(1)" || lower == "boolean" || lower == "bool" {
        return Kind::Bool;
    }
    if lower == "uuid" {
        return Kind::Uuid;
    }
    if lower == "jsonb" || lower == "json" {
        return Kind::Json;
    }
    if lower.contains("with time zone") || lower.contains("timestamptz") {
        return Kind::TimestampTz;
    }
    if lower.contains("timestamp") || lower.contains("datetime") {
        return Kind::DateTime;
    }
    if lower.contains("date") {
        return Kind::Date;
    }
    if lower == "time" || lower.starts_with("time(") {
        return Kind::Time;
    }
    if lower.contains("decimal") || lower.contains("numeric") {
        return Kind::Decimal;
    }
    if lower.contains("double") || lower.contains("real") || lower.contains("float") {
        return Kind::Float;
    }
    if lower.starts_with("int")
        || lower.starts_with("bigint")
        || lower.starts_with("smallint")
        || lower.starts_with("tinyint")
        || lower.contains("serial")
    {
        return Kind::Int;
    }
    if lower.contains("bytea") || lower.contains("blob") {
        return Kind::Bytes;
    }
    Kind::Text
}

fn parse_bool(s: &str) -> Option<bool> {
    match s.to_ascii_lowercase().as_str() {
        "true" | "t" | "1" | "yes" | "y" => Some(true),
        "false" | "f" | "0" | "no" | "n" => Some(false),
        _ => None,
    }
}

fn parse_naive_datetime(s: &str) -> Option<NaiveDateTime> {
    for fmt in [
        "%Y-%m-%d %H:%M:%S",
        "%Y-%m-%dT%H:%M:%S",
        "%Y-%m-%d %H:%M:%S%.f",
        "%Y-%m-%dT%H:%M:%S%.f",
    ] {
        if let Ok(dt) = NaiveDateTime::parse_from_str(s, fmt) {
            return Some(dt);
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    fn col(name: &str, data_type: &str) -> ColumnInfo {
        ColumnInfo {
            name: name.into(),
            data_type: data_type.into(),
            nullable: true,
            primary_key: false,
            is_auto_increment: false,
            default_value: None,
            is_generated: false,
        }
    }

    fn rule(column: &str, op: FilterOp, value: Option<FilterValue>) -> FilterRule {
        FilterRule {
            column: column.into(),
            op,
            value,
        }
    }

    #[test]
    fn empty_set_returns_none() {
        let result = build_filter_where("postgres", &[], &FilterSet::default()).unwrap();
        assert!(result.is_none());
    }

    #[test]
    fn single_eq_no_parens() {
        let cols = vec![col("id", "integer")];
        let set = FilterSet {
            combinator: Combinator::And,
            rules: vec![rule("id", FilterOp::Eq, Some(FilterValue::Single("42".into())))],
            extra_sql: None,
        };
        let (sql, params) = build_filter_where("postgres", &cols, &set).unwrap().unwrap();
        assert_eq!(sql, "\"id\" = $1");
        assert_eq!(params, vec![Value::Int(42)]);
    }

    #[test]
    fn multi_rule_wraps_in_parens() {
        let cols = vec![col("id", "integer"), col("name", "text")];
        let set = FilterSet {
            combinator: Combinator::And,
            rules: vec![
                rule("id", FilterOp::GtEq, Some(FilterValue::Single("10".into()))),
                rule("name", FilterOp::Eq, Some(FilterValue::Single("alice".into()))),
            ],
            extra_sql: None,
        };
        let (sql, params) = build_filter_where("postgres", &cols, &set).unwrap().unwrap();
        assert_eq!(sql, "(\"id\" >= $1 AND \"name\" = $2)");
        assert_eq!(params, vec![Value::Int(10), Value::Text("alice".into())]);
    }

    #[test]
    fn or_combinator_swaps_joiner() {
        let cols = vec![col("a", "integer"), col("b", "integer")];
        let set = FilterSet {
            combinator: Combinator::Or,
            rules: vec![
                rule("a", FilterOp::Eq, Some(FilterValue::Single("1".into()))),
                rule("b", FilterOp::Eq, Some(FilterValue::Single("2".into()))),
            ],
            extra_sql: None,
        };
        let (sql, _) = build_filter_where("postgres", &cols, &set).unwrap().unwrap();
        assert_eq!(sql, "(\"a\" = $1 OR \"b\" = $2)");
    }

    #[test]
    fn mysql_uses_question_marks_and_backticks() {
        let cols = vec![col("id", "int")];
        let set = FilterSet {
            combinator: Combinator::And,
            rules: vec![rule("id", FilterOp::Eq, Some(FilterValue::Single("7".into())))],
            extra_sql: None,
        };
        let (sql, _) = build_filter_where("mysql", &cols, &set).unwrap().unwrap();
        assert_eq!(sql, "`id` = ?");
    }

    #[test]
    fn sqlite_uses_question_marks_and_double_quotes() {
        let cols = vec![col("id", "INTEGER")];
        let set = FilterSet {
            combinator: Combinator::And,
            rules: vec![rule("id", FilterOp::Eq, Some(FilterValue::Single("7".into())))],
            extra_sql: None,
        };
        let (sql, _) = build_filter_where("sqlite", &cols, &set).unwrap().unwrap();
        assert_eq!(sql, "\"id\" = ?");
    }

    #[test]
    fn contains_wraps_with_percent_signs() {
        let cols = vec![col("name", "text")];
        let set = FilterSet {
            combinator: Combinator::And,
            rules: vec![rule(
                "name",
                FilterOp::Contains,
                Some(FilterValue::Single("ali".into())),
            )],
            extra_sql: None,
        };
        let (sql, params) = build_filter_where("postgres", &cols, &set).unwrap().unwrap();
        assert_eq!(sql, "\"name\" LIKE $1");
        assert_eq!(params, vec![Value::Text("%ali%".into())]);
    }

    #[test]
    fn contains_escapes_user_wildcards() {
        // `50%` should match the literal text "50%" — not anything
        // ending in "50". escape_like backslash-escapes `%` and `_`.
        let cols = vec![col("note", "text")];
        let set = FilterSet {
            combinator: Combinator::And,
            rules: vec![rule(
                "note",
                FilterOp::Contains,
                Some(FilterValue::Single("50%".into())),
            )],
            extra_sql: None,
        };
        let (_, params) = build_filter_where("postgres", &cols, &set).unwrap().unwrap();
        assert_eq!(params, vec![Value::Text("%50\\%%".into())]);
    }

    #[test]
    fn ilike_keeps_postgres_native_keyword() {
        let cols = vec![col("name", "text")];
        let set = FilterSet {
            combinator: Combinator::And,
            rules: vec![rule(
                "name",
                FilterOp::Ilike,
                Some(FilterValue::Single("%alice%".into())),
            )],
            extra_sql: None,
        };
        let (sql, _) = build_filter_where("postgres", &cols, &set).unwrap().unwrap();
        assert!(sql.contains("ILIKE"));
    }

    #[test]
    fn ilike_falls_back_to_like_on_mysql() {
        let cols = vec![col("name", "text")];
        let set = FilterSet {
            combinator: Combinator::And,
            rules: vec![rule(
                "name",
                FilterOp::Ilike,
                Some(FilterValue::Single("%alice%".into())),
            )],
            extra_sql: None,
        };
        let (sql, _) = build_filter_where("mysql", &cols, &set).unwrap().unwrap();
        assert!(sql.contains(" LIKE "));
        assert!(!sql.contains("ILIKE"));
    }

    #[test]
    fn is_null_emits_no_placeholder() {
        let cols = vec![col("optional", "text")];
        let set = FilterSet {
            combinator: Combinator::And,
            rules: vec![rule("optional", FilterOp::IsNull, None)],
            extra_sql: None,
        };
        let (sql, params) = build_filter_where("postgres", &cols, &set).unwrap().unwrap();
        assert_eq!(sql, "\"optional\" IS NULL");
        assert!(params.is_empty());
    }

    #[test]
    fn between_uses_two_placeholders() {
        let cols = vec![col("created", "date")];
        let set = FilterSet {
            combinator: Combinator::And,
            rules: vec![rule(
                "created",
                FilterOp::Between,
                Some(FilterValue::Pair("2026-01-01".into(), "2026-12-31".into())),
            )],
            extra_sql: None,
        };
        let (sql, params) = build_filter_where("postgres", &cols, &set).unwrap().unwrap();
        assert_eq!(sql, "\"created\" BETWEEN $1 AND $2");
        assert_eq!(params.len(), 2);
        assert!(matches!(params[0], Value::Date(_)));
        assert!(matches!(params[1], Value::Date(_)));
    }

    #[test]
    fn between_rejects_empty_bound() {
        let cols = vec![col("n", "integer")];
        let set = FilterSet {
            combinator: Combinator::And,
            rules: vec![rule(
                "n",
                FilterOp::Between,
                Some(FilterValue::Pair("1".into(), "".into())),
            )],
            extra_sql: None,
        };
        let err = build_filter_where("postgres", &cols, &set).unwrap_err();
        assert!(matches!(err, BuildFilterError::BetweenMissingBound));
    }

    #[test]
    fn in_emits_placeholder_per_element() {
        let cols = vec![col("id", "integer")];
        let set = FilterSet {
            combinator: Combinator::And,
            rules: vec![rule(
                "id",
                FilterOp::In,
                Some(FilterValue::List(vec!["1".into(), "2".into(), "3".into()])),
            )],
            extra_sql: None,
        };
        let (sql, params) = build_filter_where("postgres", &cols, &set).unwrap().unwrap();
        assert_eq!(sql, "\"id\" IN ($1, $2, $3)");
        assert_eq!(params, vec![Value::Int(1), Value::Int(2), Value::Int(3)]);
    }

    #[test]
    fn in_with_empty_list_rejected() {
        let cols = vec![col("id", "integer")];
        let set = FilterSet {
            combinator: Combinator::And,
            rules: vec![rule("id", FilterOp::In, Some(FilterValue::List(vec![])))],
            extra_sql: None,
        };
        let err = build_filter_where("postgres", &cols, &set).unwrap_err();
        assert!(matches!(err, BuildFilterError::EmptyInList));
    }

    #[test]
    fn unknown_column_errors_with_name() {
        let cols = vec![col("id", "integer")];
        let set = FilterSet {
            combinator: Combinator::And,
            rules: vec![rule("nope", FilterOp::Eq, Some(FilterValue::Single("1".into())))],
            extra_sql: None,
        };
        let err = build_filter_where("postgres", &cols, &set).unwrap_err();
        assert!(matches!(err, BuildFilterError::UnknownColumn(n) if n == "nope"));
    }

    #[test]
    fn missing_value_for_eq_errors() {
        let cols = vec![col("id", "integer")];
        let set = FilterSet {
            combinator: Combinator::And,
            rules: vec![rule("id", FilterOp::Eq, None)],
            extra_sql: None,
        };
        let err = build_filter_where("postgres", &cols, &set).unwrap_err();
        assert!(matches!(err, BuildFilterError::MissingValue(FilterOp::Eq)));
    }

    #[test]
    fn invalid_int_input_errors() {
        let cols = vec![col("id", "integer")];
        let set = FilterSet {
            combinator: Combinator::And,
            rules: vec![rule("id", FilterOp::Eq, Some(FilterValue::Single("abc".into())))],
            extra_sql: None,
        };
        let err = build_filter_where("postgres", &cols, &set).unwrap_err();
        assert!(matches!(err, BuildFilterError::InvalidValue { .. }));
    }

    #[test]
    fn parses_bool_yes_no() {
        let cols = vec![col("active", "boolean")];
        let set = FilterSet {
            combinator: Combinator::And,
            rules: vec![rule("active", FilterOp::Eq, Some(FilterValue::Single("yes".into())))],
            extra_sql: None,
        };
        let (_, params) = build_filter_where("postgres", &cols, &set).unwrap().unwrap();
        assert_eq!(params, vec![Value::Bool(true)]);
    }

    #[test]
    fn parses_uuid_value() {
        let cols = vec![col("id", "uuid")];
        let set = FilterSet {
            combinator: Combinator::And,
            rules: vec![rule(
                "id",
                FilterOp::Eq,
                Some(FilterValue::Single("550e8400-e29b-41d4-a716-446655440000".into())),
            )],
            extra_sql: None,
        };
        let (_, params) = build_filter_where("postgres", &cols, &set).unwrap().unwrap();
        assert!(matches!(params[0], Value::Uuid(_)));
    }

    #[test]
    fn parses_rfc3339_timestamptz() {
        let cols = vec![col("ts", "timestamp with time zone")];
        let set = FilterSet {
            combinator: Combinator::And,
            rules: vec![rule(
                "ts",
                FilterOp::Gt,
                Some(FilterValue::Single("2026-04-29T08:30:00Z".into())),
            )],
            extra_sql: None,
        };
        let (_, params) = build_filter_where("postgres", &cols, &set).unwrap().unwrap();
        assert!(matches!(params[0], Value::TimestampTz(_)));
    }

    #[test]
    fn json_column_takes_text_as_is() {
        // Filter on json column with `=` is exact-text comparison;
        // PG-specific containment (`@>`) is intentionally out of scope.
        let cols = vec![col("payload", "jsonb")];
        let set = FilterSet {
            combinator: Combinator::And,
            rules: vec![rule(
                "payload",
                FilterOp::Eq,
                Some(FilterValue::Single("{\"a\":1}".into())),
            )],
            extra_sql: None,
        };
        let (_, params) = build_filter_where("postgres", &cols, &set).unwrap().unwrap();
        assert_eq!(params, vec![Value::Text("{\"a\":1}".into())]);
    }

    #[test]
    fn bytes_column_rejected() {
        let cols = vec![col("blob_col", "bytea")];
        let set = FilterSet {
            combinator: Combinator::And,
            rules: vec![rule(
                "blob_col",
                FilterOp::Eq,
                Some(FilterValue::Single("anything".into())),
            )],
            extra_sql: None,
        };
        let err = build_filter_where("postgres", &cols, &set).unwrap_err();
        assert!(matches!(err, BuildFilterError::InvalidValue { .. }));
    }

    #[test]
    fn placeholder_indices_continue_across_rules() {
        let cols = vec![col("a", "integer"), col("b", "integer"), col("c", "integer")];
        let set = FilterSet {
            combinator: Combinator::And,
            rules: vec![
                rule("a", FilterOp::Eq, Some(FilterValue::Single("1".into()))),
                rule("b", FilterOp::Between, Some(FilterValue::Pair("2".into(), "3".into()))),
                rule("c", FilterOp::In, Some(FilterValue::List(vec!["4".into(), "5".into()]))),
            ],
            extra_sql: None,
        };
        let (sql, params) = build_filter_where("postgres", &cols, &set).unwrap().unwrap();
        assert!(sql.contains("$1"));
        assert!(sql.contains("$2"));
        assert!(sql.contains("$3"));
        assert!(sql.contains("$4"));
        assert!(sql.contains("$5"));
        assert_eq!(params.len(), 5);
    }

    #[test]
    fn filter_set_serde_round_trips() {
        let original = FilterSet {
            combinator: Combinator::Or,
            rules: vec![
                rule("a", FilterOp::Eq, Some(FilterValue::Single("1".into()))),
                rule("b", FilterOp::IsNull, None),
                rule("c", FilterOp::Between, Some(FilterValue::Pair("x".into(), "y".into()))),
                rule("d", FilterOp::In, Some(FilterValue::List(vec!["p".into(), "q".into()]))),
            ],
            extra_sql: None,
        };
        let json = serde_json::to_string(&original).unwrap();
        let parsed: FilterSet = serde_json::from_str(&json).unwrap();
        assert_eq!(original, parsed);
    }

    #[test]
    fn filter_set_default_combinator_is_and() {
        // Forward-compat: a stored file written before a hypothetical
        // future field gets added must still load. The Default impl on
        // Combinator (And) plus #[serde(default)] on the field covers
        // missing fields silently.
        let json = r#"{"rules":[]}"#;
        let parsed: FilterSet = serde_json::from_str(json).unwrap();
        assert!(matches!(parsed.combinator, Combinator::And));
    }

    #[test]
    fn not_in_emits_correct_keyword() {
        let cols = vec![col("id", "integer")];
        let set = FilterSet {
            combinator: Combinator::And,
            rules: vec![rule(
                "id",
                FilterOp::NotIn,
                Some(FilterValue::List(vec!["1".into(), "2".into()])),
            )],
            extra_sql: None,
        };
        let (sql, _) = build_filter_where("postgres", &cols, &set).unwrap().unwrap();
        assert_eq!(sql, "\"id\" NOT IN ($1, $2)");
    }

    #[test]
    fn starts_with_pattern() {
        let cols = vec![col("name", "text")];
        let set = FilterSet {
            combinator: Combinator::And,
            rules: vec![rule(
                "name",
                FilterOp::StartsWith,
                Some(FilterValue::Single("ali".into())),
            )],
            extra_sql: None,
        };
        let (_, params) = build_filter_where("postgres", &cols, &set).unwrap().unwrap();
        assert_eq!(params, vec![Value::Text("ali%".into())]);
    }

    #[test]
    fn extra_sql_alone_emits_wrapped_fragment() {
        let cols = vec![col("id", "integer")];
        let set = FilterSet {
            combinator: Combinator::And,
            rules: vec![],
            extra_sql: Some("LENGTH(name) > 10".into()),
        };
        let (sql, params) = build_filter_where("postgres", &cols, &set).unwrap().unwrap();
        // No structured rules means the join doesn't run; the raw
        // fragment is emitted bare (single-clause path skips parens).
        assert_eq!(sql, "(LENGTH(name) > 10)");
        assert!(params.is_empty());
    }

    #[test]
    fn extra_sql_combines_with_structured_rules() {
        let cols = vec![col("id", "integer")];
        let set = FilterSet {
            combinator: Combinator::And,
            rules: vec![rule("id", FilterOp::Gt, Some(FilterValue::Single("10".into())))],
            extra_sql: Some("LENGTH(name) > 10".into()),
        };
        let (sql, params) = build_filter_where("postgres", &cols, &set).unwrap().unwrap();
        assert_eq!(sql, "(\"id\" > $1 AND (LENGTH(name) > 10))");
        assert_eq!(params, vec![Value::Int(10)]);
    }

    #[test]
    fn extra_sql_or_combinator() {
        let cols = vec![col("id", "integer")];
        let set = FilterSet {
            combinator: Combinator::Or,
            rules: vec![rule("id", FilterOp::Eq, Some(FilterValue::Single("1".into())))],
            extra_sql: Some("name LIKE 'admin%'".into()),
        };
        let (sql, _) = build_filter_where("postgres", &cols, &set).unwrap().unwrap();
        assert_eq!(sql, "(\"id\" = $1 OR (name LIKE 'admin%'))");
    }

    #[test]
    fn extra_sql_blank_is_treated_as_none() {
        let cols = vec![col("id", "integer")];
        let set = FilterSet {
            combinator: Combinator::And,
            rules: vec![],
            extra_sql: Some("   \n  ".into()),
        };
        // Whitespace-only raw → no WHERE; same as empty filter.
        assert!(build_filter_where("postgres", &cols, &set).unwrap().is_none());
    }

    #[test]
    fn filter_set_is_empty_considers_extra_sql() {
        let no_rules_no_extra = FilterSet::default();
        assert!(no_rules_no_extra.is_empty());
        let only_extra = FilterSet {
            combinator: Combinator::And,
            rules: vec![],
            extra_sql: Some("a > 0".into()),
        };
        assert!(!only_extra.is_empty());
        assert_eq!(only_extra.len(), 1);
    }

    #[test]
    fn ends_with_pattern() {
        let cols = vec![col("name", "text")];
        let set = FilterSet {
            combinator: Combinator::And,
            rules: vec![rule(
                "name",
                FilterOp::EndsWith,
                Some(FilterValue::Single("son".into())),
            )],
            extra_sql: None,
        };
        let (_, params) = build_filter_where("postgres", &cols, &set).unwrap().unwrap();
        assert_eq!(params, vec![Value::Text("%son".into())]);
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
