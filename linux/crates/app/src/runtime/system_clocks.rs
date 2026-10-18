use std::time::Duration;

use rustix::time::{ClockId, Timespec, clock_gettime};

use super::{ClockSample, ClockSource};

/// `CLOCK_BOOTTIME` and `CLOCK_MONOTONIC`, read straight from the kernel.
#[derive(Debug, Clone, Copy, Default)]
pub struct SystemClocks;

impl ClockSource for SystemClocks {
    fn sample(&self) -> ClockSample {
        ClockSample {
            boottime: duration(clock_gettime(ClockId::Boottime)),
            monotonic: duration(clock_gettime(ClockId::Monotonic)),
        }
    }
}

fn duration(time: Timespec) -> Duration {
    let seconds = Duration::from_secs(u64::try_from(time.tv_sec).unwrap_or(0));
    seconds.saturating_add(Duration::from_nanos(u64::try_from(time.tv_nsec).unwrap_or(0)))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn back_to_back_samples_move_forward_and_find_no_sleep() {
        let first = SystemClocks.sample();
        let second = SystemClocks.sample();

        assert!(second.monotonic >= first.monotonic, "{first:?} then {second:?}");
        assert!(second.boottime >= first.boottime, "{first:?} then {second:?}");
        assert_eq!(
            crate::runtime::detect_resume(first, second, crate::runtime::RESUME_THRESHOLD),
            None
        );
    }
}
