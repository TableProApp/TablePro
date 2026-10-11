use chrono::{NaiveTime, Timelike};

pub(super) fn duckdb_extended_date(text: &str) -> bool {
    let (date, bc) = text.strip_suffix(" (BC)").map_or((text, false), |date| (date, true));
    let mut parts = date.split('-');
    let Some(year_text) = parts.next().map(|year| year.strip_prefix('+').unwrap_or(year)) else {
        return false;
    };
    if year_text.len() < 4 || !year_text.bytes().all(|byte| byte.is_ascii_digit()) {
        return false;
    }
    let Ok(year) = year_text.parse::<i64>() else {
        return false;
    };
    let Some(month) = parts.next().and_then(|part| part.parse::<u32>().ok()) else {
        return false;
    };
    let Some(day) = parts.next().and_then(|part| part.parse::<u32>().ok()) else {
        return false;
    };
    if parts.next().is_some() || year == 0 || month == 0 || month > 12 || (year <= 9999 && !bc) {
        return false;
    }
    let astronomical_year = if bc { 1 - year } else { year };
    let leap = astronomical_year % 4 == 0 && (astronomical_year % 100 != 0 || astronomical_year % 400 == 0);
    let last_day = match month {
        2 if leap => 29,
        2 => 28,
        4 | 6 | 9 | 11 => 30,
        _ => 31,
    };
    day > 0 && day <= last_day
}

pub fn duckdb_extended_timestamptz_nanos(text: &str) -> Option<u32> {
    let (date, time) = if let Some((date, time)) = text.split_once(" (BC) ") {
        (format!("{date} (BC)"), time)
    } else if let Some((date, time)) = text.split_once('T') {
        (date.to_owned(), time)
    } else {
        let (date, time) = text.split_once(' ')?;
        (date.to_owned(), time)
    };
    if !duckdb_extended_date(&date) {
        return None;
    }
    let zone_start = time.find(['+', '-', 'Z'])?;
    let (clock, zone) = time.split_at(zone_start);
    if !valid_duckdb_zone(zone) {
        return None;
    }
    let time = NaiveTime::parse_from_str(clock, "%H:%M:%S%.f")
        .or_else(|_| NaiveTime::parse_from_str(clock, "%H:%M"))
        .ok()?;
    Some(time.nanosecond())
}

fn valid_duckdb_zone(zone: &str) -> bool {
    if zone == "Z" {
        return true;
    }
    let Some(digits) = zone.strip_prefix('+').or_else(|| zone.strip_prefix('-')) else {
        return false;
    };
    match digits.len() {
        2 => digits.parse::<u32>().is_ok_and(|hours| hours < 24),
        5 if digits.as_bytes().get(2) == Some(&b':') => digits[..2]
            .parse::<u32>()
            .ok()
            .zip(digits[3..].parse::<u32>().ok())
            .is_some_and(|(hours, minutes)| hours < 24 && minutes < 60),
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use super::{duckdb_extended_date, duckdb_extended_timestamptz_nanos};

    #[test]
    fn extended_dates_accept_far_future_leap_days_plus_years_and_bc_era() {
        for text in ["1000000-02-29", "+10000-01-01", "0001-01-01 (BC)", "0001-02-29 (BC)"] {
            assert!(duckdb_extended_date(text), "{text}");
        }
    }

    #[test]
    fn extended_dates_reject_ordinary_years_year_zero_and_invalid_leap_days() {
        for text in [
            "2024-02-29",
            "9999-12-31",
            "0000-01-01",
            "1000001-02-29",
            "1000000-02-30",
            "1000000-00-01",
            "1000000-13-01",
            "ABC-01-01",
            "1000000-02-29T00:00:00",
        ] {
            assert!(!duckdb_extended_date(text), "{text}");
        }
    }

    #[test]
    fn extended_dates_pin_bc_year_month_day_and_gregorian_leap_boundaries() {
        for text in ["10000-12-31", "0005-02-29 (BC)", "0401-02-29 (BC)"] {
            assert!(duckdb_extended_date(text), "{text}");
        }
        for text in [
            "1-01-01 (BC)",
            "0000-01-01 (BC)",
            "0101-02-29 (BC)",
            "0201-02-29 (BC)",
            "10000-02-00",
        ] {
            assert!(!duckdb_extended_date(text), "{text}");
        }
    }

    #[test]
    fn timestamptz_nanos_keep_fractional_seconds_across_zone_forms() {
        assert_eq!(
            duckdb_extended_timestamptz_nanos("280000-02-29 12:34:56.123456+05:30"),
            Some(123_456_000)
        );
        assert_eq!(
            duckdb_extended_timestamptz_nanos("+10000-01-01T12:34:56.123456+00"),
            Some(123_456_000)
        );
        assert_eq!(duckdb_extended_timestamptz_nanos("0001-01-01 (BC) 12:34:56Z"), Some(0));
        assert_eq!(duckdb_extended_timestamptz_nanos("1000000-01-01 00:00-05"), Some(0));
    }

    #[test]
    fn timestamptz_nanos_refuse_invalid_dates_zones_and_clocks() {
        for text in [
            "280000-02-29 12:34:56+24",
            "280000-02-29 12:34:56+24:00",
            "280000-02-29 12:34:56+00:60",
            "280000-02-29 12:34:56+00.30",
            "280000-02-29 12:34:56",
            "280000-02-29 24:00:00+00",
            "1000001-02-29 12:34:56+00",
            "2024-01-01 12:34:56+00",
            "not-a-timestamp",
        ] {
            assert_eq!(duckdb_extended_timestamptz_nanos(text), None, "{text}");
        }
    }
}
