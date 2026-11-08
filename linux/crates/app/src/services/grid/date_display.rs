use tablepro_core::Value;
use tablepro_core::column::{ColumnKind, ColumnType, TimeRange};
use tablepro_core::value::Temporal;
use tablepro_linux_platform::settings::DateFormat;

#[derive(Clone, Copy)]
enum Shape {
    Date,
    Timestamp,
    Clock,
}

pub(super) fn formatted(value: &Value, column: &ColumnType, format: DateFormat) -> Option<String> {
    if format == DateFormat::Iso {
        return None;
    }
    let shape = match value {
        Value::Date(Temporal::Finite(_)) => Shape::Date,
        Value::Timestamp(Temporal::Finite(_)) | Value::TimestampTz(Temporal::Finite(_)) => Shape::Timestamp,
        Value::Time(time) if clock_column(&column.kind) && time.to_time_of_day().is_some() => Shape::Clock,
        Value::TimeTz(time) if clock_column(&column.kind) && time.time.to_time_of_day().is_some() => Shape::Clock,
        _ => return None,
    };
    // Core owns the declared precision, BC era and offset spelling. Only their layout changes here.
    let canonical = tablepro_core::export::value_text(value, column)?;
    reformat(&canonical, shape, format)
}

pub(super) fn width_text(canonical: &str, kind: &ColumnKind, format: DateFormat) -> String {
    let shape = match kind {
        ColumnKind::Date => Shape::Date,
        ColumnKind::Timestamp { .. } => Shape::Timestamp,
        _ if clock_column(kind) => Shape::Clock,
        _ => return canonical.to_owned(),
    };
    let mut text = canonical.to_owned();
    if !matches!(shape, Shape::Date)
        && let Some(digits) = kind.fractional_digits().filter(|digits| *digits > 0)
        && let Some(clock) = text.find("00:00:00")
    {
        text.insert_str(clock + 8, &format!(".{}", "0".repeat(usize::from(digits.min(9)))));
    }
    reformat(&text, shape, format).unwrap_or(text)
}

fn clock_column(kind: &ColumnKind) -> bool {
    matches!(
        kind,
        ColumnKind::Time {
            range: TimeRange::TimeOfDay,
            ..
        }
    )
}

fn reformat(canonical: &str, shape: Shape, format: DateFormat) -> Option<String> {
    if format == DateFormat::Iso {
        return Some(canonical.to_owned());
    }
    if matches!(shape, Shape::Clock) {
        return match format {
            DateFormat::UsLong => us_clock(canonical),
            _ => Some(canonical.to_owned()),
        };
    }
    let (canonical, era) = match canonical.strip_suffix(" BC") {
        Some(text) => (text, " BC"),
        None => (canonical, ""),
    };
    let (date, clock) = match shape {
        Shape::Timestamp => {
            let (date, clock) = canonical.split_once(' ')?;
            (date, Some(clock))
        }
        Shape::Date => (canonical, None),
        Shape::Clock => return None,
    };
    let (year, rest) = date.split_once('-')?;
    let (month, day) = rest.split_once('-')?;
    let date = match format {
        DateFormat::Iso | DateFormat::IsoDate => date.to_owned(),
        DateFormat::UsLong | DateFormat::UsShort => format!("{month}/{day}/{year}"),
        DateFormat::EuLong | DateFormat::EuShort => format!("{day}/{month}/{year}"),
    };
    let clock = match (clock, format) {
        (Some(clock), DateFormat::UsLong) => Some(us_clock(clock)?),
        (Some(clock), DateFormat::EuLong) => Some(clock.to_owned()),
        _ => None,
    };
    Some(match clock {
        Some(clock) => format!("{date} {clock}{era}"),
        None => format!("{date}{era}"),
    })
}

fn us_clock(canonical: &str) -> Option<String> {
    let (hour, rest) = canonical.split_once(':')?;
    let hour = hour.parse::<u8>().ok().filter(|hour| *hour < 24)?;
    let (rest, offset) = rest.split_at(rest.find(['+', '-']).unwrap_or(rest.len()));
    let shown_hour = match hour % 12 {
        0 => 12,
        other => other,
    };
    let period = if hour < 12 { "AM" } else { "PM" };
    Some(format!("{shown_hour:02}:{rest} {period}{offset}"))
}

#[cfg(test)]
mod tests {
    use chrono::{FixedOffset, NaiveDate};
    use tablepro_core::column::TemporalZone;
    use tablepro_core::value::{OffsetTimestamp, SqlTime, TimeWithOffset};

    use super::*;
    use crate::services::grid::display_text::{display_text, display_text_formatted};

    fn column(kind: ColumnKind) -> ColumnType {
        ColumnType {
            kind,
            ..ColumnType::untyped_text("temporal")
        }
    }

    fn stamp(digits: Option<u8>) -> ColumnType {
        column(ColumnKind::Timestamp {
            fractional_digits: digits,
            zone: TemporalZone::Naive,
        })
    }

    fn clock(range: TimeRange, digits: Option<u8>, with_offset: bool) -> ColumnType {
        column(ColumnKind::Time {
            fractional_digits: digits,
            range,
            with_offset,
        })
    }

    fn shown(value: &Value, column: &ColumnType, format: DateFormat) -> String {
        display_text_formatted(value, column, format, &mut String::new())
            .text
            .to_owned()
    }

    #[test]
    fn dates_follow_the_chosen_format_and_iso_leaves_them_alone() {
        let day = NaiveDate::from_ymd_opt(2024, 12, 31).expect("a day");
        let date = Value::Date(Temporal::Finite(day));
        let timestamp = Value::Timestamp(Temporal::Finite(day.and_hms_opt(23, 59, 58).expect("a clock")));
        for (format, expected_date, expected_stamp) in [
            (DateFormat::Iso, "2024-12-31", "2024-12-31 23:59:58"),
            (DateFormat::IsoDate, "2024-12-31", "2024-12-31"),
            (DateFormat::UsLong, "12/31/2024", "12/31/2024 11:59:58 PM"),
            (DateFormat::UsShort, "12/31/2024", "12/31/2024"),
            (DateFormat::EuLong, "31/12/2024", "31/12/2024 23:59:58"),
            (DateFormat::EuShort, "31/12/2024", "31/12/2024"),
        ] {
            assert_eq!(shown(&date, &column(ColumnKind::Date), format), expected_date);
            assert_eq!(shown(&timestamp, &stamp(None), format), expected_stamp);
        }
    }

    #[test]
    fn fractions_keep_the_column_precision_in_every_long_format() {
        let timestamp = Value::Timestamp(Temporal::Finite(
            NaiveDate::from_ymd_opt(2024, 12, 31)
                .expect("a day")
                .and_hms_nano_opt(23, 59, 58, 100_000_000)
                .expect("a clock"),
        ));
        for (digits, fraction) in [
            (None, ".1"),
            (Some(0), ""),
            (Some(3), ".100"),
            (Some(6), ".100000"),
            (Some(9), ".100000000"),
        ] {
            assert_eq!(
                shown(&timestamp, &stamp(digits), DateFormat::UsLong),
                format!("12/31/2024 11:59:58{fraction} PM")
            );
            assert_eq!(
                shown(&timestamp, &stamp(digits), DateFormat::EuLong),
                format!("31/12/2024 23:59:58{fraction}")
            );
        }
        assert_eq!(
            display_text(&timestamp, &stamp(Some(6)), &mut String::new()).text,
            "2024-12-31 23:59:58.100000"
        );
    }

    #[test]
    fn bc_years_and_years_past_four_digits_keep_their_era() {
        for (year, expected) in [(0, "01/01/0001 BC"), (-43, "01/01/0044 BC"), (10_000, "01/01/10000")] {
            let day = NaiveDate::from_ymd_opt(year, 1, 1).expect("a day");
            assert_eq!(
                shown(
                    &Value::Date(Temporal::Finite(day)),
                    &column(ColumnKind::Date),
                    DateFormat::UsShort
                ),
                expected
            );
        }
        let value = Value::Timestamp(Temporal::Finite(
            NaiveDate::from_ymd_opt(0, 1, 1)
                .expect("a day")
                .and_hms_opt(13, 0, 0)
                .expect("a clock"),
        ));
        assert_eq!(
            shown(&value, &stamp(None), DateFormat::UsLong),
            "01/01/0001 01:00:00 PM BC"
        );
    }

    #[test]
    fn timestamp_offsets_keep_local_dates_and_seconds_only_with_the_clock() {
        let offset = FixedOffset::east_opt(5 * 3600 + 30 * 60 + 15).expect("offset");
        let value = Value::TimestampTz(Temporal::Finite(OffsetTimestamp::from_datetime(
            NaiveDate::from_ymd_opt(2024, 12, 31)
                .expect("a day")
                .and_hms_nano_opt(0, 1, 2, 123_456_789)
                .expect("a clock")
                .and_local_timezone(offset)
                .single()
                .expect("an instant"),
        )));
        for (format, expected) in [
            (DateFormat::Iso, "2024-12-31 00:01:02.123456789+05:30:15"),
            (DateFormat::IsoDate, "2024-12-31"),
            (DateFormat::UsLong, "12/31/2024 12:01:02.123456789 AM+05:30:15"),
            (DateFormat::UsShort, "12/31/2024"),
            (DateFormat::EuLong, "31/12/2024 00:01:02.123456789+05:30:15"),
            (DateFormat::EuShort, "31/12/2024"),
        ] {
            assert_eq!(shown(&value, &stamp(Some(9)), format), expected);
        }
    }

    #[test]
    fn clocks_use_twelve_hours_only_for_us_long_even_in_date_only_formats() {
        for (hour, expected) in [
            (0, "12:04:05.100000 AM"),
            (12, "12:04:05.100000 PM"),
            (23, "11:04:05.100000 PM"),
        ] {
            let time = SqlTime::new(false, hour, 4, 5, 100_000_000).expect("clock");
            let column = clock(TimeRange::TimeOfDay, Some(6), false);
            for format in DateFormat::ALL {
                let expected = if format == DateFormat::UsLong {
                    expected.to_owned()
                } else {
                    time.format(Some(6))
                };
                assert_eq!(shown(&Value::Time(time), &column, format), expected);
            }
        }
        let value = Value::TimeTz(TimeWithOffset {
            time: SqlTime::new(false, 13, 4, 5, 100_000_000).expect("clock"),
            offset: FixedOffset::west_opt(3 * 3600 + 15).expect("offset"),
        });
        assert_eq!(
            shown(&value, &clock(TimeRange::TimeOfDay, Some(6), true), DateFormat::UsLong),
            "01:04:05.100000 PM-03:00:15"
        );
        assert_eq!(
            shown(&value, &clock(TimeRange::TimeOfDay, Some(6), true), DateFormat::UsShort),
            "13:04:05.100000-03:00:15"
        );
    }

    #[test]
    fn durations_and_unknown_time_columns_never_become_clocks() {
        for time in ["13:00:00", "-01:00:00", "24:00:00", "100:00:00"] {
            let value = Value::Time(time.parse().expect("time"));
            for column in [
                clock(TimeRange::Duration, None, false),
                clock(TimeRange::LongDuration, None, false),
                column(ColumnKind::Other),
            ] {
                for format in DateFormat::ALL {
                    assert_eq!(shown(&value, &column, format), time);
                }
            }
        }
    }

    #[test]
    fn nonfinite_and_text_values_keep_their_canonical_spelling() {
        for (value, expected) in [
            (Value::Date(Temporal::Infinity), "infinity"),
            (Value::Timestamp(Temporal::NegInfinity), "-infinity"),
            (Value::TimestampTz(Temporal::Infinity), "infinity"),
            (Value::Text("2024-12-31".into()), "2024-12-31"),
        ] {
            for format in DateFormat::ALL {
                assert_eq!(shown(&value, &stamp(None), format), expected);
            }
        }
    }
}
