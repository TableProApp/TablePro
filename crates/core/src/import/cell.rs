use chrono::{DateTime, Datelike, NaiveDate, NaiveDateTime, NaiveTime, Timelike, Utc};
use rust_decimal::Decimal;
use thiserror::Error;
use uuid::Uuid;

use crate::import::csv_import::CsvImportOptions;
use crate::import::extended_temporal::{duckdb_extended_date, duckdb_extended_timestamptz_nanos};
use crate::query::{ColumnInfo, Value};

mod mysql_calendar;
mod postgres_temporal;

/// What a field could not be turned into. Names the failure only: the cell
/// text never travels with it, because this reaches error lists and logs.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
pub enum CellError {
    #[error("not true or false")]
    NotABoolean,
    #[error("not a whole number")]
    NotAnInteger,
    #[error("not a number")]
    NotANumber,
    #[error("not a date")]
    NotADate,
    #[error("not a time")]
    NotATime,
    #[error("not a timestamp")]
    NotATimestamp,
    #[error("not a UUID")]
    NotAUuid,
    #[error("not JSON")]
    NotJson,
    #[error("not hexadecimal bytes")]
    NotBytes,
    #[error("not an interval")]
    NotAnInterval,
    #[error("empty CSV field is ambiguous for a PostgreSQL enum; set an explicit NULL marker")]
    AmbiguousEnumNullOrEmpty,
    #[error("empty CSV field is ambiguous for SQLite ANY; set an explicit NULL marker")]
    AmbiguousSqliteAnyNullOrEmpty,
    #[error("invalid tagged SQLite ANY CSV value")]
    InvalidSqliteAnyCsvValue,
}

/// A field that could not become a value, named well enough for the user
/// to find the cell without the message carrying its contents.
#[derive(Debug, Clone, PartialEq, Eq, Error)]
#[error("line {line}, column {column}: {reason}")]
pub struct CsvRowError {
    /// The row's position in the file, counting the header as line 1 so it
    /// matches what a spreadsheet shows.
    pub line: usize,
    pub column: String,
    pub reason: CellError,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ColumnKind {
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
    Text,
}

impl ColumnKind {
    pub const ALL: [Self; 12] = [
        Self::Text,
        Self::Int,
        Self::Float,
        Self::Decimal,
        Self::Bool,
        Self::Date,
        Self::Time,
        Self::DateTime,
        Self::TimestampTz,
        Self::Uuid,
        Self::Json,
        Self::Bytes,
    ];
}

/// Read a catalog type name as the value shape the import must produce.
/// Anything unrecognised is text, which is the reading that never loses
/// what the file said.
pub fn column_kind(data_type: &str) -> ColumnKind {
    let lowered = data_type.trim().to_ascii_lowercase();
    if lowered.starts_with("bindata-subtype-") {
        return if lowered.ends_with("-00") {
            ColumnKind::Bytes
        } else {
            ColumnKind::Json
        };
    }
    // Array values are transported as their driver's textual array form.
    // Parsing the element type here would incorrectly treat the whole cell
    // (for example, "{1,2}") as a scalar number.
    if lowered.contains('[') || lowered.ends_with(" array") {
        return ColumnKind::Text;
    }
    let base = lowered.split(['(', '[']).next().unwrap_or("").trim().to_owned();
    if let Some(kind) = temporal_kind(&base, &lowered) {
        return kind;
    }
    // These catalog names contain the substring `int` but are not integer
    // types. Keep them as exact text for native consumers such as DuckDB's
    // INTERVAL insert and PostgreSQL's unsupported geometric point values.
    if matches!(base.as_str(), "interval" | "point") {
        return ColumnKind::Text;
    }
    if base.contains("bool") || base == "bit" {
        return ColumnKind::Bool;
    }
    if base.contains("uuid") || base.contains("uniqueidentifier") {
        return ColumnKind::Uuid;
    }
    if matches!(base.as_str(), "int128" | "uint128") {
        return ColumnKind::Text;
    }
    if base.contains("json") {
        return ColumnKind::Json;
    }
    if base.contains("bytea") || base.contains("blob") || base.contains("binary") || base == "image" {
        return ColumnKind::Bytes;
    }
    if base.contains("decimal") || base.contains("numeric") || base.contains("money") {
        return ColumnKind::Decimal;
    }
    if base.contains("int") || base.contains("serial") {
        return ColumnKind::Int;
    }
    if base.contains("float") || base.contains("double") || base.contains("real") {
        return ColumnKind::Float;
    }
    ColumnKind::Text
}

fn is_mysql_timestamp_type(data_type: &str) -> bool {
    let data_type = data_type.trim().to_ascii_lowercase();
    data_type == "timestamp" || data_type.starts_with("timestamp(")
}

fn temporal_kind(base: &str, lowered: &str) -> Option<ColumnKind> {
    // SQL Server datetimeoffset stores the original UTC offset as part of the
    // value. Value::TimestampTz normalizes offsets to UTC, so CSV import must
    // retain this native type as exact text for a lossless bound insert.
    if base.contains("datetimeoffset") {
        return Some(ColumnKind::Text);
    }
    if base.contains("timestamptz") || lowered.contains("with time zone") {
        return Some(ColumnKind::TimestampTz);
    }
    if base.contains("timestamp") || base.contains("datetime") {
        return Some(ColumnKind::DateTime);
    }
    if base == "date" {
        return Some(ColumnKind::Date);
    }
    if base.contains("time") {
        return Some(ColumnKind::Time);
    }
    None
}

pub fn parse_cell(text: &str, kind: ColumnKind) -> Result<Value, CellError> {
    let trimmed = text.trim();
    match kind {
        ColumnKind::Text => Ok(Value::Text(text.to_owned())),
        ColumnKind::Bool => parse_bool(trimmed),
        ColumnKind::Int => trimmed.parse().map(Value::Int).map_err(|_| CellError::NotAnInteger),
        ColumnKind::Float => crate::parse_float_input(trimmed)
            .map(Value::Float)
            .map_err(|_| CellError::NotANumber),
        ColumnKind::Decimal => Decimal::from_str_exact(trimmed)
            .map(Value::Decimal)
            .map_err(|_| CellError::NotANumber),
        ColumnKind::Uuid => Uuid::parse_str(trimmed)
            .map(Value::Uuid)
            .map_err(|_| CellError::NotAUuid),
        ColumnKind::Json => serde_json::from_str(trimmed)
            .map(Value::Json)
            .map_err(|_| CellError::NotJson),
        ColumnKind::Bytes => parse_bytes(trimmed),
        ColumnKind::Date => NaiveDate::parse_from_str(trimmed, "%Y-%m-%d")
            .map(Value::Date)
            .map_err(|_| CellError::NotADate),
        ColumnKind::Time => parse_time(trimmed),
        ColumnKind::DateTime => parse_datetime(trimmed).map(Value::DateTime),
        ColumnKind::TimestampTz => parse_timestamptz(trimmed),
    }
}

fn parse_bool(text: &str) -> Result<Value, CellError> {
    match text.to_ascii_lowercase().as_str() {
        "true" | "t" | "yes" | "y" | "1" => Ok(Value::Bool(true)),
        "false" | "f" | "no" | "n" | "0" => Ok(Value::Bool(false)),
        _ => Err(CellError::NotABoolean),
    }
}

const TIME_FORMATS: [&str; 2] = ["%H:%M:%S%.f", "%H:%M"];

fn parse_time(text: &str) -> Result<Value, CellError> {
    TIME_FORMATS
        .iter()
        .find_map(|format| NaiveTime::parse_from_str(text, format).ok())
        .map(Value::Time)
        .ok_or(CellError::NotATime)
}

const DATETIME_FORMATS: [&str; 4] = [
    "%Y-%m-%d %H:%M:%S%.f",
    "%Y-%m-%dT%H:%M:%S%.f",
    "%Y-%m-%d %H:%M",
    "%Y-%m-%dT%H:%M",
];

fn parse_datetime(text: &str) -> Result<NaiveDateTime, CellError> {
    if let Some(parsed) = DATETIME_FORMATS
        .iter()
        .find_map(|format| NaiveDateTime::parse_from_str(text, format).ok())
    {
        return Ok(parsed);
    }
    NaiveDate::parse_from_str(text, "%Y-%m-%d")
        .ok()
        .and_then(|date| date.and_hms_opt(0, 0, 0))
        .ok_or(CellError::NotATimestamp)
}

fn parse_timestamptz(text: &str) -> Result<Value, CellError> {
    if let Ok(parsed) = DateTime::parse_from_rfc3339(text) {
        return Ok(Value::TimestampTz(parsed.with_timezone(&Utc)));
    }
    parse_datetime(text).map(|naive| Value::TimestampTz(naive.and_utc()))
}

/// Binary columns take hexadecimal, with or without the `0x` prefix every
/// engine's own hex literal uses. There is no other text form a delimited
/// file can carry that round-trips through every driver.
fn parse_bytes(text: &str) -> Result<Value, CellError> {
    let digits = text
        .strip_prefix("0x")
        .or_else(|| text.strip_prefix("0X"))
        .or_else(|| text.strip_prefix("\\x"))
        .unwrap_or(text);
    if !digits.len().is_multiple_of(2) {
        return Err(CellError::NotBytes);
    }
    let mut out = Vec::with_capacity(digits.len() / 2);
    for pair in digits.as_bytes().chunks(2) {
        let pair = std::str::from_utf8(pair).map_err(|_| CellError::NotBytes)?;
        out.push(u8::from_str_radix(pair, 16).map_err(|_| CellError::NotBytes)?);
    }
    Ok(Value::Bytes(out))
}

/// Turn one record into the values a bound INSERT takes, one per column in
/// `columns`. A column with no mapped field, or one whose field is past the
/// end of a short row, becomes NULL, which the statement builder drops when
/// the column has a server default.
pub fn row_to_values(
    row: &[String],
    mapping: &[Option<usize>],
    columns: &[ColumnInfo],
    options: &CsvImportOptions,
    line: usize,
) -> Result<Vec<Value>, CsvRowError> {
    row_to_values_for_driver(row, mapping, columns, options, line, "")
}

pub(crate) fn row_to_values_for_driver(
    row: &[String],
    mapping: &[Option<usize>],
    columns: &[ColumnInfo],
    options: &CsvImportOptions,
    line: usize,
    driver_id: &str,
) -> Result<Vec<Value>, CsvRowError> {
    columns
        .iter()
        .zip(mapping)
        .map(|(column, field)| {
            let Some(text) = field.and_then(|index| row.get(index)) else {
                return Ok(Value::Null);
            };
            value_for(text, column, options, driver_id).map_err(|reason| CsvRowError {
                line,
                column: column.name.clone(),
                reason,
            })
        })
        .collect()
}

fn value_for(text: &str, column: &ColumnInfo, options: &CsvImportOptions, driver_id: &str) -> Result<Value, CellError> {
    let kind = if driver_id == "mysql" && is_mysql_timestamp_type(&column.data_type) {
        ColumnKind::TimestampTz
    } else {
        column_kind(&column.data_type)
    };
    if driver_id == "sqlite" {
        let is_any = crate::sqlite_any_csv::is_any_type(&column.data_type);
        let is_unknown = crate::sqlite_any_csv::is_unknown_type(&column.data_type);
        if text == options.null_marker {
            return if is_any && options.null_marker.is_empty() {
                Err(CellError::AmbiguousSqliteAnyNullOrEmpty)
            } else {
                Ok(Value::Null)
            };
        }
        return match crate::sqlite_any_csv::decode(text) {
            Ok(Some(value)) if is_any || is_unknown => Ok(value),
            Ok(Some(Value::Int(value))) => parse_non_null_cell(&value.to_string(), column, kind, driver_id),
            Ok(Some(Value::Float(value))) => parse_non_null_cell(&value.to_string(), column, kind, driver_id),
            Ok(Some(Value::Text(value))) => parse_non_null_cell(&value, column, kind, driver_id),
            Ok(Some(Value::Bytes(value))) if matches!(kind, ColumnKind::Bytes) => Ok(Value::Bytes(value)),
            Ok(Some(Value::Bytes(_))) => Err(CellError::NotBytes),
            Ok(Some(_)) => Err(CellError::InvalidSqliteAnyCsvValue),
            Ok(None) if is_any => Ok(Value::Text(text.to_owned())),
            Ok(None) => parse_non_null_cell(text, column, kind, driver_id),
            Err(crate::sqlite_any_csv::DecodeError::Malformed) => Err(CellError::InvalidSqliteAnyCsvValue),
        };
    }
    if driver_id == "postgres" && column.enum_type.is_some() && text.is_empty() && options.null_marker.is_empty() {
        return if column.data_type.trim().ends_with("[]") {
            Ok(Value::Null)
        } else {
            Err(CellError::AmbiguousEnumNullOrEmpty)
        };
    }
    if driver_id == "duckdb" && column.data_type.trim().eq_ignore_ascii_case("interval") && text.is_empty() {
        return if options.null_marker.is_empty() {
            Ok(Value::Null)
        } else {
            Err(CellError::NotAnInterval)
        };
    }
    if text != options.null_marker {
        return parse_non_null_cell(text, column, kind, driver_id);
    }
    // Every export in this app writes NULL as an empty field, but so is an
    // empty string, and for text the empty string is the reading that loses
    // nothing.
    if options.null_marker.is_empty() && kind == ColumnKind::Text {
        return Ok(Value::Text(String::new()));
    }
    Ok(Value::Null)
}

fn parse_non_null_cell(text: &str, column: &ColumnInfo, kind: ColumnKind, driver_id: &str) -> Result<Value, CellError> {
    if driver_id == "sqlite"
        && kind == ColumnKind::Text
        && crate::sqlite_declared_type_has_numeric_affinity(&column.data_type)
    {
        return sqlite_affinity_csv_value(text);
    }
    if driver_id == "duckdb"
        && let Some(value) = duckdb_extended_calendar_text(text, &column.data_type)
    {
        return Ok(Value::Text(value.to_owned()));
    }
    if driver_id == "postgres"
        && let Some(value) = postgres_temporal::parse_extended(text, &column.data_type)
    {
        return Ok(Value::Text(value));
    }
    if driver_id == "postgres"
        && let Some(value) = postgres_text_temporal(text, &column.data_type)
    {
        // PostgreSQL's infinities, timetz offsets and 24:00 value are
        // exact text in the driver contract. Restore the CSV formula
        // marker only for recognized native sentinels.
        return Ok(Value::Text(value.to_owned()));
    }
    if driver_id == "duckdb"
        && let Some(value) = duckdb_formula_safe_interval(text, &column.data_type)
    {
        return Ok(Value::Text(value.to_owned()));
    }
    if kind == ColumnKind::Text
        && let Some(value) = sanitized_wide_integer_text(text, &column.data_type)
    {
        return Ok(Value::Text(value.to_owned()));
    }
    if kind == ColumnKind::Decimal
        && let Some(value) = sanitized_decimal(text)
    {
        return Ok(Value::Decimal(value));
    }
    if kind == ColumnKind::Decimal
        && let Some(value) = wide_decimal_text(text, &column.data_type)
    {
        return Ok(Value::Text(value.to_owned()));
    }
    if driver_id == "mysql" && mysql_calendar::invalid_text(text, &column.data_type) {
        return Ok(Value::Text(text.to_owned()));
    }
    match parse_cell(text, kind) {
        Ok(Value::TimestampTz(value)) if driver_id == "duckdb" && value.timestamp_subsec_nanos() % 1_000 != 0 => {
            Err(CellError::NotATimestamp)
        }
        Ok(value) if driver_id == "postgres" && postgres_temporal_needs_text(&value) => {
            match crate::sql_literal::postgres_temporal_text(&value) {
                Some(text) => Ok(Value::Text(text)),
                None => Ok(value),
            }
        }
        Ok(value) => Ok(value),
        Err(error) => parse_sqlite_affinity_fallback(text, kind, driver_id).unwrap_or(Err(error)),
    }
}

fn sqlite_affinity_csv_value(text: &str) -> Result<Value, CellError> {
    if let Some(decimal) = crate::sqlite_affinity_decimal(text) {
        Ok(Value::Decimal(decimal))
    } else if crate::is_numeric_input(text) {
        Err(CellError::NotANumber)
    } else {
        Ok(Value::Text(text.to_owned()))
    }
}

fn parse_sqlite_affinity_fallback(text: &str, kind: ColumnKind, driver_id: &str) -> Option<Result<Value, CellError>> {
    if driver_id != "sqlite" || !matches!(kind, ColumnKind::Int | ColumnKind::Float | ColumnKind::Decimal) {
        return None;
    }
    if let Some(decimal) = crate::sqlite_affinity_decimal(text) {
        return Some(Ok(Value::Decimal(decimal)));
    }
    if !crate::is_numeric_input(text) {
        // SQLite affinity may store nonnumeric input as TEXT.
        return Some(Ok(Value::Text(text.to_owned())));
    }
    None
}

fn duckdb_extended_calendar_text<'a>(text: &'a str, data_type: &str) -> Option<&'a str> {
    let data_type = data_type.trim();
    let date_text = if data_type.eq_ignore_ascii_case("date") {
        text
    } else if ["timestamptz", "timestamp with time zone"]
        .iter()
        .any(|kind| data_type.eq_ignore_ascii_case(kind))
    {
        if duckdb_extended_timestamptz_nanos(text)? % 1_000 != 0 {
            return None;
        }
        return Some(text);
    } else if ["timestamp", "timestamp without time zone"]
        .iter()
        .any(|kind| data_type.eq_ignore_ascii_case(kind))
    {
        let (date, time) = if let Some((date, time)) = text.split_once(" (BC) ") {
            (format!("{date} (BC)"), time)
        } else {
            let (date, time) = text.split_once(' ')?;
            (date.to_owned(), time)
        };
        let valid_date = duckdb_extended_date(&date);
        if !valid_date {
            return None;
        }
        let time = NaiveTime::parse_from_str(time, "%H:%M:%S%.f")
            .or_else(|_| NaiveTime::parse_from_str(time, "%H:%M"))
            .ok()?;
        if time.nanosecond() % 1_000 != 0 {
            return None;
        }
        return Some(text);
    } else {
        return None;
    };
    duckdb_extended_date(date_text).then_some(text)
}

fn postgres_temporal_needs_text(value: &Value) -> bool {
    let year = match value {
        Value::Date(value) => value.year(),
        Value::DateTime(value) => value.year(),
        Value::TimestampTz(value) => value.year(),
        _ => return false,
    };
    !(1..=9999).contains(&year)
}

fn postgres_text_temporal<'a>(text: &'a str, data_type: &str) -> Option<&'a str> {
    let kind = data_type.trim().to_ascii_lowercase();
    if matches!(kind.as_str(), "timetz" | "time with time zone") {
        return Some(text);
    }
    if kind == "time" || kind == "time without time zone" {
        return (text == "24:00:00" || text.starts_with("24:00:00.")).then_some(text);
    }
    if matches!(
        kind.as_str(),
        "date" | "timestamp" | "timestamp without time zone" | "timestamptz" | "timestamp with time zone"
    ) {
        let value = text.strip_prefix('\'').unwrap_or(text);
        if matches!(value, "infinity" | "+infinity" | "-infinity") {
            return Some(value);
        }
    }
    None
}

fn duckdb_formula_safe_interval<'a>(text: &'a str, data_type: &str) -> Option<&'a str> {
    if !data_type.trim().eq_ignore_ascii_case("interval") {
        return None;
    }
    let value = text.strip_prefix('\'')?;
    if !valid_duckdb_interval_text(value) {
        return None;
    }
    Some(value)
}

fn valid_duckdb_interval_text(value: &str) -> bool {
    let mut fields = value.split_whitespace();
    let Some(months) = fields.next().and_then(|value| value.parse::<i32>().ok()) else {
        return false;
    };
    let Some(month_unit) = fields.next() else {
        return false;
    };
    let Some(days) = fields.next().and_then(|value| value.parse::<i32>().ok()) else {
        return false;
    };
    let Some(day_unit) = fields.next() else {
        return false;
    };
    let Some(microseconds) = fields.next().and_then(|value| value.parse::<i64>().ok()) else {
        return false;
    };
    let Some(microsecond_unit) = fields.next() else {
        return false;
    };
    fields.next().is_none()
        && month_unit == if months.unsigned_abs() == 1 { "month" } else { "months" }
        && day_unit == if days.unsigned_abs() == 1 { "day" } else { "days" }
        && microsecond_unit
            == if microseconds.unsigned_abs() == 1 {
                "microsecond"
            } else {
                "microseconds"
            }
}

fn sanitized_wide_integer_text<'a>(text: &'a str, data_type: &str) -> Option<&'a str> {
    let value = text.strip_prefix('\'')?;
    if !value.starts_with(['+', '-']) {
        return None;
    }
    if data_type.trim().eq_ignore_ascii_case("Int128") && value.parse::<i128>().is_ok() {
        return Some(value);
    }
    if data_type.trim().eq_ignore_ascii_case("UInt128") && value.parse::<u128>().is_ok() {
        return Some(value);
    }
    None
}

fn sanitized_decimal(text: &str) -> Option<Decimal> {
    Decimal::from_str_exact(text.strip_prefix('\'')?).ok()
}

fn wide_decimal_text<'a>(text: &'a str, data_type: &str) -> Option<&'a str> {
    let value = text.strip_prefix('\'').unwrap_or(text);
    if text.starts_with('\'') && !value.starts_with(['+', '-']) {
        return None;
    }
    let (precision, scale) = decimal_type_limits(data_type)?;
    if precision <= 28 && scale <= 28 {
        return None;
    }

    let unsigned = value.strip_prefix(['+', '-']).unwrap_or(value);
    let (integer, fraction) = unsigned.split_once('.').unwrap_or((unsigned, ""));
    if integer.is_empty() && fraction.is_empty()
        || !integer.bytes().all(|byte| byte.is_ascii_digit())
        || !fraction.bytes().all(|byte| byte.is_ascii_digit())
        || fraction.len() > scale
    {
        return None;
    }
    let significant_integer_digits = integer.trim_start_matches('0').len();
    if significant_integer_digits > precision.saturating_sub(scale) {
        return None;
    }
    Some(value)
}

fn decimal_type_limits(data_type: &str) -> Option<(usize, usize)> {
    let lowered = data_type.trim().to_ascii_lowercase();
    let base = lowered.split('(').next()?.trim();
    if !matches!(base, "decimal" | "numeric" | "dec") {
        return None;
    }
    let (arguments, suffix) = lowered.split_once('(')?.1.split_once(')')?;
    let mut saw_unsigned = false;
    let mut saw_zerofill = false;
    for modifier in suffix.split_whitespace() {
        match modifier {
            "unsigned" if !saw_unsigned => saw_unsigned = true,
            "zerofill" if !saw_zerofill => saw_zerofill = true,
            _ => return None,
        }
    }
    let mut parts = arguments.split(',').map(str::trim);
    let precision = parts.next()?.parse().ok()?;
    let scale = parts.next().map_or(Some(0), |part| part.parse().ok())?;
    if parts.next().is_some() || scale > precision {
        return None;
    }
    Some((precision, scale))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[path = "sqlite_affinity.rs"]
    mod sqlite_affinity_tests;

    #[path = "column_type_tests.rs"]
    mod column_type_tests;

    #[path = "temporal_contracts.rs"]
    mod temporal_contracts;

    fn column(name: &str, data_type: &str) -> ColumnInfo {
        ColumnInfo {
            name: name.to_owned(),
            data_type: data_type.to_owned(),
            nullable: true,
            primary_key: false,
            is_auto_increment: false,
            default_value: None,
            is_generated: false,
            comment: None,
            collation: None,
            enum_type: None,
            domain_type: None,
        }
    }

    #[test]
    fn value_contract_parser_preserves_boundaries_and_rejects_rounding() {
        let parse = |kind: ColumnKind| move |text: &str| parse_cell(text, kind).ok();
        crate::parser_contract::assert_numeric_parsers(
            parse(ColumnKind::Int),
            parse(ColumnKind::Decimal),
            parse(ColumnKind::Float),
        );
        for text in crate::parser_contract::corpus_texts("texts") {
            assert_eq!(parse_cell(&text, ColumnKind::Text).unwrap(), Value::Text(text.clone()));
        }
    }

    #[test]
    fn mysql_timestamp_csv_import_restores_the_utc_instant() {
        let options = CsvImportOptions::default();
        let mysql_timestamp = column("instant", "timestamp(6)");
        let expected: Value = Value::TimestampTz("2024-01-02T03:04:05.123456+00:00".parse().unwrap());
        assert_eq!(
            value_for("2024-01-02T03:04:05.123456+00:00", &mysql_timestamp, &options, "mysql"),
            Ok(expected.clone())
        );
        assert_eq!(
            value_for("2024-01-02 03:04:05.123456", &mysql_timestamp, &options, "mysql"),
            Ok(expected),
            "an offset-free MySQL timestamp CSV cell denotes its UTC-session wall time"
        );

        let mysql_datetime = column("local_at", "datetime(6)");
        assert!(value_for("2024-01-02T03:04:05.123456+00:00", &mysql_datetime, &options, "mysql").is_err());
        assert_eq!(
            value_for(
                "2024-01-02 03:04:05.123456",
                &column("local_at", "timestamp without time zone"),
                &options,
                "postgres"
            ),
            Ok(Value::DateTime(
                NaiveDate::from_ymd_opt(2024, 1, 2)
                    .unwrap()
                    .and_hms_micro_opt(3, 4, 5, 123_456)
                    .unwrap()
            )),
            "driver-aware MySQL handling must not change PostgreSQL naive timestamps"
        );
    }

    #[test]
    fn duckdb_interval_restores_only_formula_marked_canonical_text() {
        let options = CsvImportOptions::default();
        let interval = column("span", "INTERVAL");
        assert_eq!(
            value_for("'-1 month -2 days -3 microseconds", &interval, &options, "duckdb"),
            Ok(Value::Text("-1 month -2 days -3 microseconds".into()))
        );
        assert_eq!(
            value_for(
                "'-1 month -2 days -3 microseconds",
                &column("note", "TEXT"),
                &options,
                "duckdb"
            ),
            Ok(Value::Text("'-1 month -2 days -3 microseconds".into()))
        );
        assert_eq!(
            value_for("'-1 month 2 days", &interval, &options, "duckdb"),
            Ok(Value::Text("'-1 month 2 days".into()))
        );
        for malformed in [
            "'-1 months -2 days -3 microseconds",
            "'-1 month -2 day -3 microseconds",
            "'-1 month -2 days -3 microsecond",
        ] {
            assert_eq!(
                value_for(malformed, &interval, &options, "duckdb"),
                Ok(Value::Text(malformed.into())),
                "an invalid unit spelling must not lose its formula marker: {malformed}"
            );
        }
        assert_eq!(value_for("", &interval, &options, "duckdb"), Ok(Value::Null));
        let marked_options = CsvImportOptions {
            null_marker: "NULL".into(),
            ..options
        };
        assert_eq!(
            value_for("", &interval, &marked_options, "duckdb"),
            Err(CellError::NotAnInterval)
        );
    }

    #[test]
    fn postgres_array_csv_cells_remain_text_instead_of_being_parsed_as_scalars() {
        let columns = vec![column("value", "float8[]")];
        let row = vec!["{\"1.0000000000000002\",\"-0\",\"5e-324\",\"NaN\",\"Infinity\",\"-Infinity\",NULL}".into()];
        let values = row_to_values(&row, &[Some(0)], &columns, &CsvImportOptions::default(), 2)
            .expect("float8[] CSV cells remain exact text");

        assert_eq!(values, vec![Value::Text(row[0].clone())]);
    }

    #[test]
    fn value_contract_mssql_datetimeoffset_csv_cells_preserve_the_original_offset_and_scale() {
        let columns = vec![column("zoned", "datetimeoffset(7)")];
        let original = "2024-01-02 03:04:05.1234567 +05:30";
        let row = vec![original.to_owned()];
        let values = row_to_values(&row, &[Some(0)], &columns, &CsvImportOptions::default(), 2).unwrap();

        assert_eq!(values, vec![Value::Text(original.into())]);
    }

    #[test]
    fn value_contract_wide_decimal_csv_cells_remain_exact_text_when_decimal_cannot_hold_them() {
        let columns = vec![column("amount", "decimal(65,30)")];
        let original = "12345678901234567890123456789012345.123456789012345678901234567890";
        let values = row_to_values(
            &[original.to_owned()],
            &[Some(0)],
            &columns,
            &CsvImportOptions::default(),
            2,
        )
        .expect("a valid native DECIMAL value must not be rejected because Rust Decimal is narrower");

        assert_eq!(values, vec![Value::Text(original.into())]);
    }

    #[test]
    fn value_contract_wide_integer_decimal_csv_cells_use_declared_precision_for_text_fallback() {
        let columns = vec![column("amount", "decimal(65,0)")];
        let original = "12345678901234567890123456789012345678901234567890123456789012345";
        let values = row_to_values(
            &[original.to_owned()],
            &[Some(0)],
            &columns,
            &CsvImportOptions::default(),
            2,
        )
        .expect("65 integer digits must remain exact text beyond Rust Decimal's range");

        assert_eq!(values, vec![Value::Text(original.into())]);
    }

    #[test]
    fn declared_decimal_scale_can_equal_precision_when_all_digits_are_fractional() {
        let columns = vec![column("amount", "decimal(30,30)")];
        let original = format!("0.{}", "1".repeat(30));
        let values = row_to_values(
            std::slice::from_ref(&original),
            &[Some(0)],
            &columns,
            &CsvImportOptions::default(),
            2,
        )
        .expect("DECIMAL(30,30) can store thirty fractional digits and no integer digits");

        assert_eq!(values, vec![Value::Text(original)]);
    }

    #[test]
    fn wide_decimal_text_fallback_refuses_values_outside_declared_precision_and_scale() {
        let too_many_integer_digits = format!("{}.{}", "9".repeat(36), "1".repeat(30));
        let too_many_fractional_digits = format!("0.{}", "1".repeat(31));
        for (data_type, value) in [
            ("decimal(65,30)", too_many_integer_digits.as_str()),
            ("decimal(65,30)", too_many_fractional_digits.as_str()),
            (
                "decimal(65,30,1)",
                "12345678901234567890123456789012345.123456789012345678901234567890",
            ),
            ("decimal(30,31)", "0.1234567890123456789012345678901"),
        ] {
            let columns = vec![column("amount", data_type)];
            assert_eq!(
                row_to_values(
                    &[value.to_owned()],
                    &[Some(0)],
                    &columns,
                    &CsvImportOptions::default(),
                    2,
                )
                .unwrap_err()
                .reason,
                CellError::NotANumber,
                "out-of-range value or malformed precision metadata must be refused for {data_type}"
            );
        }

        assert_eq!(decimal_type_limits("decimal(65,30) garbage"), None);
        assert_eq!(decimal_type_limits("decimal(65,30) unsigned"), Some((65, 30)));
        assert_eq!(decimal_type_limits("decimal(65,30) unsigned zerofill"), Some((65, 30)));
        assert_eq!(decimal_type_limits("decimal(65,30) unsigned garbage"), None);
        assert_eq!(decimal_type_limits("decimal(65,30) unsigned unsigned"), None);
        assert_eq!(decimal_type_limits("decimal(65,30) zerofill zerofill"), None);
    }

    #[test]
    fn wide_decimal_text_fallback_rejects_malformed_numeric_tokens() {
        let columns = vec![column("amount", "decimal(65,30)")];
        for malformed in ["+", ".", "--1", "1e", "1.2.3", "1,000", "'--1"] {
            assert_eq!(
                row_to_values(
                    &[malformed.to_owned()],
                    &[Some(0)],
                    &columns,
                    &CsvImportOptions::default(),
                    2,
                )
                .unwrap_err()
                .reason,
                CellError::NotANumber,
                "malformed numeric cell must not use the exact-text fallback: {malformed:?}"
            );
        }
    }

    #[test]
    fn formula_safe_wide_decimal_import_removes_only_its_marker() {
        let columns = vec![column("amount", "decimal(65,30)")];
        let value = "-12345678901234567890123456789012345.123456789012345678901234567890";
        let imported = row_to_values(
            &[format!("'{value}")],
            &[Some(0)],
            &columns,
            &CsvImportOptions::default(),
            2,
        )
        .unwrap();

        assert_eq!(imported, vec![Value::Text(value.into())]);
    }

    #[test]
    fn clickhouse_wide_integer_csv_cells_remain_exact_text() {
        let columns = vec![column("signed", "Int128"), column("unsigned", "UInt128")];
        let row = vec![
            "-170141183460469231731687303715884105728".to_owned(),
            "340282366920938463463374607431768211455".to_owned(),
        ];
        let values = row_to_values(&row, &[Some(0), Some(1)], &columns, &CsvImportOptions::default(), 2)
            .expect("wide integer values remain text");

        assert_eq!(values, row.into_iter().map(Value::Text).collect::<Vec<_>>());
    }

    #[test]
    fn formula_marker_is_removed_only_from_valid_signed_wide_integer_cells() {
        let columns = vec![
            column("signed", "Int128"),
            column("unsigned", "UInt128"),
            column("invalid_unsigned", "UInt128"),
            column("overflow", "Int128"),
            column("invalid_signed", "Int128"),
            column("text", "String"),
        ];
        let signed_min = "-170141183460469231731687303715884105728";
        let unsigned_max = "340282366920938463463374607431768211455";
        let row = vec![
            format!("'{signed_min}"),
            format!("'+{unsigned_max}"),
            "'-1".into(),
            "'170141183460469231731687303715884105728".into(),
            "'-not-an-integer".into(),
            "'-170141183460469231731687303715884105728".into(),
        ];
        let values = row_to_values(
            &row,
            &[Some(0), Some(1), Some(2), Some(3), Some(4), Some(5)],
            &columns,
            &CsvImportOptions::default(),
            2,
        )
        .expect("valid wide integer formula prefixes are restored");

        assert_eq!(
            values,
            vec![
                Value::Text(signed_min.into()),
                Value::Text(format!("+{unsigned_max}")),
                Value::Text("'-1".into()),
                Value::Text("'170141183460469231731687303715884105728".into()),
                Value::Text("'-not-an-integer".into()),
                Value::Text("'-170141183460469231731687303715884105728".into()),
            ]
        );
    }

    #[test]
    fn value_contract_formula_safe_decimal_import_rejects_excess_precision() {
        let columns = vec![column("amount", "decimal")];
        for input in ["-0.12345678901234567890123456789", "-1.00000000000000000000000000001"] {
            for text in [input.to_owned(), format!("'{input}")] {
                let error = row_to_values(&[text], &[Some(0)], &columns, &CsvImportOptions::default(), 2)
                    .expect_err("excess precision must not be rounded");
                assert_eq!(error.reason, CellError::NotANumber);
                assert_eq!(error.line, 2);
                assert_eq!(error.column, "amount");
            }
        }
    }

    #[test]
    fn formula_marker_is_removed_from_negative_decimal_cells_only_for_decimal_columns() {
        let columns = vec![column("amount", "decimal"), column("text", "String")];
        let row = vec!["'-123.45".to_owned(), "'-123.45".to_owned()];
        let values = row_to_values(&row, &[Some(0), Some(1)], &columns, &CsvImportOptions::default(), 2)
            .expect("sanitized decimal is parsed while text keeps its formula marker");

        assert_eq!(values[0], Value::Decimal(Decimal::new(-12345, 2)));
        assert_eq!(values[1], Value::Text("'-123.45".into()));
    }

    #[test]
    fn value_contract_duckdb_csv_preserves_extended_calendar_values_exactly() {
        let options = CsvImportOptions::default();
        for (data_type, text) in [
            ("DATE", "1000000-02-29"),
            ("DATE", "+10000-01-01"),
            ("DATE", "0001-01-01 (BC)"),
            ("TIMESTAMP", "280000-02-29 12:34:56.123456"),
            ("TIMESTAMP", "+10000-01-01 12:34:56.123456"),
            ("TIMESTAMP", "0001-01-01 (BC) 12:34:56"),
            ("TIMESTAMP WITH TIME ZONE", "280000-02-29 12:34:56.123456+05:30"),
            ("TIMESTAMPTZ", "+10000-01-01 12:34:56.123456+00:00"),
            ("TIMESTAMPTZ", "0001-01-01 (BC) 12:34:56+00"),
        ] {
            let values = row_to_values_for_driver(
                &[text.into()],
                &[Some(0)],
                &[column("value", data_type)],
                &options,
                2,
                "duckdb",
            )
            .expect("valid extended DuckDB calendar value should remain bindable text");
            assert_eq!(values, vec![Value::Text(text.into())]);
        }
        for (data_type, text) in [
            ("DATE", "1000001-02-29"),
            ("TIMESTAMP", "280001-02-29 12:34:56"),
            ("TIMESTAMP", "280000-02-29 12:34:56.123456789"),
            ("TIMESTAMPTZ", "280000-02-29 12:34:56.123456789+00:00"),
            ("TIMESTAMPTZ", "280000-02-29 12:34:56+24:00"),
        ] {
            assert!(
                row_to_values_for_driver(
                    &[text.into()],
                    &[Some(0)],
                    &[column("value", data_type)],
                    &options,
                    2,
                    "duckdb",
                )
                .is_err(),
                "invalid {data_type} input was accepted: {text}"
            );
        }
    }

    #[test]
    fn an_unknown_type_is_read_as_text_rather_than_refused() {
        assert_eq!(column_kind("citext"), ColumnKind::Text);
        assert_eq!(column_kind("my_enum"), ColumnKind::Text);
    }

    #[test]
    fn a_field_that_does_not_fit_its_column_names_the_failure_without_its_contents() {
        let error = parse_cell("not a number", ColumnKind::Int).expect_err("refused");

        assert_eq!(error, CellError::NotAnInteger);
        assert!(!error.to_string().contains("not a number"));
    }

    #[test]
    fn a_row_error_names_the_line_and_column_and_carries_no_cell_text() {
        let columns = vec![column("id", "bigint")];

        let error = row_to_values(
            &["secret-value".to_owned()],
            &[Some(0)],
            &columns,
            &CsvImportOptions::default(),
            4,
        )
        .expect_err("refused");

        assert_eq!(error.line, 4);
        assert_eq!(error.column, "id");
        assert!(!error.to_string().contains("secret-value"));
    }

    #[test]
    fn a_mapped_field_is_parsed_into_the_columns_type() {
        let columns = vec![column("id", "bigint"), column("name", "text")];

        let values = row_to_values(
            &["7".to_owned(), "ada".to_owned()],
            &[Some(0), Some(1)],
            &columns,
            &CsvImportOptions::default(),
            2,
        )
        .expect("values");

        assert_eq!(values, vec![Value::Int(7), Value::Text("ada".to_owned())]);
    }

    #[test]
    fn an_unmapped_column_becomes_null_so_the_server_default_applies() {
        let columns = vec![column("id", "bigint"), column("name", "text")];

        let values = row_to_values(
            &["7".to_owned()],
            &[Some(0), None],
            &columns,
            &CsvImportOptions::default(),
            2,
        )
        .expect("values");

        assert_eq!(values[1], Value::Null);
    }

    #[test]
    fn an_empty_field_is_null_for_a_column_that_is_not_text() {
        let columns = vec![column("id", "bigint")];

        let values =
            row_to_values(&[String::new()], &[Some(0)], &columns, &CsvImportOptions::default(), 2).expect("values");

        assert_eq!(values[0], Value::Null);
    }

    #[test]
    fn an_empty_field_stays_an_empty_string_for_a_text_column() {
        let columns = vec![column("name", "text")];

        let values =
            row_to_values(&[String::new()], &[Some(0)], &columns, &CsvImportOptions::default(), 2).expect("values");

        assert_eq!(values[0], Value::Text(String::new()));
    }

    #[test]
    fn a_null_marker_the_user_set_is_null_even_for_text() {
        let options = CsvImportOptions {
            null_marker: "\\N".to_owned(),
            ..CsvImportOptions::default()
        };
        let columns = vec![column("name", "text")];

        let values = row_to_values(&["\\N".to_owned()], &[Some(0)], &columns, &options, 2).expect("values");

        assert_eq!(values[0], Value::Null);
    }

    #[test]
    fn the_temporal_types_parse_the_forms_an_export_writes() {
        assert!(matches!(parse_cell("2024-05-06", ColumnKind::Date), Ok(Value::Date(_))));
        assert!(matches!(parse_cell("13:45:01", ColumnKind::Time), Ok(Value::Time(_))));
        assert!(matches!(
            parse_cell("2024-05-06 13:45:01", ColumnKind::DateTime),
            Ok(Value::DateTime(_))
        ));
        assert!(matches!(
            parse_cell("2024-05-06T13:45:01Z", ColumnKind::TimestampTz),
            Ok(Value::TimestampTz(_))
        ));
    }

    #[test]
    fn booleans_read_the_spellings_the_engines_export() {
        assert_eq!(parse_cell("TRUE", ColumnKind::Bool), Ok(Value::Bool(true)));
        assert_eq!(parse_cell("f", ColumnKind::Bool), Ok(Value::Bool(false)));
        assert_eq!(parse_cell("maybe", ColumnKind::Bool), Err(CellError::NotABoolean));
    }

    #[test]
    fn binary_takes_hexadecimal_with_or_without_the_engine_prefix() {
        assert_eq!(
            parse_cell("0xDEad", ColumnKind::Bytes),
            Ok(Value::Bytes(vec![0xde, 0xad]))
        );
        assert_eq!(
            parse_cell("0XDEad", ColumnKind::Bytes),
            Ok(Value::Bytes(vec![0xde, 0xad]))
        );
        assert_eq!(
            parse_cell("beef", ColumnKind::Bytes),
            Ok(Value::Bytes(vec![0xbe, 0xef]))
        );
        assert_eq!(parse_cell("xyz", ColumnKind::Bytes), Err(CellError::NotBytes));
        assert_eq!(parse_cell("\\x", ColumnKind::Bytes), Ok(Value::Bytes(vec![])));
        assert_eq!(parse_cell("\\x00ff", ColumnKind::Bytes), Ok(Value::Bytes(vec![0, 255])));
        for text in ["\\x0", "\\xgg", "\\xé", "0x0", "0xgg"] {
            assert_eq!(parse_cell(text, ColumnKind::Bytes), Err(CellError::NotBytes));
        }
    }
}
