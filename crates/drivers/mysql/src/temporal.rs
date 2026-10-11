use sqlx::Decode;
use sqlx::mysql::types::MySqlTime;
use sqlx::mysql::{MySql, MySqlValueRef};
use tablepro_core::Value;

pub(crate) fn time_value(raw: MySqlValueRef<'_>) -> Option<Value> {
    let time = <MySqlTime as Decode<MySql>>::decode(raw).ok()?;
    if time.is_valid_time_of_day() {
        return chrono::NaiveTime::from_hms_micro_opt(
            time.hours(),
            u32::from(time.minutes()),
            u32::from(time.seconds()),
            time.microseconds(),
        )
        .map(Value::Time);
    }
    Some(Value::Text(time_text(&time)))
}

fn time_text(time: &MySqlTime) -> String {
    // sqlx 0.9 `MySqlTime::is_negative` returns the positive flag, so it would print every sign inverted.
    let sign = if time.sign().is_negative() { "-" } else { "" };
    let mut text = format!("{sign}{:02}:{:02}:{:02}", time.hours(), time.minutes(), time.seconds());
    push_micros(&mut text, time.microseconds());
    text
}

pub(crate) fn year_value(raw: MySqlValueRef<'_>) -> Option<Value> {
    <u16 as Decode<MySql>>::decode(raw)
        .ok()
        .map(|year| Value::Int(i64::from(year)))
}

pub(crate) fn calendar_text(raw: MySqlValueRef<'_>, with_time: bool) -> Option<Value> {
    let bytes = <&[u8] as Decode<MySql>>::decode(raw).ok()?;
    let fields = calendar_fields(bytes)?;
    let [year_low, year_high, month, day, hour, minute, second, ..] = fields;
    let year = u16::from_le_bytes([year_low, year_high]);
    let mut text = format!("{year:04}-{month:02}-{day:02}");
    if with_time {
        text.push_str(&format!(" {hour:02}:{minute:02}:{second:02}"));
        push_micros(
            &mut text,
            u32::from_le_bytes([fields[7], fields[8], fields[9], fields[10]]),
        );
    }
    Some(Value::Text(text))
}

fn calendar_fields(bytes: &[u8]) -> Option<[u8; 11]> {
    let (&length, body) = bytes.split_first()?;
    if !matches!(length, 0 | 4 | 7 | 11) || body.len() != usize::from(length) {
        return None;
    }
    let mut fields = [0u8; 11];
    fields.get_mut(..body.len())?.copy_from_slice(body);
    Some(fields)
}

fn push_micros(text: &mut String, micros: u32) {
    if micros != 0 {
        text.push_str(&format!(".{micros:06}"));
    }
}

#[cfg(test)]
mod tests {
    use super::calendar_fields;

    #[test]
    fn calendar_fields_accept_only_the_protocol_lengths() {
        assert_eq!(calendar_fields(&[0]), Some([0; 11]));
        assert_eq!(
            calendar_fields(&[4, 0xe8, 0x07, 0, 15]),
            Some([0xe8, 0x07, 0, 15, 0, 0, 0, 0, 0, 0, 0])
        );
        assert_eq!(calendar_fields(&[]), None);
        assert_eq!(calendar_fields(&[3, 1, 2, 3]), None);
        assert_eq!(calendar_fields(&[4, 1, 2, 3]), None);
        assert_eq!(calendar_fields(&[4, 1, 2, 3, 4, 5]), None);
    }
}
