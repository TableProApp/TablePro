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

use chrono::{DateTime, NaiveDate, NaiveDateTime, NaiveTime, Timelike, Utc};
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

    pub fn narrowed_to(&self, rule: FilterRule) -> FilterSet {
        if self.combinator == Combinator::Or {
            return FilterSet {
                rules: vec![rule],
                ..FilterSet::default()
            };
        }
        let mut narrowed = self.clone();
        narrowed.rules.retain(|existing| existing.column != rule.column);
        narrowed.rules.push(rule);
        narrowed
    }
}

pub fn equality_rule(column: &str, value: &Value) -> Option<FilterRule> {
    let text = match value {
        Value::Null => {
            return Some(FilterRule {
                column: column.to_string(),
                op: FilterOp::IsNull,
                value: None,
            });
        }
        Value::Bool(b) => b.to_string(),
        Value::Int(i) => i.to_string(),
        Value::Float(f) => f.to_string(),
        Value::Decimal(d) => d.to_string(),
        Value::Text(t) => t.clone(),
        Value::Date(d) => d.format("%Y-%m-%d").to_string(),
        Value::Time(t) => t.format("%H:%M:%S%.f").to_string(),
        Value::DateTime(dt) => dt.format("%Y-%m-%d %H:%M:%S%.f").to_string(),
        Value::TimestampTz(ts) => ts.to_rfc3339(),
        Value::Uuid(u) => u.to_string(),
        Value::Json(_) | Value::Bytes(_) | Value::Undecodable(_) => return None,
    };
    Some(FilterRule {
        column: column.to_string(),
        op: FilterOp::Eq,
        value: Some(FilterValue::Single(text)),
    })
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
    let sql = if let [only] = clauses.as_slice() {
        only.clone()
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
    let col_sql = filter_column(driver_id, col);
    // PostgreSQL pattern operators require text. Unknown names include user
    // enums/domains, so only known built-in text types bypass the cast.
    let pattern_sql = if driver_id == "postgres"
        && !matches!(
            col.data_type.to_ascii_lowercase().as_str(),
            "text" | "varchar" | "character varying" | "char" | "character" | "bpchar"
        ) {
        format!("CAST({col_sql} AS text)")
    } else {
        col_sql.clone()
    };
    match rule.op {
        FilterOp::IsNull => Ok(format!("{col_sql} IS NULL")),
        FilterOp::IsNotNull => Ok(format!("{col_sql} IS NOT NULL")),

        FilterOp::Eq | FilterOp::NotEq | FilterOp::Lt | FilterOp::LtEq | FilterOp::Gt | FilterOp::GtEq => {
            let raw = require_single(rule)?;
            let value = parse_filter_value(driver_id, col, raw)?;
            let ph = filter_placeholder(driver_id, col, *placeholder_idx);
            *placeholder_idx += 1;
            params.push(value);
            let op_sql = match rule.op {
                FilterOp::Eq => "=",
                FilterOp::NotEq => "<>",
                FilterOp::Lt => "<",
                FilterOp::LtEq => "<=",
                FilterOp::Gt => ">",
                FilterOp::GtEq => ">=",
                _ => return Err(BuildFilterError::WrongValueShape { op: rule.op }),
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
                _ => return Err(BuildFilterError::WrongValueShape { op: rule.op }),
            };
            let ph = placeholder_for(driver_id, *placeholder_idx);
            *placeholder_idx += 1;
            params.push(Value::Text(pattern));
            // Case-sensitive on all drivers. The user picks Ilike
            // explicitly when they want case-insensitive matching.
            Ok(format!("{pattern_sql} LIKE {ph}"))
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
            Ok(format!("{pattern_sql} {kw} {ph}"))
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
            Ok(format!("{pattern_sql} {op_sql} {ph}"))
        }

        FilterOp::Between => {
            let (lo, hi) = require_pair(rule)?;
            let lo_v = parse_filter_value(driver_id, col, lo)?;
            let hi_v = parse_filter_value(driver_id, col, hi)?;
            let ph_lo = filter_placeholder(driver_id, col, *placeholder_idx);
            *placeholder_idx += 1;
            params.push(lo_v);
            let ph_hi = filter_placeholder(driver_id, col, *placeholder_idx);
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
                let parsed = parse_filter_value(driver_id, col, raw)?;
                placeholders.push(filter_placeholder(driver_id, col, *placeholder_idx));
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

fn filter_placeholder(driver_id: &str, col: &ColumnInfo, index: usize) -> String {
    let placeholder = placeholder_for(driver_id, index);
    let Some(enum_type) = col.enum_type.as_ref().filter(|_| driver_id == "postgres") else {
        return placeholder;
    };
    let array_suffix = if col.data_type.trim().ends_with("[]") { "[]" } else { "" };
    format!(
        "{placeholder}::{}.{}{}",
        quote_ident("postgres", &enum_type.schema),
        quote_ident("postgres", &enum_type.name),
        array_suffix
    )
}

fn filter_column(driver_id: &str, col: &ColumnInfo) -> String {
    let column = quote_ident(driver_id, &col.name);
    let Some(enum_type) = col
        .enum_type
        .as_ref()
        .filter(|_| driver_id == "postgres" && !col.data_type.trim().ends_with("[]"))
    else {
        return column;
    };
    format!(
        "({column}::{}.{})",
        quote_ident("postgres", &enum_type.schema),
        quote_ident("postgres", &enum_type.name)
    )
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
        Kind::Float => crate::parse_float_input(trimmed)
            .map(Value::Float)
            .map_err(|_| invalid(col, "number", trimmed)),
        Kind::Decimal => Decimal::from_str_exact(trimmed)
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

fn parse_filter_value(driver_id: &str, col: &ColumnInfo, text: &str) -> Result<Value, BuildFilterError> {
    let value = parse_value_for(col, text)?;
    if driver_id != "duckdb" {
        return Ok(value);
    }

    let data_type = col.data_type.trim().to_ascii_lowercase();
    let quantum_ns = match data_type.as_str() {
        "time"
        | "time without time zone"
        | "timestamp"
        | "timestamp without time zone"
        | "timestamptz"
        | "timestamp with time zone" => 1_000,
        "timestamp_s" => 1_000_000_000,
        "timestamp_ms" => 1_000_000,
        _ => return Ok(value),
    };
    let nanos = match &value {
        Value::Time(time) => Some(time.nanosecond()),
        Value::DateTime(datetime) => Some(datetime.nanosecond()),
        Value::TimestampTz(datetime) => Some(datetime.timestamp_subsec_nanos()),
        _ => None,
    };
    if nanos.is_some_and(|nanos| nanos % quantum_ns != 0) {
        return Err(BuildFilterError::InvalidValue {
            column: col.name.clone(),
            message: format!("value exceeds DuckDB {data_type} precision"),
        });
    }
    Ok(value)
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
#[path = "filter_tests.rs"]
mod tests;
