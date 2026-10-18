use std::cmp::Ordering;
use std::fmt;
use std::str::FromStr;

use thiserror::Error;

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct SqlDecimal(DecimalRepr);

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
enum DecimalRepr {
    Finite {
        negative: bool,
        coefficient: Box<str>,
        scale: u32,
    },
    NaN,
    Infinity,
    NegInfinity,
}

#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum DecimalParseError {
    #[error("the decimal is empty")]
    Empty,
    #[error("the decimal is not a number")]
    InvalidSyntax,
    #[error("the decimal exponent is out of range")]
    ExponentOutOfRange,
    #[error("the decimal has {integer_digits} integer digits and scale {scale}, which is too large")]
    TooManyDigits { integer_digits: u64, scale: u64 },
}

struct Scanned<'a> {
    negative: bool,
    integer: &'a str,
    fraction: &'a str,
    exponent: i64,
}

impl SqlDecimal {
    pub const MAX_INTEGER_DIGITS: u32 = 131_072;
    pub const MAX_SCALE: u32 = 16_383;

    pub fn nan() -> Self {
        Self(DecimalRepr::NaN)
    }

    pub fn infinity(negative: bool) -> Self {
        Self(if negative {
            DecimalRepr::NegInfinity
        } else {
            DecimalRepr::Infinity
        })
    }

    pub fn from_scaled_i128(mantissa: i128, scale: u32) -> Self {
        Self::finite(
            mantissa < 0,
            mantissa.unsigned_abs().to_string().into_boxed_str(),
            scale,
        )
    }

    pub fn from_parts(negative: bool, coefficient: &str, scale: u32) -> Result<Self, DecimalParseError> {
        if coefficient.is_empty() {
            return Err(DecimalParseError::Empty);
        }
        if !coefficient.bytes().all(|b| b.is_ascii_digit()) {
            return Err(DecimalParseError::InvalidSyntax);
        }
        let significant = coefficient.trim_start_matches('0');
        let digits = if significant.is_empty() { "0" } else { significant };
        check_bounds(digits.len() as u64, u64::from(scale))?;
        Ok(Self::finite(negative, digits.into(), scale))
    }

    fn finite(negative: bool, coefficient: Box<str>, scale: u32) -> Self {
        let negative = negative && &*coefficient != "0";
        Self(DecimalRepr::Finite {
            negative,
            coefficient,
            scale,
        })
    }

    pub fn is_finite(&self) -> bool {
        matches!(self.0, DecimalRepr::Finite { .. })
    }

    pub fn scale(&self) -> Option<u32> {
        match &self.0 {
            DecimalRepr::Finite { scale, .. } => Some(*scale),
            _ => None,
        }
    }

    pub fn precision(&self) -> Option<u32> {
        match &self.0 {
            DecimalRepr::Finite { coefficient, scale, .. } => {
                Some(u32::try_from(coefficient.len()).unwrap_or(u32::MAX).max(*scale))
            }
            _ => None,
        }
    }

    pub fn integer_digits(&self) -> Option<u32> {
        match &self.0 {
            DecimalRepr::Finite { coefficient, .. } if &**coefficient == "0" => Some(0),
            DecimalRepr::Finite { coefficient, scale, .. } => Some(
                u32::try_from(coefficient.len())
                    .unwrap_or(u32::MAX)
                    .saturating_sub(*scale),
            ),
            _ => None,
        }
    }

    pub fn to_scaled_i128(&self) -> Option<(i128, u32)> {
        let DecimalRepr::Finite {
            negative,
            coefficient,
            scale,
        } = &self.0
        else {
            return None;
        };
        if coefficient.len() > 39 {
            return None;
        }
        let magnitude = coefficient.parse::<i128>().ok()?;
        Some((if *negative { -magnitude } else { magnitude }, *scale))
    }

    pub fn fits(&self, precision: u32, scale: u32) -> bool {
        let DecimalRepr::Finite {
            coefficient,
            scale: own_scale,
            ..
        } = &self.0
        else {
            return false;
        };
        let trailing_zeros = coefficient.bytes().rev().take_while(|b| *b == b'0').count();
        let droppable = u32::try_from(trailing_zeros).unwrap_or(u32::MAX).min(*own_scale);
        let fraction_digits = own_scale - droppable;
        let integer_digits = self.integer_digits().unwrap_or(u32::MAX);
        fraction_digits <= scale && integer_digits <= precision.saturating_sub(scale)
    }

    pub fn cmp_numeric(&self, other: &Self) -> Ordering {
        match (&self.0, &other.0) {
            (DecimalRepr::NaN, DecimalRepr::NaN) => Ordering::Equal,
            (DecimalRepr::NaN, _) => Ordering::Greater,
            (_, DecimalRepr::NaN) => Ordering::Less,
            (DecimalRepr::Infinity, DecimalRepr::Infinity) | (DecimalRepr::NegInfinity, DecimalRepr::NegInfinity) => {
                Ordering::Equal
            }
            (DecimalRepr::Infinity, _) | (_, DecimalRepr::NegInfinity) => Ordering::Greater,
            (DecimalRepr::NegInfinity, _) | (_, DecimalRepr::Infinity) => Ordering::Less,
            (
                DecimalRepr::Finite {
                    negative: left_negative,
                    ..
                },
                DecimalRepr::Finite {
                    negative: right_negative,
                    ..
                },
            ) => match (left_negative, right_negative) {
                (false, true) => Ordering::Greater,
                (true, false) => Ordering::Less,
                (false, false) => self.cmp_magnitude(other),
                (true, true) => other.cmp_magnitude(self),
            },
        }
    }

    fn cmp_magnitude(&self, other: &Self) -> Ordering {
        let (Some(left_integer), Some(right_integer)) = (self.integer_digits(), other.integer_digits()) else {
            return Ordering::Equal;
        };
        let (Some(left_scale), Some(right_scale)) = (self.scale(), other.scale()) else {
            return Ordering::Equal;
        };
        let integer = left_integer.max(right_integer);
        let scale = left_scale.max(right_scale);
        self.aligned_digits(integer, scale)
            .cmp(other.aligned_digits(integer, scale))
    }

    fn aligned_digits(&self, integer: u32, scale: u32) -> impl Iterator<Item = u8> + '_ {
        let (coefficient, own_scale) = match &self.0 {
            DecimalRepr::Finite { coefficient, scale, .. } => (&**coefficient, *scale),
            _ => ("0", 0),
        };
        let coefficient = if coefficient == "0" { "" } else { coefficient };
        let occupied = u64::from(integer) + u64::from(own_scale);
        let left = occupied.saturating_sub(coefficient.len() as u64);
        let right = u64::from(scale - own_scale.min(scale));
        std::iter::repeat_n(b'0', usize::try_from(left).unwrap_or(0))
            .chain(coefficient.bytes())
            .chain(std::iter::repeat_n(b'0', usize::try_from(right).unwrap_or(0)))
    }
}

impl FromStr for SqlDecimal {
    type Err = DecimalParseError;

    fn from_str(text: &str) -> Result<Self, Self::Err> {
        let text = text.trim();
        if text.is_empty() {
            return Err(DecimalParseError::Empty);
        }
        if let Some(special) = special_value(text) {
            return Ok(special);
        }
        let scanned = scan(text)?;
        let integer_trimmed = scanned.integer.trim_start_matches('0');
        let leading_fraction_zeros = if integer_trimmed.is_empty() {
            scanned.fraction.len() - scanned.fraction.trim_start_matches('0').len()
        } else {
            0
        };
        let significant = integer_trimmed.len() + scanned.fraction.len() - leading_fraction_zeros;
        let scale_raw = (scanned.fraction.len() as i64)
            .checked_sub(scanned.exponent)
            .ok_or(DecimalParseError::ExponentOutOfRange)?;

        if significant == 0 {
            let scale = scale_raw.max(0) as u64;
            check_bounds(0, scale)?;
            return Ok(Self::finite(false, "0".into(), scale as u32));
        }
        let appended_zeros = if scale_raw < 0 { scale_raw.unsigned_abs() } else { 0 };
        let scale = scale_raw.max(0) as u64;
        let coefficient_len = (significant as u64)
            .checked_add(appended_zeros)
            .ok_or(DecimalParseError::ExponentOutOfRange)?;
        check_bounds(coefficient_len, scale)?;

        let mut coefficient = String::with_capacity(coefficient_len as usize);
        coefficient.push_str(integer_trimmed);
        coefficient.push_str(&scanned.fraction[leading_fraction_zeros..]);
        coefficient.extend(std::iter::repeat_n('0', appended_zeros as usize));
        Ok(Self::finite(
            scanned.negative,
            coefficient.into_boxed_str(),
            scale as u32,
        ))
    }
}

impl fmt::Display for SqlDecimal {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let DecimalRepr::Finite {
            negative,
            coefficient,
            scale,
        } = &self.0
        else {
            return f.write_str(match self.0 {
                DecimalRepr::NaN => "NaN",
                DecimalRepr::Infinity => "Infinity",
                _ => "-Infinity",
            });
        };
        if *negative {
            f.write_str("-")?;
        }
        let scale = *scale as usize;
        if scale == 0 {
            return f.write_str(coefficient);
        }
        if coefficient.len() > scale {
            let (integer, fraction) = coefficient.split_at(coefficient.len() - scale);
            return write!(f, "{integer}.{fraction}");
        }
        let digits = if &**coefficient == "0" { "" } else { coefficient };
        f.write_str("0.")?;
        for _ in digits.len()..scale {
            f.write_str("0")?;
        }
        f.write_str(digits)
    }
}

fn special_value(text: &str) -> Option<SqlDecimal> {
    let lower = |candidate: &str| text.eq_ignore_ascii_case(candidate);
    if lower("nan") {
        Some(SqlDecimal::nan())
    } else if lower("infinity") || lower("inf") || lower("+infinity") || lower("+inf") {
        Some(SqlDecimal::infinity(false))
    } else if lower("-infinity") || lower("-inf") {
        Some(SqlDecimal::infinity(true))
    } else {
        None
    }
}

fn scan(text: &str) -> Result<Scanned<'_>, DecimalParseError> {
    let bytes = text.as_bytes();
    let mut index = 0;
    let negative = match bytes.first() {
        Some(b'-') => {
            index += 1;
            true
        }
        Some(b'+') => {
            index += 1;
            false
        }
        _ => false,
    };
    let integer_start = index;
    while bytes.get(index).is_some_and(u8::is_ascii_digit) {
        index += 1;
    }
    let integer = &text[integer_start..index];
    let mut fraction = "";
    if bytes.get(index) == Some(&b'.') {
        index += 1;
        let fraction_start = index;
        while bytes.get(index).is_some_and(u8::is_ascii_digit) {
            index += 1;
        }
        fraction = &text[fraction_start..index];
    }
    if integer.is_empty() && fraction.is_empty() {
        return Err(DecimalParseError::InvalidSyntax);
    }
    let mut exponent = 0i64;
    if matches!(bytes.get(index), Some(b'e' | b'E')) {
        index += 1;
        let exponent_negative = match bytes.get(index) {
            Some(b'-') => {
                index += 1;
                true
            }
            Some(b'+') => {
                index += 1;
                false
            }
            _ => false,
        };
        let digits_start = index;
        while bytes.get(index).is_some_and(u8::is_ascii_digit) {
            index += 1;
        }
        let digits = text[digits_start..index].trim_start_matches('0');
        if index == digits_start {
            return Err(DecimalParseError::InvalidSyntax);
        }
        if digits.len() > 18 {
            return Err(DecimalParseError::ExponentOutOfRange);
        }
        let magnitude = if digits.is_empty() {
            0
        } else {
            digits
                .parse::<i64>()
                .map_err(|_| DecimalParseError::ExponentOutOfRange)?
        };
        exponent = if exponent_negative { -magnitude } else { magnitude };
    }
    if index != bytes.len() {
        return Err(DecimalParseError::InvalidSyntax);
    }
    Ok(Scanned {
        negative,
        integer,
        fraction,
        exponent,
    })
}

fn check_bounds(coefficient_len: u64, scale: u64) -> Result<(), DecimalParseError> {
    let integer_digits = coefficient_len.saturating_sub(scale);
    if integer_digits > u64::from(SqlDecimal::MAX_INTEGER_DIGITS) || scale > u64::from(SqlDecimal::MAX_SCALE) {
        return Err(DecimalParseError::TooManyDigits { integer_digits, scale });
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(text: &str) -> SqlDecimal {
        text.parse().unwrap()
    }

    #[test]
    fn sql_decimal_round_trips() {
        let cases = [
            ("0", "0"),
            ("-0", "0"),
            ("-0.00", "0.00"),
            ("12.30", "12.30"),
            ("+007.5", "7.5"),
            (".5", "0.5"),
            ("5.", "5"),
            ("1e-40", "0.0000000000000000000000000000000000000001"),
            ("1E+3", "1000"),
            ("-12.5e1", "-125"),
            ("NaN", "NaN"),
            ("inf", "Infinity"),
            ("-Infinity", "-Infinity"),
        ];
        for (input, expected) in cases {
            let decimal = parse(input);
            assert_eq!(decimal.to_string(), expected, "{input}");
            assert_eq!(parse(&decimal.to_string()), decimal, "{input}");
        }
        let long = "9".repeat(1000);
        assert_eq!(parse(&long).to_string(), long);
        assert_eq!(parse("12.30").scale(), Some(2));
        for invalid in ["", "abc", "1.2.3", "e5", "1e", "--1", "1 000"] {
            assert!(invalid.parse::<SqlDecimal>().is_err(), "{invalid:?}");
        }
    }

    #[test]
    fn sql_decimal_fits_and_integer_digits() {
        assert_eq!(parse("123.45").integer_digits(), Some(3));
        assert_eq!(parse("0.05").integer_digits(), Some(0));
        assert_eq!(parse("0.05").precision(), Some(2));
        assert!(parse("123.45").fits(5, 2));
        assert!(!parse("123.45").fits(4, 2));
        assert!(!parse("123.456").fits(6, 2));
        assert!(parse("1.50").fits(2, 1));
        assert!(parse("0.00").fits(2, 2));
        assert!(!SqlDecimal::nan().fits(10, 2));
    }

    #[test]
    fn to_scaled_i128_at_10e38_minus_1() {
        let max = "9".repeat(38);
        assert_eq!(parse(&max).to_scaled_i128(), Some((max.parse::<i128>().unwrap(), 0)));
        assert_eq!(parse("-1.25").to_scaled_i128(), Some((-125, 2)));
        assert_eq!(parse(&"9".repeat(40)).to_scaled_i128(), None);
        assert_eq!(SqlDecimal::from_scaled_i128(-125, 2).to_string(), "-1.25");
    }

    #[test]
    fn cmp_numeric_orders_across_scales_and_specials() {
        let ordered = [
            "-Infinity",
            "-10",
            "-1.5",
            "-0.05",
            "0",
            "0.001",
            "0.05",
            "1",
            "1.50",
            "10",
            "Infinity",
            "NaN",
        ];
        for pair in ordered.windows(2) {
            assert_eq!(parse(pair[0]).cmp_numeric(&parse(pair[1])), Ordering::Less, "{pair:?}");
        }
        assert_eq!(parse("1.5").cmp_numeric(&parse("1.50")), Ordering::Equal);
    }

    #[test]
    fn from_parts_validates_digits_and_bounds() {
        assert_eq!(SqlDecimal::from_parts(true, "00120", 1).unwrap().to_string(), "-12.0");
        assert_eq!(
            SqlDecimal::from_parts(false, "12a", 0),
            Err(DecimalParseError::InvalidSyntax)
        );
        assert!(matches!(
            SqlDecimal::from_parts(false, "1", SqlDecimal::MAX_SCALE + 1),
            Err(DecimalParseError::TooManyDigits { .. })
        ));
    }
}
