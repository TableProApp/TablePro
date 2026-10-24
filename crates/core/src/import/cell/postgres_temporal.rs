use chrono::{DateTime, Datelike, NaiveTime, Timelike, Utc};

use super::{ColumnKind, Value, duckdb_extended_date, duckdb_extended_timestamptz_nanos, parse_datetime};

pub(super) fn import_override(text: &str, data_type: &str, kind: ColumnKind) -> Option<Value> {
    if let Some(value) = parse_extended(text, data_type) {
        return Some(Value::Text(value));
    }
    if let Some(value) = text_temporal(text, data_type) {
        return Some(Value::Text(value.to_owned()));
    }
    if kind != ColumnKind::TimestampTz {
        return None;
    }
    let text = text.trim();
    if let Ok(parsed) = DateTime::parse_from_rfc3339(text) {
        let value = Value::TimestampTz(parsed.with_timezone(&Utc));
        return if needs_text(&value) {
            crate::sql_literal::postgres_temporal_text(&value).map(Value::Text)
        } else {
            Some(value)
        };
    }
    parse_datetime(text).ok().map(|_| Value::Text(text.to_owned()))
}

pub(super) fn needs_text(value: &Value) -> bool {
    let year = match value {
        Value::Date(value) => value.year(),
        Value::DateTime(value) => value.year(),
        Value::TimestampTz(value) => value.year(),
        _ => return false,
    };
    !(1..=9999).contains(&year)
}

fn text_temporal<'a>(text: &'a str, data_type: &str) -> Option<&'a str> {
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

pub(super) fn parse_extended(text: &str, data_type: &str) -> Option<String> {
    let kind = data_type.trim().to_ascii_lowercase();
    let value = text.strip_prefix('\'').unwrap_or(text);
    let (value, bc) = value.strip_suffix(" BC").map_or((value, false), |value| (value, true));
    let canonical = || {
        let mut value = value.strip_prefix('+').unwrap_or(value).replace('T', " ");
        if bc {
            value.push_str(" BC");
        }
        value
    };
    if kind == "date" {
        let value = value.strip_prefix('+').unwrap_or(value);
        let date = if bc { format!("{value} (BC)") } else { value.to_owned() };
        return duckdb_extended_date(&date).then(canonical);
    }
    if matches!(kind.as_str(), "timestamptz" | "timestamp with time zone") {
        let value_for_validation = if bc {
            let (date, time) = value.split_once(' ').or_else(|| value.split_once('T'))?;
            format!("{date} (BC) {time}")
        } else {
            value.to_owned()
        };
        return duckdb_extended_timestamptz_nanos(&value_for_validation)
            .filter(|nanos| nanos % 1_000 == 0)
            .map(|_| canonical());
    }
    if !matches!(kind.as_str(), "timestamp" | "timestamp without time zone") {
        return None;
    }
    let (date, time) = value.split_once(' ').or_else(|| value.split_once('T'))?;
    let date = if bc { format!("{date} (BC)") } else { date.to_owned() };
    if !duckdb_extended_date(&date) {
        return None;
    }
    let time = NaiveTime::parse_from_str(time, "%H:%M:%S%.f")
        .or_else(|_| NaiveTime::parse_from_str(time, "%H:%M"))
        .ok()?;
    (time.nanosecond() % 1_000 == 0).then(canonical)
}
