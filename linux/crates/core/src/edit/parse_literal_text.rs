use chrono::{DateTime, NaiveDate, NaiveDateTime, NaiveTime};

use crate::column::{ColumnKind, ColumnType, FloatKind, IntegerKind};
use crate::value::{
    BitString, JsonText, OffsetTimestamp, OtherValue, SqlDecimal, SqlInterval, SqlTime, Temporal, TimeWithOffset,
    Value, WideInteger,
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
    match strict(input, column) {
        Ok(value) => Ok(value),
        Err(error) if column.dynamic_storage() && keeps_text_on_failure(column.kind()) => {
            let _ = error;
            Ok(Value::Text(input.to_owned()))
        }
        Err(error) => Err(error),
    }
}

/// Whether a failed parse should fall back to the text as typed.
///
/// Only for kinds whose text form is what the server stores anyway. A
/// bad number is still a bad number.
fn keeps_text_on_failure(kind: ColumnKind) -> bool {
    kind.is_textual() || matches!(kind, ColumnKind::Other | ColumnKind::Network | ColumnKind::Geometry)
}

fn strict(input: &str, column: &ColumnType) -> Result<Value, EditParseError> {
    let trimmed = input.trim();
    match column.kind() {
        ColumnKind::Boolean => parse_bool(trimmed),
        ColumnKind::Integer(kind) => parse_integer(trimmed, kind),
        ColumnKind::Decimal => parse_decimal(trimmed),
        ColumnKind::Float(kind) => parse_float(trimmed, kind),
        // Text keeps what the user typed, spaces included: a trailing
        // space is a value, not a typo the app gets to remove.
        ColumnKind::Text(_) | ColumnKind::Enumeration | ColumnKind::Set => Ok(Value::Text(input.to_owned())),
        ColumnKind::Json => JsonText::parse(input.to_owned())
            .map(Value::Json)
            .map_err(|error| EditParseError::InvalidJson(error.to_string())),
        ColumnKind::Uuid => trimmed
            .parse()
            .map(Value::Uuid)
            .map_err(|_| EditParseError::InvalidUuid),
        ColumnKind::Date => parse_date(trimmed),
        ColumnKind::Time => parse_time(trimmed),
        ColumnKind::Timestamp => parse_timestamp(trimmed),
        ColumnKind::Interval => trimmed
            .parse::<SqlInterval>()
            .map(Value::Interval)
            .map_err(|_| EditParseError::InvalidInterval),
        ColumnKind::BitString => parse_bits(trimmed),
        ColumnKind::Network | ColumnKind::Geometry | ColumnKind::Other => Ok(Value::Other(Box::new(OtherValue {
            type_name: column.name().as_sql().to_owned(),
            text: input.to_owned(),
        }))),
        ColumnKind::Binary => Err(EditParseError::NotEditable(ReadOnlyReason::Bytes)),
        ColumnKind::Array => Err(EditParseError::NotEditable(ReadOnlyReason::Composite)),
    }
}

fn parse_bool(input: &str) -> Result<Value, EditParseError> {
    match input.to_ascii_lowercase().as_str() {
        "true" | "t" | "yes" | "y" | "on" | "1" => Ok(Value::Bool(true)),
        "false" | "f" | "no" | "n" | "off" | "0" => Ok(Value::Bool(false)),
        _ => Err(EditParseError::InvalidBoolean),
    }
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

fn parse_decimal(input: &str) -> Result<Value, EditParseError> {
    input
        .parse::<SqlDecimal>()
        .map(Value::Decimal)
        .map_err(EditParseError::InvalidDecimal)
}

fn parse_float(input: &str, kind: FloatKind) -> Result<Value, EditParseError> {
    if let Some(value) = non_finite(input) {
        return Ok(match kind {
            FloatKind::F32 => Value::Float32(value as f32),
            FloatKind::F64 => Value::Float64(value),
        });
    }
    match kind {
        FloatKind::F32 => input
            .parse::<f32>()
            .map(Value::Float32)
            .map_err(|_| EditParseError::InvalidFloat),
        FloatKind::F64 => input
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
    match column.kind() {
        // A filter on a binary or array column compares text the user
        // typed; the dialect decides what that means.
        ColumnKind::Binary | ColumnKind::Array => Ok(Value::Text(input.to_owned())),
        _ => parse_literal_text(input, column),
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
    use crate::column::{CatalogType, ColumnKind, ReadForm, SqlTypeExpr, TextKind};

    use super::*;

    fn column(kind: ColumnKind, dynamic_storage: bool) -> ColumnType {
        ColumnType::new(
            SqlTypeExpr::from_catalog_text("t"),
            kind,
            CatalogType::Unknown,
            dynamic_storage,
            ReadForm::Native,
        )
    }

    fn parse(kind: ColumnKind, input: &str) -> Result<Value, EditParseError> {
        parse_literal_text(input, &column(kind, false))
    }

    #[test]
    fn parse_filter_text_integer_bounds_i8_to_u64() {
        let cases = [
            (IntegerKind::I8, "127", true),
            (IntegerKind::I8, "128", false),
            (IntegerKind::I8, "-128", true),
            (IntegerKind::I8, "-129", false),
            (IntegerKind::U8, "255", true),
            (IntegerKind::U8, "-1", false),
            (IntegerKind::I32, "2147483647", true),
            (IntegerKind::I32, "2147483648", false),
            (IntegerKind::U64, "18446744073709551615", true),
            (IntegerKind::U64, "18446744073709551616", false),
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
    fn text_that_is_not_a_number_is_not_a_range_problem() {
        assert_eq!(
            parse(ColumnKind::Integer(IntegerKind::I32), "seven"),
            Err(EditParseError::InvalidInteger)
        );
    }

    #[test]
    fn an_integer_lands_in_the_smallest_variant_that_holds_it() {
        assert_eq!(parse(ColumnKind::Integer(IntegerKind::I64), "7"), Ok(Value::Int(7)));
        assert_eq!(
            parse(ColumnKind::Integer(IntegerKind::U64), "18446744073709551615"),
            Ok(Value::UInt(u64::MAX))
        );
        assert!(matches!(
            parse(
                ColumnKind::Integer(IntegerKind::I128),
                "170141183460469231731687303715884105727"
            ),
            Ok(Value::WideInt(_))
        ));
    }

    #[test]
    fn booleans_take_the_words_each_engine_uses() {
        for input in ["true", "TRUE", "t", "yes", "on", "1"] {
            assert_eq!(parse(ColumnKind::Boolean, input), Ok(Value::Bool(true)), "{input}");
        }
        for input in ["false", "F", "no", "off", "0"] {
            assert_eq!(parse(ColumnKind::Boolean, input), Ok(Value::Bool(false)), "{input}");
        }
        assert_eq!(parse(ColumnKind::Boolean, "maybe"), Err(EditParseError::InvalidBoolean));
    }

    #[test]
    fn floats_take_the_non_finite_words() {
        assert!(matches!(parse(ColumnKind::Float(FloatKind::F64), "NaN"), Ok(Value::Float64(value)) if value.is_nan()));
        assert_eq!(
            parse(ColumnKind::Float(FloatKind::F64), "-infinity"),
            Ok(Value::Float64(f64::NEG_INFINITY))
        );
        assert_eq!(parse(ColumnKind::Float(FloatKind::F32), "1.5"), Ok(Value::Float32(1.5)));
        assert_eq!(
            parse(ColumnKind::Float(FloatKind::F64), "x"),
            Err(EditParseError::InvalidFloat)
        );
    }

    #[test]
    fn text_keeps_what_the_user_typed_including_spaces() {
        assert_eq!(
            parse(ColumnKind::Text(TextKind::Variable), "  padded  "),
            Ok(Value::Text("  padded  ".to_owned())),
            "the parser trimmed a value the column can hold"
        );
    }

    #[test]
    fn a_dynamic_storage_column_keeps_unparseable_text() {
        // The server decides what it accepts here, so a strict parse
        // failure is not the app's call to make.
        let json = column(ColumnKind::Json, true);

        assert_eq!(
            parse_literal_text("not json", &json),
            Ok(Value::Text("not json".to_owned()))
        );
        assert!(matches!(
            parse_literal_text("not json", &column(ColumnKind::Json, false)),
            Err(EditParseError::InvalidJson(_))
        ));
    }

    #[test]
    fn a_bad_number_is_never_kept_as_text() {
        let dynamic = column(ColumnKind::Integer(IntegerKind::I32), true);

        assert_eq!(
            parse_literal_text("seven", &dynamic),
            Err(EditParseError::InvalidInteger)
        );
    }

    #[test]
    fn temporals_take_their_infinities() {
        assert_eq!(parse(ColumnKind::Date, "infinity"), Ok(Value::Date(Temporal::Infinity)));
        assert_eq!(
            parse(ColumnKind::Timestamp, "-infinity"),
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
        let Ok(Value::Time(time)) = parse(ColumnKind::Time, "12:00:00.123456") else {
            panic!("a fractional time did not parse");
        };

        assert_eq!(time.format(Some(6)), "12:00:00.123456");
    }

    #[test]
    fn bits_are_zeroes_and_ones_and_nothing_else() {
        let Ok(Value::Bits(bits)) = parse(ColumnKind::BitString, "1011") else {
            panic!("a bit string did not parse");
        };
        assert_eq!(bits.to_string(), "1011");

        assert_eq!(parse(ColumnKind::BitString, "1021"), Err(EditParseError::InvalidBits));
        assert_eq!(parse(ColumnKind::BitString, ""), Err(EditParseError::InvalidBits));
    }

    #[test]
    fn binary_and_array_cells_are_not_editable_as_text() {
        assert_eq!(
            parse(ColumnKind::Binary, "0xff"),
            Err(EditParseError::NotEditable(ReadOnlyReason::Bytes))
        );
        assert_eq!(
            parse(ColumnKind::Array, "{1,2}"),
            Err(EditParseError::NotEditable(ReadOnlyReason::Composite))
        );
    }

    #[test]
    fn a_filter_on_a_binary_column_compares_text() {
        let binary = column(ColumnKind::Binary, false);

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
    fn a_network_column_keeps_the_servers_own_text() {
        let Ok(Value::Other(other)) = parse(ColumnKind::Network, "10.0.0.0/8") else {
            panic!("a network value did not parse");
        };

        assert_eq!(other.text, "10.0.0.0/8");
    }
}
