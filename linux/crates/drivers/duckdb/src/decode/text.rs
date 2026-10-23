//! A value inside a nested one, spelled as DuckDB's CAST to VARCHAR
//! spells it, so a list in an editor run reads as it does in a table tab.

use chrono::NaiveDateTime;
use duckdb::arrow::array::{Array, AsArray};
use duckdb::arrow::datatypes::{Float32Type, Float64Type, IntervalMonthDayNanoType};
use tablepro_core::value::{SqlDecimal, Temporal};

use super::{bit_string, bytes, date, decimal_mantissa, integer, string, time_of_day, timestamp, uuid};
use crate::duck_type::DuckType;

/// A scalar's text, or `None` for one that cannot be read off Arrow.
pub(super) fn scalar_text(array: &dyn Array, duck: &DuckType, row: usize) -> Option<String> {
    Some(match duck {
        DuckType::Boolean => array.as_boolean_opt()?.value(row).to_string(),
        DuckType::Integer { width, signed } => {
            tablepro_core::export::value_to_text(&integer(array, *width, *signed, row).ok()?)?
        }
        DuckType::Float => float_text(f64::from(array.as_primitive_opt::<Float32Type>()?.value(row)), true),
        DuckType::Double => float_text(array.as_primitive_opt::<Float64Type>()?.value(row), false),
        DuckType::Decimal { scale, .. } => decimal_text(decimal_mantissa(array, row).ok()?, *scale),
        DuckType::Varchar | DuckType::Enum | DuckType::Json => string(array, row).ok()?.to_owned(),
        DuckType::Blob => blob_text(bytes(array, row).ok()?),
        DuckType::Uuid => uuid(array, row).ok()?.to_string(),
        DuckType::Bit => bit_string(bytes(array, row).ok()?)?.to_string(),
        DuckType::Date => match date(
            array
                .as_primitive_opt::<duckdb::arrow::datatypes::Date32Type>()?
                .value(row),
        )
        .ok()?
        {
            Temporal::Finite(day) => crate::encode::date_text(day),
            Temporal::Infinity => "infinity".to_owned(),
            Temporal::NegInfinity => "-infinity".to_owned(),
        },
        DuckType::Time | DuckType::TimeNs => time_of_day(array, row).ok()?.format(None),
        DuckType::Timestamp(_) => stamp_text(timestamp(array, row).ok()?, ""),
        // Without the ICU extension DuckDB keeps no time zone but UTC.
        DuckType::TimestampTz => stamp_text(timestamp(array, row).ok()?, "+00"),
        DuckType::Interval => {
            let interval = array.as_primitive_opt::<IntervalMonthDayNanoType>()?.value(row);
            interval_text(
                interval.months,
                interval.days,
                super::interval_micros(interval.nanoseconds)?,
            )
        }
        _ => return None,
    })
}

/// Whether DuckDB quotes this text inside a nested value: an empty or
/// padded string, the word null, or one holding a character that would
/// read as part of the nesting.
pub(super) fn needs_quotes(text: &str, key: bool) -> bool {
    let bytes = text.as_bytes();
    let space = |byte: &u8| matches!(byte, b' ' | b'\t' | b'\n' | 0x0b | 0x0c | b'\r');
    key || bytes.is_empty()
        || bytes.first().is_some_and(space)
        || (bytes.len() >= 2 && bytes.last().is_some_and(space))
        || text.eq_ignore_ascii_case("null")
        || bytes.iter().any(|byte| {
            matches!(
                byte,
                b'"' | b'\'' | b'(' | b')' | b',' | b':' | b'=' | b'[' | b']' | b'{' | b'}'
            )
        })
}

/// A string as DuckDB writes it inside a list, a struct or a map.
pub(super) fn escaped(text: &str, key: bool) -> String {
    if !needs_quotes(text, key) {
        return text.to_owned();
    }
    let mut quoted = String::with_capacity(text.len() + 2);
    quoted.push('\'');
    for character in text.chars() {
        if matches!(character, '\'' | '\\') {
            quoted.push('\\');
        }
        quoted.push(character);
    }
    quoted.push('\'');
    quoted
}

/// A double as DuckDB prints one: the shortest digits that read back
/// as the same number, in plain notation from 1e-4 up to 1e16, with a
/// `.0` on a whole number, and in exponent notation outside that.
pub(super) fn float_text(value: f64, single: bool) -> String {
    if value.is_nan() {
        return "nan".to_owned();
    }
    if value.is_infinite() {
        return if value < 0.0 { "-inf" } else { "inf" }.to_owned();
    }
    // A FLOAT's value came from an f32, so it narrows back exactly.
    let scientific = match single {
        true => format!("{:e}", value as f32),
        false => format!("{value:e}"),
    };
    let (mantissa, exponent) = scientific.split_once('e').unwrap_or((&scientific, "0"));
    let exponent: i32 = exponent.parse().unwrap_or(0);
    let negative = mantissa.starts_with('-');
    let digits: String = mantissa.chars().filter(char::is_ascii_digit).collect();
    let sign = if negative { "-" } else { "" };
    if (-4..16).contains(&exponent) {
        let point = exponent + 1;
        let body = if point <= 0 {
            format!("0.{}{digits}", "0".repeat(point.unsigned_abs() as usize))
        } else {
            let point = point.unsigned_abs() as usize;
            let padded = format!("{digits:0<point$}");
            let (whole, fraction) = padded.split_at(point);
            let fraction = if fraction.is_empty() { "0" } else { fraction };
            format!("{whole}.{fraction}")
        };
        return format!("{sign}{body}");
    }
    let (first, rest) = digits.split_at(1.min(digits.len()));
    let mantissa = match rest.is_empty() {
        true => first.to_owned(),
        false => format!("{first}.{rest}"),
    };
    let exponent_sign = if exponent < 0 { '-' } else { '+' };
    format!("{sign}{mantissa}e{exponent_sign}{:02}", exponent.unsigned_abs())
}

fn decimal_text(mantissa: i128, scale: u8) -> String {
    let text = SqlDecimal::from_scaled_i128(mantissa, u32::from(scale)).to_string();
    let present = text.split_once('.').map_or(0, |(_, fraction)| fraction.len());
    let missing = usize::from(scale).saturating_sub(present);
    match (missing, present) {
        (0, _) => text,
        (missing, 0) => format!("{text}.{}", "0".repeat(missing)),
        (missing, _) => format!("{text}{}", "0".repeat(missing)),
    }
}

/// Printable ASCII as itself, every other byte and the quote and
/// backslash characters as `\xHH`.
fn blob_text(bytes: &[u8]) -> String {
    let mut text = String::with_capacity(bytes.len());
    for byte in bytes {
        if (32..=126).contains(byte) && !matches!(byte, b'\\' | b'\'' | b'"') {
            text.push(char::from(*byte));
        } else {
            text.push_str(&format!("\\x{byte:02X}"));
        }
    }
    text
}

fn stamp_text(stamp: Temporal<NaiveDateTime>, zone: &str) -> String {
    match stamp {
        Temporal::Finite(stamp) => format!("{}{zone}", crate::encode::stamp_text(&stamp)),
        Temporal::Infinity => "infinity".to_owned(),
        Temporal::NegInfinity => "-infinity".to_owned(),
    }
}

/// DuckDB's interval text: `1 year 2 months 3 days 04:05:06.789`.
pub(crate) fn interval_text(months: i32, days: i32, micros: i64) -> String {
    let mut parts = Vec::new();
    let unit = |amount: i32, name: &str| match amount {
        1 | -1 => format!("{amount} {name}"),
        _ => format!("{amount} {name}s"),
    };
    let (years, months) = (months / 12, months % 12);
    for (amount, name) in [(years, "year"), (months, "month"), (days, "day")] {
        if amount != 0 {
            parts.push(unit(amount, name));
        }
    }
    if micros != 0 {
        let sign = if micros < 0 { "-" } else { "" };
        let magnitude = micros.unsigned_abs();
        let (hours, rest) = (magnitude / 3_600_000_000, magnitude % 3_600_000_000);
        let (minutes, rest) = (rest / 60_000_000, rest % 60_000_000);
        let (seconds, micros) = (rest / 1_000_000, rest % 1_000_000);
        let fraction = match micros {
            0 => String::new(),
            micros => format!(".{}", format!("{micros:06}").trim_end_matches('0')),
        };
        parts.push(format!("{sign}{hours:02}:{minutes:02}:{seconds:02}{fraction}"));
    }
    match parts.is_empty() {
        true => "00:00:00".to_owned(),
        false => parts.join(" "),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn doubles_print_as_duckdb_prints_them() {
        let cases = [
            (1.0, "1.0"),
            (0.1, "0.1"),
            (1e300, "1e+300"),
            (1e-7, "1e-07"),
            (123_456_789.123, "123456789.123"),
            (1e20, "1e+20"),
            (1e15, "1000000000000000.0"),
            (1e16, "1e+16"),
            (-2.5, "-2.5"),
            (0.0001, "0.0001"),
            (1.5e-5, "1.5e-05"),
        ];
        for (value, shown) in cases {
            assert_eq!(float_text(value, false), shown, "{value}");
        }
        assert_eq!(float_text(f64::from(0.1f32), true), "0.1");
        assert_eq!(float_text(f64::NAN, false), "nan");
        assert_eq!(float_text(f64::NEG_INFINITY, false), "-inf");
    }

    #[test]
    fn a_string_is_quoted_only_where_duckdb_quotes_it() {
        let cases = [
            ("b c", "b c"),
            ("", "''"),
            ("it's", "'it\\'s'"),
            ("a\\b", "a\\b"),
            ("a,b", "'a,b'"),
            (" lead", "' lead'"),
            ("trail ", "'trail '"),
            ("NULL", "'NULL'"),
            ("tab\tx", "tab\tx"),
            ("a(b)", "'a(b)'"),
        ];
        for (text, shown) in cases {
            assert_eq!(escaped(text, false), shown, "{text:?}");
        }
        assert_eq!(escaped("a", true), "'a'", "a struct key is always quoted");
    }

    #[test]
    fn intervals_print_as_duckdb_prints_them() {
        assert_eq!(
            interval_text(14, 3, 14_706_789_000),
            "1 year 2 months 3 days 04:05:06.789"
        );
        assert_eq!(interval_text(0, -1, 0), "-1 day");
        assert_eq!(interval_text(0, 0, 1), "00:00:00.000001");
        assert_eq!(interval_text(-27, 0, 0), "-2 years -3 months");
        assert_eq!(interval_text(0, 0, 90_000_000_000), "25:00:00");
        assert_eq!(interval_text(0, 0, 0), "00:00:00");
    }

    #[test]
    fn blobs_and_decimals_print_as_duckdb_prints_them() {
        assert_eq!(blob_text(&[0xaa, b'a', b'\\']), "\\xAAa\\x5C");
        assert_eq!(decimal_text(150, 2), "1.50");
        assert_eq!(decimal_text(-5, 3), "-0.005");
        assert_eq!(decimal_text(12, 0), "12");
    }
}
