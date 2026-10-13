use tablepro_core::Value;

/// A million-character value would hang the main thread in Pango
/// layout. The model keeps the whole value; only the cell is cut.
const DISPLAY_TEXT_MAX_CHARS: usize = 10_000;
/// UTF-8 is at most 4 bytes a char, so a shorter string skips the
/// O(n) char count.
const DISPLAY_TEXT_BYTES_THRESHOLD: usize = DISPLAY_TEXT_MAX_CHARS * 4;

/// The brackets keep it apart from a literal `NULL` text value.
pub(crate) fn editable_null_sentinel() -> String {
    crate::i18n::gettext("<NULL>")
}

/// A read-only cell dims its NULL instead, so it needs no brackets.
fn readonly_null_sentinel() -> String {
    crate::i18n::gettext("NULL")
}

/// For a column the server fills in on INSERT, so a new draft row does
/// not read as if its id were stored as NULL.
pub(super) fn auto_filled_sentinel() -> String {
    crate::i18n::gettext("(auto)")
}

pub(super) fn value_to_display_text(value: &Value) -> String {
    match value {
        Value::Null => readonly_null_sentinel(),
        // A blob has no readable text form, so the grid says how big
        // it is rather than showing bytes.
        Value::Bytes(b) => format!("<{} bytes>", b.len()),
        // The driver could not read this, and saying so is better than
        // an empty cell that looks like a NULL.
        Value::Undecodable(undecodable) => format!("<unreadable {}>", undecodable.type_name),
        // Everything else renders the way it exports, so what the grid
        // shows and what a copy produces are the same text.
        other => match tablepro_core::export::value_to_text(other) {
            Some(text) => truncate_for_display(&text),
            None => readonly_null_sentinel(),
        },
    }
}

/// The whole value as an editor starts from it, which committed
/// unchanged writes the value back. Never the display text, which is cut
/// short or stands in for a value. `None` for a value with no text form.
pub(super) fn value_to_edit_text(value: &Value) -> Option<String> {
    match value {
        Value::Null => Some(String::new()),
        Value::Bytes(_) | Value::Undecodable(_) => None,
        other => tablepro_core::export::value_to_text(other),
    }
}

/// Whether the cell shows only the start of `s`. Such a text is too long
/// for the one-line editor, which lays out all of it.
pub(super) fn is_cut_for_display(s: &str) -> bool {
    s.len() >= DISPLAY_TEXT_BYTES_THRESHOLD && s.chars().nth(DISPLAY_TEXT_MAX_CHARS).is_some()
}

pub(super) fn truncate_for_display(s: &str) -> String {
    if s.len() < DISPLAY_TEXT_BYTES_THRESHOLD {
        return s.to_string();
    }
    // Cut on a char boundary.
    let mut cut = s.len();
    for (i, (byte_idx, _)) in s.char_indices().enumerate() {
        if i >= DISPLAY_TEXT_MAX_CHARS {
            cut = byte_idx;
            break;
        }
    }
    if cut >= s.len() {
        return s.to_string();
    }
    let head = &s[..cut];
    let remaining = s[cut..].chars().count();
    format!("{head}… (+{remaining} more chars)")
}

#[cfg(test)]
mod tests {
    use tablepro_core::Value;

    use super::{is_cut_for_display, truncate_for_display, value_to_display_text, value_to_edit_text};

    #[test]
    fn display_text_primitive_variants() {
        assert_eq!(value_to_display_text(&Value::Null), "NULL");
        assert_eq!(value_to_display_text(&Value::Bool(true)), "true");
        assert_eq!(value_to_display_text(&Value::Int(42)), "42");
        assert_eq!(value_to_display_text(&Value::Text("hello".into())), "hello");
        assert_eq!(value_to_display_text(&Value::Bytes(vec![0u8; 16])), "<16 bytes>");
    }

    fn date_value(year: i32, month: u32, day: u32) -> Value {
        Value::Date(tablepro_core::value::Temporal::Finite(
            chrono::NaiveDate::from_ymd_opt(year, month, day).expect("a date"),
        ))
    }

    #[test]
    fn display_text_temporal_variants() {
        let date = chrono::NaiveDate::from_ymd_opt(2026, 4, 26).expect("a date");
        assert_eq!(value_to_display_text(&date_value(2026, 4, 26)), "2026-04-26");

        let time = chrono::NaiveTime::from_hms_opt(14, 30, 0).expect("a time");
        assert_eq!(
            value_to_display_text(&Value::Time(tablepro_core::value::SqlTime::from_time_of_day(time))),
            "14:30:00"
        );

        let datetime = chrono::NaiveDateTime::new(date, time);
        assert_eq!(
            value_to_display_text(&Value::Timestamp(tablepro_core::value::Temporal::Finite(datetime))),
            "2026-04-26 14:30:00"
        );

        let tz = chrono::DateTime::<chrono::Utc>::from_naive_utc_and_offset(datetime, chrono::Utc);
        assert_eq!(
            value_to_display_text(&Value::TimestampTz(tablepro_core::value::Temporal::Finite(
                tablepro_core::value::OffsetTimestamp::from_datetime(tz.fixed_offset())
            ))),
            "2026-04-26 14:30:00+00:00"
        );
    }

    #[test]
    fn display_text_extended_variants() {
        let dec: tablepro_core::value::SqlDecimal = "1234.56789".parse().expect("a decimal");
        assert_eq!(value_to_display_text(&Value::Decimal(dec)), "1234.56789");

        let id = uuid::Uuid::parse_str("550e8400-e29b-41d4-a716-446655440000").expect("a uuid");
        assert_eq!(
            value_to_display_text(&Value::Uuid(id)),
            "550e8400-e29b-41d4-a716-446655440000"
        );

        let json = tablepro_core::value::JsonText::parse(r#"{"a":1,"b":[2,3]}"#.to_owned()).expect("valid json");
        let text = value_to_display_text(&Value::Json(json));
        assert!(text.contains("\"a\":1"), "{text}");
    }

    #[test]
    fn a_value_the_driver_could_not_read_says_so() {
        let undecodable = Value::Undecodable(Box::new(tablepro_core::value::UndecodedValue {
            type_name: "geography".to_owned(),
            reason: tablepro_core::value::UndecodableReason::UnsupportedType,
        }));

        let text = value_to_display_text(&undecodable);

        assert!(text.contains("geography"), "{text}");
        assert_ne!(text, "NULL", "an unreadable value looked like a missing one");
    }

    #[test]
    fn edit_text_distinguishes_null_from_text_null() {
        assert_eq!(value_to_edit_text(&Value::Null).as_deref(), Some(""));
        assert_eq!(value_to_edit_text(&Value::Text("NULL".into())).as_deref(), Some("NULL"));
        assert_eq!(value_to_edit_text(&Value::Int(0)).as_deref(), Some("0"));
    }

    #[test]
    fn edit_text_keeps_extended_variants_visible() {
        assert_eq!(
            value_to_edit_text(&date_value(2026, 4, 26)).as_deref(),
            Some("2026-04-26")
        );

        let id = uuid::Uuid::parse_str("550e8400-e29b-41d4-a716-446655440000").unwrap();
        assert_eq!(
            value_to_edit_text(&Value::Uuid(id)).as_deref(),
            Some("550e8400-e29b-41d4-a716-446655440000")
        );
    }

    #[test]
    fn edit_text_is_the_whole_value_however_long() {
        let huge = "x".repeat(1_000_000);

        assert_eq!(value_to_edit_text(&Value::Text(huge.clone())), Some(huge.clone()));
        assert!(is_cut_for_display(&huge));
        assert!(!is_cut_for_display(&"x".repeat(39_999)));
        // 40,000 bytes, but only 10,000 characters, which the cell shows
        // whole.
        assert!(!is_cut_for_display(&"🦀".repeat(10_000)));
    }

    #[test]
    fn a_value_shown_by_a_stand_in_has_no_edit_text() {
        assert_eq!(value_to_edit_text(&Value::Bytes(vec![0u8; 16])), None);
    }

    #[test]
    fn truncate_short_text_passes_through() {
        let s = "hello world";
        assert_eq!(truncate_for_display(s), "hello world");
    }

    #[test]
    fn truncate_caps_long_text_at_char_boundary() {
        // 100k ASCII chars: should truncate to ~10k + suffix.
        let s = "a".repeat(100_000);
        let out = truncate_for_display(&s);
        assert!(out.starts_with(&"a".repeat(10_000)));
        assert!(out.contains("more chars"));
        assert!(out.len() < 10_500); // ~10k chars + suffix bytes
    }

    #[test]
    fn truncate_handles_multibyte_boundary() {
        // 30k 4-byte emoji (120k bytes): truncation must land on a
        // char boundary, not mid-codepoint.
        let s = "🦀".repeat(30_000);
        let out = truncate_for_display(&s);
        // Must be valid UTF-8.
        assert!(std::str::from_utf8(out.as_bytes()).is_ok());
        // First DISPLAY_TEXT_MAX_CHARS chars should be 🦀 plus the
        // suffix appended after.
        assert!(out.contains("more chars"));
    }

    #[test]
    fn display_text_truncates_huge_text_value() {
        let huge = "x".repeat(1_000_000);
        let display = value_to_display_text(&Value::Text(huge));
        assert!(display.len() < 100_000); // bounded
        assert!(display.contains("more chars"));
    }
}
