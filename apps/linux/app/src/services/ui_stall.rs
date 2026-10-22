use std::cell::Cell;
use std::time::{Duration, Instant};

use relm4::gtk::glib;

pub const STALL_MS_ENV: &str = "TABLEPRO_UI_STALL_MS";
const TICK: Duration = Duration::from_millis(16);

pub fn install_from_env() {
    let Some(threshold) = std::env::var(STALL_MS_ENV).ok().as_deref().and_then(threshold_from) else {
        return;
    };
    let last = Cell::new(Instant::now());
    glib::timeout_add_local(TICK, move || {
        let now = Instant::now();
        if let Some(stall) = stall_over(now.duration_since(last.replace(now)), threshold) {
            tracing::warn!(stall_ms = stall.as_millis() as u64, "UI thread stalled");
        }
        glib::ControlFlow::Continue
    });
}

fn threshold_from(value: &str) -> Option<Duration> {
    value
        .trim()
        .parse::<u64>()
        .ok()
        .filter(|ms| *ms > 0)
        .map(Duration::from_millis)
}

fn stall_over(since_last_tick: Duration, threshold: Duration) -> Option<Duration> {
    let late = since_last_tick.saturating_sub(TICK);
    (late >= threshold).then_some(late)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_a_positive_whole_number_of_milliseconds_enables_the_meter() {
        assert_eq!(threshold_from("50"), Some(Duration::from_millis(50)));
        for value in ["", "0", "-5", "fast", "1.5"] {
            assert_eq!(threshold_from(value), None, "{value}");
        }
    }

    #[test]
    fn a_tick_is_a_stall_only_when_it_is_late_by_the_threshold() {
        let threshold = Duration::from_millis(50);
        assert_eq!(stall_over(Duration::from_millis(16), threshold), None);
        assert_eq!(stall_over(Duration::from_millis(65), threshold), None);
        assert_eq!(
            stall_over(Duration::from_millis(216), threshold),
            Some(Duration::from_millis(200))
        );
    }
}
