use std::fmt;
use std::str::FromStr;

use thiserror::Error;

const MICROS_PER_SECOND: i64 = 1_000_000;
const MICROS_PER_MINUTE: i64 = 60 * MICROS_PER_SECOND;
const MICROS_PER_HOUR: i64 = 60 * MICROS_PER_MINUTE;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct SqlInterval {
    pub months: i32,
    pub days: i32,
    pub microseconds: i64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
pub enum IntervalParseError {
    #[error("the interval is not an ISO 8601 duration")]
    InvalidSyntax,
    #[error("the interval is out of range")]
    OutOfRange,
}

impl fmt::Display for SqlInterval {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        if self.months == 0 && self.days == 0 && self.microseconds == 0 {
            return f.write_str("PT0S");
        }
        f.write_str("P")?;
        let (years, months) = (self.months / 12, self.months % 12);
        for (amount, unit) in [(years, 'Y'), (months, 'M'), (self.days, 'D')] {
            if amount != 0 {
                write!(f, "{amount}{unit}")?;
            }
        }
        if self.microseconds == 0 {
            return Ok(());
        }
        f.write_str("T")?;
        let hours = self.microseconds / MICROS_PER_HOUR;
        let minutes = self.microseconds % MICROS_PER_HOUR / MICROS_PER_MINUTE;
        let micros = self.microseconds % MICROS_PER_MINUTE;
        for (amount, unit) in [(hours, 'H'), (minutes, 'M')] {
            if amount != 0 {
                write!(f, "{amount}{unit}")?;
            }
        }
        if micros != 0 {
            let sign = if micros < 0 { "-" } else { "" };
            let magnitude = micros.unsigned_abs();
            let fraction = format!("{:06}", magnitude % 1_000_000);
            let fraction = fraction.trim_end_matches('0');
            write!(f, "{sign}{}", magnitude / 1_000_000)?;
            if !fraction.is_empty() {
                write!(f, ".{fraction}")?;
            }
            f.write_str("S")?;
        }
        Ok(())
    }
}

impl FromStr for SqlInterval {
    type Err = IntervalParseError;

    fn from_str(text: &str) -> Result<Self, Self::Err> {
        let body = text.strip_prefix('P').ok_or(IntervalParseError::InvalidSyntax)?;
        if body.is_empty() {
            return Err(IntervalParseError::InvalidSyntax);
        }
        let (date_part, time_part) = match body.split_once('T') {
            Some((_, "")) => return Err(IntervalParseError::InvalidSyntax),
            Some((date, time)) => (date, time),
            None => (body, ""),
        };
        let mut interval = SqlInterval {
            months: 0,
            days: 0,
            microseconds: 0,
        };
        for (amount, unit) in components(date_part)? {
            let whole = whole_number(amount)?;
            match unit {
                'Y' => interval.months = add_i32(interval.months, whole.checked_mul(12))?,
                'M' => interval.months = add_i32(interval.months, Some(whole))?,
                'W' => interval.days = add_i32(interval.days, whole.checked_mul(7))?,
                'D' => interval.days = add_i32(interval.days, Some(whole))?,
                _ => return Err(IntervalParseError::InvalidSyntax),
            }
        }
        for (amount, unit) in components(time_part)? {
            let micros = match unit {
                'H' => i64::from(whole_number(amount)?).checked_mul(MICROS_PER_HOUR),
                'M' => i64::from(whole_number(amount)?).checked_mul(MICROS_PER_MINUTE),
                'S' => Some(seconds_as_micros(amount)?),
                _ => return Err(IntervalParseError::InvalidSyntax),
            };
            interval.microseconds = micros
                .and_then(|micros| interval.microseconds.checked_add(micros))
                .ok_or(IntervalParseError::OutOfRange)?;
        }
        Ok(interval)
    }
}

fn components(text: &str) -> Result<Vec<(&str, char)>, IntervalParseError> {
    let mut parts = Vec::new();
    let mut start = 0;
    for (index, ch) in text.char_indices() {
        if ch.is_ascii_alphabetic() {
            if index == start {
                return Err(IntervalParseError::InvalidSyntax);
            }
            parts.push((&text[start..index], ch));
            start = index + ch.len_utf8();
        }
    }
    if start != text.len() {
        return Err(IntervalParseError::InvalidSyntax);
    }
    Ok(parts)
}

fn whole_number(text: &str) -> Result<i32, IntervalParseError> {
    let digits = text.strip_prefix('-').unwrap_or(text);
    if digits.is_empty() || !digits.bytes().all(|b| b.is_ascii_digit()) {
        return Err(IntervalParseError::InvalidSyntax);
    }
    text.parse().map_err(|_| IntervalParseError::OutOfRange)
}

fn seconds_as_micros(text: &str) -> Result<i64, IntervalParseError> {
    let (negative, unsigned) = match text.strip_prefix('-') {
        Some(rest) => (true, rest),
        None => (false, text),
    };
    let (whole, fraction) = unsigned.split_once('.').unwrap_or((unsigned, ""));
    let valid = !whole.is_empty()
        && whole.bytes().all(|b| b.is_ascii_digit())
        && fraction.len() <= 9
        && fraction.bytes().all(|b| b.is_ascii_digit())
        && !(unsigned.contains('.') && fraction.is_empty());
    if !valid {
        return Err(IntervalParseError::InvalidSyntax);
    }
    let seconds: i64 = whole.parse().map_err(|_| IntervalParseError::OutOfRange)?;
    let fraction_micros: i64 = format!("{:0<6}", &fraction[..fraction.len().min(6)])
        .parse()
        .map_err(|_| IntervalParseError::InvalidSyntax)?;
    let magnitude = seconds
        .checked_mul(MICROS_PER_SECOND)
        .and_then(|micros| micros.checked_add(fraction_micros))
        .ok_or(IntervalParseError::OutOfRange)?;
    Ok(if negative { -magnitude } else { magnitude })
}

fn add_i32(current: i32, amount: Option<i32>) -> Result<i32, IntervalParseError> {
    amount
        .and_then(|amount| current.checked_add(amount))
        .ok_or(IntervalParseError::OutOfRange)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sql_interval_iso_negative_parts() {
        let interval: SqlInterval = "P-1Y2M-3DT-4H5M-6.5S".parse().unwrap();
        assert_eq!(
            interval,
            SqlInterval {
                months: -10,
                days: -3,
                microseconds: -4 * MICROS_PER_HOUR + 5 * MICROS_PER_MINUTE - 6_500_000,
            }
        );
        assert_eq!(interval.to_string().parse::<SqlInterval>(), Ok(interval));

        let zero: SqlInterval = "PT0S".parse().unwrap();
        assert_eq!(zero.to_string(), "PT0S");
        assert_eq!("P2W".parse::<SqlInterval>().unwrap().days, 14);
        assert_eq!(
            "P1Y2M3DT4H5M6.25S".parse::<SqlInterval>().unwrap().to_string(),
            "P1Y2M3DT4H5M6.25S"
        );
        for invalid in ["", "P", "PT", "1Y", "PXY", "P1.5Y", "PT1.S"] {
            assert!(invalid.parse::<SqlInterval>().is_err(), "{invalid:?}");
        }
    }
}
