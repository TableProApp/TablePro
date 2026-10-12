use std::fmt;
use std::str::FromStr;

use clickhouse_types::data_types::DataTypeNode;
use serde::Deserialize;
use serde::de::{DeserializeSeed, Deserializer, IgnoredAny, SeqAccess, Visitor};
use serde_json::value::RawValue;
use tablepro_core::Value;
use tablepro_core::value::{OtherValue, SqlDecimal, SqlTime, Temporal, UndecodableReason, UndecodedValue, WideInteger};

/// How one column's cells are read from a JSON row.
///
/// Each kind reads the JSON token the way the server wrote it, so a
/// number keeps every digit and a string that is not UTF-8 keeps every
/// byte.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum CellPlan {
    /// String, FixedString and Enum: the bytes of the JSON string, which
    /// the server sends as they are stored.
    Text,
    Integer,
    Float32,
    Float64,
    Decimal,
    Bool,
    Date,
    DateTime,
    Time,
    Uuid,
    /// A string the app keeps as the server's text, such as an address.
    ServerText {
        type_name: String,
    },
    Nullable(Box<CellPlan>),
    Array(Box<CellPlan>),
    /// Map, Tuple, Variant, Dynamic, JSON, AggregateFunction and the geo
    /// types: the JSON token, kept whole.
    Raw {
        type_name: String,
    },
}

impl CellPlan {
    pub(crate) fn of(node: &DataTypeNode) -> Self {
        match node {
            DataTypeNode::String | DataTypeNode::FixedString(_) | DataTypeNode::Enum(..) => Self::Text,
            DataTypeNode::UInt8
            | DataTypeNode::UInt16
            | DataTypeNode::UInt32
            | DataTypeNode::UInt64
            | DataTypeNode::UInt128
            | DataTypeNode::UInt256
            | DataTypeNode::Int8
            | DataTypeNode::Int16
            | DataTypeNode::Int32
            | DataTypeNode::Int64
            | DataTypeNode::Int128
            | DataTypeNode::Int256 => Self::Integer,
            DataTypeNode::Float32 | DataTypeNode::BFloat16 => Self::Float32,
            DataTypeNode::Float64 => Self::Float64,
            DataTypeNode::Decimal(..) => Self::Decimal,
            DataTypeNode::Bool => Self::Bool,
            DataTypeNode::Date | DataTypeNode::Date32 => Self::Date,
            DataTypeNode::DateTime(_) | DataTypeNode::DateTime64(..) => Self::DateTime,
            DataTypeNode::Time | DataTypeNode::Time64(_) => Self::Time,
            DataTypeNode::UUID => Self::Uuid,
            DataTypeNode::IPv4 | DataTypeNode::IPv6 => Self::ServerText {
                type_name: node.to_string(),
            },
            DataTypeNode::Nullable(inner) => Self::Nullable(Box::new(Self::of(inner))),
            DataTypeNode::LowCardinality(inner) | DataTypeNode::SimpleAggregateFunction(_, inner) => Self::of(inner),
            DataTypeNode::Array(element) => Self::Array(Box::new(Self::of(element))),
            other => Self::Raw {
                type_name: other.to_string(),
            },
        }
    }

    /// Whether the value is the server's own text rather than a decoded
    /// value.
    pub(crate) fn reads_server_text(&self) -> bool {
        match self {
            Self::Raw { .. } | Self::ServerText { .. } => true,
            Self::Nullable(inner) => inner.reads_server_text(),
            _ => false,
        }
    }

    /// Whether any part of a cell is read as a raw JSON token, which
    /// serde_json refuses when a string inside it is not UTF-8.
    pub(crate) fn uses_raw(&self) -> bool {
        match self {
            Self::Raw { .. } => true,
            Self::Nullable(inner) | Self::Array(inner) => inner.uses_raw(),
            _ => false,
        }
    }

    /// The type a value that cannot be read is reported as.
    pub(crate) fn type_name(&self) -> String {
        match self {
            Self::Text => "String".to_owned(),
            Self::Integer => "Integer".to_owned(),
            Self::Float32 => "Float32".to_owned(),
            Self::Float64 => "Float64".to_owned(),
            Self::Decimal => "Decimal".to_owned(),
            Self::Bool => "Bool".to_owned(),
            Self::Date => "Date".to_owned(),
            Self::DateTime => "DateTime".to_owned(),
            Self::Time => "Time".to_owned(),
            Self::Uuid => "UUID".to_owned(),
            Self::ServerText { type_name } | Self::Raw { type_name } => type_name.clone(),
            Self::Nullable(inner) => format!("Nullable({})", inner.type_name()),
            Self::Array(inner) => format!("Array({})", inner.type_name()),
        }
    }
}

/// Reads one cell by its plan, or skips it when `plan` is `None`.
///
/// Skipping goes through `IgnoredAny`, which serde_json does without
/// checking that strings are UTF-8, so a cell that cannot be read does
/// not stop the cells around it from being read.
#[derive(Debug, Clone, Copy)]
pub(crate) struct CellSeed<'p> {
    pub(crate) plan: Option<&'p CellPlan>,
}

impl<'de> DeserializeSeed<'de> for CellSeed<'_> {
    type Value = Value;

    fn deserialize<D: Deserializer<'de>>(self, deserializer: D) -> Result<Value, D::Error> {
        let Some(plan) = self.plan else {
            IgnoredAny::deserialize(deserializer)?;
            return Ok(Value::Null);
        };
        match plan {
            CellPlan::Text => deserializer.deserialize_bytes(TextVisitor),
            CellPlan::Nullable(inner) => deserializer.deserialize_option(NullableVisitor { inner }),
            CellPlan::Array(element) => deserializer.deserialize_seq(ArrayVisitor { element }),
            CellPlan::Raw { type_name } => {
                let raw = <&RawValue>::deserialize(deserializer)?;
                Ok(match raw.get() {
                    "null" => Value::Null,
                    text => other(type_name, text),
                })
            }
            CellPlan::ServerText { type_name } => {
                let text = String::deserialize(deserializer)?;
                Ok(other(type_name, &text))
            }
            CellPlan::Date | CellPlan::DateTime | CellPlan::Time | CellPlan::Uuid => {
                let text = Option::<String>::deserialize(deserializer)?;
                Ok(text.map_or(Value::Null, |text| temporal_or_uuid(plan, &text)))
            }
            CellPlan::Integer | CellPlan::Float32 | CellPlan::Float64 | CellPlan::Decimal | CellPlan::Bool => {
                let raw = <&RawValue>::deserialize(deserializer)?;
                Ok(number(plan, raw.get()))
            }
        }
    }
}

fn other(type_name: &str, text: &str) -> Value {
    Value::Other(Box::new(OtherValue {
        type_name: type_name.to_owned(),
        text: text.to_owned(),
    }))
}

fn undecodable(plan: &CellPlan, reason: UndecodableReason) -> Value {
    Value::Undecodable(Box::new(UndecodedValue {
        type_name: plan.type_name(),
        reason,
    }))
}

/// A number token, quoted or bare: the server quotes 64-bit and wider
/// integers, and the non-finite floats, so that JSON readers keep them.
fn number(plan: &CellPlan, token: &str) -> Value {
    if token == "null" {
        return Value::Null;
    }
    let text = token
        .strip_prefix('"')
        .and_then(|inner| inner.strip_suffix('"'))
        .unwrap_or(token);
    let parsed = match plan {
        CellPlan::Integer => integer(text),
        CellPlan::Float32 => f32::from_str(text).ok().map(Value::Float32),
        CellPlan::Float64 => f64::from_str(text).ok().map(Value::Float64),
        CellPlan::Decimal => SqlDecimal::from_str(text).ok().map(Value::Decimal),
        CellPlan::Bool => match text {
            "true" | "1" => Some(Value::Bool(true)),
            "false" | "0" => Some(Value::Bool(false)),
            _ => None,
        },
        _ => None,
    };
    parsed.unwrap_or_else(|| undecodable(plan, UndecodableReason::OutOfRange))
}

/// An integer of any width, in the smallest variant that holds it, the
/// way an edit parses one, so a value read back compares equal to the
/// same value typed in.
fn integer(text: &str) -> Option<Value> {
    if let Ok(value) = text.parse::<i64>() {
        return Some(Value::Int(value));
    }
    if let Ok(value) = text.parse::<u64>() {
        return Some(Value::UInt(value));
    }
    text.parse::<WideInteger>().ok().map(Value::WideInt)
}

/// A date, time, timestamp or UUID in the server's text. One the driver
/// cannot parse is kept as that text rather than lost.
fn temporal_or_uuid(plan: &CellPlan, text: &str) -> Value {
    let parsed = match plan {
        CellPlan::Date => chrono::NaiveDate::parse_from_str(text, "%Y-%m-%d")
            .ok()
            .map(|date| Value::Date(Temporal::Finite(date))),
        // `%.f` also reads a whole second, so this covers DateTime and
        // every DateTime64 precision.
        CellPlan::DateTime => chrono::NaiveDateTime::parse_from_str(text, "%Y-%m-%d %H:%M:%S%.f")
            .ok()
            .map(|stamp| Value::Timestamp(Temporal::Finite(stamp))),
        CellPlan::Time => time(text).map(Value::Time),
        CellPlan::Uuid => uuid::Uuid::parse_str(text).ok().map(Value::Uuid),
        _ => None,
    };
    parsed.unwrap_or_else(|| other(&plan.type_name(), text))
}

/// `[-]H:MM:SS[.fraction]`, where the hours run past a day.
fn time(text: &str) -> Option<SqlTime> {
    let (negative, unsigned) = match text.strip_prefix('-') {
        Some(rest) => (true, rest),
        None => (false, text),
    };
    let (clock, fraction) = match unsigned.split_once('.') {
        Some((clock, fraction)) => (clock, fraction),
        None => (unsigned, ""),
    };
    let mut parts = clock.split(':');
    let hours = parts.next()?.parse().ok()?;
    let minutes = parts.next()?.parse().ok()?;
    let seconds = parts.next()?.parse().ok()?;
    if parts.next().is_some() || fraction.len() > 9 || !fraction.bytes().all(|byte| byte.is_ascii_digit()) {
        return None;
    }
    let nanos = if fraction.is_empty() {
        0
    } else {
        format!("{fraction:0<9}").parse().ok()?
    };
    SqlTime::new(negative, hours, minutes, seconds, nanos).ok()
}

struct TextVisitor;

impl<'de> Visitor<'de> for TextVisitor {
    type Value = Value;

    fn expecting(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("a string")
    }

    fn visit_bytes<E: serde::de::Error>(self, bytes: &[u8]) -> Result<Value, E> {
        Ok(text_or_bytes(bytes.to_vec()))
    }

    fn visit_byte_buf<E: serde::de::Error>(self, bytes: Vec<u8>) -> Result<Value, E> {
        Ok(text_or_bytes(bytes))
    }

    fn visit_str<E: serde::de::Error>(self, text: &str) -> Result<Value, E> {
        Ok(Value::Text(text.to_owned()))
    }

    fn visit_unit<E: serde::de::Error>(self) -> Result<Value, E> {
        Ok(Value::Null)
    }
}

/// Text when the bytes are UTF-8. Otherwise the bytes themselves, which
/// is what the column stores: replacing the bad sequences would show a
/// value the row does not hold, and a save keyed on it would miss.
fn text_or_bytes(bytes: Vec<u8>) -> Value {
    match String::from_utf8(bytes) {
        Ok(text) => Value::Text(text),
        Err(error) => Value::Bytes(error.into_bytes()),
    }
}

struct NullableVisitor<'p> {
    inner: &'p CellPlan,
}

impl<'de> Visitor<'de> for NullableVisitor<'_> {
    type Value = Value;

    fn expecting(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("a value or null")
    }

    fn visit_none<E: serde::de::Error>(self) -> Result<Value, E> {
        Ok(Value::Null)
    }

    fn visit_unit<E: serde::de::Error>(self) -> Result<Value, E> {
        Ok(Value::Null)
    }

    fn visit_some<D: Deserializer<'de>>(self, deserializer: D) -> Result<Value, D::Error> {
        CellSeed { plan: Some(self.inner) }.deserialize(deserializer)
    }
}

struct ArrayVisitor<'p> {
    element: &'p CellPlan,
}

impl<'de> Visitor<'de> for ArrayVisitor<'_> {
    type Value = Value;

    fn expecting(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("an array")
    }

    fn visit_seq<A: SeqAccess<'de>>(self, mut seq: A) -> Result<Value, A::Error> {
        let mut values = Vec::with_capacity(seq.size_hint().unwrap_or(0));
        while let Some(value) = seq.next_element_seed(CellSeed {
            plan: Some(self.element),
        })? {
            values.push(value);
        }
        Ok(Value::Array(values))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn read(plan: &CellPlan, json: &[u8]) -> Value {
        let mut deserializer = serde_json::Deserializer::from_slice(json);
        CellSeed { plan: Some(plan) }
            .deserialize(&mut deserializer)
            .expect("a cell")
    }

    #[test]
    fn invalid_utf8_string_is_bytes() {
        assert_eq!(
            read(&CellPlan::Text, b"\"\xff\xfeA\""),
            Value::Bytes(vec![0xff, 0xfe, b'A'])
        );
        assert_eq!(
            read(&CellPlan::Text, b"\"caf\xc3\xa9\""),
            Value::Text("café".to_owned())
        );
        assert_eq!(read(&CellPlan::Text, br#""a\"b""#), Value::Text("a\"b".to_owned()));
    }

    #[test]
    fn numbers_keep_every_digit_quoted_or_bare() {
        assert_eq!(
            read(&CellPlan::Integer, b"\"18446744073709551615\""),
            Value::UInt(u64::MAX)
        );
        assert_eq!(read(&CellPlan::Integer, b"-7"), Value::Int(-7));
        let widest = "57896044618658097711785492504343953926634992332820282019728792003956564819967";
        let Value::WideInt(wide) = read(&CellPlan::Integer, format!("\"{widest}\"").as_bytes()) else {
            panic!("an Int256 was not kept whole");
        };
        assert_eq!(wide.to_string(), widest);
        let decimal = "12345678901234567890123456789012345678901234567890123456.12345678901234567890";
        assert_eq!(
            read(&CellPlan::Decimal, decimal.as_bytes()),
            Value::Decimal(decimal.parse().expect("a decimal"))
        );
    }

    #[test]
    fn non_finite_floats_arrive_quoted() {
        let Value::Float32(nan) = read(&CellPlan::Float32, b"\"nan\"") else {
            panic!("nan was not a Float32");
        };
        assert!(nan.is_nan());
        assert_eq!(read(&CellPlan::Float64, b"\"-inf\""), Value::Float64(f64::NEG_INFINITY));
        assert_eq!(read(&CellPlan::Float64, b"1.5"), Value::Float64(1.5));
    }

    #[test]
    fn temporal_values_parse_and_fall_back_to_text() {
        assert_eq!(
            read(&CellPlan::DateTime, b"\"2024-06-15 08:30:00.123\""),
            Value::Timestamp(Temporal::Finite(
                chrono::NaiveDate::from_ymd_opt(2024, 6, 15)
                    .and_then(|date| date.and_hms_milli_opt(8, 30, 0, 123))
                    .expect("a timestamp")
            ))
        );
        assert_eq!(
            read(&CellPlan::Time, b"\"-100:00:01.5\""),
            Value::Time(SqlTime::new(true, 100, 0, 1, 500_000_000).expect("a time"))
        );
        assert!(matches!(read(&CellPlan::Date, b"\"not a date\""), Value::Other(_)));
    }

    #[test]
    fn nullable_arrays_and_raw_tokens() {
        let nullable = CellPlan::Nullable(Box::new(CellPlan::Integer));
        assert_eq!(read(&nullable, b"null"), Value::Null);
        assert_eq!(read(&nullable, b"3"), Value::Int(3));

        let array = CellPlan::Array(Box::new(CellPlan::Nullable(Box::new(CellPlan::Text))));
        assert_eq!(
            read(&array, br#"["a",null]"#),
            Value::Array(vec![Value::Text("a".to_owned()), Value::Null])
        );

        let map = CellPlan::Raw {
            type_name: "Map(String, UInt8)".to_owned(),
        };
        assert_eq!(
            read(&map, br#"{"a":1}"#),
            Value::Other(Box::new(OtherValue {
                type_name: "Map(String, UInt8)".to_owned(),
                text: r#"{"a":1}"#.to_owned(),
            }))
        );
    }
}
