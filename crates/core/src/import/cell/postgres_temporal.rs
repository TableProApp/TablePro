use chrono::{NaiveTime, Timelike};

use super::{duckdb_extended_date, duckdb_extended_timestamptz_nanos};

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
