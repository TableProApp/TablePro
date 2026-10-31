use std::ops::Range;

use chrono::{NaiveDate, NaiveTime};

use super::parse_literal_text::{chrono_year, far_year_stand_in};

// Byte ranges in the text, so a picker can replace one part and keep the rest as written.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct TemporalParts {
    pub day: Option<Range<usize>>,
    // None for a day out of range or a year past the last chrono holds.
    pub date: Option<NaiveDate>,
    pub clock: Option<Range<usize>>,
    // None for a clock out of range, PostgreSQL's 24:00:00 among them.
    pub time: Option<NaiveTime>,
    pub era: Option<Range<usize>>,
}

// The day, clock and ` BC` a date or time text spells, read as `parse_literal_text` reads them:
// the same year forms, a space or `T` between day and clock, seconds optional.
pub fn temporal_parts(text: &str) -> TemporalParts {
    // A 1 for every digit keeps the shape and drops the values, so a part out of range still has
    // its place for a picker to replace.
    let shape: String = text
        .chars()
        .map(|char| if char.is_ascii_digit() { '1' } else { char })
        .collect();
    let mut parts = spans(&shape);
    let era = parts.era.clone().and_then(|era| text.get(era)).unwrap_or_default();
    parts.date = parts.day.clone().and_then(|day| {
        let day = chrono_year(&format!("{}{era}", text.get(day)?.trim_start()))?.into_owned();
        NaiveDate::parse_from_str(&day, "%Y-%m-%d").ok()
    });
    parts.time = parts.clock.clone().and_then(|clock| {
        let clock = text.get(clock)?;
        ["%H:%M:%S", "%H:%M"]
            .into_iter()
            .find_map(|format| NaiveTime::parse_from_str(clock, format).ok())
    });
    parts
}

fn spans(text: &str) -> TemporalParts {
    let start = text.len() - text.trim_start().len();
    let trimmed = text.trim();
    let written = trimmed
        .strip_suffix(" BC")
        .or_else(|| trimmed.strip_suffix(" bc"))
        .unwrap_or(trimmed);
    let Some(read) = chrono_year(trimmed) else {
        return TemporalParts::default();
    };
    // `read` differs from the text only in its year and era, so a suffix of it is one of the text.
    let end = start + written.len();
    let at = |rest: &str| end - rest.len();
    let mut parts = TemporalParts {
        era: (written.len() < trimmed.len()).then_some(end..start + trimmed.len()),
        ..TemporalParts::default()
    };
    let mut clock_text = read.as_ref();
    if let Some(rest) = day_rest(&read, written) {
        let after_t = rest.strip_prefix('T').unwrap_or(rest);
        let joined = rest.is_empty() || rest.starts_with(char::is_whitespace) || rest.starts_with('T');
        if joined || parse_clock(after_t).is_some() {
            parts.day = Some(start..at(rest));
            clock_text = after_t;
        }
    }
    if let Some((_, rest)) = parse_clock(clock_text) {
        parts.clock = Some(at(clock_text.trim_start())..at(rest));
    }
    parts
}

fn day_rest<'a>(read: &'a str, written: &str) -> Option<&'a str> {
    if let Ok((_, rest)) = NaiveDate::parse_and_remainder(read, "%Y-%m-%d") {
        return Some(rest);
    }
    let stand_in = far_year_stand_in(written)?;
    let (_, rest) = NaiveDate::parse_and_remainder(&stand_in, "%Y-%m-%d").ok()?;
    read.get(read.len() - rest.len()..)
}

fn parse_clock(text: &str) -> Option<(NaiveTime, &str)> {
    ["%H:%M:%S", "%H:%M"]
        .into_iter()
        .find_map(|format| NaiveTime::parse_and_remainder(text, format).ok())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn day(text: &str) -> Option<&str> {
        text.get(temporal_parts(text).day?)
    }

    fn clock(text: &str) -> Option<&str> {
        text.get(temporal_parts(text).clock?)
    }

    #[test]
    fn the_parts_are_read_as_the_commit_reads_them() {
        assert_eq!(day(" 2024-1-5T 9:05:30.25+02 "), Some("2024-1-5"));
        assert_eq!(clock(" 2024-1-5T 9:05:30.25+02 "), Some("9:05:30"));
        assert_eq!(
            clock("2024-01-0512:00"),
            Some("12:00"),
            "chrono reads no space as a space"
        );
        assert_eq!(day("12024-01-05 10:00:00"), Some("12024-01-05"));
        assert_eq!(clock("13:45+05:30"), Some("13:45"));
        assert_eq!(temporal_parts("13:45").time, NaiveTime::from_hms_opt(13, 45, 0));
    }

    #[test]
    fn a_year_chrono_cannot_hold_has_a_day_and_no_date() {
        let parts = temporal_parts("5874897-12-31 23:59:59");

        assert_eq!(parts.day, Some(0..13));
        assert_eq!(parts.date, None);
        assert_eq!(parts.clock, Some(14..22));
    }

    #[test]
    fn a_bc_value_keeps_its_era_apart() {
        let text = "0044-03-15 12:00:00 BC";
        let parts = temporal_parts(text);

        assert_eq!(day(text), Some("0044-03-15"));
        assert_eq!(parts.date, NaiveDate::from_ymd_opt(-43, 3, 15));
        assert_eq!(clock(text), Some("12:00:00"));
        assert_eq!(parts.era.and_then(|era| text.get(era)), Some(" BC"));
    }

    #[test]
    fn the_end_of_the_day_is_a_clock_with_no_time() {
        let parts = temporal_parts("24:00:00+01");

        assert_eq!(parts.clock, Some(0..8));
        assert_eq!(parts.time, None);
        assert_eq!(temporal_parts("24:30:00").clock, Some(0..8));
    }

    #[test]
    fn text_the_commit_refuses_has_no_parts() {
        assert_eq!(temporal_parts("2024-02-2é 10:00:00").day, None);
        assert_eq!(temporal_parts("infinity"), TemporalParts::default());
        assert_eq!(temporal_parts(""), TemporalParts::default());
    }

    #[test]
    fn a_part_out_of_range_has_its_place_and_no_value() {
        let text = "2024-02-30 12:34:99";
        let parts = temporal_parts(text);

        assert_eq!(day(text), Some("2024-02-30"));
        assert_eq!(parts.date, None);
        assert_eq!(clock(text), Some("12:34:99"));
        assert_eq!(parts.time, None);
    }
}
