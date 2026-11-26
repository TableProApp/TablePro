use std::time::{Duration, SystemTime, UNIX_EPOCH};

/// Seconds since the epoch, as SQLite stores a timestamp here.
///
/// A clock that reads before 1970 (skew, a restored VM snapshot) keeps
/// its negative offset rather than collapsing every row onto the epoch,
/// so what was written comes back.
pub(crate) fn to_unix(time: SystemTime) -> i64 {
    match time.duration_since(UNIX_EPOCH) {
        Ok(elapsed) => elapsed.as_secs() as i64,
        Err(error) => -(error.duration().as_secs() as i64),
    }
}

pub(crate) fn from_unix(seconds: i64) -> SystemTime {
    if seconds >= 0 {
        UNIX_EPOCH + Duration::from_secs(seconds as u64)
    } else {
        UNIX_EPOCH - Duration::from_secs((-seconds) as u64)
    }
}

// Whole milliseconds, the precision a CloudKit date keeps, so every device compares the same value (core ADR 0052).
pub(crate) fn to_unix_millis(time: SystemTime) -> i64 {
    match time.duration_since(UNIX_EPOCH) {
        Ok(elapsed) => i64::try_from(elapsed.as_millis()).unwrap_or(i64::MAX),
        Err(error) => i64::try_from(error.duration().as_millis()).map_or(i64::MIN, |millis| -millis),
    }
}

pub(crate) fn from_unix_millis(millis: i64) -> SystemTime {
    let span = Duration::from_millis(millis.unsigned_abs());
    let time = match millis >= 0 {
        true => UNIX_EPOCH.checked_add(span),
        false => UNIX_EPOCH.checked_sub(span),
    };
    time.unwrap_or(UNIX_EPOCH)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_time_before_the_epoch_round_trips() {
        let before = UNIX_EPOCH - Duration::from_secs(86_400);

        assert_eq!(from_unix(to_unix(before)), before);
    }

    #[test]
    fn a_time_after_the_epoch_round_trips() {
        let after = UNIX_EPOCH + Duration::from_secs(1_800_000_000);

        assert_eq!(from_unix(to_unix(after)), after);
    }

    #[test]
    fn milliseconds_round_trip_and_drop_what_is_below_them() {
        let after = UNIX_EPOCH + Duration::from_micros(1_800_000_000_123_456);
        let before = UNIX_EPOCH - Duration::from_millis(86_400_250);

        assert_eq!(to_unix_millis(after), 1_800_000_000_123);
        assert_eq!(
            from_unix_millis(to_unix_millis(after)),
            UNIX_EPOCH + Duration::from_millis(1_800_000_000_123)
        );
        assert_eq!(from_unix_millis(to_unix_millis(before)), before);
    }
}
