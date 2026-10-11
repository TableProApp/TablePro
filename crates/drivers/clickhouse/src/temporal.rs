use tablepro_core::Value;

pub(super) fn parse_datetime(raw: &serde_json::Value, type_name: &str) -> Value {
    let Some(text) = raw.as_str() else {
        return fallback_text(raw);
    };
    if let Ok(datetime) = chrono::DateTime::parse_from_rfc3339(text) {
        return Value::TimestampTz(datetime.with_timezone(&chrono::Utc));
    }
    // `%.f` also matches a whole-second timestamp, so one pattern covers
    // both `DateTime` and every `DateTime64` precision.
    let Ok(datetime) = chrono::NaiveDateTime::parse_from_str(text, "%Y-%m-%d %H:%M:%S%.f") else {
        return Value::Text(text.to_string());
    };
    let Some(timezone_name) = datetime_timezone(type_name) else {
        return Value::DateTime(datetime);
    };
    let Ok(timezone) = jiff::tz::TimeZone::get(timezone_name) else {
        return Value::Undecodable(format!("unknown ClickHouse timezone in type {type_name}"));
    };
    let Ok(civil) = jiff::civil::DateTime::strptime("%Y-%m-%d %H:%M:%S%.f", text) else {
        return Value::Undecodable(format!("invalid ClickHouse timestamp for timezone {type_name}"));
    };
    let Ok(zoned) = timezone.to_ambiguous_zoned(civil).unambiguous() else {
        return Value::Undecodable(format!("ambiguous or nonexistent local time in {type_name}"));
    };
    let timestamp = zoned.timestamp();
    let total_nanos = i128::from(timestamp.as_second()) * 1_000_000_000 + i128::from(timestamp.subsec_nanosecond());
    let seconds = total_nanos.div_euclid(1_000_000_000);
    let subsec_nanos = total_nanos.rem_euclid(1_000_000_000) as u32;
    let Ok(seconds) = i64::try_from(seconds) else {
        return Value::Undecodable(format!("ClickHouse instant outside supported range in {type_name}"));
    };
    chrono::DateTime::<chrono::Utc>::from_timestamp(seconds, subsec_nanos)
        .map(Value::TimestampTz)
        .unwrap_or_else(|| Value::Undecodable(format!("ClickHouse instant outside supported range in {type_name}")))
}

fn datetime_timezone(type_name: &str) -> Option<&str> {
    let mut inner = type_name.trim();
    while let Some(unwrapped) = unwrap_type(inner, "LowCardinality").or_else(|| unwrap_type(inner, "Nullable")) {
        if unwrapped.len() >= inner.len() {
            return None;
        }
        inner = unwrapped;
    }
    let (name, arguments) = inner.split_once('(')?;
    let arguments = arguments.strip_suffix(')')?.trim();
    let zone = match name.trim() {
        "DateTime" => arguments,
        "DateTime64" => arguments.split_once(',')?.1.trim(),
        _ => return None,
    };
    zone.strip_prefix('\'')?.strip_suffix('\'')
}

fn unwrap_type<'a>(type_name: &'a str, wrapper: &str) -> Option<&'a str> {
    type_name
        .strip_prefix(wrapper)?
        .strip_prefix('(')?
        .strip_suffix(')')
        .map(str::trim)
}

fn fallback_text(raw: &serde_json::Value) -> Value {
    match raw.as_str() {
        Some(text) => Value::Text(text.to_string()),
        None => Value::Text(raw.to_string()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn datetime_timezone_is_read_from_wrapped_type_metadata() {
        assert_eq!(datetime_timezone("DateTime('UTC')"), Some("UTC"));
        assert_eq!(datetime_timezone("DateTime64(6, 'Asia/Tokyo')"), Some("Asia/Tokyo"));
        assert_eq!(
            datetime_timezone("LowCardinality(Nullable(DateTime64(9, 'Europe/Vienna')))").unwrap(),
            "Europe/Vienna"
        );
        assert_eq!(datetime_timezone("DateTime64(3)"), None);
        assert_eq!(datetime_timezone("Date"), None);
    }

    #[test]
    fn named_datetime_zones_decode_instants_and_refuse_dst_ambiguity() {
        assert_eq!(
            parse_datetime(
                &serde_json::json!("2026-09-27 12:34:56.123456"),
                "DateTime64(6, 'Asia/Tokyo')",
            ),
            Value::TimestampTz(
                chrono::DateTime::parse_from_rfc3339("2026-09-27T03:34:56.123456Z")
                    .unwrap()
                    .to_utc()
            )
        );
        for (text, type_name, expected) in [
            (
                "2024-11-03 01:30:00",
                "DateTime('America/New_York')",
                "ambiguous or nonexistent",
            ),
            (
                "2024-03-10 02:30:00",
                "DateTime('America/New_York')",
                "ambiguous or nonexistent",
            ),
            (
                "2024-04-07 01:45:00",
                "DateTime('Australia/Lord_Howe')",
                "ambiguous or nonexistent",
            ),
            (
                "2024-01-01 12:00:00",
                "DateTime('Not/A_Real_Zone')",
                "unknown ClickHouse timezone",
            ),
        ] {
            assert!(matches!(
                parse_datetime(&serde_json::json!(text), type_name),
                Value::Undecodable(message) if message.contains(expected)
            ));
        }
    }
}
