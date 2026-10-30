use std::borrow::Cow;

use chrono::{DateTime, Datelike, NaiveDate, NaiveDateTime, NaiveTime, Timelike};

use crate::column::{BoolStorage, ColumnKind, ColumnType, FloatWidth, IntegerKind, TemporalZone, TimeRange};
use crate::value::{
    BitString, JsonText, OffsetTimestamp, OtherValue, SqlDecimal, SqlInterval, SqlTime, Temporal, TimeRangeError,
    TimeWithOffset, Value, WideInteger,
};

use super::{EditParseError, ReadOnlyReason};

/// Turn text the user typed into a value of the column's type.
///
/// Parsing here rather than at the server means a wrong number is a
/// message beside the cell instead of a failed transaction. A column
/// whose server decides the stored form keeps the text as typed when
/// the strict parse fails, because the server is the authority on what
/// it accepts.
pub fn parse_literal_text(input: &str, column: &ColumnType) -> Result<Value, EditParseError> {
    parse(input, column, Purpose::Store)
}

/// What the parsed value is for, which decides whether the column's
/// declared precision applies.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Purpose {
    /// Written to the column, so it has to fit: the server would round
    /// or refuse a value that does not.
    Store,
    /// Compared against the column. `price > 1.005` is a fair question
    /// for a `numeric(10,2)` column.
    Compare,
}

fn parse(input: &str, column: &ColumnType, purpose: Purpose) -> Result<Value, EditParseError> {
    match strict(input, column, purpose) {
        Ok(_) if column.dynamic_storage && keeps_text_when_valid(&column.kind) => {
            Ok(Value::Text(input.trim().to_owned()))
        }
        Ok(value) => Ok(value),
        Err(_) if column.dynamic_storage && keeps_text_on_failure(&column.kind) => Ok(Value::Text(input.to_owned())),
        Err(EditParseError::InvalidDate | EditParseError::InvalidTime | EditParseError::InvalidTimestamp)
            if column.dynamic_storage && keeps_text_when_valid(&column.kind) && is_time_value_text(input.trim()) =>
        {
            Ok(Value::Text(input.trim().to_owned()))
        }
        Err(error) => Err(error),
    }
}

/// Whether a value that parsed is still stored as the text typed.
///
/// A column whose server stores whatever text it is given keeps a date
/// or time in the spelling it was written in, such as SQLite's
/// `2024-01-01T11:00:00`. The parse only checks the text: binding the
/// parsed value would store the app's own spelling instead.
fn keeps_text_when_valid(kind: &ColumnKind) -> bool {
    matches!(
        kind,
        ColumnKind::Date | ColumnKind::Time { .. } | ColumnKind::Timestamp { .. }
    )
}

/// Whether `input` is a date or time in a form SQLite's date and time
/// functions read, whichever of DATE, TIME or DATETIME the column
/// declares: SQLite gives the three names the same affinity, so any of
/// them holds any form, and a time or timestamp may end in an offset or
/// `Z`.
fn is_time_value_text(input: &str) -> bool {
    parse_date(input).is_ok()
        || parse_time(input).is_ok()
        || parse_timestamp(input).is_ok()
        || parse_time_with_offset(input).is_ok()
        || parse_timestamp_with_offset(input).is_ok()
}

/// Whether a failed parse should fall back to the text as typed.
///
/// Only for kinds whose text form is what the server stores anyway. A
/// bad number is still a bad number, and the server validates JSON, so
/// saying so now beats a failed transaction later.
fn keeps_text_on_failure(kind: &ColumnKind) -> bool {
    matches!(
        kind,
        ColumnKind::Text { .. }
            | ColumnKind::Enum { .. }
            | ColumnKind::Network(_)
            | ColumnKind::Xml
            | ColumnKind::Other
    )
}

fn strict(input: &str, column: &ColumnType, purpose: Purpose) -> Result<Value, EditParseError> {
    let value = strict_value(input, column, purpose)?;
    if purpose == Purpose::Store {
        check_declared_fraction(&value, column.kind.fractional_digits())?;
    }
    Ok(value)
}

fn strict_value(input: &str, column: &ColumnType, purpose: Purpose) -> Result<Value, EditParseError> {
    let trimmed = input.trim();
    match &column.kind {
        ColumnKind::Bool(BoolStorage::Native) => parse_bool(trimmed).map(Value::Bool),
        ColumnKind::Bool(BoolStorage::Integer) => parse_integer_bool(trimmed),
        ColumnKind::Integer(kind) => parse_integer(trimmed, *kind),
        ColumnKind::Decimal { precision, scale } => parse_decimal(trimmed, purpose, *precision, *scale),
        ColumnKind::Money { scale } => parse_decimal(trimmed, purpose, None, scale.map(u32::from)),
        ColumnKind::Float(width) => parse_float(trimmed, *width),
        // Text keeps what the user typed, spaces included: a trailing
        // space is a value, not a typo the app gets to remove.
        // XML too: every driver reads it back as text, so an edit has to
        // be text to bind as one and to compare equal when unchanged.
        ColumnKind::Text { .. } | ColumnKind::Enum { .. } | ColumnKind::Xml => Ok(Value::Text(input.to_owned())),
        ColumnKind::Json { .. } => JsonText::parse(input.to_owned())
            .map(Value::Json)
            .map_err(EditParseError::InvalidJson),
        ColumnKind::Uuid => trimmed
            .parse()
            .map(Value::Uuid)
            .map_err(|_| EditParseError::InvalidUuid),
        ColumnKind::Date => parse_date(trimmed)
            .or_else(|error| far_temporal(trimmed, column, purpose, parse_date).unwrap_or(Err(error))),
        ColumnKind::Time { with_offset: true, .. } => parse_time_with_offset(trimmed),
        ColumnKind::Time {
            range: range @ (TimeRange::Duration | TimeRange::LongDuration),
            ..
        } => parse_duration(trimmed, *range),
        ColumnKind::Time { .. } => parse_time(trimmed),
        ColumnKind::Timestamp {
            zone: TemporalZone::Offset,
            ..
        } => parse_timestamp_with_offset(trimmed)
            .or_else(|error| far_temporal(trimmed, column, purpose, parse_timestamp_with_offset).unwrap_or(Err(error))),
        ColumnKind::Timestamp { .. } => parse_timestamp(trimmed)
            .or_else(|error| far_temporal(trimmed, column, purpose, parse_timestamp).unwrap_or(Err(error))),
        ColumnKind::Interval => trimmed
            .parse::<SqlInterval>()
            .map(Value::Interval)
            .map_err(|_| EditParseError::InvalidInterval),
        ColumnKind::BitString { .. } => parse_bits(trimmed),
        ColumnKind::Network(_) | ColumnKind::Other => Ok(Value::Other(Box::new(OtherValue {
            type_name: column.name.clone(),
            text: input.to_owned(),
        }))),
        ColumnKind::Bytes { .. } => Err(EditParseError::NotEditable(ReadOnlyReason::Bytes)),
        ColumnKind::Spatial => Err(EditParseError::NotEditable(ReadOnlyReason::Spatial)),
        ColumnKind::Variant => Err(EditParseError::NotEditable(ReadOnlyReason::Variant)),
        ColumnKind::Array { .. } | ColumnKind::Composite => Err(EditParseError::NotEditable(ReadOnlyReason::Composite)),
    }
}

fn parse_bool(input: &str) -> Result<bool, EditParseError> {
    match input.to_ascii_lowercase().as_str() {
        "true" | "t" | "yes" | "y" | "on" | "1" => Ok(true),
        "false" | "f" | "no" | "n" | "off" | "0" => Ok(false),
        _ => Err(EditParseError::InvalidBoolean),
    }
}

/// A boolean the server stores as an integer. It keeps any integer, so
/// a typed 2 stays 2 rather than becoming true.
fn parse_integer_bool(input: &str) -> Result<Value, EditParseError> {
    if let Ok(flag) = parse_bool(input) {
        return Ok(Value::Int(i64::from(flag)));
    }
    input
        .parse::<i64>()
        .map(Value::Int)
        .map_err(|_| EditParseError::InvalidBoolean)
}

fn parse_integer(input: &str, kind: IntegerKind) -> Result<Value, EditParseError> {
    // i128 first so a number that is merely out of range is reported
    // as such rather than as unreadable.
    let Ok(wide) = input.parse::<WideInteger>() else {
        return Err(EditParseError::InvalidInteger);
    };
    if !wide.fits(kind) {
        return Err(EditParseError::IntegerOutOfRange { kind });
    }
    Ok(narrow(wide))
}

/// Keep a value in the smallest variant that holds it, so a `1` from a
/// bigint column compares equal to a `1` read back from it.
fn narrow(wide: WideInteger) -> Value {
    if let Some(value) = wide.to_i128()
        && let Ok(value) = i64::try_from(value)
    {
        return Value::Int(value);
    }
    if let Some(value) = wide.to_u128()
        && let Ok(value) = u64::try_from(value)
    {
        return Value::UInt(value);
    }
    Value::WideInt(wide)
}

fn parse_decimal(
    input: &str,
    purpose: Purpose,
    precision: Option<u32>,
    scale: Option<u32>,
) -> Result<Value, EditParseError> {
    let decimal = input.parse::<SqlDecimal>().map_err(EditParseError::InvalidDecimal)?;
    if purpose == Purpose::Store && decimal.is_finite() {
        check_declared_digits(&decimal, precision, scale)?;
    }
    Ok(Value::Decimal(decimal))
}

/// Refuse a value the column would round or overflow, rather than let
/// the server change what the user typed. Trailing zeros past the scale
/// are not a change, so `1.50` fits `numeric(10,1)`.
fn check_declared_digits(
    decimal: &SqlDecimal,
    precision: Option<u32>,
    scale: Option<u32>,
) -> Result<(), EditParseError> {
    match (precision, scale) {
        (_, Some(scale)) if !decimal.fits(u32::MAX, scale) => Err(EditParseError::ScaleExceeded { scale }),
        (Some(precision), Some(scale)) if !decimal.fits(precision, scale) => {
            Err(EditParseError::PrecisionExceeded { precision })
        }
        (Some(precision), None) if decimal.integer_digits().is_some_and(|digits| digits > precision) => {
            Err(EditParseError::PrecisionExceeded { precision })
        }
        _ => Ok(()),
    }
}

/// Refuse a fraction of a second finer than the column keeps. The
/// server rounds it, and `23:59:59.5` in a `timestamp(0)` becomes the
/// next day.
fn check_declared_fraction(value: &Value, digits: Option<u8>) -> Result<(), EditParseError> {
    let Some(digits) = digits.filter(|digits| *digits < 9) else {
        return Ok(());
    };
    let nanos = match value {
        Value::Time(time) => time.total_nanos().rem_euclid(1_000_000_000),
        Value::TimeTz(time) => time.time.total_nanos().rem_euclid(1_000_000_000),
        Value::Timestamp(Temporal::Finite(stamp)) => i128::from(stamp.nanosecond()),
        Value::TimestampTz(Temporal::Finite(stamp)) => i128::from(stamp.utc().nanosecond()),
        _ => return Ok(()),
    };
    match nanos % 10_i128.pow(9 - u32::from(digits)) {
        0 => Ok(()),
        _ => Err(EditParseError::ScaleExceeded {
            scale: u32::from(digits),
        }),
    }
}

fn parse_float(input: &str, width: FloatWidth) -> Result<Value, EditParseError> {
    if let Some(value) = non_finite(input) {
        return Ok(match width {
            FloatWidth::F32 => Value::Float32(value as f32),
            FloatWidth::F64 => Value::Float64(value),
        });
    }
    match width {
        FloatWidth::F32 => input
            .parse::<f32>()
            .map(Value::Float32)
            .map_err(|_| EditParseError::InvalidFloat),
        FloatWidth::F64 => input
            .parse::<f64>()
            .map(Value::Float64)
            .map_err(|_| EditParseError::InvalidFloat),
    }
}

/// The words each engine uses for the non-finite floats, which
/// `str::parse` does not accept.
fn non_finite(input: &str) -> Option<f64> {
    match input.to_ascii_lowercase().as_str() {
        "nan" => Some(f64::NAN),
        "inf" | "infinity" | "+inf" | "+infinity" => Some(f64::INFINITY),
        "-inf" | "-infinity" => Some(f64::NEG_INFINITY),
        _ => None,
    }
}

fn parse_date(input: &str) -> Result<Value, EditParseError> {
    if let Some(temporal) = infinite_temporal(input) {
        return Ok(Value::Date(temporal));
    }
    let input = chrono_year(input).ok_or(EditParseError::InvalidDate)?;
    NaiveDate::parse_from_str(&input, "%Y-%m-%d")
        .map(|date| Value::Date(Temporal::Finite(date)))
        .map_err(|_| EditParseError::InvalidDate)
}

fn parse_time(input: &str) -> Result<Value, EditParseError> {
    if let Ok(time) = NaiveTime::parse_from_str(input, "%H:%M:%S%.f") {
        return Ok(Value::Time(SqlTime::from_time_of_day(time)));
    }
    if let Ok(time) = NaiveTime::parse_from_str(input, "%H:%M") {
        return Ok(Value::Time(SqlTime::from_time_of_day(time)));
    }
    // PostgreSQL's time runs to 24:00:00 inclusive, which no NaiveTime
    // holds.
    match input.parse::<SqlTime>() {
        Ok(time) if time.total_nanos() == END_OF_DAY_NANOS => Ok(Value::Time(time)),
        _ => Err(EditParseError::InvalidTime),
    }
}

const END_OF_DAY_NANOS: i128 = 86_400 * 1_000_000_000;

/// MySQL TIME or ClickHouse Time, which measure an amount of time and so
/// run past 24 hours and below zero, each to its own bound.
fn parse_duration(input: &str, range: TimeRange) -> Result<Value, EditParseError> {
    let time = input.parse::<SqlTime>().map_err(|error| match error {
        TimeRangeError::OutOfRange => EditParseError::TimeOutOfRange,
        TimeRangeError::InvalidComponent | TimeRangeError::InvalidSyntax => EditParseError::InvalidTime,
    })?;
    match range.holds(&time) {
        true => Ok(Value::Time(time)),
        false => Err(EditParseError::TimeOutOfRange),
    }
}

fn parse_timestamp(input: &str) -> Result<Value, EditParseError> {
    if let Some(temporal) = infinite_temporal(input) {
        return Ok(Value::Timestamp(temporal));
    }
    let input = chrono_year(input).ok_or(EditParseError::InvalidTimestamp)?;
    for format in ["%Y-%m-%d %H:%M:%S%.f", "%Y-%m-%dT%H:%M:%S%.f", "%Y-%m-%d %H:%M"] {
        if let Ok(stamp) = NaiveDateTime::parse_from_str(&input, format) {
            return Ok(Value::Timestamp(Temporal::Finite(stamp)));
        }
    }
    Err(EditParseError::InvalidTimestamp)
}

/// The text with its year spelled the way chrono's `%Y` reads one. The
/// grid and PostgreSQL write a year past 9999 without a sign and a year
/// before AD 1 as ` BC` after the whole value, where chrono wants
/// `+10000` and `-4712`: there is no year 0 between 1 BC and AD 1, so
/// 1 BC is chrono's 0. `None` for a ` BC` value with no year to count
/// back from.
pub(super) fn chrono_year(input: &str) -> Option<Cow<'_, str>> {
    let (dated, before_christ) = match input.strip_suffix(" BC").or_else(|| input.strip_suffix(" bc")) {
        Some(dated) => (dated, true),
        None => (input, false),
    };
    let year_digits = dated.bytes().take_while(u8::is_ascii_digit).count();
    let (year, rest) = dated.split_at(year_digits);
    if !before_christ {
        return Some(match year_digits > 4 && rest.starts_with('-') {
            true => Cow::Owned(format!("+{dated}")),
            false => Cow::Borrowed(input),
        });
    }
    if !rest.starts_with('-') {
        return None;
    }
    let year = year.parse::<i64>().ok().filter(|year| *year >= 1)?;
    Some(Cow::Owned(match 1 - year {
        0 => format!("0000{rest}"),
        signed => format!("{signed}{rest}"),
    }))
}

/// A date or timestamp past the last year chrono holds, kept as the text
/// it was written in: PostgreSQL keeps dates to 5874897 AD and its driver
/// reads one that far as that text. The Gregorian
/// calendar repeats every 400 years, so the text is checked by `parse`
/// with its year moved into chrono's range, fraction and all. `None`
/// for text that is not such a value.
fn far_temporal(
    input: &str,
    column: &ColumnType,
    purpose: Purpose,
    parse: fn(&str) -> Result<Value, EditParseError>,
) -> Option<Result<Value, EditParseError>> {
    let stand_in = parse(&far_year_stand_in(input)?).ok()?;
    if purpose == Purpose::Store
        && let Err(error) = check_declared_fraction(&stand_in, column.kind.fractional_digits())
    {
        return Some(Err(error));
    }
    Some(Ok(Value::Other(Box::new(OtherValue {
        type_name: column.name.clone(),
        text: input.to_owned(),
    }))))
}

// The text with a year past chrono's last moved into its range, keeping the rest as written.
pub(super) fn far_year_stand_in(input: &str) -> Option<String> {
    let year_digits = input.bytes().take_while(u8::is_ascii_digit).count();
    let (year, rest) = input.split_at(year_digits);
    let last_year = u64::try_from(NaiveDate::MAX.year()).ok()?;
    let year = year.parse::<u64>().ok().filter(|year| *year > last_year)?;
    Some(format!("{}{rest}", 2000 + year % 400))
}

fn infinite_temporal<T>(input: &str) -> Option<Temporal<T>> {
    match input.to_ascii_lowercase().as_str() {
        "infinity" | "inf" => Some(Temporal::Infinity),
        "-infinity" | "-inf" => Some(Temporal::NegInfinity),
        _ => None,
    }
}

fn parse_bits(input: &str) -> Result<Value, EditParseError> {
    if input.is_empty() || !input.bytes().all(|byte| byte == b'0' || byte == b'1') {
        return Err(EditParseError::InvalidBits);
    }
    let bit_len = u32::try_from(input.len()).map_err(|_| EditParseError::InvalidBits)?;
    let mut bytes = vec![0u8; bit_len.div_ceil(8) as usize];
    for (position, bit) in input.bytes().enumerate() {
        if bit == b'1'
            && let Some(byte) = bytes.get_mut(position / 8)
        {
            *byte |= 0x80 >> (position % 8);
        }
    }
    BitString::from_bytes(bit_len, bytes)
        .map(Value::Bits)
        .map_err(|_| EditParseError::InvalidBits)
}

/// Parse text typed into a filter box.
///
/// Same rules as a cell, except that a filter is a comparison rather
/// than a stored value, so a column whose type has no text form still
/// takes one here.
pub fn parse_filter_text(input: &str, column: &ColumnType) -> Result<Value, EditParseError> {
    match column.kind {
        // The form an export and a copy write a blob in.
        ColumnKind::Bytes { .. } => parse_hex_bytes(input.trim()),
        // A filter on a column with no editable text form compares text
        // the user typed; the dialect decides what that means.
        ColumnKind::Spatial | ColumnKind::Array { .. } | ColumnKind::Variant | ColumnKind::Composite => {
            Ok(Value::Text(input.to_owned()))
        }
        _ => parse(input, column, Purpose::Compare),
    }
}

fn parse_hex_bytes(input: &str) -> Result<Value, EditParseError> {
    input
        .strip_prefix("0x")
        .or_else(|| input.strip_prefix("0X"))
        .and_then(crate::hex::decode)
        .map(Value::Bytes)
        .ok_or(EditParseError::InvalidBytes)
}

/// A `TimeTz` from text, for the engines that have one.
pub fn parse_time_with_offset(input: &str) -> Result<Value, EditParseError> {
    let trimmed = input.trim();
    // chrono has no time-with-offset parser, so the value is dated to
    // a fixed day, parsed, and the date thrown away.
    let dated = format!("1970-01-01 {trimmed}");
    for format in ["%Y-%m-%d %H:%M:%S%.f%#z", "%Y-%m-%d %H:%M%#z"] {
        if let Ok(stamp) = DateTime::parse_from_str(&dated, format) {
            return Ok(Value::TimeTz(TimeWithOffset {
                time: SqlTime::from_time_of_day(stamp.time()),
                offset: *stamp.offset(),
            }));
        }
    }
    if NaiveTime::parse_from_str(trimmed, "%H:%M:%S%.f").is_ok() {
        return Err(EditParseError::OffsetRequired);
    }
    Err(EditParseError::InvalidTime)
}

/// A `TimestampTz` from text.
pub fn parse_timestamp_with_offset(input: &str) -> Result<Value, EditParseError> {
    let trimmed = input.trim();
    if let Some(temporal) = infinite_temporal(trimmed) {
        return Ok(Value::TimestampTz(temporal));
    }
    let dated = chrono_year(trimmed).ok_or(EditParseError::InvalidTimestamp)?;
    for format in [
        "%Y-%m-%d %H:%M:%S%.f%#z",
        "%Y-%m-%dT%H:%M:%S%.f%#z",
        "%Y-%m-%d %H:%M%#z",
    ] {
        if let Ok(stamp) = DateTime::parse_from_str(&dated, format) {
            return Ok(Value::TimestampTz(Temporal::Finite(OffsetTimestamp::from_datetime(
                stamp,
            ))));
        }
    }
    if NaiveDateTime::parse_from_str(&dated, "%Y-%m-%d %H:%M:%S%.f").is_ok() {
        return Err(EditParseError::OffsetRequired);
    }
    Err(EditParseError::InvalidTimestamp)
}

#[cfg(test)]
mod tests {
    use crate::column::{IntegerWidth, ReadForm, TextLength};

    use super::*;

    fn column(kind: ColumnKind, dynamic_storage: bool) -> ColumnType {
        ColumnType {
            name: "t".to_owned(),
            kind,
            catalog: None,
            dynamic_storage,
            read_form: ReadForm::Native,
        }
    }

    fn int(width: IntegerWidth, signed: bool) -> ColumnKind {
        ColumnKind::Integer(IntegerKind { width, signed })
    }

    fn time(with_offset: bool, range: TimeRange) -> ColumnKind {
        ColumnKind::Time {
            fractional_digits: None,
            with_offset,
            range,
        }
    }

    fn stamp(zone: TemporalZone) -> ColumnKind {
        ColumnKind::Timestamp {
            fractional_digits: None,
            zone,
        }
    }

    fn bytes() -> ColumnKind {
        ColumnKind::Bytes {
            length: TextLength::Unbounded,
        }
    }

    fn parse(kind: ColumnKind, input: &str) -> Result<Value, EditParseError> {
        parse_literal_text(input, &column(kind, false))
    }

    #[test]
    fn parse_filter_text_integer_bounds_i8_to_u64() {
        let i8 = IntegerKind {
            width: IntegerWidth::W8,
            signed: true,
        };
        let u8 = IntegerKind {
            width: IntegerWidth::W8,
            signed: false,
        };
        let i24 = IntegerKind {
            width: IntegerWidth::W24,
            signed: true,
        };
        let i32 = IntegerKind {
            width: IntegerWidth::W32,
            signed: true,
        };
        let u64 = IntegerKind {
            width: IntegerWidth::W64,
            signed: false,
        };
        let cases = [
            (i8, "127", true),
            (i8, "128", false),
            (i8, "-128", true),
            (i8, "-129", false),
            (u8, "255", true),
            (u8, "-1", false),
            (i24, "8388607", true),
            (i24, "8388608", false),
            (i32, "2147483647", true),
            (i32, "2147483648", false),
            (u64, "18446744073709551615", true),
            (u64, "18446744073709551616", false),
        ];

        for (kind, input, accepted) in cases {
            let parsed = parse(ColumnKind::Integer(kind), input);
            assert_eq!(parsed.is_ok(), accepted, "{kind:?} {input}: {parsed:?}");
            if !accepted {
                assert_eq!(
                    parsed,
                    Err(EditParseError::IntegerOutOfRange { kind }),
                    "{kind:?} {input}"
                );
            }
        }
    }

    #[test]
    fn parse_literal_text_numeric_scale_exceeded() {
        let numeric = ColumnKind::Decimal {
            precision: Some(10),
            scale: Some(2),
        };

        assert_eq!(
            parse(numeric.clone(), "1.005"),
            Err(EditParseError::ScaleExceeded { scale: 2 }),
            "the server would have rounded the value"
        );
        assert_eq!(
            parse(numeric.clone(), "123456789.5"),
            Err(EditParseError::PrecisionExceeded { precision: 10 })
        );
        assert!(matches!(parse(numeric.clone(), "12345678.50"), Ok(Value::Decimal(_))));
        assert!(
            matches!(parse(numeric.clone(), "NaN"), Ok(Value::Decimal(_))),
            "a non-finite value is the server's to judge"
        );
        assert!(
            matches!(
                parse_filter_text("1.005", &column(numeric, false)),
                Ok(Value::Decimal(_))
            ),
            "a comparison was held to the column's scale"
        );
        assert_eq!(
            parse(ColumnKind::Money { scale: Some(2) }, "0.001"),
            Err(EditParseError::ScaleExceeded { scale: 2 })
        );
    }

    #[test]
    fn text_that_is_not_a_number_is_not_a_range_problem() {
        assert_eq!(
            parse(int(IntegerWidth::W32, true), "seven"),
            Err(EditParseError::InvalidInteger)
        );
    }

    #[test]
    fn an_integer_lands_in_the_smallest_variant_that_holds_it() {
        assert_eq!(parse(int(IntegerWidth::W64, true), "7"), Ok(Value::Int(7)));
        assert_eq!(
            parse(int(IntegerWidth::W64, false), "18446744073709551615"),
            Ok(Value::UInt(u64::MAX))
        );
        assert!(matches!(
            parse(int(IntegerWidth::W128, true), "170141183460469231731687303715884105727"),
            Ok(Value::WideInt(_))
        ));
    }

    #[test]
    fn booleans_take_the_words_each_engine_uses() {
        let native = ColumnKind::Bool(BoolStorage::Native);
        for input in ["true", "TRUE", "t", "yes", "on", "1"] {
            assert_eq!(parse(native.clone(), input), Ok(Value::Bool(true)), "{input}");
        }
        for input in ["false", "F", "no", "off", "0"] {
            assert_eq!(parse(native.clone(), input), Ok(Value::Bool(false)), "{input}");
        }
        assert_eq!(parse(native, "maybe"), Err(EditParseError::InvalidBoolean));
    }

    #[test]
    fn an_integer_stored_boolean_keeps_its_exact_integer() {
        let stored = ColumnKind::Bool(BoolStorage::Integer);

        assert_eq!(parse(stored.clone(), "true"), Ok(Value::Int(1)));
        assert_eq!(parse(stored.clone(), "off"), Ok(Value::Int(0)));
        assert_eq!(
            parse(stored.clone(), "2"),
            Ok(Value::Int(2)),
            "a tinyint(1) holding 2 was read as true"
        );
        assert_eq!(parse(stored, "maybe"), Err(EditParseError::InvalidBoolean));
    }

    #[test]
    fn floats_take_the_non_finite_words() {
        assert!(
            matches!(parse(ColumnKind::Float(FloatWidth::F64), "NaN"), Ok(Value::Float64(value)) if value.is_nan())
        );
        assert_eq!(
            parse(ColumnKind::Float(FloatWidth::F64), "-infinity"),
            Ok(Value::Float64(f64::NEG_INFINITY))
        );
        assert_eq!(
            parse(ColumnKind::Float(FloatWidth::F32), "1.5"),
            Ok(Value::Float32(1.5))
        );
        assert_eq!(
            parse(ColumnKind::Float(FloatWidth::F64), "x"),
            Err(EditParseError::InvalidFloat)
        );
    }

    #[test]
    fn text_keeps_what_the_user_typed_including_spaces() {
        assert_eq!(
            parse(
                ColumnKind::Text {
                    length: TextLength::Varying(20)
                },
                "  padded  "
            ),
            Ok(Value::Text("  padded  ".to_owned())),
            "the parser trimmed a value the column can hold"
        );
    }

    #[test]
    fn xml_is_edited_as_text() {
        assert_eq!(
            parse(ColumnKind::Xml, "<a> b </a>"),
            Ok(Value::Text("<a> b </a>".to_owned()))
        );
    }

    #[test]
    fn a_column_whose_text_is_what_the_server_stores_keeps_unparseable_text() {
        // An enum label this build has not seen is still text the
        // server may accept, so it is not the app's call to refuse.
        let enumeration = column(
            ColumnKind::Enum {
                labels: vec!["draft".to_owned()],
                multiple: false,
            },
            true,
        );

        assert_eq!(
            parse_literal_text("unexpected", &enumeration),
            Ok(Value::Text("unexpected".to_owned()))
        );
    }

    #[test]
    fn invalid_json_is_refused_rather_than_stored_as_text() {
        // The server validates JSON, so saying so beside the cell
        // beats a failed transaction later.
        for dynamic_storage in [true, false] {
            assert!(
                matches!(
                    parse_literal_text("not json", &column(ColumnKind::Json { binary: false }, dynamic_storage)),
                    Err(EditParseError::InvalidJson(_))
                ),
                "dynamic_storage = {dynamic_storage}"
            );
        }
    }

    #[test]
    fn a_bad_number_is_never_kept_as_text() {
        let dynamic = column(int(IntegerWidth::W32, true), true);

        assert_eq!(
            parse_literal_text("seven", &dynamic),
            Err(EditParseError::InvalidInteger)
        );
    }

    #[test]
    fn temporals_take_their_infinities() {
        assert_eq!(parse(ColumnKind::Date, "infinity"), Ok(Value::Date(Temporal::Infinity)));
        assert_eq!(
            parse(stamp(TemporalZone::Naive), "-infinity"),
            Ok(Value::Timestamp(Temporal::NegInfinity))
        );
        assert_eq!(
            parse(ColumnKind::Date, "2024-06-15"),
            Ok(Value::Date(Temporal::Finite(
                NaiveDate::from_ymd_opt(2024, 6, 15).expect("a date")
            )))
        );
        assert_eq!(parse(ColumnKind::Date, "15/06/2024"), Err(EditParseError::InvalidDate));
    }

    #[test]
    fn a_fractional_second_survives_the_parse() {
        let Ok(Value::Time(time)) = parse(time(false, TimeRange::TimeOfDay), "12:00:00.123456") else {
            panic!("a fractional time did not parse");
        };

        assert_eq!(time.format(Some(6)), "12:00:00.123456");
    }

    fn bit_kind() -> ColumnKind {
        ColumnKind::BitString {
            length: None,
            varying: true,
        }
    }

    #[test]
    fn bits_are_zeroes_and_ones_and_nothing_else() {
        let Ok(Value::Bits(parsed)) = parse(bit_kind(), "1011") else {
            panic!("a bit string did not parse");
        };
        assert_eq!(parsed.to_string(), "1011");

        assert_eq!(parse(bit_kind(), "1021"), Err(EditParseError::InvalidBits));
        assert_eq!(parse(bit_kind(), ""), Err(EditParseError::InvalidBits));
    }

    #[test]
    fn cells_with_no_text_form_are_not_editable_as_text() {
        let array = ColumnKind::Array {
            element: Box::new(int(IntegerWidth::W32, true)),
        };
        let cases = [
            (bytes(), ReadOnlyReason::Bytes),
            (ColumnKind::Spatial, ReadOnlyReason::Spatial),
            (ColumnKind::Variant, ReadOnlyReason::Variant),
            (ColumnKind::Composite, ReadOnlyReason::Composite),
            (array, ReadOnlyReason::Composite),
        ];

        for (kind, reason) in cases {
            for dynamic_storage in [false, true] {
                assert_eq!(
                    parse_literal_text("x", &column(kind.clone(), dynamic_storage)),
                    Err(EditParseError::NotEditable(reason)),
                    "{kind:?} dynamic_storage = {dynamic_storage}"
                );
            }
        }
    }

    #[test]
    fn a_filter_on_a_binary_column_reads_the_hex_form_an_export_writes() {
        let binary = column(bytes(), false);

        assert_eq!(
            parse_filter_text(" 0x0aFF ", &binary),
            Ok(Value::Bytes(vec![0x0a, 0xff]))
        );
        assert_eq!(parse_filter_text("0X", &binary), Ok(Value::Bytes(Vec::new())));
        for text in ["ff", "0xf", "0xzz", ""] {
            assert_eq!(
                parse_filter_text(text, &binary),
                Err(EditParseError::InvalidBytes),
                "{text:?}"
            );
        }
    }

    #[test]
    fn an_offset_is_required_where_the_column_has_one() {
        assert_eq!(
            parse_timestamp_with_offset("2024-06-15 12:00:00"),
            Err(EditParseError::OffsetRequired)
        );
        assert_eq!(parse_time_with_offset("12:00:00"), Err(EditParseError::OffsetRequired));

        let Ok(Value::TimestampTz(Temporal::Finite(stamp))) = parse_timestamp_with_offset("2024-06-15 12:00:00+05:30")
        else {
            panic!("an offset timestamp did not parse");
        };
        assert_eq!(stamp.offset().local_minus_utc(), 5 * 3600 + 1800);
    }

    #[test]
    fn an_offset_column_parses_with_its_offset() {
        assert!(matches!(
            parse(stamp(TemporalZone::Offset), "2024-06-15 12:00:00+05:30"),
            Ok(Value::TimestampTz(Temporal::Finite(_)))
        ));
        assert_eq!(
            parse(stamp(TemporalZone::Offset), "2024-06-15 12:00:00"),
            Err(EditParseError::OffsetRequired)
        );
        assert!(matches!(
            parse(time(true, TimeRange::TimeOfDay), "12:00:00+02:00"),
            Ok(Value::TimeTz(_))
        ));
        assert!(matches!(
            parse(stamp(TemporalZone::Named("UTC".to_owned())), "2024-06-15 12:00:00"),
            Ok(Value::Timestamp(Temporal::Finite(_)))
        ));
    }

    #[test]
    fn a_duration_runs_past_a_day_and_below_zero() {
        let duration = time(false, TimeRange::Duration);

        let Ok(Value::Time(long)) = parse(duration.clone(), "838:59:59") else {
            panic!("the longest MySQL TIME did not parse");
        };
        assert_eq!(long.format(None), "838:59:59");
        assert!(matches!(parse(duration.clone(), "-01:30:00"), Ok(Value::Time(_))));
        assert_eq!(
            parse(duration.clone(), "839:00:00"),
            Err(EditParseError::TimeOutOfRange)
        );
        assert_eq!(parse(duration, "noon"), Err(EditParseError::InvalidTime));
        let long = time(false, TimeRange::LongDuration);
        assert!(matches!(parse(long.clone(), "-999:59:59"), Ok(Value::Time(_))));
        assert_eq!(parse(long, "1000:00:00"), Err(EditParseError::TimeOutOfRange));
        assert_eq!(
            parse(time(false, TimeRange::TimeOfDay), "25:00:00"),
            Err(EditParseError::InvalidTime)
        );
    }

    #[test]
    fn a_fraction_finer_than_the_column_keeps_is_refused() {
        let declared = |digits| ColumnKind::Timestamp {
            fractional_digits: Some(digits),
            zone: TemporalZone::Naive,
        };

        assert_eq!(
            parse(declared(0), "2024-12-31 23:59:59.5"),
            Err(EditParseError::ScaleExceeded { scale: 0 }),
            "the server would have rounded into the next day"
        );
        assert!(parse(declared(3), "2024-12-31 23:59:59.120").is_ok());
        assert_eq!(
            parse(declared(3), "2024-12-31 23:59:59.1234"),
            Err(EditParseError::ScaleExceeded { scale: 3 })
        );
        assert_eq!(
            parse(
                ColumnKind::Time {
                    fractional_digits: Some(0),
                    with_offset: false,
                    range: TimeRange::Duration,
                },
                "-01:00:00.5"
            ),
            Err(EditParseError::ScaleExceeded { scale: 0 })
        );
        assert!(
            parse_filter_text("2024-12-31 23:59:59.5", &column(declared(0), false)).is_ok(),
            "a comparison was held to the column's precision"
        );
        assert!(parse(stamp(TemporalZone::Naive), "2024-12-31 23:59:59.123456789").is_ok());
    }

    #[test]
    fn the_end_of_the_day_is_a_time_of_day() {
        let Ok(Value::Time(end)) = parse(time(false, TimeRange::TimeOfDay), "24:00:00") else {
            panic!("24:00:00 did not parse");
        };
        assert_eq!(end.format(None), "24:00:00");
        assert_eq!(
            parse(time(false, TimeRange::TimeOfDay), "24:00:01"),
            Err(EditParseError::InvalidTime)
        );
    }

    #[test]
    fn a_network_column_keeps_the_servers_own_text() {
        let Ok(Value::Other(other)) = parse(ColumnKind::Network(crate::column::NetworkFamily::Cidr), "10.0.0.0/8")
        else {
            panic!("a network value did not parse");
        };

        assert_eq!(other.text, "10.0.0.0/8");
    }

    #[test]
    fn a_dynamic_column_keeps_a_valid_date_or_time_as_typed() {
        let stamp = ColumnKind::Timestamp {
            fractional_digits: None,
            zone: TemporalZone::Naive,
        };

        assert_eq!(
            parse_literal_text(" 2024-01-01T11:00:00 ", &column(stamp.clone(), true)),
            Ok(Value::Text("2024-01-01T11:00:00".to_owned()))
        );
        assert_eq!(
            parse_literal_text("11:00", &column(time(false, TimeRange::TimeOfDay), true)),
            Ok(Value::Text("11:00".to_owned()))
        );
        assert_eq!(
            parse_literal_text("2024-02-30", &column(ColumnKind::Date, true)),
            Err(EditParseError::InvalidDate),
            "an invalid date was kept as text"
        );
        assert!(
            matches!(
                parse_literal_text("2024-01-01T11:00:00", &column(stamp, false)),
                Ok(Value::Timestamp(_))
            ),
            "a declared column lost its typed value"
        );
    }

    #[test]
    fn a_dynamic_column_keeps_any_date_or_time_form_sqlite_reads() {
        let stamp = ColumnKind::Timestamp {
            fractional_digits: None,
            zone: TemporalZone::Naive,
        };
        let time_of_day = time(false, TimeRange::TimeOfDay);
        for (input, kind) in [
            ("2024-03-10T02:30:00-08:00", &stamp),
            ("2024-03-10 10:30:00.5Z", &stamp),
            ("2024-03-10 02:30+05:45", &stamp),
            ("12:30:00+05:30", &time_of_day),
            ("12:30Z", &time_of_day),
            ("2024-03-10 02:30:00", &ColumnKind::Date),
            ("2024-03-10", &stamp),
            ("12:30:00", &ColumnKind::Date),
        ] {
            assert_eq!(
                parse_literal_text(input, &column(kind.clone(), true)),
                Ok(Value::Text(input.to_owned())),
                "{input} in {kind:?}"
            );
        }
    }

    #[test]
    fn a_date_before_year_one_reads_with_its_era() {
        let date = column(ColumnKind::Date, false);
        let day = |year, month, day| Value::Date(Temporal::Finite(NaiveDate::from_ymd_opt(year, month, day).unwrap()));

        assert_eq!(parse_literal_text("4713-01-01 BC", &date), Ok(day(-4712, 1, 1)));
        assert_eq!(parse_literal_text("0001-12-31 BC", &date), Ok(day(0, 12, 31)));
        assert_eq!(
            parse_literal_text("0000-01-01 BC", &date),
            Err(EditParseError::InvalidDate)
        );
        let instant = column(
            ColumnKind::Timestamp {
                fractional_digits: None,
                zone: TemporalZone::Offset,
            },
            false,
        );
        assert!(
            matches!(
                parse_literal_text("4713-01-01 00:00:00+00:00 BC", &instant),
                Ok(Value::TimestampTz(Temporal::Finite(stamp))) if stamp.to_datetime().year() == -4712
            ),
            "an instant before year one lost its era"
        );
    }

    #[test]
    fn a_year_past_chronos_last_keeps_its_text_once_checked() {
        let date = column(ColumnKind::Date, false);
        let kept = |text: &str| {
            Value::Other(Box::new(OtherValue {
                type_name: "t".to_owned(),
                text: text.to_owned(),
            }))
        };

        assert_eq!(
            parse_literal_text("10000-01-01", &date),
            Ok(Value::Date(Temporal::Finite(
                NaiveDate::from_ymd_opt(10_000, 1, 1).unwrap()
            )))
        );
        assert_eq!(parse_literal_text("5874897-12-31", &date), Ok(kept("5874897-12-31")));
        let last = NaiveDate::MAX.year();
        assert_eq!(
            parse_literal_text(&format!("{last}-12-31"), &date),
            Ok(Value::Date(Temporal::Finite(NaiveDate::MAX)))
        );
        let first_far = format!("{}-01-01", last + 1);
        assert_eq!(parse_literal_text(&first_far, &date), Ok(kept(&first_far)));
        assert_eq!(parse_literal_text("262144-02-29", &date), Ok(kept("262144-02-29")));
        assert_eq!(
            parse_literal_text("5874897-02-30", &date),
            Err(EditParseError::InvalidDate)
        );
        let whole_seconds = column(
            ColumnKind::Timestamp {
                fractional_digits: Some(0),
                zone: TemporalZone::Naive,
            },
            false,
        );
        assert_eq!(
            parse_literal_text("294276-12-31 23:59:59", &whole_seconds),
            Ok(kept("294276-12-31 23:59:59"))
        );
        assert_eq!(
            parse_literal_text("294276-12-31 23:59:59.5", &whole_seconds),
            Err(EditParseError::ScaleExceeded { scale: 0 })
        );
    }

    #[test]
    fn a_dynamic_column_still_refuses_text_that_is_no_date_or_time() {
        let stamp = ColumnKind::Timestamp {
            fractional_digits: None,
            zone: TemporalZone::Naive,
        };
        for input in ["2024-03-10T02:30:00+25:00", "2024-02-30 12:00", "1710037800", "soon"] {
            assert_eq!(
                parse_literal_text(input, &column(stamp.clone(), true)),
                Err(EditParseError::InvalidTimestamp),
                "{input}"
            );
        }
        assert_eq!(
            parse_literal_text("2024-03-10T02:30:00-08:00", &column(stamp, false)),
            Err(EditParseError::InvalidTimestamp),
            "a declared naive timestamp took an offset"
        );
    }
}
