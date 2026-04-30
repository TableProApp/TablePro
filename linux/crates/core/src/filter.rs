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
}

impl FilterSet {
    pub fn is_empty(&self) -> bool {
        self.rules.is_empty()
    }
    pub fn len(&self) -> usize {
        self.rules.len()
    }
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
    if set.rules.is_empty() {
        return Ok(None);
    }
    let mut params: Vec<Value> = Vec::new();
    let mut placeholder_idx: usize = 0;
    let mut clauses: Vec<String> = Vec::with_capacity(set.rules.len());
    for rule in &set.rules {
        let col = columns
            .iter()
            .find(|c| c.name == rule.column)
            .ok_or_else(|| BuildFilterError::UnknownColumn(rule.column.clone()))?;
        let clause = build_rule_sql(driver_id, col, rule, &mut placeholder_idx, &mut params)?;
        clauses.push(clause);
    }
    let joiner = match set.combinator {
        Combinator::And => " AND ",
        Combinator::Or => " OR ",
    };
    let sql = if clauses.len() == 1 {
        clauses.into_iter().next().unwrap()
    } else {
        format!("({})", clauses.join(joiner))
    };
    Ok(Some((sql, params)))
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

        FilterOp::Eq | FilterOp::NotEq | FilterOp::Lt | FilterOp::LtEq | FilterOp::Gt | FilterOp::GtEq => {
            let raw = require_single(rule)?;
            let value = parse_value_for(col, raw)?;
            let ph = placeholder_for(driver_id, *placeholder_idx);
            *placeholder_idx += 1;
            params.push(value);
            let op_sql = match rule.op {
                FilterOp::Eq => "=",
                FilterOp::NotEq => "<>",
                FilterOp::Lt => "<",
                FilterOp::LtEq => "<=",
                FilterOp::Gt => ">",
                FilterOp::GtEq => ">=",
                _ => unreachable!(),
            };
            Ok(format!("{col_sql} {op_sql} {ph}"))
        }

        FilterOp::Contains | FilterOp::StartsWith | FilterOp::EndsWith => {
            let raw = require_single(rule)?;
            let escaped = escape_like(raw);
            let pattern = match rule.op {
                FilterOp::Contains => format!("%{escaped}%"),
                FilterOp::StartsWith => format!("{escaped}%"),
                FilterOp::EndsWith => format!("%{escaped}"),
                _ => unreachable!(),
            };
            let ph = placeholder_for(driver_id, *placeholder_idx);
            *placeholder_idx += 1;
            params.push(Value::Text(pattern));
            // Case-sensitive on all drivers. The user picks Ilike
            // explicitly when they want case-insensitive matching.
            Ok(format!("{col_sql} LIKE {ph}"))
        }

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
        };
        let (_, params) = build_filter_where("postgres", &cols, &set).unwrap().unwrap();
        assert_eq!(params, vec![Value::Text("ali%".into())]);
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
        };
        let (_, params) = build_filter_where("postgres", &cols, &set).unwrap().unwrap();
        assert_eq!(params, vec![Value::Text("%son".into())]);
    }
}
