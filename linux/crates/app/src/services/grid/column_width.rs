use tablepro_core::Value;
use tablepro_core::column::{ColumnKind, TemporalZone, TextLength};
use unicode_width::{UnicodeWidthChar, UnicodeWidthStr};

use super::display_text::display_text;
use super::{CellDisplay, GridColumn};

const MIN_CHARS: u32 = 4;
const TEXT_MAX_CHARS: u32 = 40;
/// `false`, the longer of the two values.
const BOOL_CHARS: u32 = 5;
const SAMPLE_ROWS: usize = 200;
/// A value of a type that sets no length, as wide as a name or a code.
const TYPICAL_CHARS: u32 = 20;
/// A number of a type that sets no precision.
const TYPICAL_DIGITS: u32 = 10;

/// The monospace cells a column's values open at: its widest sampled
/// value. Text is capped so one long value does not push the rest off
/// screen; a number or a date is never cut. The header, drawn in another
/// font, is the caller's to measure.
pub fn default_width_chars<'a>(column: &GridColumn, sample: impl IntoIterator<Item = &'a Value>) -> u32 {
    let widest = widest_cells(column, sample);
    let cells = match column.display() {
        CellDisplay::Bool => BOOL_CHARS,
        CellDisplay::Number => widest,
        CellDisplay::Temporal => widest.max(spelled_chars(&column.column_type.kind).unwrap_or(0)),
        CellDisplay::Text | CellDisplay::Json | CellDisplay::Binary => widest.min(TEXT_MAX_CHARS),
    };
    cells.max(MIN_CHARS)
}

/// The monospace cells a column's values open at in a table that holds
/// no rows: a value its type leads one to expect. A bounded type gives
/// its widest value, text no wider than a name.
pub fn typical_width_chars(column: &GridColumn) -> u32 {
    let kind = &column.column_type.kind;
    let typical = match kind {
        ColumnKind::Bool(_) => BOOL_CHARS,
        // The digits, a sign and a decimal point.
        ColumnKind::Decimal {
            precision: Some(precision),
            ..
        } => precision.saturating_add(2).min(TYPICAL_CHARS),
        _ if kind.is_numeric() => TYPICAL_DIGITS,
        ColumnKind::Text {
            length: TextLength::Varying(length) | TextLength::Fixed(length),
        } => (*length).min(TYPICAL_CHARS),
        _ => spelled_chars(kind).unwrap_or(TYPICAL_CHARS),
    };
    typical.clamp(MIN_CHARS, TEXT_MAX_CHARS)
}

/// The values the column's type spells out, cut at the cap, for the
/// caller to measure.
pub fn typical_texts(column: &GridColumn) -> Vec<String> {
    spelled(&column.column_type.kind)
        .into_iter()
        .map(|text| within_cap(text).to_owned())
        .collect()
}

/// The width of a column that turned out to hold only numbers, as an
/// untyped PostgreSQL result does: a number is never cut.
pub fn number_width_chars<'a>(column: &GridColumn, sample: impl IntoIterator<Item = &'a Value>) -> u32 {
    widest_cells(column, sample).max(MIN_CHARS)
}

/// The column's name as its header draws it, cut at the cap.
pub fn header_text(column: &GridColumn) -> &str {
    within_cap(&column.name)
}

fn widest_cells<'a>(column: &GridColumn, sample: impl IntoIterator<Item = &'a Value>) -> u32 {
    let mut scratch = String::new();
    sample
        .into_iter()
        .take(SAMPLE_ROWS)
        .filter(|value| !value.is_null())
        .map(|value| cells(display_text(value, &column.column_type, &mut scratch).text))
        .max()
        .unwrap_or(0)
}

/// The sampled value that takes the most cells, as the cell draws it and
/// cut at the cap, for the caller to measure. A number column is
/// measured in tabular digits instead.
pub fn widest_text<'a>(column: &GridColumn, sample: impl IntoIterator<Item = &'a Value>) -> Option<String> {
    if column.display() == CellDisplay::Number {
        return None;
    }
    let mut scratch = String::new();
    let mut widest: Option<(u32, String)> = None;
    for value in sample.into_iter().take(SAMPLE_ROWS).filter(|value| !value.is_null()) {
        let text = within_cap(display_text(value, &column.column_type, &mut scratch).text);
        let width = cells(text);
        if widest.as_ref().is_none_or(|(most, _)| width > *most) {
            widest = Some((width, text.to_owned()));
        }
    }
    widest.map(|(_, text)| text)
}

/// The values of a type that holds nothing wider: a date or a time
/// without the fractional seconds a sample adds when the column holds
/// them, a UUID, or an enum's labels, as many as a sample holds. A MySQL
/// SET joins its labels, so it has none.
fn spelled(kind: &ColumnKind) -> Vec<&str> {
    match kind {
        ColumnKind::Date => vec!["0000-00-00"],
        ColumnKind::Time { with_offset: false, .. } => vec!["00:00:00"],
        ColumnKind::Time { with_offset: true, .. } => vec!["00:00:00+00:00"],
        ColumnKind::Timestamp {
            zone: TemporalZone::Offset,
            ..
        } => vec!["0000-00-00 00:00:00+00:00"],
        ColumnKind::Timestamp { .. } => vec!["0000-00-00 00:00:00"],
        ColumnKind::Uuid => vec!["00000000-0000-0000-0000-000000000000"],
        ColumnKind::Enum {
            labels,
            multiple: false,
        } => labels.iter().take(SAMPLE_ROWS).map(String::as_str).collect(),
        _ => Vec::new(),
    }
}

fn spelled_chars(kind: &ColumnKind) -> Option<u32> {
    spelled(kind).into_iter().map(cells).max()
}

/// The cells `text` takes in a monospace font, where a Chinese or
/// Japanese character takes two.
fn cells(text: &str) -> u32 {
    u32::try_from(text.width()).unwrap_or(u32::MAX)
}

/// The start of `text` that fits in the cap's cells.
fn within_cap(text: &str) -> &str {
    let cap = usize::try_from(TEXT_MAX_CHARS).unwrap_or(usize::MAX);
    let mut taken = 0;
    for (at, character) in text.char_indices() {
        taken += character.width().unwrap_or(0);
        if taken > cap {
            return &text[..at];
        }
    }
    text
}

#[cfg(test)]
mod tests {
    use tablepro_core::Value;
    use tablepro_core::column::{BoolStorage, ColumnKind, IntegerKind, IntegerWidth, TemporalZone, TextLength};
    use tablepro_core::value::{SqlDecimal, Temporal};

    use super::{default_width_chars, number_width_chars, typical_texts, typical_width_chars, widest_text};
    use crate::services::grid::test_columns::result_only;

    fn text() -> ColumnKind {
        ColumnKind::Text {
            length: TextLength::Unbounded,
        }
    }

    fn texts(values: &[&str]) -> Vec<Value> {
        values.iter().map(|value| Value::Text((*value).to_owned())).collect()
    }

    #[test]
    fn text_widths_take_the_widest_value_within_bounds() {
        let note = result_only("note", text());

        assert_eq!(default_width_chars(&note, &texts(&["a", "bb"])), 4, "the minimum");
        assert_eq!(default_width_chars(&note, &texts(&["a", "twelve chars"])), 12);
        assert_eq!(
            default_width_chars(&note, &texts(&["x".repeat(500).as_str()])),
            40,
            "the cap"
        );
        assert_eq!(
            default_width_chars(&result_only("a_rather_long_column_name", text()), &texts(&["a"])),
            4,
            "the header is drawn in another font"
        );
        assert_eq!(
            default_width_chars(&note, &[Value::Null, Value::Null]),
            4,
            "a NULL is a placeholder, not a value"
        );
    }

    #[test]
    fn the_widest_text_is_the_longest_value_within_the_cap() {
        let note = result_only("note", text());
        let integer = ColumnKind::Integer(IntegerKind {
            width: IntegerWidth::W64,
            signed: true,
        });

        assert_eq!(
            widest_text(
                &note,
                &[Value::Text("CF-1001".into()), Value::Null, Value::Text("a".into())]
            ),
            Some("CF-1001".to_owned())
        );
        assert_eq!(
            widest_text(&note, &texts(&["x".repeat(500).as_str()])).map(|text| text.chars().count()),
            Some(40)
        );
        assert_eq!(widest_text(&note, &[Value::Null]), None);
        assert_eq!(widest_text(&result_only("id", integer), &[Value::Int(7)]), None);
    }

    /// A Chinese or Japanese character takes two cells of a monospace font.
    #[test]
    fn a_wide_character_takes_two_cells() {
        let note = result_only("note", text());

        assert_eq!(
            widest_text(&note, &texts(&["Marunouchi 1", "東京都千代田区"])),
            Some("東京都千代田区".to_owned())
        );
        assert_eq!(default_width_chars(&note, &texts(&["東京都千代田区"])), 14);
        assert_eq!(
            widest_text(&note, &texts(&["東".repeat(500).as_str()])).map(|text| text.chars().count()),
            Some(20),
            "the cap counts cells"
        );
        assert_eq!(
            typical_texts(&result_only(
                "state",
                ColumnKind::Enum {
                    labels: vec!["東".repeat(30)],
                    multiple: false,
                }
            ))
            .iter()
            .map(|text| text.chars().count())
            .collect::<Vec<_>>(),
            [20]
        );
    }

    #[test]
    fn only_the_first_200_rows_are_sampled() {
        let note = result_only("note", text());
        let mut values = texts(&["short"; 200]);
        values.push(Value::Text("x".repeat(30)));

        assert_eq!(default_width_chars(&note, &values), 5);
    }

    #[test]
    fn a_number_is_never_cut() {
        let integer = ColumnKind::Integer(IntegerKind {
            width: IntegerWidth::W64,
            signed: true,
        });
        let wide: SqlDecimal = "1234567890123456789012345678901234567890.5".parse().expect("a decimal");
        let decimal = ColumnKind::Decimal {
            precision: None,
            scale: None,
        };

        assert_eq!(
            default_width_chars(&result_only("id", integer.clone()), &[Value::Int(7)]),
            4
        );
        assert_eq!(
            default_width_chars(&result_only("id", integer), &[Value::Int(-1_234_567_890)]),
            11
        );
        assert_eq!(
            default_width_chars(&result_only("n", decimal), &[Value::Decimal(wide)]),
            42
        );
    }

    #[test]
    fn an_untyped_column_of_numbers_is_never_cut() {
        let untyped = result_only("n", ColumnKind::Other);
        let wide = [Value::Text("9".repeat(50))];

        assert_eq!(default_width_chars(&untyped, &wide), 40, "as text it is capped");
        assert_eq!(number_width_chars(&untyped, &wide), 50);
    }

    #[test]
    fn a_bool_is_as_wide_as_false() {
        let flag = ColumnKind::Bool(BoolStorage::Native);

        assert_eq!(
            default_width_chars(&result_only("ok", flag.clone()), &[Value::Bool(true)]),
            5
        );
        assert_eq!(default_width_chars(&result_only("is_active", flag), &[]), 5);
    }

    #[test]
    fn a_temporal_column_is_as_wide_as_its_format() {
        let stamped = ColumnKind::Timestamp {
            fractional_digits: None,
            zone: TemporalZone::Offset,
        };
        let day = chrono::NaiveDate::from_ymd_opt(2026, 4, 26).expect("a date");

        assert_eq!(default_width_chars(&result_only("day", ColumnKind::Date), &[]), 10);
        assert_eq!(
            default_width_chars(
                &result_only("day", ColumnKind::Date),
                &[Value::Date(Temporal::Finite(day))]
            ),
            10
        );
        assert_eq!(default_width_chars(&result_only("at", stamped), &[]), 25);
    }

    #[test]
    fn with_no_rows_a_column_opens_at_what_its_type_leads_one_to_expect() {
        let bounded = |length| ColumnKind::Text { length };
        let integer = ColumnKind::Integer(IntegerKind {
            width: IntegerWidth::W64,
            signed: true,
        });
        let money = ColumnKind::Decimal {
            precision: Some(10),
            scale: Some(2),
        };
        let labels = vec!["active".to_owned(), "suspended".to_owned()];
        let state = ColumnKind::Enum {
            labels: labels.clone(),
            multiple: false,
        };
        let tags = ColumnKind::Enum { labels, multiple: true };
        let stamped = ColumnKind::Timestamp {
            fractional_digits: None,
            zone: TemporalZone::Offset,
        };

        assert_eq!(typical_width_chars(&result_only("realm", text())), 20, "unbounded text");
        assert_eq!(
            typical_width_chars(&result_only("code", bounded(TextLength::Varying(8)))),
            8,
            "no wider than its bound"
        );
        assert_eq!(
            typical_width_chars(&result_only("name", bounded(TextLength::Varying(255)))),
            20
        );
        assert_eq!(typical_width_chars(&result_only("id", ColumnKind::Uuid)), 36);
        assert_eq!(typical_width_chars(&result_only("id", integer)), 10);
        assert_eq!(typical_width_chars(&result_only("total", money)), 12);
        assert_eq!(
            typical_width_chars(&result_only("state", state)),
            9,
            "its longest label"
        );
        assert_eq!(
            typical_width_chars(&result_only("tags", tags)),
            20,
            "a SET joins its labels"
        );
        assert_eq!(typical_width_chars(&result_only("created", stamped)), 25);
        assert_eq!(
            typical_width_chars(&result_only("ok", ColumnKind::Bool(BoolStorage::Native))),
            5
        );
        assert_eq!(
            typical_width_chars(&result_only("a_column_with_a_name_far_longer_than_it_holds", text())),
            20,
            "the header is drawn in another font"
        );
    }

    #[test]
    fn the_typical_texts_are_the_values_a_type_spells_out() {
        let state = ColumnKind::Enum {
            labels: vec!["active".to_owned(), "suspended".to_owned()],
            multiple: false,
        };

        assert_eq!(typical_texts(&result_only("on", ColumnKind::Date)), ["0000-00-00"]);
        assert_eq!(
            typical_texts(&result_only("id", ColumnKind::Uuid))
                .iter()
                .map(|text| text.chars().count())
                .collect::<Vec<_>>(),
            [36]
        );
        assert_eq!(
            typical_texts(&result_only("state", state)),
            ["active", "suspended"],
            "every label, since the longest is not always the widest"
        );
        assert!(
            typical_texts(&result_only("name", text())).is_empty(),
            "text has no widest"
        );
    }
}
