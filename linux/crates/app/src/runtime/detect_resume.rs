use std::time::Duration;

use super::ClockSample;

/// Below this the gap is scheduling noise, not a suspend.
pub const RESUME_THRESHOLD: Duration = Duration::from_secs(2);

/// How long the machine slept between two samples, when it slept longer
/// than `threshold`.
pub fn detect_resume(prev: ClockSample, now: ClockSample, threshold: Duration) -> Option<Duration> {
    let awake = now.monotonic.saturating_sub(prev.monotonic);
    let slept = now.boottime.saturating_sub(prev.boottime).saturating_sub(awake);
    (slept > threshold).then_some(slept)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample(boottime: u64, monotonic: u64) -> ClockSample {
        ClockSample {
            boottime: Duration::from_secs(boottime),
            monotonic: Duration::from_secs(monotonic),
        }
    }

    #[test]
    fn drift_over_threshold_reports_sleep() {
        let slept = detect_resume(sample(100, 90), sample(700, 95), RESUME_THRESHOLD);

        assert_eq!(slept, Some(Duration::from_secs(595)));
    }

    #[test]
    fn equal_clocks_report_none() {
        assert_eq!(detect_resume(sample(100, 90), sample(105, 95), RESUME_THRESHOLD), None);
        assert_eq!(
            detect_resume(sample(100, 90), sample(107, 95), RESUME_THRESHOLD),
            None,
            "two seconds is not a sleep"
        );
        assert_eq!(
            detect_resume(sample(100, 90), sample(90, 80), RESUME_THRESHOLD),
            None,
            "clocks read out of order are not a sleep"
        );
    }
}
