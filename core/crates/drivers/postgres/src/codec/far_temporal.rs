//! Dates and timestamps past 262143 AD, the last year chrono holds.
//! PostgreSQL keeps dates to 5874897 AD and timestamps to 294276 AD, so
//! a value out there is written from its days and microseconds here, as
//! the grid writes one chrono holds.

/// From 1970-01-01, where the civil-date arithmetic counts, to
/// 2000-01-01, where PostgreSQL counts.
const DAYS_1970_TO_2000: i64 = 10_957;
const MICROS_PER_DAY: i64 = 86_400_000_000;
const MICROS_PER_SECOND: i64 = 1_000_000;
/// 5874898-01-01 and 294277-01-01, the first date and timestamp the
/// server refuses. Anything at or past them is not a value it sent.
const END_DATE: i32 = 2_145_031_949;
const END_TIMESTAMP: i64 = 9_223_371_331_200_000_000;

/// A DATE's binary form: days since 2000-01-01.
pub(crate) fn date_text(days_since_2000: i32) -> Option<String> {
    if days_since_2000 >= END_DATE {
        return None;
    }
    let (year, month, day) = civil_date(i64::from(days_since_2000) + DAYS_1970_TO_2000);
    Some(format!("{year:04}-{month:02}-{day:02}"))
}

/// A TIMESTAMP's binary form: microseconds since 2000-01-01 00:00:00.
pub(crate) fn timestamp_text(micros_since_2000: i64) -> Option<String> {
    if micros_since_2000 >= END_TIMESTAMP {
        return None;
    }
    let days = micros_since_2000.div_euclid(MICROS_PER_DAY);
    let micros = micros_since_2000.rem_euclid(MICROS_PER_DAY);
    let (year, month, day) = civil_date(days + DAYS_1970_TO_2000);
    let seconds = micros / MICROS_PER_SECOND;
    let mut text = format!(
        "{year:04}-{month:02}-{day:02} {:02}:{:02}:{:02}",
        seconds / 3600,
        seconds / 60 % 60,
        seconds % 60
    );
    let fraction = format!("{:06}", micros % MICROS_PER_SECOND);
    let fraction = fraction.trim_end_matches('0');
    if !fraction.is_empty() {
        text.push('.');
        text.push_str(fraction);
    }
    Some(text)
}

/// The proleptic Gregorian year, month and day `days` after 1970-01-01,
/// by Howard Hinnant's `civil_from_days`, which has no range limit of
/// its own.
fn civil_date(days: i64) -> (i64, i64, i64) {
    let shifted = days + 719_468;
    let era = shifted.div_euclid(146_097);
    let day_of_era = shifted.rem_euclid(146_097);
    let year_of_era = (day_of_era - day_of_era / 1_460 + day_of_era / 36_524 - day_of_era / 146_096) / 365;
    let day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    let month_index = (5 * day_of_year + 2) / 153;
    let day = day_of_year - (153 * month_index + 2) / 5 + 1;
    let month = if month_index < 10 {
        month_index + 3
    } else {
        month_index - 9
    };
    let year = year_of_era + era * 400 + i64::from(month <= 2);
    (year, month, day)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_last_date_and_timestamp_postgresql_holds() {
        assert_eq!(date_text(END_DATE - 1).as_deref(), Some("5874897-12-31"));
        assert_eq!(
            timestamp_text(END_TIMESTAMP - 1).as_deref(),
            Some("294276-12-31 23:59:59.999999")
        );
        assert_eq!(date_text(END_DATE), None);
        assert_eq!(timestamp_text(END_TIMESTAMP), None);
    }

    #[test]
    fn days_around_the_epoch_match_the_calendar() {
        assert_eq!(date_text(0).as_deref(), Some("2000-01-01"));
        assert_eq!(date_text(-1).as_deref(), Some("1999-12-31"));
        assert_eq!(date_text(59).as_deref(), Some("2000-02-29"));
        assert_eq!(timestamp_text(-1).as_deref(), Some("1999-12-31 23:59:59.999999"));
        assert_eq!(timestamp_text(1_500_000).as_deref(), Some("2000-01-01 00:00:01.5"));
    }
}
