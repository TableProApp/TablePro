//! TIME and TIMETZ in their binary forms. postgres-types reads TIME
//! through chrono's `NaiveTime`, whose addition wraps 24:00:00 back to
//! midnight, so both are read here as microseconds.

use bytes::{BufMut, BytesMut};
use chrono::FixedOffset;
use postgres_protocol::types::{time_from_sql as protocol_time_from_sql, time_to_sql as protocol_time_to_sql};
use tablepro_core::value::{SqlTime, TimeWithOffset};

use super::WireError;

/// The longest a time of day can be: 24:00:00 is a valid PostgreSQL
/// time, one past the last instant of the day.
const MICROS_PER_DAY: i64 = 86_400_000_000;

pub(crate) fn time_from_sql(bytes: &[u8]) -> Result<SqlTime, WireError> {
    let micros = protocol_time_from_sql(bytes).map_err(|_| WireError::Malformed)?;
    time_of_day(micros)
}

pub(crate) fn time_to_sql(micros: i64, out: &mut BytesMut) {
    protocol_time_to_sql(micros, out);
}

/// TIMETZ: the time, then the zone as seconds *west* of UTC, which is
/// the opposite sign of the offset it prints.
pub(crate) fn timetz_from_sql(bytes: &[u8]) -> Result<TimeWithOffset, WireError> {
    let bytes: [u8; 12] = bytes.try_into().map_err(|_| WireError::Malformed)?;
    let [m0, m1, m2, m3, m4, m5, m6, m7, z0, z1, z2, z3] = bytes;
    let micros = i64::from_be_bytes([m0, m1, m2, m3, m4, m5, m6, m7]);
    let west = i32::from_be_bytes([z0, z1, z2, z3]);
    let offset = west
        .checked_neg()
        .and_then(FixedOffset::east_opt)
        .ok_or(WireError::OutOfRange)?;
    Ok(TimeWithOffset {
        time: time_of_day(micros)?,
        offset,
    })
}

pub(crate) fn timetz_to_sql(micros: i64, offset: FixedOffset, out: &mut BytesMut) {
    out.put_i64(micros);
    out.put_i32(-offset.local_minus_utc());
}

fn time_of_day(micros: i64) -> Result<SqlTime, WireError> {
    if !(0..=MICROS_PER_DAY).contains(&micros) {
        return Err(WireError::OutOfRange);
    }
    SqlTime::from_micros(micros).map_err(|_| WireError::OutOfRange)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn time_24_00_00() {
        let mut out = BytesMut::new();
        time_to_sql(MICROS_PER_DAY, &mut out);

        let time = time_from_sql(&out).expect("24:00:00 is a valid time");

        assert_eq!(time.format(None), "24:00:00");
        assert_eq!(time.total_micros(), Some(MICROS_PER_DAY));
    }

    #[test]
    fn a_time_past_the_end_of_the_day_is_out_of_range() {
        let mut out = BytesMut::new();
        time_to_sql(MICROS_PER_DAY + 1, &mut out);

        assert_eq!(time_from_sql(&out), Err(WireError::OutOfRange));
        assert_eq!(time_from_sql(&[0, 1]), Err(WireError::Malformed));
    }

    #[test]
    fn timetz_keeps_the_offset_with_its_own_sign() {
        let offset = FixedOffset::east_opt(7 * 3600).expect("an offset");
        let mut out = BytesMut::new();
        timetz_to_sql(45_296_000_000, offset, &mut out);

        let read = timetz_from_sql(&out).expect("a timetz");

        assert_eq!(read.offset, offset);
        assert_eq!(read.time.format(None), "12:34:56");
    }
}
