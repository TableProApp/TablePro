use std::borrow::Cow;

use tablepro_core::Value;
use tablepro_core::column::ColumnType;
use tablepro_core::grid::display::{ValueDisplay, value_display, write_scalar};
use tablepro_linux_platform::settings::DateFormat;

pub use tablepro_core::grid::display::{DISPLAY_MAX_CHARS, WRAP_MAX_LINES, keep_line_breaks, line_cut};

use super::date_display::core_format;

/// What a cell shows for a value. `text` borrows the value where it can, so
/// a text cell draws with no copy of its own.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DisplayText<'a> {
    pub text: &'a str,
    /// The text stands in for a value rather than spelling it.
    pub placeholder: bool,
    /// How much of the value's text the cell left out.
    pub truncated_bytes: usize,
}

impl<'a> DisplayText<'a> {
    pub fn placeholder(text: &'a str) -> Self {
        Self {
            text,
            placeholder: true,
            truncated_bytes: 0,
        }
    }
}

/// The brackets keep it apart from a literal `NULL` text value.
pub fn editable_null_sentinel() -> String {
    crate::i18n::gettext("<NULL>")
}

pub fn null_text(text: &str, editable: bool) -> String {
    match (editable, text) {
        (true, "NULL") => editable_null_sentinel(),
        _ => text.to_owned(),
    }
}

/// A read-only cell dims its NULL instead, so it needs no brackets. A
/// technical term, so it is not translated.
const READONLY_NULL: &str = "NULL";

/// For a column the server fills in on INSERT, so a new draft row does not
/// read as if its id were stored as NULL.
pub fn auto_filled_sentinel() -> String {
    crate::i18n::gettext("(auto)")
}

pub fn display_text<'a>(value: &'a Value, column: &ColumnType, scratch: &'a mut String) -> DisplayText<'a> {
    display_text_formatted(value, column, DateFormat::Iso, scratch)
}

pub fn display_text_formatted<'a>(
    value: &'a Value,
    column: &ColumnType,
    date_format: DateFormat,
    scratch: &'a mut String,
) -> DisplayText<'a> {
    match value_display(value, column, core_format(date_format)) {
        ValueDisplay::Null => DisplayText::placeholder(READONLY_NULL),
        ValueDisplay::Bytes(count) => {
            *scratch = crate::i18n::ngettext_f(
                "<{count} byte>",
                "<{count} bytes>",
                count,
                &[("count", &count.to_string())],
            );
            DisplayText::placeholder(scratch)
        }
        ValueDisplay::Undecodable(type_name) => {
            *scratch = crate::i18n::gettext_f("<unreadable {type}>", &[("type", type_name)]);
            DisplayText::placeholder(scratch)
        }
        ValueDisplay::Shown { text, truncated_bytes } => shown(text, truncated_bytes, scratch),
    }
}

/// The value's own text, with the byte count the core left to the app worded
/// and appended.
fn shown<'a>(text: Cow<'a, str>, truncated_bytes: usize, scratch: &'a mut String) -> DisplayText<'a> {
    match text {
        Cow::Borrowed(borrowed) => DisplayText {
            text: borrowed,
            placeholder: false,
            truncated_bytes,
        },
        Cow::Owned(owned) => {
            *scratch = owned;
            if truncated_bytes > 0 {
                scratch.push_str(&more_bytes(truncated_bytes));
            }
            DisplayText {
                text: scratch,
                placeholder: false,
                truncated_bytes,
            }
        }
    }
}

pub fn whole_text<'a>(
    value: &'a Value,
    column: &ColumnType,
    date_format: DateFormat,
    scratch: &'a mut String,
) -> &'a str {
    match value {
        Value::Text(text) => text,
        Value::Json(json) => json.as_str(),
        Value::Other(other) => &other.text,
        Value::Null | Value::Bytes(_) | Value::Undecodable(_) => display_text(value, column, scratch).text,
        other => {
            scratch.clear();
            write_scalar(other, column, core_format(date_format), scratch);
            scratch
        }
    }
}

pub fn more_bytes(count: usize) -> String {
    crate::i18n::ngettext_f(
        "… ({count} more byte)",
        "… ({count} more bytes)",
        count,
        &[("count", &count.to_string())],
    )
}

#[cfg(test)]
mod tests {
    use tablepro_core::Value;
    use tablepro_core::column::{BoolStorage, ColumnKind, ColumnType};
    use tablepro_core::value::{JsonText, OffsetTimestamp, SqlTime, Temporal, UndecodableReason, UndecodedValue};

    use std::borrow::Cow;

    use super::{DISPLAY_MAX_CHARS, DisplayText, WRAP_MAX_LINES, display_text, keep_line_breaks, line_cut, null_text};

    fn text_column() -> ColumnType {
        ColumnType::untyped_text("text")
    }

    fn shown(value: &Value) -> String {
        let mut scratch = String::new();
        display_text(value, &text_column(), &mut scratch).text.to_owned()
    }

    #[test]
    fn a_chosen_null_text_reaches_editable_cells_and_the_default_keeps_its_brackets() {
        assert_eq!(null_text("NULL", true), "<NULL>");
        assert_eq!(null_text("(none)", true), "(none)");
        assert_eq!(null_text("(none)", false), "(none)");
        assert_eq!(null_text("NULL", false), "NULL");
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
        assert!(display.text.ends_with("… (20 more bytes)"), "{}", display.text);
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
        assert_eq!(shown(&Value::Int32(-7)), "-7");
        assert_eq!(shown(&Value::Float64(1.5)), "1.5");
        assert_eq!(shown(&Value::Float32(0.1)), "0.1");
        assert_eq!(shown(&Value::Text("hello".into())), "hello");
    }

    #[test]
    fn an_integer_boolean_reads_true_or_false_and_other_numbers_as_themselves() {
        let flag = ColumnType {
            kind: ColumnKind::Bool(BoolStorage::Integer),
            ..ColumnType::untyped_text("tinyint(1)")
        };
        let mut scratch = String::new();
        let mut text = |value: Value| display_text(&value, &flag, &mut scratch).text.to_owned();

        assert_eq!(text(Value::Int(1)), "true");
        assert_eq!(text(Value::Int(0)), "false");
        assert_eq!(text(Value::UInt(1)), "true");
        assert_eq!(text(Value::Int(2)), "2");
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

    #[test]
    fn a_wrapped_cell_shows_ten_lines_on_every_platform() {
        assert_eq!(WRAP_MAX_LINES, 10);
    }

    #[test]
    fn every_line_break_form_becomes_one_lf() {
        let cases = [
            ("a\nb", "a\nb"),
            ("a\r\nb", "a\nb"),
            ("a\rb", "a\nb"),
            ("a\u{b}b", "a\nb"),
            ("a\u{c}b", "a\nb"),
            ("a\u{85}b", "a\nb"),
            ("a\u{2028}b", "a\nb"),
            ("a\u{2029}b", "a\nb"),
            ("a\r\n\r\nb", "a\n\nb"),
            ("a\n\rb", "a\n\nb"),
        ];
        for (value, kept) in cases {
            assert_eq!(keep_line_breaks(value), kept, "{value:?}");
        }
    }

    #[test]
    fn one_trailing_line_break_is_dropped() {
        let cases = [
            ("a\n", "a"),
            ("a\r\n", "a"),
            ("a\r", "a"),
            ("a\u{2029}", "a"),
            ("a\n\n", "a\n"),
            ("a\r\n\r\n", "a\n"),
            ("\n", ""),
            ("", ""),
        ];
        for (value, kept) in cases {
            assert_eq!(keep_line_breaks(value), kept, "{value:?}");
        }
    }

    #[test]
    fn text_with_only_lf_breaks_is_not_copied() {
        assert!(matches!(
            keep_line_breaks("one\ntwo\tthree"),
            Cow::Borrowed("one\ntwo\tthree")
        ));
        assert!(matches!(keep_line_breaks("one\n"), Cow::Borrowed("one")));
    }

    #[test]
    fn a_line_cut_ends_in_one_ellipsis() {
        assert_eq!(line_cut("one two three", 8), "one two…");
        assert_eq!(line_cut("one\ntwo\nthree", 8), "one\ntwo…");
        assert_eq!(
            line_cut("one\n\nthree", 5),
            "one\n…",
            "an empty last line keeps its place"
        );
        assert_eq!(
            line_cut("wait…\nmore", 8),
            "wait…",
            "the value's own ellipsis is not doubled"
        );
        assert_eq!(line_cut("short", 99), "short…");
    }

    #[test]
    fn a_line_cut_never_splits_a_character() {
        assert_eq!(line_cut("日本語", 4), "日…");
    }
}
