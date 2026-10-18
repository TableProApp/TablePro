//! Every MySQL value in the form the server sent it.
//!
//! A non-NULL cell never becomes NULL and no path panics. One function
//! serves workspace and editor results, so a value reads the same in the
//! grid and in the editor.

use sqlx::error::BoxDynError;
use sqlx::mysql::types::{MySqlTime, MySqlTimeSign};
use sqlx::mysql::{MySql, MySqlRow, MySqlTypeInfo, MySqlValueRef};
use sqlx::{Decode, Row as _, Type, TypeInfo as _, ValueRef as _};
use tablepro_core::Value;
use tablepro_core::value::{BitString, JsonText, OtherValue, SqlDecimal, SqlTime, UndecodableReason, UndecodedValue};

use crate::mysql_temporal::{self, TemporalType};
use crate::mysql_timestamp_mode::MySqlTimestampMode;
use crate::mysql_wire_format::MySqlWireFormat;

pub(crate) fn decode_row(row: &MySqlRow, format: MySqlWireFormat, timestamps: MySqlTimestampMode) -> Vec<Value> {
    (0..row.len())
        .map(|index| match row.try_get_raw(index) {
            Ok(value) => decode_cell(value, format, timestamps),
            Err(_) => undecodable("unknown", UndecodableReason::UnsupportedType),
        })
        .collect()
}

pub(crate) fn decode_cell(value: MySqlValueRef<'_>, format: MySqlWireFormat, timestamps: MySqlTimestampMode) -> Value {
    let type_info = value.type_info().into_owned();
    let name = type_info.name();
    if let Some(kind) = temporal_type(name) {
        // sqlx calls a zero date NULL; only a missing value is one.
        return match <&[u8] as Decode<MySql>>::decode(value) {
            Ok(bytes) => mysql_temporal::decode(bytes, format, kind, timestamps),
            Err(_) => Value::Null,
        };
    }
    if value.is_null() {
        return Value::Null;
    }
    match name {
        "BOOLEAN" | "TINYINT" | "SMALLINT" | "MEDIUMINT" | "INT" | "BIGINT" | "YEAR" => integer(value, &type_info),
        _ if is_integer_name(name) => integer(value, &type_info),
        "FLOAT" => read::<f32>(value, name).map_or_else(|error| error, Value::Float32),
        "DOUBLE" => read::<f64>(value, name).map_or_else(|error| error, Value::Float64),
        // DECIMAL travels as text in both protocols, so it is read as the
        // digits the server sent: a fixed-width type would round a
        // DECIMAL(65,30) the server holds exactly.
        "DECIMAL" => match read::<&str>(value, name) {
            Ok(text) => text.parse::<SqlDecimal>().map_or_else(
                |_| undecodable(name, UndecodableReason::InvalidEncoding),
                Value::Decimal,
            ),
            Err(error) => error,
        },
        "TIME" => match read::<MySqlTime>(value, name) {
            Ok(time) => mysql_time(time).unwrap_or_else(|| undecodable(name, UndecodableReason::OutOfRange)),
            Err(error) => error,
        },
        // As the server rendered it: parsing and printing again would
        // reorder keys and drop spacing.
        "JSON" => match read::<&[u8]>(value, name) {
            Ok(bytes) => match std::str::from_utf8(bytes).map(|text| JsonText::parse(text.to_owned())) {
                Ok(Ok(json)) => Value::Json(json),
                _ => undecodable(name, UndecodableReason::InvalidEncoding),
            },
            Err(error) => error,
        },
        // BIT(M) arrives as the ceil(M/8) bytes that hold it, with no
        // count of its own, so the byte width is what the value keeps.
        "BIT" => match read::<&[u8]>(value, name) {
            Ok(bytes) => match u32::try_from(bytes.len().saturating_mul(8))
                .ok()
                .and_then(|bits| BitString::from_bytes(bits, bytes.to_vec()).ok())
            {
                Some(bits) => Value::Bits(bits),
                None => undecodable(name, UndecodableReason::OutOfRange),
            },
            Err(error) => error,
        },
        "GEOMETRY" => read::<&[u8]>(value, name).map_or_else(|error| error, |bytes| Value::Bytes(bytes.to_vec())),
        "NULL" => Value::Null,
        _ => string(value, &type_info, name),
    }
}

fn temporal_type(name: &str) -> Option<TemporalType> {
    match name {
        "DATE" => Some(TemporalType::Date),
        "DATETIME" => Some(TemporalType::DateTime),
        "TIMESTAMP" => Some(TemporalType::Timestamp),
        _ => None,
    }
}

fn is_integer_name(name: &str) -> bool {
    name.strip_suffix(" UNSIGNED")
        .is_some_and(|base| matches!(base, "TINYINT" | "SMALLINT" | "MEDIUMINT" | "INT" | "BIGINT"))
}

/// Signedness comes from the column's UNSIGNED flag, never the name:
/// an unsigned value read through a signed decoder is sign-extended,
/// so 255 in a TINYINT UNSIGNED would come back as -1. Only BIGINT
/// UNSIGNED runs past `i64`, so only it stays unsigned.
fn integer(value: MySqlValueRef<'_>, type_info: &MySqlTypeInfo) -> Value {
    let name = type_info.name();
    if !<u64 as Type<MySql>>::compatible(type_info) {
        return read::<i64>(value, name).map_or_else(|error| error, Value::Int);
    }
    read::<u64>(value, name).map_or_else(|error| error, |unsigned| unsigned_value(name, unsigned))
}

pub(crate) fn unsigned_value(name: &str, unsigned: u64) -> Value {
    match name.starts_with("BIGINT") {
        true => Value::UInt(unsigned),
        false => i64::try_from(unsigned).map_or_else(|_| undecodable(name, UndecodableReason::OutOfRange), Value::Int),
    }
}

/// Text or bytes, by the column's character set: only the `binary`
/// charset holds bytes. The sqlx type name is no guide, because MySQL
/// marks a `_bin` collation column BINARY and sqlx then names a
/// VARCHAR COLLATE utf8mb4_bin a VARBINARY.
fn string(value: MySqlValueRef<'_>, type_info: &MySqlTypeInfo, name: &str) -> Value {
    if <str as Type<MySql>>::compatible(type_info) {
        return match read::<&str>(value, name) {
            Ok(text) => Value::Text(text.to_owned()),
            Err(error) => error,
        };
    }
    match read::<&[u8]>(value, name) {
        Ok(bytes) if is_string_family(name) => Value::Bytes(bytes.to_vec()),
        // A type the driver does not know keeps the server's text, or
        // its bytes when there is no text.
        Ok(bytes) => match std::str::from_utf8(bytes) {
            Ok(text) => Value::Other(Box::new(OtherValue {
                type_name: name.to_owned(),
                text: text.to_owned(),
            })),
            Err(_) => Value::Bytes(bytes.to_vec()),
        },
        Err(error) => error,
    }
}

fn is_string_family(name: &str) -> bool {
    matches!(
        name,
        "CHAR"
            | "VARCHAR"
            | "TEXT"
            | "TINYTEXT"
            | "MEDIUMTEXT"
            | "LONGTEXT"
            | "BINARY"
            | "VARBINARY"
            | "BLOB"
            | "TINYBLOB"
            | "MEDIUMBLOB"
            | "LONGBLOB"
            | "ENUM"
            | "SET"
    )
}

/// Decode without the type check, which the caller already made by
/// name; a failure is the value the cell shows instead.
fn read<'r, T: Decode<'r, MySql>>(value: MySqlValueRef<'r>, name: &str) -> Result<T, Value> {
    T::decode(value).map_err(|error: BoxDynError| {
        tracing::debug!(%error, type_name = name, "a MySQL value could not be decoded");
        undecodable(name, UndecodableReason::InvalidEncoding)
    })
}

/// A MySQL TIME spans -838:59:59 to 838:59:59, which is a span rather
/// than a time of day, so it keeps a type that holds the whole range.
pub(crate) fn mysql_time(time: MySqlTime) -> Option<Value> {
    let nanos = time.microseconds().checked_mul(1_000)?;
    // The sign comes from `sign()`: `MySqlTime::is_negative` in sqlx
    // 0.9 returns `sign.is_positive()`, so it answers backwards.
    let negative = matches!(time.sign(), MySqlTimeSign::Negative);
    SqlTime::new(negative, time.hours(), time.minutes(), time.seconds(), nanos)
        .ok()
        .map(Value::Time)
}

fn undecodable(type_name: &str, reason: UndecodableReason) -> Value {
    Value::Undecodable(Box::new(UndecodedValue {
        type_name: type_name.to_owned(),
        reason,
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn wire_time(sign: MySqlTimeSign, hours: u32, minutes: u8, seconds: u8, micros: u32) -> MySqlTime {
        MySqlTime::new(sign, hours, minutes, seconds, micros).expect("a time the wire holds")
    }

    #[test]
    fn a_time_past_a_day_is_kept_whole() {
        let Some(Value::Time(time)) = mysql_time(wire_time(MySqlTimeSign::Negative, 838, 59, 59, 0)) else {
            panic!("the shortest MySQL time did not convert");
        };

        assert_eq!(time.format(None), "-838:59:59");
    }

    #[test]
    fn a_fractional_second_survives() {
        let Some(Value::Time(time)) = mysql_time(wire_time(MySqlTimeSign::Positive, 1, 2, 3, 123_456)) else {
            panic!("a fractional time did not convert");
        };

        assert_eq!(time.format(Some(6)), "01:02:03.123456");
    }

    #[test]
    fn narrow_unsigned_converts_to_int_checked() {
        assert!(is_integer_name("TINYINT UNSIGNED"));
        assert!(is_integer_name("INT UNSIGNED"));
        assert!(!is_integer_name("DOUBLE UNSIGNED"));
        assert_eq!(unsigned_value("TINYINT UNSIGNED", 255), Value::Int(255));
        assert_eq!(
            unsigned_value("INT UNSIGNED", u64::from(u32::MAX)),
            Value::Int(4_294_967_295)
        );
        assert_eq!(unsigned_value("YEAR", 2155), Value::Int(2155));
        assert_eq!(unsigned_value("BIGINT UNSIGNED", u64::MAX), Value::UInt(u64::MAX));
        assert!(
            matches!(unsigned_value("INT UNSIGNED", u64::MAX), Value::Undecodable(undecodable) if undecodable.reason == UndecodableReason::OutOfRange),
            "a value past i64 in a narrow column is out of range, never wrapped"
        );
    }
}
