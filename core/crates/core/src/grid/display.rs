use std::borrow::Cow;
use std::fmt::Write;

use crate::column::{BoolStorage, ColumnKind, ColumnType};
use crate::grid::DateFormat;
use crate::value::Value;

/// A million-character value would hang a layout engine, and a cell shapes
/// all it is given though a line of it shows. The model keeps the whole
/// value; only the cell is cut, past what its tooltip quotes.
pub const DISPLAY_MAX_CHARS: usize = 1_000;

/// The most lines a wrapped cell shows. A constant on every platform, with no setting.
pub const WRAP_MAX_LINES: i32 = 10;

const LINE_BREAKS: [char; 6] = ['\r', '\u{b}', '\u{c}', '\u{85}', '\u{2028}', '\u{2029}'];

/// `text` for a cell that wraps: each line break as LF, a CRLF as one, and
/// without one break at its end, which would draw an empty line. A layout
/// engine breaks at only some of these, so it never meets the rest.
pub fn keep_line_breaks(text: &str) -> Cow<'_, str> {
    let head = &text[..text.len() - trailing_break_len(text)];
    if !head.contains(LINE_BREAKS) {
        return Cow::Borrowed(head);
    }
    let mut kept = String::with_capacity(head.len());
    let mut chars = head.chars().peekable();
    while let Some(character) = chars.next() {
        match character {
            '\r' => {
                chars.next_if_eq(&'\n');
                kept.push('\n');
            }
            other if LINE_BREAKS.contains(&other) => kept.push('\n'),
            other => kept.push(other),
        }
    }
    Cow::Owned(kept)
}

fn trailing_break_len(text: &str) -> usize {
    if text.ends_with("\r\n") {
        return 2;
    }
    text.chars()
        .next_back()
        .filter(|last| *last == '\n' || LINE_BREAKS.contains(last))
        .map_or(0, char::len_utf8)
}

/// `text` up to `hidden_from`, where its first hidden line starts, ending
/// in an ellipsis. A layout engine draws none when the cut falls on a line
/// break.
pub fn line_cut(text: &str, hidden_from: usize) -> String {
    let mut end = hidden_from.min(text.len());
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    let head = &text[..end];
    let head = head.strip_suffix('\n').unwrap_or(head).trim_end_matches(' ');
    let mut cut = String::with_capacity(head.len() + '…'.len_utf8());
    cut.push_str(head);
    if !head.ends_with('…') {
        cut.push('…');
    }
    cut
}

/// What a cell shows for a value, apart from any word the app puts in a
/// placeholder's place: the value's own text where it has one, a cell-wide
/// cut, or a marker the app words.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ValueDisplay<'a> {
    /// The value's text, cut to the cell's cap with any NUL shown as a
    /// symbol. `text` borrows the value where it can. `truncated_bytes` is
    /// how much the cut left out, which the app says in its own words.
    Shown { text: Cow<'a, str>, truncated_bytes: usize },
    /// A NULL: the app shows its chosen null word.
    Null,
    /// A blob of this many bytes: no readable text, so the app says how big
    /// it is.
    Bytes(usize),
    /// A value the driver could not read, named by its type.
    Undecodable(&'a str),
}

/// What a cell shows for `value`, at the column's precision, laid out as
/// `date_format` asks.
pub fn value_display<'a>(value: &'a Value, column: &ColumnType, date_format: DateFormat) -> ValueDisplay<'a> {
    match value {
        Value::Null => ValueDisplay::Null,
        Value::Text(text) => shown(text),
        // The server's own text, never parsed and written out again.
        Value::Json(json) => shown(json.as_str()),
        Value::Other(other) => shown(&other.text),
        Value::Bytes(bytes) => ValueDisplay::Bytes(bytes.len()),
        Value::Undecodable(undecodable) => ValueDisplay::Undecodable(&undecodable.type_name),
        other => {
            let mut out = String::new();
            write_scalar(other, column, date_format, &mut out);
            let truncated_bytes = cut_in_place(&mut out);
            ValueDisplay::Shown {
                text: Cow::Owned(out),
                truncated_bytes,
            }
        }
    }
}

/// `value`'s own text in full, for a value that has one: text, JSON and the
/// server's own text borrow, scalars and temporals format. `None` for null,
/// a blob or an unreadable value, which have no text of their own.
pub fn whole_text<'a>(
    value: &'a Value,
    column: &ColumnType,
    date_format: DateFormat,
    scratch: &'a mut String,
) -> Option<&'a str> {
    match value {
        Value::Text(text) => Some(text),
        Value::Json(json) => Some(json.as_str()),
        Value::Other(other) => Some(&other.text),
        Value::Null | Value::Bytes(_) | Value::Undecodable(_) => None,
        other => {
            scratch.clear();
            write_scalar(other, column, date_format, scratch);
            Some(scratch)
        }
    }
}

/// `value` written out as a scalar or temporal, for a value the grid shows
/// as its own text rather than through a placeholder.
pub fn write_scalar(value: &Value, column: &ColumnType, date_format: DateFormat, scratch: &mut String) {
    if let Some(text) = crate::grid::date_display::formatted(value, column, date_format) {
        *scratch = text;
        return;
    }
    // Writing to a String cannot fail.
    let _ = match value {
        Value::Bool(flag) => scratch.write_str(if *flag { "true" } else { "false" }),
        // A boolean kept in an integer reads as one; any other number it
        // holds is not a boolean and shows as itself.
        Value::Int(flag @ (0 | 1)) if column.kind == ColumnKind::Bool(BoolStorage::Integer) => {
            scratch.write_str(if *flag == 1 { "true" } else { "false" })
        }
        Value::UInt(flag @ (0 | 1)) if column.kind == ColumnKind::Bool(BoolStorage::Integer) => {
            scratch.write_str(if *flag == 1 { "true" } else { "false" })
        }
        Value::Int32(number) => write!(scratch, "{number}"),
        Value::Int(number) => write!(scratch, "{number}"),
        Value::UInt(number) => write!(scratch, "{number}"),
        Value::Float32(number) if number.is_finite() => write!(scratch, "{number}"),
        Value::Float64(number) if number.is_finite() => write!(scratch, "{number}"),
        Value::Uuid(id) => write!(scratch, "{id}"),
        other => {
            if let Some(text) = crate::export::value_text(other, column) {
                *scratch = text;
            }
            Ok(())
        }
    };
}

/// `text` as it is when it is short and holds no NUL, else its head,
/// cleaned, as an owned string with the bytes it left out counted.
fn shown(text: &str) -> ValueDisplay<'_> {
    let end = cut_at(text).unwrap_or(text.len());
    let head = &text[..end];
    if end == text.len() && !head.contains('\0') {
        return ValueDisplay::Shown {
            text: Cow::Borrowed(text),
            truncated_bytes: 0,
        };
    }
    let mut out = String::with_capacity(head.len());
    push_without_nul(&mut out, head);
    ValueDisplay::Shown {
        text: Cow::Owned(out),
        truncated_bytes: text.len() - end,
    }
}

fn cut_in_place(scratch: &mut String) -> usize {
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
    truncated_bytes
}

/// Where the cell cuts `text`, on a char boundary. A string of no more
/// bytes than the cap has no more chars either, so it is not walked.
fn cut_at(text: &str) -> Option<usize> {
    if text.len() <= DISPLAY_MAX_CHARS {
        return None;
    }
    text.char_indices().nth(DISPLAY_MAX_CHARS).map(|(index, _)| index)
}

/// A C string ends at a NUL, so the cell shows U+2400 in its place rather
/// than a value cut short.
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

#[cfg(test)]
impl ValueDisplay<'_> {
    /// The shown text, for a test over a value with one.
    pub(crate) fn into_text(self) -> String {
        match self {
            ValueDisplay::Shown { text, .. } => text.into_owned(),
            other => panic!("expected shown text, got {other:?}"),
        }
    }
}

#[cfg(test)]
pub(crate) fn display_text_formatted<'a>(
    value: &'a Value,
    column: &ColumnType,
    date_format: DateFormat,
) -> ValueDisplay<'a> {
    value_display(value, column, date_format)
}

#[cfg(test)]
mod tests {
    use std::borrow::Cow;

    use super::{DISPLAY_MAX_CHARS, ValueDisplay, WRAP_MAX_LINES, keep_line_breaks, line_cut, value_display};
    use crate::column::{BoolStorage, ColumnKind, ColumnType};
    use crate::grid::DateFormat;
    use crate::value::{JsonText, OffsetTimestamp, SqlTime, Temporal, UndecodableReason, UndecodedValue, Value};

    fn text_column() -> ColumnType {
        ColumnType::untyped_text("text")
    }

    fn display(value: &Value) -> ValueDisplay<'_> {
        value_display(value, &text_column(), DateFormat::Iso)
    }

    fn shown(value: &Value) -> String {
        display(value).into_text()
    }

    #[test]
    fn value_display_borrows_text_without_allocating() {
        let value = Value::Text("hello".into());

        let ValueDisplay::Shown { text, truncated_bytes } = display(&value) else {
            unreachable!("text is shown");
        };
        let Value::Text(stored) = &value else {
            unreachable!("built as text");
        };
        assert_eq!(text, "hello");
        assert!(matches!(text, Cow::Borrowed(_)), "the text was copied");
        assert!(std::ptr::eq(text.as_ptr(), stored.as_ptr()), "the text was copied");
        assert_eq!(truncated_bytes, 0);
    }

    #[test]
    fn value_display_truncates_emoji_at_char_boundary_with_byte_count() {
        let value = Value::Text("🦀".repeat(DISPLAY_MAX_CHARS + 5));

        let ValueDisplay::Shown { text, truncated_bytes } = display(&value) else {
            unreachable!("text is shown");
        };
        assert_eq!(truncated_bytes, 5 * 4, "the bytes left out");
        assert!(text.starts_with(&"🦀".repeat(DISPLAY_MAX_CHARS)));
        assert!(
            !text.starts_with(&"🦀".repeat(DISPLAY_MAX_CHARS + 1)),
            "the cut kept more than the cap"
        );
        assert!(!text.contains('…'), "the core leaves the suffix to the app");
    }

    #[test]
    fn a_long_formatted_value_is_cut_too() {
        let value = Value::Array(vec![Value::Int(1); DISPLAY_MAX_CHARS]);

        let ValueDisplay::Shown { truncated_bytes, .. } = display(&value) else {
            unreachable!("an array is shown");
        };
        assert!(truncated_bytes > 0);
    }

    #[test]
    fn value_display_json_shows_stored_text_verbatim() {
        // Spacing and key order a re-serialisation would change.
        let stored = r#"{ "b":1,  "a" : [2,3] }"#;
        let value = Value::Json(JsonText::parse(stored.to_owned()).expect("valid json"));

        let ValueDisplay::Shown { text, .. } = display(&value) else {
            unreachable!("json is shown");
        };
        assert_eq!(text, stored);
        assert!(matches!(text, Cow::Borrowed(_)), "the JSON was copied");
    }

    #[test]
    fn value_display_bytes_and_undecodable_and_null_are_markers() {
        let undecodable = Value::Undecodable(Box::new(UndecodedValue {
            type_name: "geography".to_owned(),
            reason: UndecodableReason::UnsupportedType,
        }));

        assert_eq!(display(&Value::Bytes(vec![0u8; 16])), ValueDisplay::Bytes(16));
        assert_eq!(display(&Value::Bytes(vec![7])), ValueDisplay::Bytes(1));
        assert_eq!(display(&undecodable), ValueDisplay::Undecodable("geography"));
        assert_eq!(display(&Value::Null), ValueDisplay::Null);
    }

    #[test]
    fn a_nul_in_text_shows_as_its_symbol() {
        assert_eq!(shown(&Value::Text("a\0b".into())), "a\u{2400}b");
    }

    #[test]
    fn value_display_primitive_variants() {
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
        let text = |value: Value| value_display(&value, &flag, DateFormat::Iso).into_text();

        assert_eq!(text(Value::Int(1)), "true");
        assert_eq!(text(Value::Int(0)), "false");
        assert_eq!(text(Value::UInt(1)), "true");
        assert_eq!(text(Value::Int(2)), "2");
    }

    #[test]
    fn value_display_temporal_variants() {
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
    fn value_display_extended_variants() {
        let dec: crate::value::SqlDecimal = "1234.56789".parse().expect("a decimal");
        assert_eq!(shown(&Value::Decimal(dec)), "1234.56789");

        let id = uuid::Uuid::parse_str("550e8400-e29b-41d4-a716-446655440000").expect("a uuid");
        assert_eq!(shown(&Value::Uuid(id)), "550e8400-e29b-41d4-a716-446655440000");
    }

    #[test]
    fn a_huge_text_value_is_bounded() {
        let value = Value::Text("x".repeat(1_000_000));
        let ValueDisplay::Shown { text, truncated_bytes } = display(&value) else {
            unreachable!("text is shown");
        };

        assert!(text.len() <= DISPLAY_MAX_CHARS, "{}", text.len());
        assert_eq!(truncated_bytes, 1_000_000 - DISPLAY_MAX_CHARS);
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
