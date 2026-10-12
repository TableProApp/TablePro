//! DATE, DATETIME and TIMESTAMP as the server sent them.
//!
//! The server stores dates chrono has no value for: the zero date
//! `0000-00-00` and dates with a zero month or day, under a lenient
//! sql_mode. sqlx reads a zero date as NULL, which would hide a value
//! that is there, so these are read from the bytes instead and kept as
//! the server's own text when chrono cannot hold them.

use chrono::{NaiveDate, NaiveDateTime, NaiveTime};
use tablepro_core::Value;
use tablepro_core::value::{OffsetTimestamp, OtherValue, Temporal, UndecodableReason, UndecodedValue};

use crate::mysql_timestamp_mode::MySqlTimestampMode;
use crate::mysql_wire_format::MySqlWireFormat;

/// Which of the three types a value is.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum TemporalType {
    Date,
    DateTime,
    Timestamp,
}

impl TemporalType {
    fn name(self) -> &'static str {
        match self {
            Self::Date => "DATE",
            Self::DateTime => "DATETIME",
            Self::Timestamp => "TIMESTAMP",
        }
    }
}

/// The calendar fields, before chrono is asked whether they are a date.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
struct Fields {
    year: u16,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
    micros: u32,
}

impl Fields {
    fn text(&self, kind: TemporalType) -> String {
        let date = format!("{:04}-{:02}-{:02}", self.year, self.month, self.day);
        match kind {
            TemporalType::Date => date,
            TemporalType::DateTime | TemporalType::Timestamp => {
                let time = format!("{date} {:02}:{:02}:{:02}", self.hour, self.minute, self.second);
                match self.micros {
                    0 => time,
                    micros => format!("{time}.{micros:06}"),
                }
            }
        }
    }
}

pub(crate) fn decode(bytes: &[u8], format: MySqlWireFormat, kind: TemporalType, mode: MySqlTimestampMode) -> Value {
    let fields = match format {
        MySqlWireFormat::Binary => binary_fields(bytes),
        MySqlWireFormat::Text => std::str::from_utf8(bytes).ok().and_then(text_fields),
    };
    let Some(fields) = fields else {
        return Value::Undecodable(Box::new(UndecodedValue {
            type_name: kind.name().to_owned(),
            reason: UndecodableReason::InvalidEncoding,
        }));
    };
    let date = NaiveDate::from_ymd_opt(i32::from(fields.year), u32::from(fields.month), u32::from(fields.day));
    let time = NaiveTime::from_hms_micro_opt(
        u32::from(fields.hour),
        u32::from(fields.minute),
        u32::from(fields.second),
        fields.micros,
    );
    let (Some(date), Some(time)) = (date, time) else {
        return Value::Other(Box::new(OtherValue {
            type_name: kind.name().to_owned(),
            text: fields.text(kind),
        }));
    };
    let stamp = NaiveDateTime::new(date, time);
    match (kind, mode) {
        (TemporalType::Date, _) => Value::Date(Temporal::Finite(date)),
        (TemporalType::DateTime, _) | (TemporalType::Timestamp, MySqlTimestampMode::SessionLocal) => {
            Value::Timestamp(Temporal::Finite(stamp))
        }
        (TemporalType::Timestamp, MySqlTimestampMode::WorkspaceUtc) => Value::TimestampTz(Temporal::Finite(
            OffsetTimestamp::from_datetime(stamp.and_utc().fixed_offset()),
        )),
    }
}

/// The binary protocol's length byte, then as many fields as it says:
/// 0 is the zero date, 4 a date, 7 adds the time, 11 the microseconds.
fn binary_fields(bytes: &[u8]) -> Option<Fields> {
    let (&length, body) = bytes.split_first()?;
    let body = body.get(..usize::from(length))?;
    let mut fields = Fields::default();
    if length == 0 {
        return Some(fields);
    }
    if !matches!(length, 4 | 7 | 11) {
        return None;
    }
    fields.year = u16::from_le_bytes([*body.first()?, *body.get(1)?]);
    fields.month = *body.get(2)?;
    fields.day = *body.get(3)?;
    if length >= 7 {
        fields.hour = *body.get(4)?;
        fields.minute = *body.get(5)?;
        fields.second = *body.get(6)?;
    }
    if length == 11 {
        fields.micros = u32::from_le_bytes([*body.get(7)?, *body.get(8)?, *body.get(9)?, *body.get(10)?]);
    }
    Some(fields)
}

/// `YYYY-MM-DD`, optionally followed by ` HH:MM:SS` and a fraction of up
/// to six digits.
fn text_fields(text: &str) -> Option<Fields> {
    let (date, time) = match text.split_once(' ') {
        Some((date, time)) => (date, Some(time)),
        None => (text, None),
    };
    let mut date_parts = date.split('-');
    let mut fields = Fields {
        year: number(date_parts.next()?, 4)?,
        month: number(date_parts.next()?, 2)?,
        day: number(date_parts.next()?, 2)?,
        ..Fields::default()
    };
    if date_parts.next().is_some() {
        return None;
    }
    let Some(time) = time else {
        return Some(fields);
    };
    let (clock, fraction) = match time.split_once('.') {
        Some((clock, fraction)) => (clock, Some(fraction)),
        None => (time, None),
    };
    let mut clock_parts = clock.split(':');
    fields.hour = number(clock_parts.next()?, 2)?;
    fields.minute = number(clock_parts.next()?, 2)?;
    fields.second = number(clock_parts.next()?, 2)?;
    if clock_parts.next().is_some() {
        return None;
    }
    if let Some(fraction) = fraction {
        if fraction.is_empty() || fraction.len() > 6 || !fraction.bytes().all(|byte| byte.is_ascii_digit()) {
            return None;
        }
        let padded = format!("{fraction:0<6}");
        fields.micros = padded.parse().ok()?;
    }
    Some(fields)
}

fn number<T: std::str::FromStr>(text: &str, digits: usize) -> Option<T> {
    if text.len() != digits || !text.bytes().all(|byte| byte.is_ascii_digit()) {
        return None;
    }
    text.parse().ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn binary(kind: TemporalType, bytes: &[u8]) -> Value {
        decode(bytes, MySqlWireFormat::Binary, kind, MySqlTimestampMode::SessionLocal)
    }

    fn other_text(value: &Value) -> Option<&str> {
        match value {
            Value::Other(other) => Some(other.text.as_str()),
            _ => None,
        }
    }

    #[test]
    fn mysql_temporal_binary_lengths_0_4_7_11() {
        let zero = binary(TemporalType::DateTime, &[0]);
        assert_eq!(other_text(&zero), Some("0000-00-00 00:00:00"));

        let date = binary(TemporalType::Date, &[4, 0xe9, 0x07, 3, 9]);
        assert_eq!(
            date,
            Value::Date(Temporal::Finite(NaiveDate::from_ymd_opt(2025, 3, 9).unwrap()))
        );

        let seconds = binary(TemporalType::DateTime, &[7, 0xe9, 0x07, 3, 9, 13, 45, 30]);
        let expected = NaiveDate::from_ymd_opt(2025, 3, 9)
            .unwrap()
            .and_hms_opt(13, 45, 30)
            .unwrap();
        assert_eq!(seconds, Value::Timestamp(Temporal::Finite(expected)));

        let micros = 123_456_u32.to_le_bytes();
        let fraction = binary(
            TemporalType::DateTime,
            &[
                11, 0xe9, 0x07, 3, 9, 13, 45, 30, micros[0], micros[1], micros[2], micros[3],
            ],
        );
        let expected = NaiveDate::from_ymd_opt(2025, 3, 9)
            .unwrap()
            .and_hms_micro_opt(13, 45, 30, 123_456)
            .unwrap();
        assert_eq!(fraction, Value::Timestamp(Temporal::Finite(expected)));

        assert!(matches!(
            binary(TemporalType::Date, &[5, 1, 2, 3, 4, 5]),
            Value::Undecodable(_)
        ));
        assert!(matches!(binary(TemporalType::Date, &[4, 1]), Value::Undecodable(_)));
    }

    #[test]
    fn mysql_zero_date_is_other_in_both_formats() {
        let text = decode(
            b"0000-00-00",
            MySqlWireFormat::Text,
            TemporalType::Date,
            MySqlTimestampMode::WorkspaceUtc,
        );
        let binary = decode(
            &[0],
            MySqlWireFormat::Binary,
            TemporalType::Date,
            MySqlTimestampMode::WorkspaceUtc,
        );
        assert_eq!(other_text(&text), Some("0000-00-00"));
        assert_eq!(other_text(&binary), Some("0000-00-00"));

        let partial = decode(
            b"2024-00-15 10:00:00",
            MySqlWireFormat::Text,
            TemporalType::DateTime,
            MySqlTimestampMode::WorkspaceUtc,
        );
        assert_eq!(other_text(&partial), Some("2024-00-15 10:00:00"));
    }

    #[test]
    fn a_workspace_timestamp_is_an_instant_and_a_session_one_is_wall_time() {
        let workspace = decode(
            b"2025-04-01 00:00:00.5",
            MySqlWireFormat::Text,
            TemporalType::Timestamp,
            MySqlTimestampMode::WorkspaceUtc,
        );
        let Value::TimestampTz(Temporal::Finite(instant)) = workspace else {
            panic!("a workspace TIMESTAMP read as {workspace:?}");
        };
        assert_eq!(instant.offset().local_minus_utc(), 0);
        assert_eq!(instant.utc().and_utc().timestamp_subsec_micros(), 500_000);

        let session = decode(
            b"2025-04-01 00:00:00",
            MySqlWireFormat::Text,
            TemporalType::Timestamp,
            MySqlTimestampMode::SessionLocal,
        );
        assert!(matches!(session, Value::Timestamp(Temporal::Finite(_))));
    }
}
