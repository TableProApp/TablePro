use std::time::{Duration, SystemTime};

use chrono::{DateTime, Local, NaiveTime, TimeDelta};
use tablepro_storage::query_history::StatusFilter;
use uuid::Uuid;

const DAY: Duration = Duration::from_secs(86_400);

/// What the history filters are set to.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub(crate) struct HistoryFilterState {
    pub connection: Option<Uuid>,
    pub status: StatusFilter,
    pub window: TimeWindow,
}

/// How far back the history looks.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub(crate) enum TimeWindow {
    #[default]
    AnyTime,
    Today,
    Last7Days,
    Last30Days,
}

impl TimeWindow {
    /// In the order the drop-down lists them.
    pub(crate) const ALL: [Self; 4] = [Self::AnyTime, Self::Today, Self::Last7Days, Self::Last30Days];

    /// The earliest run the window keeps. Today starts at the local
    /// midnight, not 24 hours back.
    pub(crate) fn executed_after(self, now: SystemTime) -> Option<SystemTime> {
        match self {
            Self::AnyTime => None,
            Self::Today => Some(start_of_local_day(now)),
            Self::Last7Days => now.checked_sub(7 * DAY),
            Self::Last30Days => now.checked_sub(30 * DAY),
        }
    }
}

/// A zone that moves its clocks at midnight skips it on that day, which
/// then starts at the first hour that exists.
fn start_of_local_day(now: SystemTime) -> SystemTime {
    let midnight = DateTime::<Local>::from(now).date_naive().and_time(NaiveTime::MIN);
    (0..=24)
        .filter_map(|hours| midnight.checked_add_signed(TimeDelta::hours(hours)))
        .find_map(|moment| moment.and_local_timezone(Local).earliest())
        .map_or(now, SystemTime::from)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn time_window_executed_after() {
        let now = SystemTime::UNIX_EPOCH + Duration::from_secs(1_800_000_000);

        assert_eq!(TimeWindow::AnyTime.executed_after(now), None);
        assert_eq!(TimeWindow::Last7Days.executed_after(now), Some(now - 7 * DAY));
        assert_eq!(TimeWindow::Last30Days.executed_after(now), Some(now - 30 * DAY));

        let today = TimeWindow::Today.executed_after(now).expect("a start");
        let local = DateTime::<Local>::from(today);
        assert!(today <= now);
        assert_eq!(local.date_naive(), DateTime::<Local>::from(now).date_naive());
        assert_eq!(local.time(), NaiveTime::MIN);
    }
}
