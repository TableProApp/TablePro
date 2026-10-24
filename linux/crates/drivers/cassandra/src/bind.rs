//! A value the app holds, as the CQL value a prepared statement's marker
//! takes.

use chrono::{NaiveDate, Timelike};
use num_bigint::BigInt;
use scylla::frame::response::result::{CollectionType, ColumnType as WireType, NativeType};
use scylla::value::{
    Counter, CqlDate, CqlDecimal, CqlDuration, CqlTime, CqlTimestamp, CqlTimeuuid, CqlValue, CqlVarint,
};
use tablepro_core::value::{SqlDecimal, Temporal};
use tablepro_core::{DriverError, Value};

/// `value` for a marker of type `target`, `None` for NULL.
pub(crate) fn to_cql(value: &Value, target: &WireType<'_>) -> Result<Option<CqlValue>, DriverError> {
    if value.is_null() {
        return Ok(None);
    }
    let refused = || DriverError::Protocol(format!("a {} value cannot be sent as {target:?}", value.variant_name()));
    let cql = match target {
        WireType::Native(native) => native_value(value, native).ok_or_else(refused)?,
        WireType::Collection { typ, .. } => match (typ, value) {
            (CollectionType::List(element), Value::Array(items)) => CqlValue::List(elements(items, element)?),
            (CollectionType::Set(element), Value::Array(items)) => CqlValue::Set(elements(items, element)?),
            _ => return Err(refused()),
        },
        WireType::Vector { typ, .. } => match value {
            Value::Array(items) => CqlValue::Vector(elements(items, typ)?),
            _ => return Err(refused()),
        },
        WireType::Tuple(types) => match value {
            Value::Array(items) if items.len() == types.len() => CqlValue::Tuple(
                items
                    .iter()
                    .zip(types)
                    .map(|(item, typ)| to_cql(item, typ))
                    .collect::<Result<_, _>>()?,
            ),
            _ => return Err(refused()),
        },
        _ => return Err(refused()),
    };
    Ok(Some(cql))
}

fn elements(items: &[Value], element: &WireType<'_>) -> Result<Vec<CqlValue>, DriverError> {
    items
        .iter()
        .map(|item| {
            to_cql(item, element)?.ok_or_else(|| DriverError::Protocol("a collection cannot hold NULL".to_owned()))
        })
        .collect()
}

fn native_value(value: &Value, native: &NativeType) -> Option<CqlValue> {
    Some(match (native, value) {
        (NativeType::Ascii, Value::Text(text)) => CqlValue::Ascii(text.clone()),
        (NativeType::Text, Value::Text(text)) => CqlValue::Text(text.clone()),
        (NativeType::Boolean, Value::Bool(flag)) => CqlValue::Boolean(*flag),
        (NativeType::BigInt, _) => CqlValue::BigInt(integer(value)?),
        (NativeType::Counter, _) => CqlValue::Counter(Counter(integer(value)?)),
        (NativeType::Int, _) => CqlValue::Int(i32::try_from(integer(value)?).ok()?),
        (NativeType::SmallInt, _) => CqlValue::SmallInt(i16::try_from(integer(value)?).ok()?),
        (NativeType::TinyInt, _) => CqlValue::TinyInt(i8::try_from(integer(value)?).ok()?),
        (NativeType::Varint, _) => {
            let (unscaled, scale) = unscaled(value)?;
            (scale == 0).then_some(())?;
            CqlValue::Varint(CqlVarint::from_signed_bytes_be(unscaled.to_signed_bytes_be()))
        }
        (NativeType::Decimal, _) => {
            let (unscaled, scale) = unscaled(value)?;
            CqlValue::Decimal(CqlDecimal::from_signed_be_bytes_and_exponent(
                unscaled.to_signed_bytes_be(),
                i32::try_from(scale).ok()?,
            ))
        }
        (NativeType::Float, Value::Float32(number)) => CqlValue::Float(*number),
        (NativeType::Double, Value::Float64(number)) => CqlValue::Double(*number),
        (NativeType::Double, Value::Float32(number)) => CqlValue::Double(f64::from(*number)),
        (NativeType::Blob, Value::Bytes(bytes)) => CqlValue::Blob(bytes.clone()),
        (NativeType::Uuid, Value::Uuid(uuid)) => CqlValue::Uuid(*uuid),
        (NativeType::Timeuuid, Value::Uuid(uuid)) => CqlValue::Timeuuid(CqlTimeuuid::from(*uuid)),
        (NativeType::Timestamp, Value::TimestampTz(Temporal::Finite(instant))) => {
            CqlValue::Timestamp(whole_millis(instant.utc())?)
        }
        (NativeType::Timestamp, Value::Timestamp(Temporal::Finite(naive))) => {
            CqlValue::Timestamp(whole_millis(*naive)?)
        }
        (NativeType::Date, Value::Date(Temporal::Finite(day))) => CqlValue::Date(date(*day)?),
        (NativeType::Time, Value::Time(time)) => {
            let of_day = time.to_time_of_day()?;
            let nanos = i64::from(of_day.num_seconds_from_midnight()) * 1_000_000_000 + i64::from(of_day.nanosecond());
            CqlValue::Time(CqlTime(nanos))
        }
        (NativeType::Duration, Value::Interval(interval)) => CqlValue::Duration(CqlDuration {
            months: interval.months,
            days: interval.days,
            nanoseconds: interval.microseconds.checked_mul(1_000)?,
        }),
        (NativeType::Inet, Value::Text(text)) => CqlValue::Inet(text.trim().parse().ok()?),
        (NativeType::Inet, Value::Other(other)) => CqlValue::Inet(other.text.trim().parse().ok()?),
        _ => return None,
    })
}

fn integer(value: &Value) -> Option<i64> {
    match value {
        Value::Int(number) => Some(*number),
        Value::UInt(number) => i64::try_from(*number).ok(),
        _ => None,
    }
}

/// The digits and scale of a number, whatever integer or decimal form
/// the app holds it in. NaN and the infinities have none.
fn unscaled(value: &Value) -> Option<(BigInt, u32)> {
    match value {
        Value::Int(number) => Some((BigInt::from(*number), 0)),
        Value::UInt(number) => Some((BigInt::from(*number), 0)),
        Value::WideInt(number) => Some((number.to_string().parse().ok()?, 0)),
        Value::Decimal(decimal) => decimal_parts(decimal),
        _ => None,
    }
}

fn decimal_parts(decimal: &SqlDecimal) -> Option<(BigInt, u32)> {
    let scale = decimal.scale()?;
    let text = decimal.to_string();
    let (negative, digits) = match text.strip_prefix('-') {
        Some(digits) => (true, digits),
        None => (false, text.as_str()),
    };
    let joined: String = digits.chars().filter(|c| *c != '.').collect();
    let magnitude: BigInt = joined.parse().ok()?;
    Some((if negative { -magnitude } else { magnitude }, scale))
}

/// A CQL timestamp counts milliseconds, so a finer instant is refused
/// rather than cut.
fn whole_millis(instant: chrono::NaiveDateTime) -> Option<CqlTimestamp> {
    let utc = instant.and_utc();
    utc.timestamp_subsec_nanos()
        .is_multiple_of(1_000_000)
        .then(|| CqlTimestamp(utc.timestamp_millis()))
}

fn date(day: NaiveDate) -> Option<CqlDate> {
    let epoch = NaiveDate::from_ymd_opt(1970, 1, 1)?;
    let days = day.signed_duration_since(epoch).num_days() + (1_i64 << 31);
    u32::try_from(days).ok().map(CqlDate)
}

#[cfg(test)]
mod tests {
    use chrono::{DateTime, Utc};
    use tablepro_core::value::{OffsetTimestamp, SqlTime};

    use super::*;
    use crate::decode::decode;

    fn native(native: NativeType) -> WireType<'static> {
        WireType::Native(native)
    }

    #[test]
    fn an_integer_out_of_its_columns_range_is_refused() {
        assert_eq!(
            to_cql(&Value::Int(127), &native(NativeType::TinyInt)),
            Ok(Some(CqlValue::TinyInt(127)))
        );
        assert!(to_cql(&Value::Int(128), &native(NativeType::TinyInt)).is_err());
        assert!(to_cql(&Value::Text("1".to_owned()), &native(NativeType::Int)).is_err());
        assert_eq!(to_cql(&Value::Null, &native(NativeType::Int)), Ok(None));
    }

    #[test]
    fn values_read_back_bind_to_the_same_cql_value() {
        let cases = [
            (NativeType::Decimal, "decimal"),
            (NativeType::Varint, "varint"),
            (NativeType::Timestamp, "timestamp"),
            (NativeType::Date, "date"),
            (NativeType::Time, "time"),
            (NativeType::Duration, "duration"),
            (NativeType::Inet, "inet"),
        ];
        let values = [
            CqlValue::Decimal(CqlDecimal::from_signed_be_bytes_and_exponent(
                BigInt::from(-1_234_567).to_signed_bytes_be(),
                4,
            )),
            CqlValue::Varint(CqlVarint::from_signed_bytes_be(BigInt::from(-42).to_signed_bytes_be())),
            CqlValue::Timestamp(CqlTimestamp(1_700_000_000_123)),
            CqlValue::Date(CqlDate((1 << 31) - 3)),
            CqlValue::Time(CqlTime(3_723_000_000_004)),
            CqlValue::Duration(CqlDuration {
                months: 1,
                days: -2,
                nanoseconds: 5_000,
            }),
            CqlValue::Inet("2001:db8::1".parse().unwrap()),
        ];
        for ((typ, name), value) in cases.into_iter().zip(values) {
            let decoded = decode(Some(value.clone()), name);
            assert_eq!(to_cql(&decoded, &native(typ)), Ok(Some(value)), "{name}");
        }
    }

    #[test]
    fn an_instant_finer_than_a_millisecond_is_refused() {
        let instant = DateTime::<Utc>::from_timestamp(1, 500).unwrap().fixed_offset();
        let value = Value::TimestampTz(Temporal::Finite(OffsetTimestamp::from_datetime(instant)));

        assert!(to_cql(&value, &native(NativeType::Timestamp)).is_err());
        assert!(
            to_cql(
                &Value::Time(SqlTime::new(false, 25, 0, 0, 0).unwrap()),
                &native(NativeType::Time)
            )
            .is_err()
        );
    }

    #[test]
    fn a_frozen_list_and_a_tuple_bind_from_arrays() {
        let list = WireType::Collection {
            frozen: true,
            typ: CollectionType::List(Box::new(native(NativeType::Int))),
        };
        assert_eq!(
            to_cql(&Value::Array(vec![Value::Int(1), Value::Int(2)]), &list),
            Ok(Some(CqlValue::List(vec![CqlValue::Int(1), CqlValue::Int(2)])))
        );
        let tuple = WireType::Tuple(vec![native(NativeType::Int), native(NativeType::Text)]);
        assert_eq!(
            to_cql(&Value::Array(vec![Value::Int(1), Value::Null]), &tuple),
            Ok(Some(CqlValue::Tuple(vec![Some(CqlValue::Int(1)), None])))
        );
        assert!(
            to_cql(&Value::Array(vec![Value::Int(1)]), &tuple).is_err(),
            "a short tuple"
        );
    }
}
