//! Values off DuckDB's results.
//!
//! DuckDB hands a result over as Arrow arrays, whose types say less
//! than DuckDB's own: HUGEINT, UHUGEINT and DECIMAL(38,0) arrive alike,
//! as do VARCHAR, JSON and UUID. Each value is read by the column's
//! DuckDB type, and one that Arrow cannot carry whole reads as
//! unreadable rather than as a wrong value.

mod bits;
mod nested;
mod text;

use chrono::{DateTime, FixedOffset, NaiveDate, NaiveDateTime, Offset, Utc};
use duckdb::arrow::array::{Array, AsArray};
use duckdb::arrow::datatypes::{
    DataType, Date32Type, Decimal32Type, Decimal64Type, Decimal128Type, Float32Type, Float64Type, Int8Type, Int16Type,
    Int32Type, Int64Type, IntervalMonthDayNanoType, Time64MicrosecondType, Time64NanosecondType, TimeUnit,
    TimestampMicrosecondType, TimestampMillisecondType, TimestampNanosecondType, TimestampSecondType, UInt8Type,
    UInt16Type, UInt32Type, UInt64Type,
};
use tablepro_core::column::IntegerWidth;
use tablepro_core::value::{
    JsonText, OffsetTimestamp, OtherValue, SqlDecimal, SqlInterval, SqlTime, Temporal, UndecodableReason,
    UndecodedValue, Value, WideInteger,
};

use crate::duck_type::DuckType;

pub(crate) use self::bits::bit_string;
pub(crate) use self::text::interval_text;

/// DuckDB's infinite DATE, one either side of every finite one.
const DATE_INFINITY: i32 = i32::MAX;
/// DuckDB's infinite TIMESTAMP, in every unit.
const TIMESTAMP_INFINITY: i64 = i64::MAX;
const DAYS_TO_UNIX_EPOCH_FROM_CE: i32 = 719_163;

/// The value at `row` of a column of type `duck`.
pub(crate) fn value_at(array: &dyn Array, duck: &DuckType, row: usize) -> Value {
    if array.is_null(row) {
        return Value::Null;
    }
    if duck.is_nested() {
        return match nested::text(array, duck, row) {
            Some(text) => Value::Other(Box::new(OtherValue {
                type_name: duck.name(),
                text,
            })),
            None => unreadable(duck, UndecodableReason::UnsupportedType),
        };
    }
    scalar(array, duck, row).unwrap_or_else(|reason| unreadable(duck, reason))
}

pub(crate) fn unreadable(duck: &DuckType, reason: UndecodableReason) -> Value {
    Value::Undecodable(Box::new(UndecodedValue {
        type_name: duck.name(),
        reason,
    }))
}

type Read<T> = Result<T, UndecodableReason>;

fn scalar(array: &dyn Array, duck: &DuckType, row: usize) -> Read<Value> {
    Ok(match duck {
        DuckType::Boolean => Value::Bool(array.as_boolean_opt().ok_or(mismatch())?.value(row)),
        DuckType::Integer { width, signed } => integer(array, *width, *signed, row)?,
        DuckType::Float => Value::Float32(primitive::<Float32Type>(array, row)?),
        DuckType::Double => Value::Float64(primitive::<Float64Type>(array, row)?),
        DuckType::Decimal { scale, .. } => Value::Decimal(SqlDecimal::from_scaled_i128(
            decimal_mantissa(array, row)?,
            u32::from(*scale),
        )),
        DuckType::Varchar | DuckType::Enum => Value::Text(string(array, row)?.to_owned()),
        DuckType::Json => {
            let text = string(array, row)?.to_owned();
            match JsonText::parse(text.clone()) {
                Ok(json) => Value::Json(json),
                Err(_) => Value::Text(text),
            }
        }
        DuckType::Blob | DuckType::Geometry => Value::Bytes(bytes(array, row)?.to_vec()),
        DuckType::Uuid => Value::Uuid(uuid(array, row)?),
        DuckType::Bit => Value::Bits(bit_string(bytes(array, row)?).ok_or(UndecodableReason::InvalidEncoding)?),
        DuckType::BigNum => big_number(array, row)?,
        DuckType::Date => Value::Date(date(primitive::<Date32Type>(array, row)?)?),
        DuckType::Time => Value::Time(time_of_day(array, row)?),
        DuckType::TimeNs => Value::Time(time_of_day(array, row)?),
        DuckType::Timestamp(_) => Value::Timestamp(timestamp(array, row)?),
        DuckType::TimestampTz => Value::TimestampTz(match timestamp(array, row)? {
            Temporal::Finite(utc) => Temporal::Finite(OffsetTimestamp::from_datetime(
                utc.and_utc().with_timezone(&utc_offset()),
            )),
            Temporal::Infinity => Temporal::Infinity,
            Temporal::NegInfinity => Temporal::NegInfinity,
        }),
        DuckType::Interval => {
            let interval = primitive::<IntervalMonthDayNanoType>(array, row)?;
            Value::Interval(SqlInterval {
                months: interval.months,
                days: interval.days,
                microseconds: interval_micros(interval.nanoseconds).ok_or(UndecodableReason::OutOfRange)?,
            })
        }
        DuckType::Null => Value::Null,
        // Arrow carries a TIME WITH TIME ZONE as its time alone, so the
        // offset would be lost and the value read as another one.
        DuckType::TimeTz | DuckType::Variant | DuckType::Other(_) => return Err(UndecodableReason::UnsupportedType),
        DuckType::List(_) | DuckType::Array(..) | DuckType::Struct(_) | DuckType::Map(..) | DuckType::Union(_) => {
            return Err(UndecodableReason::UnsupportedType);
        }
    })
}

/// The microseconds of an interval DuckDB handed over as nanoseconds.
/// DuckDB multiplies its microseconds by 1,000 in an `i64` on the way to
/// Arrow, which wraps for a span past about 292 years; a wrapped value is
/// no whole number of microseconds, and one that is cannot be told apart.
pub(crate) fn interval_micros(nanoseconds: i64) -> Option<i64> {
    (nanoseconds % 1_000 == 0).then_some(nanoseconds / 1_000)
}

fn mismatch() -> UndecodableReason {
    UndecodableReason::InvalidEncoding
}

fn primitive<T: duckdb::arrow::datatypes::ArrowPrimitiveType>(array: &dyn Array, row: usize) -> Read<T::Native> {
    array
        .as_primitive_opt::<T>()
        .map(|values| values.value(row))
        .ok_or(mismatch())
}

fn integer(array: &dyn Array, width: IntegerWidth, signed: bool, row: usize) -> Read<Value> {
    Ok(match (width, signed) {
        (IntegerWidth::W8, true) => Value::Int(i64::from(primitive::<Int8Type>(array, row)?)),
        (IntegerWidth::W16, true) => Value::Int(i64::from(primitive::<Int16Type>(array, row)?)),
        (IntegerWidth::W24 | IntegerWidth::W32, true) => Value::Int(i64::from(primitive::<Int32Type>(array, row)?)),
        (IntegerWidth::W64, true) => Value::Int(primitive::<Int64Type>(array, row)?),
        (IntegerWidth::W8, false) => Value::UInt(u64::from(primitive::<UInt8Type>(array, row)?)),
        (IntegerWidth::W16, false) => Value::UInt(u64::from(primitive::<UInt16Type>(array, row)?)),
        (IntegerWidth::W24 | IntegerWidth::W32, false) => Value::UInt(u64::from(primitive::<UInt32Type>(array, row)?)),
        (IntegerWidth::W64, false) => Value::UInt(primitive::<UInt64Type>(array, row)?),
        (IntegerWidth::W128 | IntegerWidth::W256, true) => {
            Value::WideInt(WideInteger::from_i128(primitive::<Decimal128Type>(array, row)?))
        }
        // A UHUGEINT travels in a 128-bit decimal's bits, so its sign bit is
        // the top bit of the number.
        (IntegerWidth::W128 | IntegerWidth::W256, false) => Value::WideInt(WideInteger::from_u128(
            primitive::<Decimal128Type>(array, row)?.cast_unsigned(),
        )),
    })
}

/// A decimal's digits, at whatever width DuckDB sent them.
fn decimal_mantissa(array: &dyn Array, row: usize) -> Read<i128> {
    match array.data_type() {
        DataType::Decimal32(..) => primitive::<Decimal32Type>(array, row).map(i128::from),
        DataType::Decimal64(..) => primitive::<Decimal64Type>(array, row).map(i128::from),
        _ => primitive::<Decimal128Type>(array, row),
    }
}

/// A string column's text, whichever Arrow layout carries it.
pub(crate) fn string(array: &dyn Array, row: usize) -> Read<&str> {
    if let Some(values) = array.as_string_opt::<i32>() {
        return Ok(values.value(row));
    }
    if let Some(values) = array.as_string_opt::<i64>() {
        return Ok(values.value(row));
    }
    if let Some(values) = array.as_string_view_opt() {
        return Ok(values.value(row));
    }
    dictionary_label(array, row)
}

/// An ENUM's label: its dictionary entry for the row's key.
fn dictionary_label(array: &dyn Array, row: usize) -> Read<&str> {
    let (key, values) = if let Some(dictionary) = array.as_dictionary_opt::<UInt8Type>() {
        (usize::from(dictionary.keys().value(row)), dictionary.values())
    } else if let Some(dictionary) = array.as_dictionary_opt::<UInt16Type>() {
        (usize::from(dictionary.keys().value(row)), dictionary.values())
    } else if let Some(dictionary) = array.as_dictionary_opt::<UInt32Type>() {
        let key = usize::try_from(dictionary.keys().value(row)).map_err(|_| mismatch())?;
        (key, dictionary.values())
    } else {
        return Err(mismatch());
    };
    if key >= values.len() {
        return Err(UndecodableReason::OutOfRange);
    }
    string(values.as_ref(), key)
}

pub(crate) fn bytes(array: &dyn Array, row: usize) -> Read<&[u8]> {
    if let Some(values) = array.as_binary_opt::<i32>() {
        return Ok(values.value(row));
    }
    if let Some(values) = array.as_binary_opt::<i64>() {
        return Ok(values.value(row));
    }
    if let Some(values) = array.as_binary_view_opt() {
        return Ok(values.value(row));
    }
    array
        .as_fixed_size_binary_opt()
        .map(|values| values.value(row))
        .ok_or(mismatch())
}

fn uuid(array: &dyn Array, row: usize) -> Read<uuid::Uuid> {
    if let Some(values) = array.as_fixed_size_binary_opt() {
        return uuid::Uuid::from_slice(values.value(row)).map_err(|_| mismatch());
    }
    uuid::Uuid::parse_str(string(array, row)?).map_err(|_| mismatch())
}

/// A BIGNUM as its digits, where DuckDB sent them as text, and as an
/// integer where it fits one.
fn big_number(array: &dyn Array, row: usize) -> Read<Value> {
    let text = string(array, row).map_err(|_| UndecodableReason::UnsupportedType)?;
    Ok(match text.parse::<WideInteger>() {
        Ok(number) => Value::WideInt(number),
        Err(_) => Value::Text(text.to_owned()),
    })
}

pub(crate) fn date(days: i32) -> Read<Temporal<NaiveDate>> {
    match days {
        DATE_INFINITY => Ok(Temporal::Infinity),
        days if days == -DATE_INFINITY => Ok(Temporal::NegInfinity),
        days => days
            .checked_add(DAYS_TO_UNIX_EPOCH_FROM_CE)
            .and_then(NaiveDate::from_num_days_from_ce_opt)
            .map(Temporal::Finite)
            .ok_or(UndecodableReason::OutOfRange),
    }
}

/// TIME and TIME_NS: DuckDB's TIME runs to 24:00:00 inclusive.
pub(crate) fn time_of_day(array: &dyn Array, row: usize) -> Read<SqlTime> {
    let nanos = match array.data_type() {
        DataType::Time64(TimeUnit::Nanosecond) => i128::from(primitive::<Time64NanosecondType>(array, row)?),
        _ => i128::from(primitive::<Time64MicrosecondType>(array, row)?) * 1_000,
    };
    time_from_nanos(nanos)
}

pub(crate) fn time_from_nanos(nanos: i128) -> Read<SqlTime> {
    let seconds = nanos.div_euclid(1_000_000_000);
    let fraction = u32::try_from(nanos.rem_euclid(1_000_000_000)).map_err(|_| UndecodableReason::OutOfRange)?;
    let hours = u32::try_from(seconds / 3_600).map_err(|_| UndecodableReason::OutOfRange)?;
    let minutes = u8::try_from(seconds / 60 % 60).map_err(|_| UndecodableReason::OutOfRange)?;
    let whole = u8::try_from(seconds % 60).map_err(|_| UndecodableReason::OutOfRange)?;
    SqlTime::new(false, hours, minutes, whole, fraction).map_err(|_| UndecodableReason::OutOfRange)
}

/// A timestamp in whatever unit it counts, as the wall time it holds.
pub(crate) fn timestamp(array: &dyn Array, row: usize) -> Read<Temporal<NaiveDateTime>> {
    let (count, unit) = match array.data_type() {
        DataType::Timestamp(TimeUnit::Second, _) => (primitive::<TimestampSecondType>(array, row)?, TimeUnit::Second),
        DataType::Timestamp(TimeUnit::Millisecond, _) => (
            primitive::<TimestampMillisecondType>(array, row)?,
            TimeUnit::Millisecond,
        ),
        DataType::Timestamp(TimeUnit::Nanosecond, _) => {
            (primitive::<TimestampNanosecondType>(array, row)?, TimeUnit::Nanosecond)
        }
        _ => (
            primitive::<TimestampMicrosecondType>(array, row)?,
            TimeUnit::Microsecond,
        ),
    };
    match count {
        TIMESTAMP_INFINITY => return Ok(Temporal::Infinity),
        count if count == -TIMESTAMP_INFINITY => return Ok(Temporal::NegInfinity),
        _ => {}
    }
    let stamp = match unit {
        TimeUnit::Second => DateTime::from_timestamp(count, 0),
        TimeUnit::Millisecond => DateTime::from_timestamp_millis(count),
        TimeUnit::Nanosecond => Some(DateTime::from_timestamp_nanos(count)),
        TimeUnit::Microsecond => DateTime::from_timestamp_micros(count),
    };
    stamp
        .map(|stamp| Temporal::Finite(stamp.naive_utc()))
        .ok_or(UndecodableReason::OutOfRange)
}

fn utc_offset() -> FixedOffset {
    Utc.fix()
}
