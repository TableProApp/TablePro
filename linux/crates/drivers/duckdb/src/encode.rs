//! Values as DuckDB takes them in: bound as parameters, or as the text
//! a literal casts.
//!
//! A value DuckDB has a binding for goes as itself. The rest go as text
//! the dialect casts, which DuckDB parses exactly: a decimal wider than
//! any binding, a nanosecond timestamp, a time with an offset.

use chrono::{Datelike, NaiveDate, NaiveDateTime, Timelike};
use duckdb::types::{TimeUnit, Value as Bound};
use tablepro_core::DriverError;
use tablepro_core::export::value_to_text;
use tablepro_core::statement::BoundParam;
use tablepro_core::value::{SqlTime, Temporal, Value};

const UNIX_EPOCH_DAYS_FROM_CE: i32 = 719_163;

pub(crate) fn bind_all(params: &[BoundParam]) -> Result<Vec<Bound>, DriverError> {
    params.iter().map(|param| bind(param.value())).collect()
}

pub(crate) fn bind(value: &Value) -> Result<Bound, DriverError> {
    Ok(match value {
        Value::Null => Bound::Null,
        Value::Bool(flag) => Bound::Boolean(*flag),
        Value::Int(integer) => Bound::BigInt(*integer),
        Value::UInt(integer) => Bound::UBigInt(*integer),
        Value::WideInt(integer) => match (integer.to_i128(), integer.to_u128()) {
            (Some(signed), _) => Bound::HugeInt(signed),
            (None, Some(unsigned)) => Bound::UHugeInt(unsigned),
            (None, None) => Bound::Text(integer.to_string()),
        },
        Value::Float32(real) => Bound::Float(*real),
        Value::Float64(real) => Bound::Double(*real),
        Value::Bytes(bytes) => Bound::Blob(bytes.clone()),
        Value::Date(Temporal::Finite(day)) => Bound::Date32(day.num_days_from_ce() - UNIX_EPOCH_DAYS_FROM_CE),
        Value::Time(time) if time.total_nanos() % 1_000 == 0 => match time.total_micros() {
            Some(micros) if micros >= 0 => Bound::Time64(TimeUnit::Microsecond, micros),
            _ => text(value)?,
        },
        // The crate binds nanoseconds, which hold a smaller span than
        // DuckDB's microseconds; a longer one goes as DuckDB's text.
        Value::Interval(interval) => match interval.microseconds.checked_mul(1_000) {
            Some(nanos) => Bound::Interval {
                months: interval.months,
                days: interval.days,
                nanos,
            },
            None => text(value)?,
        },
        Value::Undecodable(_) => {
            return Err(DriverError::Protocol(
                "a value the driver could not read was bound".to_owned(),
            ));
        }
        _ => text(value)?,
    })
}

fn text(value: &Value) -> Result<Bound, DriverError> {
    duck_text(value)
        .map(Bound::Text)
        .ok_or_else(|| DriverError::Protocol(format!("a {} value has no text", value.variant_name())))
}

/// The text DuckDB reads back as `value` when cast to the value's type.
pub(crate) fn duck_text(value: &Value) -> Option<String> {
    Some(match value {
        Value::Null | Value::Undecodable(_) => return None,
        Value::Other(other) => other.text.clone(),
        Value::Date(day) => temporal(day, |day| date_text(*day)),
        Value::Time(time) => time_text(time),
        Value::TimeTz(time) => format!(
            "{}{}",
            time_text(&time.time),
            offset_text(time.offset.local_minus_utc())
        ),
        Value::Timestamp(stamp) => temporal(stamp, stamp_text),
        Value::TimestampTz(stamp) => temporal(stamp, |stamp| {
            let at = stamp.to_datetime();
            format!(
                "{}{}",
                stamp_text(&at.naive_local()),
                offset_text(at.offset().local_minus_utc())
            )
        }),
        Value::Interval(interval) => {
            crate::decode::interval_text(interval.months, interval.days, interval.microseconds)
        }
        other => value_to_text(other)?,
    })
}

fn temporal<T>(value: &Temporal<T>, finite: impl Fn(&T) -> String) -> String {
    match value {
        Temporal::Finite(inner) => finite(inner),
        Temporal::Infinity => "infinity".to_owned(),
        Temporal::NegInfinity => "-infinity".to_owned(),
    }
}

/// A date as DuckDB parses one, a year before 1 written `(BC)`: DuckDB
/// reads a plain `BC` as nothing and keeps the year.
pub(crate) fn date_text(day: NaiveDate) -> String {
    let year = day.year();
    match year <= 0 {
        true => format!("{:04}-{:02}-{:02} (BC)", 1 - year, day.month(), day.day()),
        false => format!("{year:04}-{:02}-{:02}", day.month(), day.day()),
    }
}

fn time_text(time: &SqlTime) -> String {
    time.format(None)
}

/// A timestamp as DuckDB parses one, to the nanosecond.
pub(crate) fn stamp_text(stamp: &NaiveDateTime) -> String {
    let nanos = stamp.nanosecond();
    let fraction = match nanos {
        0 => String::new(),
        nanos => format!(".{}", format!("{nanos:09}").trim_end_matches('0')),
    };
    format!(
        "{} {:02}:{:02}:{:02}{fraction}",
        date_text(stamp.date()),
        stamp.hour(),
        stamp.minute(),
        stamp.second()
    )
}

fn offset_text(seconds: i32) -> String {
    let sign = if seconds < 0 { '-' } else { '+' };
    let magnitude = seconds.unsigned_abs();
    let (hours, minutes, seconds) = (magnitude / 3_600, magnitude / 60 % 60, magnitude % 60);
    match seconds {
        0 => format!("{sign}{hours:02}:{minutes:02}"),
        _ => format!("{sign}{hours:02}:{minutes:02}:{seconds:02}"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_timestamp_is_text_duckdb_reads_back() {
        let stamp = NaiveDate::from_ymd_opt(2024, 2, 29)
            .unwrap()
            .and_hms_nano_opt(12, 0, 1, 123_456_789)
            .unwrap();
        let bc = NaiveDate::from_ymd_opt(-43, 3, 15)
            .unwrap()
            .and_hms_opt(12, 0, 0)
            .unwrap();

        assert_eq!(stamp_text(&stamp), "2024-02-29 12:00:01.123456789");
        assert_eq!(stamp_text(&bc), "0044-03-15 (BC) 12:00:00");
        assert_eq!(offset_text(-19_800), "-05:30");
        assert_eq!(offset_text(1_172), "+00:19:32");
    }

    #[test]
    fn an_interval_too_long_for_nanoseconds_goes_as_text() {
        let long = tablepro_core::value::SqlInterval {
            months: 0,
            days: 0,
            microseconds: 10_000_000_000_000_000,
        };
        let short = tablepro_core::value::SqlInterval {
            months: 1,
            days: 2,
            microseconds: 3,
        };

        assert!(matches!(bind(&Value::Interval(long)).unwrap(), Bound::Text(_)));
        assert!(matches!(
            bind(&Value::Interval(short)).unwrap(),
            Bound::Interval {
                months: 1,
                days: 2,
                nanos: 3_000
            }
        ));
    }

    #[test]
    fn integers_too_wide_for_a_binding_go_as_text() {
        let wide: tablepro_core::value::WideInteger =
            "115792089237316195423570985008687907853269984665640564039457584007913129639935"
                .parse()
                .unwrap();

        assert!(matches!(bind(&Value::WideInt(wide)).unwrap(), Bound::Text(_)));
        assert_eq!(
            bind(&Value::WideInt(tablepro_core::value::WideInteger::from_i128(-5))).unwrap(),
            Bound::HugeInt(-5)
        );
    }
}
