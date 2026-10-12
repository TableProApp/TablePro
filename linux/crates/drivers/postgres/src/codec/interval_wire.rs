//! INTERVAL in its binary form: microseconds, days and months, kept
//! apart because a month and a day have no fixed length.

use bytes::{BufMut, BytesMut};
use tablepro_core::value::SqlInterval;

use super::WireError;

const LEN: usize = 16;

pub(crate) fn interval_from_sql(bytes: &[u8]) -> Result<SqlInterval, WireError> {
    let bytes: [u8; LEN] = bytes.try_into().map_err(|_| WireError::Malformed)?;
    let [m0, m1, m2, m3, m4, m5, m6, m7, d0, d1, d2, d3, n0, n1, n2, n3] = bytes;
    Ok(SqlInterval {
        microseconds: i64::from_be_bytes([m0, m1, m2, m3, m4, m5, m6, m7]),
        days: i32::from_be_bytes([d0, d1, d2, d3]),
        months: i32::from_be_bytes([n0, n1, n2, n3]),
    })
}

pub(crate) fn interval_to_sql(interval: &SqlInterval, out: &mut BytesMut) {
    out.put_i64(interval.microseconds);
    out.put_i32(interval.days);
    out.put_i32(interval.months);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn interval_wire_round_trip() {
        let interval = SqlInterval {
            months: -14,
            days: 3,
            microseconds: -4_500_000,
        };
        let mut out = BytesMut::new();

        interval_to_sql(&interval, &mut out);

        assert_eq!(out.len(), LEN);
        assert_eq!(interval_from_sql(&out), Ok(interval));
        assert_eq!(interval_from_sql(&out[..15]), Err(WireError::Malformed));
    }
}
