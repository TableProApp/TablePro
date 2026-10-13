use chrono::Timelike;

use crate::column::{ColumnKind, ColumnType};
use crate::value::{SqlDecimal, Value};

/// Full text of a value for export, at the precision the column
/// declares.
///
/// A `timestamp(6)` that holds `12:00:00.100000` reads back as
/// `12:00:00.1` from the value alone: the trailing zeros are not in the
/// number, they are in the column. The same goes for a
/// `numeric(38,10)` holding `1`. Export writes what the column says,
/// because that is what the server would print.
pub fn value_text(value: &Value, column: &ColumnType) -> Option<String> {
    kind_text(value, &column.kind)
}

pub(super) fn kind_text(value: &Value, kind: &ColumnKind) -> Option<String> {
    match value {
        Value::Time(time) => Some(time.format(second_digits(kind))),
        Value::TimeTz(time) => Some(format!(
            "{}{}",
            time.time.format(second_digits(kind)),
            offset_text(time.offset)
        )),
        Value::Timestamp(stamp) => temporal_text(stamp, |stamp| {
            format!(
                "{}{}",
                stamp.format("%Y-%m-%d %H:%M:%S"),
                fraction_text(stamp.nanosecond(), kind.fractional_digits())
            )
        }),
        Value::TimestampTz(stamp) => temporal_text(stamp, |stamp| {
            let stamp = stamp.to_datetime();
            format!(
                "{}{}{}",
                stamp.format("%Y-%m-%d %H:%M:%S"),
                fraction_text(stamp.nanosecond(), kind.fractional_digits()),
                stamp.format("%:z")
            )
        }),
        Value::Decimal(decimal) => Some(decimal_text(decimal, kind.decimal_scale())),
        Value::Array(values) => Some(array_text(values, Some(element_kind(kind)))),
        other => value_to_text(other),
    }
}

/// The kind each item of an array holds. A PostgreSQL `int4[][]` is
/// declared once for every dimension, so a kind that is not itself an
/// array passes down unchanged.
pub(super) fn element_kind(kind: &ColumnKind) -> &ColumnKind {
    match kind {
        ColumnKind::Array { element } => element,
        other => other,
    }
}

/// The digits a time type declares, in the width `SqlTime` formats at.
fn second_digits(kind: &ColumnKind) -> Option<u8> {
    kind.fractional_digits().map(|digits| digits.min(9))
}

/// The fractional second, at the digits the column declares.
///
/// With no declared precision the fraction is the one the value
/// carries, trimmed, because inventing digits would claim a precision
/// the column never promised.
fn fraction_text(nanos: u32, digits: Option<u8>) -> String {
    let nanos = nanos.min(999_999_999);
    let Some(digits) = digits else {
        return match nanos {
            0 => String::new(),
            _ => format!(".{}", format!("{nanos:09}").trim_end_matches('0')),
        };
    };
    if digits == 0 {
        return String::new();
    }
    let digits = usize::from(digits.min(9));
    let mut text = format!("{nanos:09}");
    text.truncate(digits);
    format!(".{text}")
}

/// A decimal padded out to the column's scale. A value wider than the
/// column declares keeps every digit it came with: the server sent it,
/// so it is not ours to round.
fn decimal_text(decimal: &SqlDecimal, scale: Option<u32>) -> String {
    let text = decimal.to_string();
    let Some(scale) = scale.filter(|_| decimal.is_finite()) else {
        return text;
    };
    let present = match text.split_once('.') {
        Some((_, fraction)) => fraction.len(),
        None => 0,
    };
    let scale = scale as usize;
    if present >= scale {
        return text;
    }
    let mut padded = text;
    if present == 0 {
        padded.push('.');
    }
    padded.extend(std::iter::repeat_n('0', scale - present));
    padded
}

/// Full text of a value for export. Never truncates. `None` for Null.
pub fn value_to_text(v: &Value) -> Option<String> {
    match v {
        Value::Null => None,
        Value::Bool(b) => Some(if *b { "true".to_string() } else { "false".to_string() }),
        Value::Int(i) => Some(i.to_string()),
        Value::UInt(i) => Some(i.to_string()),
        Value::WideInt(i) => Some(i.to_string()),
        // Shortest round-trip form at the value's own width: an f32
        // widened first prints `0.10000000149011612` for a `real`
        // holding 0.1, digits the column never held.
        Value::Float32(f) if f.is_finite() => Some(f.to_string()),
        Value::Float64(f) if f.is_finite() => Some(f.to_string()),
        Value::Float32(f) => Some(non_finite_text(f.is_nan(), f.is_sign_negative())),
        Value::Float64(f) => Some(non_finite_text(f.is_nan(), f.is_sign_negative())),
        // Full scale: trimming a trailing zero loses the precision
        // the column declared.
        Value::Decimal(d) => Some(d.to_string()),
        Value::Text(s) => Some(s.clone()),
        Value::Bytes(b) => Some(format!("0x{}", crate::hex::encode_lower(b))),
        Value::Uuid(u) => Some(u.to_string()),
        Value::Json(j) => Some(j.as_str().to_owned()),
        Value::Date(d) => temporal_text(d, |date| date.format("%Y-%m-%d").to_string()),
        // The fraction is kept as it came, never rounded to seconds.
        Value::Time(t) => Some(t.format(None)),
        Value::TimeTz(t) => Some(format!("{}{}", t.time.format(None), offset_text(t.offset))),
        Value::Timestamp(t) => temporal_text(t, |stamp| stamp.format("%Y-%m-%d %H:%M:%S%.f").to_string()),
        // The original offset, not UTC: the row said what zone it was
        // written in and the export says the same.
        Value::TimestampTz(t) => temporal_text(t, |stamp| {
            stamp.to_datetime().format("%Y-%m-%d %H:%M:%S%.f%:z").to_string()
        }),
        Value::Interval(i) => Some(i.to_string()),
        Value::Bits(b) => Some(b.to_string()),
        Value::Array(values) => Some(array_text(values, None)),
        Value::Other(other) => Some(other.text.clone()),
        // The driver could not read it, so there is no text to write.
        // The caller reports the cell rather than inventing one.
        Value::Undecodable(_) => None,
    }
}

fn non_finite_text(is_nan: bool, is_negative: bool) -> String {
    match (is_nan, is_negative) {
        (true, _) => "NaN",
        (false, true) => "-Infinity",
        (false, false) => "Infinity",
    }
    .to_owned()
}

/// An infinite date or timestamp has a keyword rather than a number.
fn temporal_text<T>(value: &crate::value::Temporal<T>, finite: impl Fn(&T) -> String) -> Option<String> {
    match value {
        crate::value::Temporal::Finite(inner) => Some(finite(inner)),
        crate::value::Temporal::Infinity => Some("infinity".to_owned()),
        crate::value::Temporal::NegInfinity => Some("-infinity".to_owned()),
    }
}

fn offset_text(offset: chrono::FixedOffset) -> String {
    let total = offset.local_minus_utc();
    let sign = if total < 0 { '-' } else { '+' };
    let minutes = total.abs() / 60;
    format!("{sign}{:02}:{:02}", minutes / 60, minutes % 60)
}

/// An array as JSON array text, which is the one spelling every engine
/// reads back. Each item is written at the precision its element kind
/// declares, when there is one, and an inner dimension stays an array
/// rather than becoming the string of one.
fn array_text(values: &[Value], element: Option<&ColumnKind>) -> String {
    let parts: Vec<String> = values
        .iter()
        .map(|value| match value {
            Value::Array(inner) => array_text(inner, element.map(element_kind)),
            other => match element.map_or_else(|| value_to_text(other), |kind| kind_text(other, kind)) {
                Some(text) => serde_json::Value::String(text).to_string(),
                None => "null".to_owned(),
            },
        })
        .collect();
    format!("[{}]", parts.join(","))
}

#[cfg(test)]
mod tests {
    use std::str::FromStr;

    use chrono::{NaiveDate, NaiveTime};
    use uuid::Uuid;

    use super::*;
    use crate::column::{ColumnKind, ReadForm, TemporalZone, TimeRange};
    use crate::value::{JsonText, SqlTime, Temporal};

    fn typed(name: &str, kind: ColumnKind) -> ColumnType {
        ColumnType {
            name: name.to_owned(),
            kind,
            catalog: None,
            dynamic_storage: false,
            read_form: ReadForm::Native,
        }
    }

    fn time(fractional_digits: Option<u8>) -> ColumnKind {
        ColumnKind::Time {
            fractional_digits,
            with_offset: false,
            range: TimeRange::TimeOfDay,
        }
    }

    fn stamp(fractional_digits: Option<u8>, zone: TemporalZone) -> ColumnKind {
        ColumnKind::Timestamp {
            fractional_digits,
            zone,
        }
    }

    fn decimal(precision: u32, scale: u32) -> ColumnKind {
        ColumnKind::Decimal {
            precision: Some(precision),
            scale: Some(scale),
        }
    }

    fn date(year: i32, month: u32, day: u32) -> Value {
        Value::Date(Temporal::Finite(
            NaiveDate::from_ymd_opt(year, month, day).expect("a date"),
        ))
    }

    fn json(text: &str) -> Value {
        Value::Json(JsonText::parse(text.to_owned()).expect("valid json"))
    }

    #[test]
    fn value_to_text_covers_every_variant() {
        assert_eq!(value_to_text(&Value::Null), None);
        assert_eq!(value_to_text(&Value::Bool(true)), Some("true".to_string()));
        assert_eq!(value_to_text(&Value::Bool(false)), Some("false".to_string()));
        assert_eq!(value_to_text(&Value::Int(42)), Some("42".to_string()));
        assert_eq!(value_to_text(&Value::UInt(u64::MAX)), Some(u64::MAX.to_string()));
        assert_eq!(value_to_text(&Value::Float64(1.5)), Some("1.5".to_string()));
        assert_eq!(value_to_text(&Value::Text("hi".into())), Some("hi".to_string()));
        assert_eq!(
            value_to_text(&Value::Bytes(vec![0xde, 0xad])),
            Some("0xdead".to_string())
        );
        assert_eq!(value_to_text(&date(2024, 1, 2)), Some("2024-01-02".to_string()));
        assert_eq!(
            value_to_text(&Value::Time(SqlTime::from_time_of_day(
                NaiveTime::from_hms_opt(13, 5, 9).expect("a time")
            ))),
            Some("13:05:09".to_string())
        );
        assert_eq!(
            value_to_text(&Value::Timestamp(Temporal::Finite(
                NaiveDate::from_ymd_opt(2024, 1, 2)
                    .expect("a date")
                    .and_hms_opt(13, 5, 9)
                    .expect("a time")
            ))),
            Some("2024-01-02 13:05:09".to_string())
        );
        assert_eq!(
            value_to_text(&Value::Decimal("12.30".parse().expect("a decimal"))),
            Some("12.30".to_string()),
            "the declared scale was trimmed"
        );
        let uuid = Uuid::from_str("550e8400-e29b-41d4-a716-446655440000").expect("a uuid");
        assert_eq!(value_to_text(&Value::Uuid(uuid)), Some(uuid.to_string()));
        assert_eq!(value_to_text(&json(r#"{"a":1}"#)), Some(r#"{"a":1}"#.to_string()));
    }

    #[test]
    fn value_to_text_keeps_fraction_offset_and_full_scale() {
        let time = SqlTime::new(false, 12, 0, 0, 123_456_000).expect("a time");
        assert_eq!(value_to_text(&Value::Time(time)), Some("12:00:00.123456".to_owned()));

        let stamp = chrono::DateTime::parse_from_rfc3339("2024-06-15T12:00:00+05:30").expect("a timestamp");
        assert_eq!(
            value_to_text(&Value::TimestampTz(Temporal::Finite(
                crate::value::OffsetTimestamp::from_datetime(stamp)
            ))),
            Some("2024-06-15 12:00:00+05:30".to_owned()),
            "the row's own offset was rewritten as UTC"
        );

        assert_eq!(
            value_to_text(&Value::Decimal("1.0000000000".parse().expect("a decimal"))),
            Some("1.0000000000".to_owned())
        );
    }

    #[test]
    fn value_to_text_names_the_non_finite_values() {
        assert_eq!(value_to_text(&Value::Float64(f64::NAN)), Some("NaN".to_owned()));
        assert_eq!(
            value_to_text(&Value::Float64(f64::NEG_INFINITY)),
            Some("-Infinity".to_owned())
        );
        assert_eq!(
            value_to_text(&Value::Date(Temporal::Infinity)),
            Some("infinity".to_owned())
        );
    }

    #[test]
    fn an_undecodable_value_has_no_text() {
        let undecodable = Value::Undecodable(Box::new(crate::value::UndecodedValue {
            type_name: "geography".to_owned(),
            reason: crate::value::UndecodableReason::UnsupportedType,
        }));

        assert_eq!(
            value_to_text(&undecodable),
            None,
            "a value the driver could not read was given a text form"
        );
    }

    #[test]
    fn value_text_timestamp_keeps_declared_microseconds() {
        let column = typed("timestamp(6)", stamp(Some(6), TemporalZone::Naive));
        let stamp = Value::Timestamp(Temporal::Finite(
            NaiveDate::from_ymd_opt(2024, 6, 15)
                .expect("a date")
                .and_hms_nano_opt(12, 0, 0, 100_000_000)
                .expect("a time"),
        ));

        assert_eq!(
            value_text(&stamp, &column).as_deref(),
            Some("2024-06-15 12:00:00.100000")
        );
    }

    #[test]
    fn value_text_time_precision_from_kind() {
        let value = Value::Time(SqlTime::new(false, 12, 0, 0, 123_456_000).expect("a time"));

        assert_eq!(
            value_text(&value, &typed("time(3)", time(Some(3)))).as_deref(),
            Some("12:00:00.123")
        );
        assert_eq!(
            value_text(&value, &typed("time(0)", time(Some(0)))).as_deref(),
            Some("12:00:00")
        );
        assert_eq!(
            value_text(&value, &typed("time", time(None))).as_deref(),
            Some("12:00:00.123456"),
            "a column with no declared precision kept the value's own fraction"
        );
    }

    #[test]
    fn value_text_timestamptz_keeps_offset() {
        let column = typed("timestamptz(3)", stamp(Some(3), TemporalZone::Offset));
        let stamp = chrono::DateTime::parse_from_rfc3339("2024-06-15T12:00:00.5+05:30").expect("a timestamp");
        let value = Value::TimestampTz(Temporal::Finite(crate::value::OffsetTimestamp::from_datetime(stamp)));

        assert_eq!(
            value_text(&value, &column).as_deref(),
            Some("2024-06-15 12:00:00.500+05:30")
        );
    }

    #[test]
    fn value_text_numeric_38_10_full_scale() {
        let column = typed("numeric(38,10)", decimal(38, 10));

        assert_eq!(
            value_text(&Value::Decimal("1".parse().expect("a decimal")), &column).as_deref(),
            Some("1.0000000000")
        );
        assert_eq!(
            value_text(&Value::Decimal("1.5".parse().expect("a decimal")), &column).as_deref(),
            Some("1.5000000000")
        );
    }

    #[test]
    fn a_decimal_wider_than_its_column_keeps_every_digit() {
        let column = typed("numeric(10,2)", decimal(10, 2));
        let value = Value::Decimal("1.23456".parse().expect("a decimal"));

        assert_eq!(
            value_text(&value, &column).as_deref(),
            Some("1.23456"),
            "the server's own digits were rounded away"
        );
    }

    #[test]
    fn a_real_prints_its_own_shortest_digits() {
        for real in [0.1_f32, 1.1, -3.3, 16_777_216.0] {
            let text = value_to_text(&Value::Float32(real)).expect("a real has text");

            assert_eq!(text, real.to_string(), "{real} was widened before printing");
            assert_eq!(text.parse::<f32>().ok(), Some(real), "{text} does not read back");
        }
        assert_eq!(
            value_to_text(&Value::Float32(f32::NEG_INFINITY)).as_deref(),
            Some("-Infinity")
        );
    }

    #[test]
    fn array_items_take_the_precision_of_their_element() {
        let column = typed(
            "timestamp(6)[]",
            ColumnKind::Array {
                element: Box::new(stamp(Some(6), TemporalZone::Naive)),
            },
        );
        let value = Value::Array(vec![
            Value::Timestamp(Temporal::Finite(
                NaiveDate::from_ymd_opt(2024, 6, 15)
                    .expect("a date")
                    .and_hms_nano_opt(12, 0, 0, 100_000_000)
                    .expect("a time"),
            )),
            Value::Null,
        ]);

        assert_eq!(
            value_text(&value, &column).as_deref(),
            Some(r#"["2024-06-15 12:00:00.100000",null]"#)
        );
    }

    #[test]
    fn an_inner_dimension_stays_an_array() {
        let column = typed(
            "numeric(5,2)[]",
            ColumnKind::Array {
                element: Box::new(decimal(5, 2)),
            },
        );
        let value = Value::Array(vec![
            Value::Array(vec![Value::Decimal("1".parse().expect("a decimal"))]),
            Value::Array(vec![Value::Decimal("2.5".parse().expect("a decimal"))]),
        ]);

        assert_eq!(
            value_text(&value, &column).as_deref(),
            Some(r#"[["1.00"],["2.50"]]"#),
            "a row of a two-dimensional array was written as a string"
        );
        assert_eq!(
            value_to_text(&value).as_deref(),
            Some(r#"[["1"],["2.5"]]"#),
            "without a column, a row of the array was written as a string"
        );
    }
}
