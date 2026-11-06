use std::time::Duration;

use chrono::{Days, NaiveDate};
use tablepro_linux_platform::AppSettings;

// The 30th day of use opens it; each ask closes it for 90 days, and a license closes it for good. The macOS app
// asks on the same days (#3922).
pub(crate) const FIRST_ASK_DAY: u32 = 30;
const DAYS_BETWEEN_ASKS: u64 = 90;
// Someone who just launched the app came to do something; the ask waits until they have.
pub(crate) const LAUNCH_QUIET_PERIOD: Duration = Duration::from_secs(5 * 60);
const DAY_FORMAT: &str = "%Y-%m-%d";

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct LicenseAsk {
    pub usage_days: u32,
    pub has_license: bool,
    pub last_asked: Option<NaiveDate>,
}

impl LicenseAsk {
    pub(crate) fn read(settings: &AppSettings, has_license: bool) -> Self {
        Self {
            usage_days: settings.usage_days(),
            has_license,
            last_asked: parse_day(&settings.license_ask_day()),
        }
    }

    pub(crate) fn is_due(&self, today: NaiveDate) -> bool {
        if self.has_license || self.usage_days < FIRST_ASK_DAY {
            return false;
        }
        let Some(last_asked) = self.last_asked else {
            return true;
        };
        last_asked
            .checked_add_days(Days::new(DAYS_BETWEEN_ASKS))
            .is_some_and(|next| today >= next)
    }
}

// Never over a query or a page someone is waiting for, and not in the first minutes after launch.
pub(crate) fn is_quiet_moment(since_launch: Duration, loading: bool) -> bool {
    !loading && since_launch >= LAUNCH_QUIET_PERIOD
}

pub(crate) fn day_stamp(day: NaiveDate) -> String {
    day.format(DAY_FORMAT).to_string()
}

fn parse_day(text: &str) -> Option<NaiveDate> {
    NaiveDate::parse_from_str(text, DAY_FORMAT).ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn day(text: &str) -> NaiveDate {
        parse_day(text).expect("a day")
    }

    fn ask(usage_days: u32, last_asked: Option<&str>) -> LicenseAsk {
        LicenseAsk {
            usage_days,
            has_license: false,
            last_asked: last_asked.map(day),
        }
    }

    #[test]
    fn the_thirtieth_day_of_use_opens_it() {
        let today = day("2026-11-05");

        assert!(!ask(29, None).is_due(today));
        assert!(ask(30, None).is_due(today));
        assert!(ask(400, None).is_due(today));
    }

    #[test]
    fn a_license_closes_it_for_good() {
        let mut licensed = ask(300, None);
        licensed.has_license = true;

        assert!(!licensed.is_due(day("2026-11-05")));
    }

    #[test]
    fn each_ask_waits_ninety_days() {
        let asked = ask(40, Some("2026-01-01"));

        assert!(!asked.is_due(day("2026-03-31")));
        assert!(asked.is_due(day("2026-04-01")));
    }

    #[test]
    fn a_clock_set_back_never_asks_early() {
        assert!(!ask(40, Some("2026-06-01")).is_due(day("2026-05-01")));
    }

    #[test]
    fn it_waits_out_the_launch_and_any_loading_tab() {
        let minute = Duration::from_secs(60);

        assert!(!is_quiet_moment(4 * minute, false));
        assert!(!is_quiet_moment(5 * minute, true));
        assert!(is_quiet_moment(5 * minute, false));
    }

    #[test]
    fn days_round_trip_as_the_schema_stores_them() {
        assert_eq!(day_stamp(day("2026-01-09")), "2026-01-09");
        assert_eq!(parse_day(""), None);
        assert_eq!(parse_day("09/01/2026"), None);
    }
}
