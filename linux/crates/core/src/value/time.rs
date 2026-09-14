use std::str::FromStr;

use chrono::{NaiveTime, Timelike};
use thiserror::Error;

const NANOS_PER_SECOND: u64 = 1_000_000_000;
const MAX_HOURS: u32 = 838;
const MAX_MAGNITUDE_NANOS: u128 = (838 * 3600 + 59 * 60 + 59) * NANOS_PER_SECOND as u128;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct SqlTime {
    negative: bool,
    hours: u32,
    minutes: u8,
    seconds: u8,
    nanos: u32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
pub enum TimeRangeError {
    #[error("minutes and seconds must be below 60 and fractions below one second")]
    InvalidComponent,
    #[error("the time is outside -838:59:59 to 838:59:59")]
    OutOfRange,
    #[error("the time is not in H:MM[:SS[.fraction]] form")]
    InvalidSyntax,
}

impl SqlTime {
    pub fn new(negative: bool, hours: u32, minutes: u8, seconds: u8, nanos: u32) -> Result<Self, TimeRangeError> {
        if minutes >= 60 || seconds >= 60 || u64::from(nanos) >= NANOS_PER_SECOND {
            return Err(TimeRangeError::InvalidComponent);
        }
        let time = Self {
            negative,
            hours,
            minutes,
            seconds,
            nanos,
        };
        if hours > MAX_HOURS || time.magnitude_nanos() > MAX_MAGNITUDE_NANOS {
            return Err(TimeRangeError::OutOfRange);
        }
        Ok(Self {
            negative: negative && time.magnitude_nanos() != 0,
            ..time
        })
    }

    pub fn from_time_of_day(time: NaiveTime) -> Self {
        Self {
            negative: false,
            hours: time.hour(),
            minutes: u8::try_from(time.minute()).unwrap_or(59),
            seconds: u8::try_from(time.second()).unwrap_or(59),
            nanos: time.nanosecond().min(999_999_999),
        }
    }

    pub fn to_time_of_day(&self) -> Option<NaiveTime> {
        if self.negative || self.hours >= 24 {
            return None;
        }
        NaiveTime::from_hms_nano_opt(self.hours, u32::from(self.minutes), u32::from(self.seconds), self.nanos)
    }

    pub fn from_micros(micros: i64) -> Result<Self, TimeRangeError> {
        let magnitude = micros.unsigned_abs();
        let total_seconds = magnitude / 1_000_000;
        let hours = u32::try_from(total_seconds / 3600).map_err(|_| TimeRangeError::OutOfRange)?;
        let minutes = u8::try_from(total_seconds / 60 % 60).map_err(|_| TimeRangeError::InvalidComponent)?;
        let seconds = u8::try_from(total_seconds % 60).map_err(|_| TimeRangeError::InvalidComponent)?;
        let nanos = u32::try_from(magnitude % 1_000_000 * 1000).map_err(|_| TimeRangeError::InvalidComponent)?;
        Self::new(micros < 0, hours, minutes, seconds, nanos)
    }

    pub fn total_micros(&self) -> Option<i64> {
        if !self.nanos.is_multiple_of(1000) {
            return None;
        }
        i64::try_from(self.total_nanos() / 1000).ok()
    }

    pub fn total_nanos(&self) -> i128 {
        let magnitude = i128::try_from(self.magnitude_nanos()).unwrap_or(i128::MAX);
        if self.negative { -magnitude } else { magnitude }
    }

    pub fn format(&self, fractional_digits: Option<u8>) -> String {
        let sign = if self.negative { "-" } else { "" };
        let mut text = format!("{sign}{:02}:{:02}:{:02}", self.hours, self.minutes, self.seconds);
        let fraction = format!("{:09}", self.nanos);
        let fraction = match fractional_digits {
            Some(digits) => &fraction[..usize::from(digits.min(9))],
            None => fraction.trim_end_matches('0'),
        };
        if !fraction.is_empty() {
            text.push('.');
            text.push_str(fraction);
        }
        text
    }

    fn magnitude_nanos(&self) -> u128 {
        let seconds = u128::from(self.hours) * 3600 + u128::from(self.minutes) * 60 + u128::from(self.seconds);
        seconds * u128::from(NANOS_PER_SECOND) + u128::from(self.nanos)
    }
}

impl FromStr for SqlTime {
    type Err = TimeRangeError;

    fn from_str(text: &str) -> Result<Self, Self::Err> {
        let (negative, rest) = match text.strip_prefix('-') {
            Some(rest) => (true, rest),
            None => (false, text),
        };
        let mut parts = rest.splitn(3, ':');
        let hours = parts
            .next()
            .filter(|h| is_digits(h, 1..=4))
            .ok_or(TimeRangeError::InvalidSyntax)?;
        let minutes = parts
            .next()
            .filter(|m| is_digits(m, 2..=2))
            .ok_or(TimeRangeError::InvalidSyntax)?;
        let (seconds, nanos) = match parts.next() {
            None => ("0", 0),
            Some(seconds) => {
                let (whole, fraction) = seconds.split_once('.').unwrap_or((seconds, ""));
                if !is_digits(whole, 2..=2) || (seconds.contains('.') && !is_digits(fraction, 1..=9)) {
                    return Err(TimeRangeError::InvalidSyntax);
                }
                let padded = format!("{fraction:0<9}");
                (whole, padded.parse::<u32>().map_err(|_| TimeRangeError::InvalidSyntax)?)
            }
        };
        let parse = |digits: &str| digits.parse::<u32>().map_err(|_| TimeRangeError::InvalidSyntax);
        Self::new(
            negative,
            parse(hours)?,
            u8::try_from(parse(minutes)?).map_err(|_| TimeRangeError::InvalidComponent)?,
            u8::try_from(parse(seconds)?).map_err(|_| TimeRangeError::InvalidComponent)?,
            nanos,
        )
    }
}

fn is_digits(text: &str, lengths: std::ops::RangeInclusive<usize>) -> bool {
    lengths.contains(&text.len()) && text.bytes().all(|b| b.is_ascii_digit())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sql_time_24h_and_negative_838() {
        let midnight_end: SqlTime = "24:00:00".parse().unwrap();
        assert_eq!(midnight_end.to_time_of_day(), None);
        assert_eq!(midnight_end.format(None), "24:00:00");

        let lowest: SqlTime = "-838:59:59".parse().unwrap();
        assert_eq!(lowest.total_micros(), Some(-3_020_399_000_000));
        assert_eq!(SqlTime::from_micros(-3_020_399_000_000), Ok(lowest));
        assert_eq!("839:00:00".parse::<SqlTime>(), Err(TimeRangeError::OutOfRange));
        assert_eq!("838:59:59.5".parse::<SqlTime>(), Err(TimeRangeError::OutOfRange));
        assert_eq!("12:60".parse::<SqlTime>(), Err(TimeRangeError::InvalidComponent));
        assert_eq!("12:5".parse::<SqlTime>(), Err(TimeRangeError::InvalidSyntax));
    }

    #[test]
    fn formats_fractions_and_round_trips_time_of_day() {
        let time: SqlTime = "13:45:30.123456789".parse().unwrap();
        assert_eq!(time.format(Some(3)), "13:45:30.123");
        assert_eq!(time.format(None), "13:45:30.123456789");
        assert_eq!(time.total_micros(), None);
        let of_day = time.to_time_of_day().unwrap();
        assert_eq!(SqlTime::from_time_of_day(of_day), time);
        assert_eq!("-0:00".parse::<SqlTime>().unwrap().format(Some(0)), "00:00:00");
    }
}
