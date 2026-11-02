use std::fmt;

use chrono::{DateTime, FixedOffset, NaiveDateTime, SecondsFormat};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct OffsetTimestamp {
    utc: NaiveDateTime,
    offset: FixedOffset,
}

impl OffsetTimestamp {
    pub fn from_datetime(value: DateTime<FixedOffset>) -> Self {
        Self {
            utc: value.naive_utc(),
            offset: *value.offset(),
        }
    }

    pub fn to_datetime(&self) -> DateTime<FixedOffset> {
        DateTime::from_naive_utc_and_offset(self.utc, self.offset)
    }

    pub fn utc(&self) -> NaiveDateTime {
        self.utc
    }

    pub fn offset(&self) -> FixedOffset {
        self.offset
    }
}

impl fmt::Display for OffsetTimestamp {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.to_datetime().to_rfc3339_opts(SecondsFormat::AutoSi, false))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keeps_the_offset_through_a_round_trip() {
        let original = DateTime::parse_from_rfc3339("2024-06-15T13:45:30.5+07:00").unwrap();
        let timestamp = OffsetTimestamp::from_datetime(original);
        assert_eq!(timestamp.to_datetime(), original);
        assert_eq!(timestamp.offset(), FixedOffset::east_opt(7 * 3600).unwrap());
        assert_eq!(timestamp.to_string(), "2024-06-15T13:45:30.500+07:00");

        let same_instant = OffsetTimestamp::from_datetime(original.with_timezone(&FixedOffset::east_opt(0).unwrap()));
        assert_eq!(timestamp.utc(), same_instant.utc());
        assert_ne!(timestamp, same_instant);
    }
}
