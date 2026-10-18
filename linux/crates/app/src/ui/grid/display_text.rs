use std::fmt::Write;

use tablepro_core::Value;
use tablepro_core::column::ColumnType;

/// A million-character value would hang the main thread in Pango
/// layout, and the cell shapes all it is given though a line of it
/// shows. The model keeps the whole value; only the cell is cut, past
/// what its tooltip quotes.
pub(super) const DISPLAY_MAX_CHARS: usize = 1_000;

/// What a cell shows for a value. `text` borrows the value where it
/// can, so a text cell draws with no copy of its own.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) struct DisplayText<'a> {
    pub text: &'a str,
    /// The text stands in for a value rather than spelling it.
    pub placeholder: bool,
    /// How much of the value's text the cell left out.
    pub truncated_bytes: usize,
}

impl<'a> DisplayText<'a> {
    pub(super) fn placeholder(text: &'a str) -> Self {
        Self {
            text,
            placeholder: true,
            truncated_bytes: 0,
        }
    }
}

/// The brackets keep it apart from a literal `NULL` text value.
pub(super) fn editable_null_sentinel() -> String {
    crate::i18n::gettext("<NULL>")
}

/// A read-only cell dims its NULL instead, so it needs no brackets.
/// A technical term, so it is not translated.
const READONLY_NULL: &str = "NULL";

/// For a column the server fills in on INSERT, so a new draft row does
/// not read as if its id were stored as NULL.
pub(super) fn auto_filled_sentinel() -> String {
    crate::i18n::gettext("(auto)")
}

/// The text of `value` as the cell draws it. Text, JSON and a value the
/// driver kept as the server's text are borrowed; anything else is
/// written into `scratch`, the cell's own buffer.
pub(super) fn display_text<'a>(value: &'a Value, column: &ColumnType, scratch: &'a mut String) -> DisplayText<'a> {
    scratch.clear();
    match value {
        Value::Null => DisplayText::placeholder(READONLY_NULL),
        Value::Text(text) => shown(text, scratch),
        // The server's own text, never parsed and written out again.
        Value::Json(json) => shown(json.as_str(), scratch),
        Value::Other(other) => shown(&other.text, scratch),
        // A blob has no readable text form, so the grid says how big it
        // is rather than showing bytes.
        Value::Bytes(bytes) => {
            let count = bytes.len();
            *scratch = crate::i18n::ngettext_f(
                "<{count} byte>",
                "<{count} bytes>",
                plural_count(count),
                &[("count", &count.to_string())],
            );
            DisplayText::placeholder(scratch)
        }
        // The driver could not read this, and saying so is better than an
        // empty cell that looks like a NULL.
        Value::Undecodable(undecodable) => {
            *scratch = crate::i18n::gettext_f("<unreadable {type}>", &[("type", &undecodable.type_name)]);
            DisplayText::placeholder(scratch)
        }
        other => {
            write_value(other, column, scratch);
            cut_in_place(scratch)
        }
    }
}

/// Everything else renders the way it exports, so what the grid shows
/// and what a copy produces are the same text. The common scalars are
/// written straight into the buffer.
fn write_value(value: &Value, column: &ColumnType, scratch: &mut String) {
    // Writing to a String cannot fail.
    let _ = match value {
        Value::Bool(flag) => scratch.write_str(if *flag { "true" } else { "false" }),
        Value::Int(number) => write!(scratch, "{number}"),
        Value::UInt(number) => write!(scratch, "{number}"),
        Value::Float32(number) if number.is_finite() => write!(scratch, "{number}"),
        Value::Float64(number) if number.is_finite() => write!(scratch, "{number}"),
        Value::Uuid(id) => write!(scratch, "{id}"),
        other => {
            if let Some(text) = tablepro_core::export::value_text(other, column) {
                *scratch = text;
            }
            Ok(())
        }
    };
}

/// `text` as it is when it is short and holds no NUL, else its head,
/// cleaned, in `scratch`.
fn shown<'a>(text: &'a str, scratch: &'a mut String) -> DisplayText<'a> {
    let end = cut_at(text).unwrap_or(text.len());
    let head = &text[..end];
    if end == text.len() && !head.contains('\0') {
        return DisplayText {
            text,
            placeholder: false,
            truncated_bytes: 0,
        };
    }
    push_without_nul(scratch, head);
    finish_cut(scratch, text.len() - end)
}

fn cut_in_place(scratch: &mut String) -> DisplayText<'_> {
    let truncated_bytes = match cut_at(scratch) {
        Some(end) => {
            let left_out = scratch.len() - end;
            scratch.truncate(end);
            left_out
        }
        None => 0,
    };
    if scratch.contains('\0') {
        *scratch = scratch.replace('\0', "\u{2400}");
    }
    finish_cut(scratch, truncated_bytes)
}

fn finish_cut(scratch: &mut String, truncated_bytes: usize) -> DisplayText<'_> {
    if truncated_bytes > 0 {
        scratch.push_str(&crate::i18n::ngettext_f(
            "… ({count} more byte)",
            "… ({count} more bytes)",
            plural_count(truncated_bytes),
            &[("count", &truncated_bytes.to_string())],
        ));
    }
    DisplayText {
        text: scratch,
        placeholder: false,
        truncated_bytes,
    }
}

/// Where the cell cuts `text`, on a char boundary. A string of no more
/// bytes than the cap has no more chars either, so it is not walked.
fn cut_at(text: &str) -> Option<usize> {
    if text.len() <= DISPLAY_MAX_CHARS {
        return None;
    }
    text.char_indices().nth(DISPLAY_MAX_CHARS).map(|(index, _)| index)
}

/// GTK takes C strings, which end at a NUL, so the cell shows U+2400 in
/// its place rather than a value cut short.
fn push_without_nul(scratch: &mut String, text: &str) {
    let mut parts = text.split('\0');
    if let Some(first) = parts.next() {
        scratch.push_str(first);
    }
    for part in parts {
        scratch.push('\u{2400}');
        scratch.push_str(part);
    }
}

fn plural_count(count: usize) -> u32 {
    u32::try_from(count).unwrap_or(u32::MAX)
}

#[cfg(test)]
mod tests {
    use tablepro_core::Value;
    use tablepro_core::column::ColumnType;
    use tablepro_core::value::{JsonText, OffsetTimestamp, SqlTime, Temporal, UndecodableReason, UndecodedValue};

    use super::{DISPLAY_MAX_CHARS, DisplayText, display_text};

    fn text_column() -> ColumnType {
        ColumnType::untyped_text("text")
    }

    fn shown(value: &Value) -> String {
        let mut scratch = String::new();
        display_text(value, &text_column(), &mut scratch).text.to_owned()
    }

    #[test]
    fn display_text_borrows_text_without_allocating() {
        let value = Value::Text("hello".into());
        let mut scratch = String::new();

        let display = display_text(&value, &text_column(), &mut scratch);

        let Value::Text(stored) = &value else {
            unreachable!("built as text");
        };
        assert_eq!(display.text, "hello");
        assert!(
            std::ptr::eq(display.text.as_ptr(), stored.as_ptr()),
            "the text was copied"
        );
        assert!(!display.placeholder);
        assert_eq!(scratch.capacity(), 0, "the scratch buffer was written to");
    }

    #[test]
    fn display_text_truncates_emoji_at_char_boundary_with_byte_suffix() {
        let value = Value::Text("🦀".repeat(DISPLAY_MAX_CHARS + 5));
        let mut scratch = String::new();

        let display = display_text(&value, &text_column(), &mut scratch);

        assert_eq!(display.truncated_bytes, 5 * 4, "the bytes left out");
        assert!(display.text.starts_with(&"🦀".repeat(DISPLAY_MAX_CHARS)));
        assert!(
            !display.text.starts_with(&"🦀".repeat(DISPLAY_MAX_CHARS + 1)),
            "the cut kept more than the cap"
        );
        assert!(
            display.text.ends_with("… (20 more bytes)"),
            "{}",
            &display.text[40_000..]
        );
    }

    #[test]
    fn a_long_formatted_value_is_cut_too() {
        let value = Value::Array(vec![Value::Int(1); DISPLAY_MAX_CHARS]);
        let mut scratch = String::new();

        let display = display_text(&value, &text_column(), &mut scratch);

        assert!(display.truncated_bytes > 0);
        assert!(display.text.contains("more bytes"));
    }

    #[test]
    fn display_text_json_shows_stored_text_verbatim() {
        // Spacing and key order a re-serialisation would change.
        let stored = r#"{ "b":1,  "a" : [2,3] }"#;
        let value = Value::Json(JsonText::parse(stored.to_owned()).expect("valid json"));
        let mut scratch = String::new();

        let display = display_text(&value, &text_column(), &mut scratch);

        assert_eq!(display.text, stored);
        assert_eq!(scratch.capacity(), 0, "the JSON was copied");
    }

    #[test]
    fn display_text_bytes_and_undecodable_placeholders() {
        let undecodable = Value::Undecodable(Box::new(UndecodedValue {
            type_name: "geography".to_owned(),
            reason: UndecodableReason::UnsupportedType,
        }));
        let mut scratch = String::new();

        assert_eq!(
            display_text(&Value::Bytes(vec![0u8; 16]), &text_column(), &mut scratch),
            DisplayText::placeholder("<16 bytes>")
        );
        assert_eq!(shown(&Value::Bytes(vec![7])), "<1 byte>");
        let unreadable = display_text(&undecodable, &text_column(), &mut scratch);
        assert!(unreadable.placeholder);
        assert!(unreadable.text.contains("geography"), "{}", unreadable.text);
        assert_eq!(
            display_text(&Value::Null, &text_column(), &mut scratch),
            DisplayText::placeholder("NULL")
        );
    }

    #[test]
    fn a_nul_in_text_shows_as_its_symbol() {
        assert_eq!(shown(&Value::Text("a\0b".into())), "a\u{2400}b");
    }

    #[test]
    fn display_text_primitive_variants() {
        assert_eq!(shown(&Value::Bool(true)), "true");
        assert_eq!(shown(&Value::Int(42)), "42");
        assert_eq!(shown(&Value::UInt(7)), "7");
        assert_eq!(shown(&Value::Float64(1.5)), "1.5");
        assert_eq!(shown(&Value::Float32(0.1)), "0.1");
        assert_eq!(shown(&Value::Text("hello".into())), "hello");
    }

    #[test]
    fn display_text_temporal_variants() {
        let date = chrono::NaiveDate::from_ymd_opt(2026, 4, 26).expect("a date");
        assert_eq!(shown(&Value::Date(Temporal::Finite(date))), "2026-04-26");

        let time = chrono::NaiveTime::from_hms_opt(14, 30, 0).expect("a time");
        assert_eq!(shown(&Value::Time(SqlTime::from_time_of_day(time))), "14:30:00");

        let datetime = chrono::NaiveDateTime::new(date, time);
        assert_eq!(
            shown(&Value::Timestamp(Temporal::Finite(datetime))),
            "2026-04-26 14:30:00"
        );

        let tz = chrono::DateTime::<chrono::Utc>::from_naive_utc_and_offset(datetime, chrono::Utc);
        assert_eq!(
            shown(&Value::TimestampTz(Temporal::Finite(OffsetTimestamp::from_datetime(
                tz.fixed_offset()
            )))),
            "2026-04-26 14:30:00+00:00"
        );
    }

    #[test]
    fn display_text_extended_variants() {
        let dec: tablepro_core::value::SqlDecimal = "1234.56789".parse().expect("a decimal");
        assert_eq!(shown(&Value::Decimal(dec)), "1234.56789");

        let id = uuid::Uuid::parse_str("550e8400-e29b-41d4-a716-446655440000").expect("a uuid");
        assert_eq!(shown(&Value::Uuid(id)), "550e8400-e29b-41d4-a716-446655440000");
    }

    #[test]
    fn a_huge_text_value_draws_bounded() {
        let display = shown(&Value::Text("x".repeat(1_000_000)));

        assert!(display.len() < 1_100, "{}", display.len());
        assert!(display.ends_with("… (999000 more bytes)"));
    }
}
