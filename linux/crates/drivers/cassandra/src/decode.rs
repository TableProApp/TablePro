//! A CQL value as the app holds it.
//!
//! Every value is read through scylla's `CqlValue`, which keeps each
//! type whole: a varint or a decimal of any length, a time to the
//! nanosecond. Where the app's own value would lose part of one, the
//! value is kept as the server's text instead, or marked unreadable so
//! it is never written back changed.

use std::net::IpAddr;

use chrono::{DateTime, Days, NaiveDate, Utc};
use num_bigint::BigInt;
use scylla::value::{CqlDate, CqlDecimal, CqlDuration, CqlTime, CqlTimestamp, CqlValue, CqlVarint};
use tablepro_core::Value;
use tablepro_core::sql_syntax::SqlGrammar;
use tablepro_core::value::{
    OffsetTimestamp, OtherValue, SqlDecimal, SqlInterval, SqlTime, Temporal, UndecodableReason, UndecodedValue,
};

const NANOS_PER_MICRO: i64 = 1_000;

/// `value` read off the wire for a column whose type the server named
/// `type_name`.
pub(crate) fn decode(value: Option<CqlValue>, type_name: &str) -> Value {
    match value {
        None => Value::Null,
        Some(value) => decode_value(value, type_name),
    }
}

fn decode_value(value: CqlValue, type_name: &str) -> Value {
    match value {
        CqlValue::Ascii(text) | CqlValue::Text(text) => Value::Text(text),
        CqlValue::Boolean(flag) => Value::Bool(flag),
        CqlValue::Blob(bytes) => Value::Bytes(bytes),
        CqlValue::Counter(counter) => Value::Int(counter.0),
        CqlValue::BigInt(number) => Value::Int(number),
        CqlValue::Int(number) => Value::Int(i64::from(number)),
        CqlValue::SmallInt(number) => Value::Int(i64::from(number)),
        CqlValue::TinyInt(number) => Value::Int(i64::from(number)),
        CqlValue::Varint(varint) => varint_value(&varint, type_name),
        CqlValue::Decimal(decimal) => decimal_value(&decimal, type_name),
        CqlValue::Float(number) => Value::Float32(number),
        CqlValue::Double(number) => Value::Float64(number),
        CqlValue::Uuid(uuid) => Value::Uuid(uuid),
        CqlValue::Timeuuid(uuid) => Value::Uuid(uuid.into()),
        CqlValue::Timestamp(timestamp) => timestamp_value(timestamp, type_name),
        CqlValue::Date(date) => date_value(date, type_name),
        CqlValue::Time(time) => time_value(time, type_name),
        CqlValue::Duration(duration) => duration_value(duration, type_name),
        CqlValue::Inet(address) => other(type_name, address.to_string()),
        CqlValue::List(items) | CqlValue::Set(items) | CqlValue::Vector(items) => {
            Value::Array(items.into_iter().map(|item| decode_value(item, type_name)).collect())
        }
        CqlValue::Tuple(items) => Value::Array(items.into_iter().map(|item| decode(item, type_name)).collect()),
        map @ (CqlValue::Map(_) | CqlValue::UserDefinedType { .. }) => match literal(&map) {
            Some(text) => other(type_name, text),
            None => undecodable(type_name, UndecodableReason::InvalidEncoding),
        },
        // A zero-length value for a type that has none, which old
        // clients could write; it is neither NULL nor a value.
        CqlValue::Empty => undecodable(type_name, UndecodableReason::InvalidEncoding),
        _ => undecodable(type_name, UndecodableReason::UnsupportedType),
    }
}

fn other(type_name: &str, text: String) -> Value {
    Value::Other(Box::new(OtherValue {
        type_name: type_name.to_owned(),
        text,
    }))
}

fn undecodable(type_name: &str, reason: UndecodableReason) -> Value {
    Value::Undecodable(Box::new(UndecodedValue {
        type_name: type_name.to_owned(),
        reason,
    }))
}

fn varint_value(varint: &CqlVarint, type_name: &str) -> Value {
    let number = BigInt::from_signed_bytes_be(varint.as_signed_bytes_be_slice());
    let digits = number.magnitude().to_string();
    match SqlDecimal::from_parts(number.sign() == num_bigint::Sign::Minus, &digits, 0) {
        Ok(decimal) => Value::Decimal(decimal),
        Err(_) => undecodable(type_name, UndecodableReason::OutOfRange),
    }
}

/// A negative scale multiplies by ten to its magnitude, so it becomes
/// trailing zeros at scale 0.
fn decimal_value(decimal: &CqlDecimal, type_name: &str) -> Value {
    let (bytes, scale) = decimal.as_signed_be_bytes_slice_and_exponent();
    let unscaled = BigInt::from_signed_bytes_be(bytes);
    let negative = unscaled.sign() == num_bigint::Sign::Minus;
    let mut digits = unscaled.magnitude().to_string();
    let scale = match u32::try_from(scale) {
        Ok(scale) => scale,
        Err(_) => {
            let zeros = scale.unsigned_abs();
            if zeros > SqlDecimal::MAX_INTEGER_DIGITS {
                return undecodable(type_name, UndecodableReason::OutOfRange);
            }
            if digits != "0" {
                digits.extend(std::iter::repeat_n('0', zeros as usize));
            }
            0
        }
    };
    match SqlDecimal::from_parts(negative, &digits, scale) {
        Ok(decimal) => Value::Decimal(decimal),
        Err(_) => undecodable(type_name, UndecodableReason::OutOfRange),
    }
}

/// An instant in milliseconds, shown in UTC.
fn timestamp_value(timestamp: CqlTimestamp, type_name: &str) -> Value {
    match DateTime::<Utc>::from_timestamp_millis(timestamp.0) {
        Some(instant) => Value::TimestampTz(Temporal::Finite(OffsetTimestamp::from_datetime(instant.fixed_offset()))),
        None => undecodable(type_name, UndecodableReason::OutOfRange),
    }
}

/// Days counted from 2^31 days before the Unix epoch.
fn date_value(date: CqlDate, type_name: &str) -> Value {
    let days = i64::from(date.0) - (1_i64 << 31);
    let epoch = NaiveDate::from_ymd_opt(1970, 1, 1);
    let day = epoch.and_then(|epoch| match u64::try_from(days) {
        Ok(after) => epoch.checked_add_days(Days::new(after)),
        Err(_) => epoch.checked_sub_days(Days::new(days.unsigned_abs())),
    });
    match day {
        Some(day) => Value::Date(Temporal::Finite(day)),
        None => undecodable(type_name, UndecodableReason::OutOfRange),
    }
}

fn time_value(time: CqlTime, type_name: &str) -> Value {
    let nanos = time.0;
    let seconds = nanos.div_euclid(1_000_000_000);
    let fraction = u32::try_from(nanos.rem_euclid(1_000_000_000)).unwrap_or(0);
    let parts = (
        u32::try_from(seconds / 3_600),
        u8::try_from(seconds / 60 % 60),
        u8::try_from(seconds % 60),
    );
    match parts {
        (Ok(hours), Ok(minutes), Ok(seconds)) if nanos >= 0 && hours < 24 => {
            match SqlTime::new(false, hours, minutes, seconds, fraction) {
                Ok(time) => Value::Time(time),
                Err(_) => undecodable(type_name, UndecodableReason::OutOfRange),
            }
        }
        _ => undecodable(type_name, UndecodableReason::OutOfRange),
    }
}

/// An interval holds microseconds, so a duration with a finer part is
/// kept as the server's own spelling.
fn duration_value(duration: CqlDuration, type_name: &str) -> Value {
    match duration.nanoseconds % NANOS_PER_MICRO {
        0 => Value::Interval(SqlInterval {
            months: duration.months,
            days: duration.days,
            microseconds: duration.nanoseconds / NANOS_PER_MICRO,
        }),
        _ => other(type_name, duration_literal(duration)),
    }
}

/// CQL's own duration spelling, as `1mo2d3h4m5s6ms7us8ns`.
pub(crate) fn duration_literal(duration: CqlDuration) -> String {
    let negative = duration.months < 0 || duration.days < 0 || duration.nanoseconds < 0;
    let mut text = String::from(if negative { "-" } else { "" });
    let months = duration.months.unsigned_abs();
    let mut push = |amount: u64, unit: &str| {
        if amount != 0 {
            text.push_str(&format!("{amount}{unit}"));
        }
    };
    push(u64::from(months / 12), "y");
    push(u64::from(months % 12), "mo");
    push(u64::from(duration.days.unsigned_abs()), "d");
    let mut nanos = duration.nanoseconds.unsigned_abs();
    for (unit, size) in [
        ("h", 3_600_000_000_000),
        ("m", 60_000_000_000),
        ("s", 1_000_000_000),
        ("ms", 1_000_000),
        ("us", 1_000),
        ("ns", 1),
    ] {
        push(nanos / size, unit);
        nanos %= size;
    }
    if text.is_empty() || text == "-" {
        return "0s".to_owned();
    }
    text
}

/// `value` as a CQL literal, for the text of a value the app holds only
/// as text: a map or a user-defined type, and what they contain. `None`
/// for a value no literal spells, so the composite reads as unreadable
/// rather than as text that would write something else back.
pub(crate) fn literal(value: &CqlValue) -> Option<String> {
    Some(match value {
        CqlValue::Ascii(text) | CqlValue::Text(text) => quoted(text),
        CqlValue::Boolean(flag) => flag.to_string(),
        CqlValue::Blob(bytes) => blob_literal(bytes),
        CqlValue::Counter(counter) => counter.0.to_string(),
        CqlValue::BigInt(number) => number.to_string(),
        CqlValue::Int(number) => number.to_string(),
        CqlValue::SmallInt(number) => number.to_string(),
        CqlValue::TinyInt(number) => number.to_string(),
        CqlValue::Varint(varint) => BigInt::from_signed_bytes_be(varint.as_signed_bytes_be_slice()).to_string(),
        CqlValue::Decimal(decimal) => decimal_literal(decimal),
        CqlValue::Float(number) => float_literal(f64::from(*number)),
        CqlValue::Double(number) => float_literal(*number),
        CqlValue::Uuid(uuid) => uuid.to_string(),
        CqlValue::Timeuuid(uuid) => uuid.to_string(),
        CqlValue::Inet(address) => quoted(&address_text(address)),
        CqlValue::Timestamp(timestamp) => match DateTime::<Utc>::from_timestamp_millis(timestamp.0) {
            Some(instant) => quoted(&instant.format("%Y-%m-%d %H:%M:%S%.3fZ").to_string()),
            None => timestamp.0.to_string(),
        },
        CqlValue::Date(date) => match date_value(*date, "date") {
            Value::Date(Temporal::Finite(day)) => quoted(&day.to_string()),
            _ => date.0.to_string(),
        },
        CqlValue::Time(time) => match time_value(*time, "time") {
            Value::Time(time) => quoted(&time.format(Some(9))),
            _ => time.0.to_string(),
        },
        CqlValue::Duration(duration) => duration_literal(*duration),
        CqlValue::List(items) | CqlValue::Vector(items) => format!("[{}]", joined(items.iter().map(literal))?),
        CqlValue::Set(items) => format!("{{{}}}", joined(items.iter().map(literal))?),
        CqlValue::Map(pairs) => format!(
            "{{{}}}",
            joined(
                pairs
                    .iter()
                    .map(|(key, value)| Some(format!("{}: {}", literal(key)?, literal(value)?)))
            )?
        ),
        CqlValue::Tuple(items) => format!("({})", joined(items.iter().map(optional_literal))?),
        CqlValue::UserDefinedType { fields, .. } => format!(
            "{{{}}}",
            joined(fields.iter().map(|(name, value)| Some(format!(
                "{}: {}",
                field_name(name),
                optional_literal(value)?
            ))))?
        ),
        _ => return None,
    })
}

/// A decimal as its unscaled digits and exponent, which CQL reads back
/// whatever the scale, beyond what the app's own decimal holds.
fn decimal_literal(decimal: &CqlDecimal) -> String {
    match decimal_value(decimal, "decimal") {
        Value::Decimal(decimal) => decimal.to_string(),
        _ => {
            let (bytes, scale) = decimal.as_signed_be_bytes_slice_and_exponent();
            let exponent = -i64::from(scale);
            format!("{}E{exponent}", BigInt::from_signed_bytes_be(bytes))
        }
    }
}

fn optional_literal(value: &Option<CqlValue>) -> Option<String> {
    value.as_ref().map_or_else(|| Some("null".to_owned()), literal)
}

fn joined(items: impl Iterator<Item = Option<String>>) -> Option<String> {
    Some(items.collect::<Option<Vec<_>>>()?.join(", "))
}

pub(crate) fn quoted(text: &str) -> String {
    format!("'{}'", text.replace('\'', "''"))
}

pub(crate) fn blob_literal(bytes: &[u8]) -> String {
    let mut text = String::with_capacity(2 + bytes.len() * 2);
    text.push_str("0x");
    for byte in bytes {
        text.push_str(&format!("{byte:02x}"));
    }
    text
}

/// NaN and the infinities are words in CQL.
pub(crate) fn float_literal(number: f64) -> String {
    if number.is_nan() {
        "NaN".to_owned()
    } else if number.is_infinite() {
        if number < 0.0 { "-Infinity" } else { "Infinity" }.to_owned()
    } else {
        format!("{number:?}")
    }
}

fn address_text(address: &IpAddr) -> String {
    address.to_string()
}

/// A field name bare where CQL reads it back as the same name: not a
/// reserved word, no capital to fold.
fn field_name(name: &str) -> String {
    match SqlGrammar::Cql.is_bare_identifier(name) {
        true => name.to_owned(),
        false => format!("\"{}\"", name.replace('"', "\"\"")),
    }
}

#[cfg(test)]
mod tests {
    use scylla::value::Counter;
    use uuid::Uuid;

    use super::*;

    #[test]
    fn integers_of_every_width_read_as_integers() {
        assert_eq!(decode(Some(CqlValue::TinyInt(-8)), "tinyint"), Value::Int(-8));
        assert_eq!(decode(Some(CqlValue::Counter(Counter(9))), "counter"), Value::Int(9));
        assert_eq!(decode(None, "int"), Value::Null);
    }

    #[test]
    fn a_varint_of_any_length_reads_whole() {
        let digits = "123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890";
        let number: BigInt = digits.parse().unwrap();
        let varint = CqlVarint::from_signed_bytes_be((-number).to_signed_bytes_be());

        assert_eq!(
            decode(Some(CqlValue::Varint(varint)), "varint"),
            Value::Decimal(format!("-{digits}").parse().unwrap())
        );
    }

    #[test]
    fn a_decimal_keeps_its_scale_and_a_negative_scale_becomes_zeros() {
        let decimal = |unscaled: i64, scale: i32| {
            CqlValue::Decimal(CqlDecimal::from_signed_be_bytes_and_exponent(
                BigInt::from(unscaled).to_signed_bytes_be(),
                scale,
            ))
        };

        assert_eq!(
            decode(Some(decimal(-12_345, 3)), "decimal"),
            Value::Decimal("-12.345".parse().unwrap())
        );
        assert_eq!(
            decode(Some(decimal(12, -2)), "decimal"),
            Value::Decimal("1200".parse().unwrap())
        );
        assert_eq!(
            decode(Some(decimal(0, -2)), "decimal"),
            Value::Decimal("0".parse().unwrap())
        );
    }

    #[test]
    fn dates_times_and_instants_read_at_their_extremes() {
        let epoch_day = CqlDate(1 << 31);
        assert_eq!(
            decode(Some(CqlValue::Date(epoch_day)), "date"),
            Value::Date(Temporal::Finite(NaiveDate::from_ymd_opt(1970, 1, 1).unwrap()))
        );
        assert!(matches!(
            decode(Some(CqlValue::Date(CqlDate(0))), "date"),
            Value::Undecodable(_)
        ));
        let time = decode(Some(CqlValue::Time(CqlTime(86_399_999_999_999))), "time");
        assert_eq!(time, Value::Time(SqlTime::new(false, 23, 59, 59, 999_999_999).unwrap()));
        let instant = decode(Some(CqlValue::Timestamp(CqlTimestamp(-1))), "timestamp");
        let Value::TimestampTz(Temporal::Finite(instant)) = instant else {
            panic!("{instant:?}");
        };
        assert_eq!(instant.to_string(), "1969-12-31T23:59:59.999+00:00");
    }

    #[test]
    fn a_duration_finer_than_a_microsecond_keeps_its_cql_spelling() {
        let exact = CqlDuration {
            months: 14,
            days: 3,
            nanoseconds: 3_600_000_001_000,
        };
        assert_eq!(
            decode(Some(CqlValue::Duration(exact)), "duration"),
            Value::Interval(SqlInterval {
                months: 14,
                days: 3,
                microseconds: 3_600_000_001
            })
        );
        let fine = CqlDuration {
            months: 0,
            days: 0,
            nanoseconds: 1_000_000_007,
        };
        assert_eq!(
            decode(Some(CqlValue::Duration(fine)), "duration"),
            other("duration", "1s7ns".to_owned())
        );
        assert_eq!(duration_literal(exact), "1y2mo3d1h1us");
    }

    #[test]
    fn collections_read_as_arrays_and_maps_as_cql_text() {
        let list = CqlValue::List(vec![CqlValue::Int(1), CqlValue::Int(2)]);
        assert_eq!(
            decode(Some(list), "list<int>"),
            Value::Array(vec![Value::Int(1), Value::Int(2)])
        );
        let map = CqlValue::Map(vec![(CqlValue::Text("it's".to_owned()), CqlValue::Uuid(Uuid::nil()))]);
        assert_eq!(
            decode(Some(map), "map<text, uuid>"),
            other(
                "map<text, uuid>",
                "{'it''s': 00000000-0000-0000-0000-000000000000}".to_owned()
            )
        );
        let tuple = CqlValue::Tuple(vec![Some(CqlValue::Int(1)), None]);
        assert_eq!(
            decode(Some(tuple), "tuple<int, text>"),
            Value::Array(vec![Value::Int(1), Value::Null])
        );
    }

    #[test]
    fn a_composite_keeps_a_decimal_past_the_apps_range_and_refuses_what_no_literal_spells() {
        let tiny = CqlValue::Decimal(CqlDecimal::from_signed_be_bytes_slice_and_exponent(&[1], 20_000));

        assert_eq!(
            literal(&CqlValue::Map(vec![(CqlValue::Int(1), tiny)])).as_deref(),
            Some("{1: 1E-20000}")
        );
        let empty = decode(
            Some(CqlValue::Map(vec![(CqlValue::Int(1), CqlValue::Empty)])),
            "map<int, int>",
        );
        assert!(matches!(empty, Value::Undecodable(_)), "{empty:?}");
    }

    #[test]
    fn literals_quote_text_and_spell_floats_as_cql_does() {
        assert_eq!(literal(&CqlValue::Blob(vec![0, 255])).as_deref(), Some("0x00ff"));
        assert_eq!(float_literal(f64::NEG_INFINITY), "-Infinity");
        assert_eq!(float_literal(0.5), "0.5");
        assert_eq!(
            literal(&CqlValue::UserDefinedType {
                keyspace: "ks".to_owned(),
                name: "address".to_owned(),
                fields: vec![
                    ("Street".to_owned(), Some(CqlValue::Text("Main".to_owned()))),
                    ("no".to_owned(), None),
                    ("from".to_owned(), Some(CqlValue::Int(1)))
                ],
            }),
            Some("{\"Street\": 'Main', no: null, \"from\": 1}".to_owned())
        );
    }
}
