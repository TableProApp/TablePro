use std::fmt::Write as _;

use chrono::{DateTime, NaiveDate, NaiveDateTime, Utc};
use postgres_protocol::types as wire;
use postgres_types::{Date, FromSql, Kind, Timestamp, Type};
use tablepro_core::Value;
use tablepro_core::export::value_to_text;
use tablepro_core::value::{
    BitString, JsonText, OffsetTimestamp, OtherValue, Temporal, UndecodableReason, UndecodedValue,
};

use super::WireError;
use super::array_decode::decode_array;
use super::interval_wire::interval_from_sql;
use super::network_text::{inet_text, macaddr_text, macaddr8_text};
use super::numeric_wire::numeric_from_sql;
use super::oid;
use super::temporal_wire::{time_from_sql, timetz_from_sql};

const JSONB_VERSION: u8 = 1;

/// Why a value has no decoded form.
enum Failure {
    Wire(WireError),
    Unsupported,
}

impl From<WireError> for Failure {
    fn from(error: WireError) -> Self {
        Self::Wire(error)
    }
}

/// A non-NULL binary value as the app's `Value`.
///
/// Nothing here returns `Null` for bytes that are there: a value this
/// build cannot read becomes `Undecodable`, so the grid shows that it
/// exists rather than an empty cell that looks like a NULL.
pub(crate) fn decode_binary(ty: &Type, raw: &[u8]) -> Value {
    match decode(ty, raw) {
        Ok(value) => value,
        Err(Failure::Wire(error)) => undecodable(ty, error.reason()),
        Err(Failure::Unsupported) => undecodable(ty, UndecodableReason::UnsupportedType),
    }
}

/// Whether a column of this type reads exactly in binary, so a page
/// selects it as it is rather than as the server's text.
pub(crate) fn decodes_natively(ty: &Type) -> bool {
    match ty.kind() {
        Kind::Array(element) => decodes_natively(element),
        Kind::Domain(base) => decodes_natively(base),
        Kind::Simple => matches!(
            ty.oid(),
            oid::BOOL
                | oid::INT2
                | oid::INT4
                | oid::INT8
                | oid::OID
                | oid::FLOAT4
                | oid::FLOAT8
                | oid::NUMERIC
                | oid::TEXT
                | oid::VARCHAR
                | oid::BPCHAR
                | oid::NAME
                | oid::CHAR
                | oid::XML
                | oid::BYTEA
                | oid::UUID
                | oid::JSON
                | oid::JSONB
                | oid::DATE
                | oid::TIME
                | oid::TIMETZ
                | oid::TIMESTAMP
                | oid::TIMESTAMPTZ
                | oid::INTERVAL
                | oid::BIT
                | oid::VARBIT
                | oid::INET
                | oid::CIDR
                | oid::MACADDR
                | oid::MACADDR8
                | oid::POINT
                | oid::BOX
                | oid::PATH
                | oid::PG_LSN
        ),
        _ => false,
    }
}

fn decode(ty: &Type, raw: &[u8]) -> Result<Value, Failure> {
    match ty.kind() {
        Kind::Array(element) => return Ok(decode_array(ty, element, raw)?),
        Kind::Domain(base) => return decode(base, raw),
        // An enum's binary form is its label.
        Kind::Enum(_) => return Ok(Value::Text(text(raw)?.to_owned())),
        Kind::Range(element) => return Ok(other(ty, range_text(element, raw)?)),
        Kind::Simple => {}
        _ => return Err(Failure::Unsupported),
    }
    let value = match ty.oid() {
        oid::BOOL => Value::Bool(wire::bool_from_sql(raw).map_err(malformed)?),
        oid::INT2 => Value::Int(i64::from(wire::int2_from_sql(raw).map_err(malformed)?)),
        oid::INT4 => Value::Int(i64::from(wire::int4_from_sql(raw).map_err(malformed)?)),
        oid::INT8 => Value::Int(wire::int8_from_sql(raw).map_err(malformed)?),
        oid::FLOAT4 => Value::Float32(wire::float4_from_sql(raw).map_err(malformed)?),
        oid::FLOAT8 => Value::Float64(wire::float8_from_sql(raw).map_err(malformed)?),
        oid::NUMERIC => Value::Decimal(numeric_from_sql(raw)?),
        oid::TEXT | oid::VARCHAR | oid::BPCHAR | oid::NAME | oid::XML | oid::UNKNOWN => {
            Value::Text(text(raw)?.to_owned())
        }
        oid::CHAR => Value::Text(char::from(raw.first().copied().ok_or(WireError::Malformed)?).to_string()),
        oid::BYTEA => Value::Bytes(wire::bytea_from_sql(raw).to_vec()),
        oid::UUID => Value::Uuid(uuid::Uuid::from_bytes(wire::uuid_from_sql(raw).map_err(malformed)?)),
        oid::JSON => json(raw)?,
        oid::JSONB => match raw.split_first() {
            Some((&JSONB_VERSION, document)) => json(document)?,
            _ => return Err(WireError::Malformed.into()),
        },
        oid::DATE => Value::Date(date(ty, raw)?),
        oid::TIMESTAMP => Value::Timestamp(timestamp(ty, raw)?),
        oid::TIMESTAMPTZ => Value::TimestampTz(timestamptz(ty, raw)?),
        oid::TIME => Value::Time(time_from_sql(raw)?),
        oid::TIMETZ => Value::TimeTz(timetz_from_sql(raw)?),
        oid::INTERVAL => Value::Interval(interval_from_sql(raw)?),
        oid::BIT | oid::VARBIT => Value::Bits(bits(raw)?),
        oid::INET => other(ty, inet_text(raw, false)?),
        oid::CIDR => other(ty, inet_text(raw, true)?),
        oid::MACADDR => other(ty, macaddr_text(raw)?),
        oid::MACADDR8 => other(ty, macaddr8_text(raw)?),
        oid::POINT => {
            let point = wire::point_from_sql(raw).map_err(malformed)?;
            other(ty, point_text(point.x(), point.y()))
        }
        oid::BOX => {
            let shape = wire::box_from_sql(raw).map_err(malformed)?;
            let (upper, lower) = (shape.upper_right(), shape.lower_left());
            other(
                ty,
                format!(
                    "{},{}",
                    point_text(upper.x(), upper.y()),
                    point_text(lower.x(), lower.y())
                ),
            )
        }
        oid::PATH => other(ty, path_text(raw)?),
        oid::PG_LSN => {
            let lsn = wire::lsn_from_sql(raw).map_err(malformed)?;
            other(ty, format!("{:X}/{:X}", lsn >> 32, lsn & 0xFFFF_FFFF))
        }
        oid::OID => Value::Int(i64::from(wire::oid_from_sql(raw).map_err(malformed)?)),
        alias if oid::REG_TYPES.contains(&alias) => Value::Int(i64::from(wire::oid_from_sql(raw).map_err(malformed)?)),
        oid::XID | oid::CID => other(ty, wire::oid_from_sql(raw).map_err(malformed)?.to_string()),
        oid::XID8 => other(
            ty,
            wire::int8_from_sql(raw).map_err(malformed)?.cast_unsigned().to_string(),
        ),
        oid::TID => other(ty, tid_text(raw)?),
        _ => return Err(Failure::Unsupported),
    };
    Ok(value)
}

fn malformed<E>(_: E) -> WireError {
    WireError::Malformed
}

fn text(raw: &[u8]) -> Result<&str, WireError> {
    std::str::from_utf8(raw).map_err(malformed)
}

/// JSON kept as the server rendered it: decoding and printing it again
/// would reorder the keys and drop the spacing.
fn json(raw: &[u8]) -> Result<Value, WireError> {
    JsonText::parse(text(raw)?.to_owned())
        .map(Value::Json)
        .map_err(malformed)
}

fn bits(raw: &[u8]) -> Result<BitString, WireError> {
    let varbit = wire::varbit_from_sql(raw).map_err(malformed)?;
    let bit_len = u32::try_from(varbit.len()).map_err(|_| WireError::OutOfRange)?;
    BitString::from_bytes(bit_len, varbit.bytes().to_vec()).map_err(malformed)
}

/// postgres-types reads the infinities and refuses a date chrono cannot
/// hold. A well-formed value it refuses is therefore out of range.
fn date(ty: &Type, raw: &[u8]) -> Result<Temporal<NaiveDate>, WireError> {
    expect_len(raw, 4)?;
    match Date::<NaiveDate>::from_sql(ty, raw).map_err(|_| WireError::OutOfRange)? {
        Date::Value(date) => Ok(Temporal::Finite(date)),
        Date::PosInfinity => Ok(Temporal::Infinity),
        Date::NegInfinity => Ok(Temporal::NegInfinity),
    }
}

fn timestamp(ty: &Type, raw: &[u8]) -> Result<Temporal<NaiveDateTime>, WireError> {
    expect_len(raw, 8)?;
    match Timestamp::<NaiveDateTime>::from_sql(ty, raw).map_err(|_| WireError::OutOfRange)? {
        Timestamp::Value(stamp) => Ok(Temporal::Finite(stamp)),
        Timestamp::PosInfinity => Ok(Temporal::Infinity),
        Timestamp::NegInfinity => Ok(Temporal::NegInfinity),
    }
}

/// A TIMESTAMPTZ is an instant; the server sends it in UTC, so the offset
/// it carries here is UTC's.
fn timestamptz(ty: &Type, raw: &[u8]) -> Result<Temporal<OffsetTimestamp>, WireError> {
    expect_len(raw, 8)?;
    match Timestamp::<DateTime<Utc>>::from_sql(ty, raw).map_err(|_| WireError::OutOfRange)? {
        Timestamp::Value(stamp) => Ok(Temporal::Finite(OffsetTimestamp::from_datetime(stamp.fixed_offset()))),
        Timestamp::PosInfinity => Ok(Temporal::Infinity),
        Timestamp::NegInfinity => Ok(Temporal::NegInfinity),
    }
}

fn expect_len(raw: &[u8], len: usize) -> Result<(), WireError> {
    if raw.len() == len {
        Ok(())
    } else {
        Err(WireError::Malformed)
    }
}

fn point_text(x: f64, y: f64) -> String {
    format!("({x},{y})")
}

fn path_text(raw: &[u8]) -> Result<String, WireError> {
    use fallible_iterator::FallibleIterator;

    let path = wire::path_from_sql(raw).map_err(malformed)?;
    let points: Vec<String> = path
        .points()
        .map(|point| Ok(point_text(point.x(), point.y())))
        .collect()
        .map_err(malformed)?;
    let (open, close) = if path.closed() { ('(', ')') } else { ('[', ']') };
    Ok(format!("{open}{}{close}", points.join(",")))
}

fn tid_text(raw: &[u8]) -> Result<String, WireError> {
    let bytes: [u8; 6] = raw.try_into().map_err(malformed)?;
    let block = u32::from_be_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]);
    let offset = u16::from_be_bytes([bytes[4], bytes[5]]);
    Ok(format!("({block},{offset})"))
}

/// A range printed the way the server prints one, its bounds quoted
/// where their text needs it.
fn range_text(element: &Type, raw: &[u8]) -> Result<String, Failure> {
    let range = wire::range_from_sql(raw).map_err(malformed)?;
    let wire::Range::Nonempty(lower, upper) = range else {
        return Ok("empty".to_owned());
    };
    let mut text = String::new();
    let (open, lower_value) = bound(element, lower, '[', '(')?;
    let (close, upper_value) = bound(element, upper, ']', ')')?;
    text.push(open);
    text.push_str(&lower_value);
    text.push(',');
    text.push_str(&upper_value);
    text.push(close);
    Ok(text)
}

fn bound(
    element: &Type,
    bound: wire::RangeBound<Option<&[u8]>>,
    inclusive: char,
    exclusive: char,
) -> Result<(char, String), Failure> {
    let (bracket, value) = match bound {
        wire::RangeBound::Inclusive(value) => (inclusive, value),
        wire::RangeBound::Exclusive(value) => (exclusive, value),
        wire::RangeBound::Unbounded => return Ok((exclusive, String::new())),
    };
    let Some(bytes) = value else {
        return Ok((bracket, String::new()));
    };
    let text = value_to_text(&decode(element, bytes)?).ok_or(Failure::Unsupported)?;
    Ok((bracket, quote_element(&text, ",()[]")))
}

/// Quote an element of a composite text form the way the server does
/// when it holds a character the form uses itself.
pub(crate) fn quote_element(text: &str, specials: &str) -> String {
    let needs_quotes = text.is_empty()
        || text
            .chars()
            .any(|ch| ch == '"' || ch == '\\' || ch.is_whitespace() || specials.contains(ch));
    if !needs_quotes {
        return text.to_owned();
    }
    let mut quoted = String::with_capacity(text.len() + 2);
    quoted.push('"');
    for ch in text.chars() {
        if ch == '"' || ch == '\\' {
            quoted.push('\\');
        }
        let _ = write!(quoted, "{ch}");
    }
    quoted.push('"');
    quoted
}

fn other(ty: &Type, text: String) -> Value {
    Value::Other(Box::new(OtherValue {
        type_name: ty.name().to_owned(),
        text,
    }))
}

fn undecodable(ty: &Type, reason: UndecodableReason) -> Value {
    Value::Undecodable(Box::new(UndecodedValue {
        type_name: ty.name().to_owned(),
        reason,
    }))
}

#[cfg(test)]
mod tests {
    use bytes::BytesMut;
    use postgres_types::ToSql;

    use super::*;

    fn encoded<T: ToSql>(value: T, ty: &Type) -> BytesMut {
        let mut out = BytesMut::new();
        value.to_sql(ty, &mut out).expect("an encodable value");
        out
    }

    #[test]
    fn date_timestamp_infinity_sentinels() {
        let infinity = encoded(i32::MAX, &Type::INT4);
        let negative = encoded(i32::MIN, &Type::INT4);
        assert_eq!(decode_binary(&Type::DATE, &infinity), Value::Date(Temporal::Infinity));
        assert_eq!(
            decode_binary(&Type::DATE, &negative),
            Value::Date(Temporal::NegInfinity)
        );

        let infinity = encoded(i64::MAX, &Type::INT8);
        assert_eq!(
            decode_binary(&Type::TIMESTAMP, &infinity),
            Value::Timestamp(Temporal::Infinity)
        );
        assert_eq!(
            decode_binary(&Type::TIMESTAMPTZ, &encoded(i64::MIN, &Type::INT8)),
            Value::TimestampTz(Temporal::NegInfinity)
        );
    }

    #[test]
    fn timestamp_overflow_is_out_of_range() {
        let far = encoded(i64::MAX - 1, &Type::INT8);

        let Value::Undecodable(undecoded) = decode_binary(&Type::TIMESTAMP, &far) else {
            panic!("an overflowing timestamp decoded");
        };
        assert_eq!(undecoded.reason, UndecodableReason::OutOfRange);
        let Value::Undecodable(short) = decode_binary(&Type::TIMESTAMP, &[0, 1]) else {
            panic!("a short timestamp decoded");
        };
        assert_eq!(short.reason, UndecodableReason::InvalidEncoding);
    }

    #[test]
    fn scalars_keep_their_width_and_text_keeps_its_bytes() {
        assert_eq!(
            decode_binary(&Type::FLOAT4, &encoded(1.5f32, &Type::FLOAT4)),
            Value::Float32(1.5)
        );
        assert_eq!(decode_binary(&Type::INT2, &encoded(-7i16, &Type::INT2)), Value::Int(-7));
        assert_eq!(
            decode_binary(&Type::OID, &encoded(u32::MAX, &Type::OID)),
            Value::Int(4_294_967_295)
        );
        assert_eq!(
            decode_binary(&Type::TEXT, "naïve".as_bytes()),
            Value::Text("naïve".to_owned())
        );
        let Value::Undecodable(invalid) = decode_binary(&Type::TEXT, &[0xff, 0xfe]) else {
            panic!("invalid UTF-8 decoded");
        };
        assert_eq!(invalid.reason, UndecodableReason::InvalidEncoding);
    }

    #[test]
    fn jsonb_skips_its_version_byte_and_keeps_the_text() {
        let document = br#"{"b": 1, "a": [2]}"#;
        let mut jsonb = vec![JSONB_VERSION];
        jsonb.extend_from_slice(document);

        let Value::Json(read) = decode_binary(&Type::JSONB, &jsonb) else {
            panic!("jsonb did not decode");
        };
        assert_eq!(read.as_str(), r#"{"b": 1, "a": [2]}"#);
    }

    #[test]
    fn an_unknown_type_is_undecodable_not_null() {
        let mystery = Type::new("mystery".to_owned(), 99_999, Kind::Pseudo, "public".to_owned());

        let Value::Undecodable(undecoded) = decode_binary(&mystery, b"x") else {
            panic!("an unknown type decoded");
        };
        assert_eq!(undecoded.type_name, "mystery");
        assert_eq!(undecoded.reason, UndecodableReason::UnsupportedType);
    }

    #[test]
    fn geometric_and_lsn_values_print_as_the_server_does() {
        let mut point = BytesMut::new();
        wire::point_to_sql(1.5, -2.0, &mut point);
        let Value::Other(read) = decode_binary(&Type::POINT, &point) else {
            panic!("a point did not decode");
        };
        assert_eq!(read.text, "(1.5,-2)");

        let mut lsn = BytesMut::new();
        wire::lsn_to_sql(0x0000_0001_00AB_CDEF, &mut lsn);
        let Value::Other(read) = decode_binary(&Type::PG_LSN, &lsn) else {
            panic!("an lsn did not decode");
        };
        assert_eq!(read.text, "1/ABCDEF");
    }

    #[test]
    fn an_int4range_prints_in_canonical_form() {
        let mut range = BytesMut::new();
        wire::range_to_sql(
            |out| {
                wire::int4_to_sql(1, out);
                Ok(wire::RangeBound::Inclusive(postgres_protocol::IsNull::No))
            },
            |out| {
                wire::int4_to_sql(5, out);
                Ok(wire::RangeBound::Exclusive(postgres_protocol::IsNull::No))
            },
            &mut range,
        )
        .expect("a range");

        let Value::Other(read) = decode_binary(&Type::INT4_RANGE, &range) else {
            panic!("a range did not decode");
        };
        assert_eq!(read.text, "[1,5)");
    }

    #[test]
    fn quoting_follows_the_composite_text_rules() {
        assert_eq!(quote_element("plain", ",{}"), "plain");
        assert_eq!(quote_element("a b", ",{}"), "\"a b\"");
        assert_eq!(quote_element("", ",{}"), "\"\"");
        assert_eq!(quote_element("say \"hi\"", ",{}"), "\"say \\\"hi\\\"\"");
    }
}
