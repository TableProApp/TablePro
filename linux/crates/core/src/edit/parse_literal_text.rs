use chrono::{DateTime, NaiveDate, NaiveDateTime, NaiveTime};

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
        Ok(value) => Ok(value),
        Err(_) if column.dynamic_storage && keeps_text_on_failure(&column.kind) => Ok(Value::Text(input.to_owned())),
        Err(error) => Err(error),
    }
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
            .map_err(|error| EditParseError::InvalidJson(error.to_string())),
        ColumnKind::Uuid => trimmed
            .parse()
            .map(Value::Uuid)
            .map_err(|_| EditParseError::InvalidUuid),
        ColumnKind::Date => parse_date(trimmed),
        ColumnKind::Time { with_offset: true, .. } => parse_time_with_offset(trimmed),
        ColumnKind::Time {
            range: TimeRange::Duration,
            ..
        } => parse_duration(trimmed),
        ColumnKind::Time { .. } => parse_time(trimmed),
        ColumnKind::Timestamp {
            zone: TemporalZone::Offset,
            ..
        } => parse_timestamp_with_offset(trimmed),
        ColumnKind::Timestamp { .. } => parse_timestamp(trimmed),
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
    NaiveDate::parse_from_str(input, "%Y-%m-%d")
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
    Err(EditParseError::InvalidTime)
}

/// MySQL TIME, which measures an amount of time and so runs past 24
/// hours and below zero.
fn parse_duration(input: &str) -> Result<Value, EditParseError> {
    input.parse::<SqlTime>().map(Value::Time).map_err(|error| match error {
        TimeRangeError::OutOfRange => EditParseError::TimeOutOfRange,
        TimeRangeError::InvalidComponent | TimeRangeError::InvalidSyntax => EditParseError::InvalidTime,
    })
}

fn parse_timestamp(input: &str) -> Result<Value, EditParseError> {
    if let Some(temporal) = infinite_temporal(input) {
        return Ok(Value::Timestamp(temporal));
    }
    for format in ["%Y-%m-%d %H:%M:%S%.f", "%Y-%m-%dT%H:%M:%S%.f", "%Y-%m-%d %H:%M"] {
        if let Ok(stamp) = NaiveDateTime::parse_from_str(input, format) {
            return Ok(Value::Timestamp(Temporal::Finite(stamp)));
        }
    }
    Err(EditParseError::InvalidTimestamp)
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
        // A filter on a column with no editable text form compares text
        // the user typed; the dialect decides what that means.
        ColumnKind::Bytes { .. }
        | ColumnKind::Spatial
        | ColumnKind::Array { .. }
        | ColumnKind::Variant
        | ColumnKind::Composite => Ok(Value::Text(input.to_owned())),
        _ => parse(input, column, Purpose::Compare),
    }
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
    for format in [
        "%Y-%m-%d %H:%M:%S%.f%#z",
        "%Y-%m-%dT%H:%M:%S%.f%#z",
        "%Y-%m-%d %H:%M%#z",
    ] {
        if let Ok(stamp) = DateTime::parse_from_str(trimmed, format) {
            return Ok(Value::TimestampTz(Temporal::Finite(OffsetTimestamp::from_datetime(
                stamp,
            ))));
        }
    }
    if NaiveDateTime::parse_from_str(trimmed, "%Y-%m-%d %H:%M:%S%.f").is_ok() {
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
    fn a_filter_on_a_binary_column_compares_text() {
        let binary = column(bytes(), false);

        assert_eq!(
            parse_filter_text("0xff", &binary),
            Ok(Value::Text("0xff".to_owned())),
            "a filter could not be typed against a binary column"
        );
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
        assert_eq!(
            parse(time(false, TimeRange::TimeOfDay), "25:00:00"),
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
}
