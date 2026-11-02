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
}
