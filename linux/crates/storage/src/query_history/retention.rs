use std::time::{Duration, SystemTime};

const SECONDS_PER_DAY: u64 = 86_400;

/// The moment before which unpinned history is dropped.
///
/// `None` means keep everything: zero days is the user asking for no
/// expiry, not for an immediate purge.
pub fn cutoff(days: u32, now: SystemTime) -> Option<SystemTime> {
    if days == 0 {
        return None;
    }
    // `checked_sub` rather than `-`: a clock far enough in the past to
    // overflow must keep history, not panic.
    now.checked_sub(Duration::from_secs(u64::from(days) * SECONDS_PER_DAY))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cutoff_zero_keeps_forever() {
        assert_eq!(cutoff(0, SystemTime::now()), None);
    }

    #[test]
    fn cutoff_is_that_many_days_back() {
        let now = SystemTime::UNIX_EPOCH + Duration::from_secs(100 * SECONDS_PER_DAY);

        let cutoff = cutoff(30, now).expect("a cutoff");

        assert_eq!(
            cutoff,
            SystemTime::UNIX_EPOCH + Duration::from_secs(70 * SECONDS_PER_DAY)
        );
    }
}
