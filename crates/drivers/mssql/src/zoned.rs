use chrono::{DateTime, FixedOffset, Timelike};
use tablepro_core::Value;
use tiberius::ColumnData;
use tiberius::FromSql;
use tiberius::time::DateTimeOffset;

const MAX_SCALE: u8 = 7;

pub(crate) fn datetimeoffset_text(stored: Option<DateTimeOffset>) -> Option<Value> {
    let Some(stored) = stored else {
        return Some(Value::Null);
    };
    let time = stored.datetime2().time();
    let scale = time.scale();
    if scale > MAX_SCALE || !(-840..=840).contains(&stored.offset()) {
        return None;
    }
    if time.increments() >= 86_400 * 10u64.pow(u32::from(scale)) {
        return None;
    }
    let local = DateTime::<FixedOffset>::from_sql(&ColumnData::DateTimeOffset(Some(stored))).ok()??;
    Some(Value::Text(render(local, scale)))
}

fn render(local: DateTime<FixedOffset>, scale: u8) -> String {
    let mut text = local.format("%Y-%m-%d %H:%M:%S").to_string();
    if scale > 0 {
        let fraction = local.nanosecond() / 10u32.pow(9 - u32::from(scale));
        text.push_str(&format!(".{fraction:0width$}", width = usize::from(scale)));
    }
    text.push_str(&local.format(" %:z").to_string());
    text
}

#[cfg(test)]
mod tests {
    use super::*;
    use tiberius::time::{Date, DateTime2, Time};

    fn stored(days: u32, increments: u64, scale: u8, offset: i16) -> Option<DateTimeOffset> {
        Some(DateTimeOffset::new(
            DateTime2::new(Date::new(days), Time::new(increments, scale)),
            offset,
        ))
    }

    #[test]
    fn value_contract_datetimeoffset_renders_local_time_scale_and_offset() {
        let text = |value: Option<Value>| match value {
            Some(Value::Text(text)) => text,
            other => panic!("{other:?}"),
        };
        assert_eq!(
            text(datetimeoffset_text(stored(0, 14 * 3_600 * 10_000_000 + 1, 7, -840))),
            "0001-01-01 00:00:00.0000001 -14:00"
        );
        assert_eq!(
            text(datetimeoffset_text(stored(0, 5, 1, 330))),
            "0001-01-01 05:30:00.5 +05:30"
        );
        assert_eq!(
            text(datetimeoffset_text(stored(0, 0, 0, 840))),
            "0001-01-01 14:00:00 +14:00"
        );
        assert_eq!(datetimeoffset_text(None), Some(Value::Null));
    }

    #[test]
    fn value_contract_datetimeoffset_refuses_invalid_scale_and_offset() {
        assert_eq!(datetimeoffset_text(stored(0, 0, 8, 0)), None);
        assert_eq!(datetimeoffset_text(stored(0, 0, 7, 841)), None);
        assert_eq!(datetimeoffset_text(stored(0, 0, 7, -841)), None);
        assert_eq!(datetimeoffset_text(stored(0, 86_400, 0, 0)), None);
    }
}
