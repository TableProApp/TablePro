use tablepro_core::Value;
use tablepro_core::column::{ColumnKind, TemporalZone, TextLength};

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

/// A column's starting width in characters: its header or its widest
/// sampled value. Text is capped so one long value does not push the rest
/// off screen; a number or a date is never cut.
pub fn default_width_chars<'a>(column: &GridColumn, sample: impl IntoIterator<Item = &'a Value>) -> u32 {
    let (header, widest) = header_and_widest(column, sample);
    match column.display() {
        CellDisplay::Bool => header.max(BOOL_CHARS),
        CellDisplay::Number => header.max(widest),
        CellDisplay::Temporal => header
            .max(widest)
            .max(spelled_chars(&column.column_type.kind).unwrap_or(0)),
        CellDisplay::Text | CellDisplay::Json | CellDisplay::Binary => header.max(widest).min(TEXT_MAX_CHARS),
    }
}

/// A column's starting width in characters in a table that holds no
/// rows: its header or a value its type leads one to expect. A bounded
/// type gives its widest value, text no wider than a name.
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
    header_chars(column).max(typical).min(TEXT_MAX_CHARS)
}

/// The values the column's type spells out, cut at the cap, for the
/// caller to measure in tabular figures: a count of average characters
/// runs short of digits and capitals.
pub fn typical_texts(column: &GridColumn) -> Vec<String> {
    let cap = usize::try_from(TEXT_MAX_CHARS).unwrap_or(usize::MAX);
    spelled(&column.column_type.kind)
        .into_iter()
        .map(|text| text.chars().take(cap).collect())
        .collect()
}

/// The width of a column that turned out to hold only numbers, as an
/// untyped PostgreSQL result does: a number is never cut.
pub fn number_width_chars<'a>(column: &GridColumn, sample: impl IntoIterator<Item = &'a Value>) -> u32 {
    let (header, widest) = header_and_widest(column, sample);
    header.max(widest)
}

fn header_chars(column: &GridColumn) -> u32 {
    char_count(&column.name).clamp(MIN_CHARS, TEXT_MAX_CHARS)
}

fn header_and_widest<'a>(column: &GridColumn, sample: impl IntoIterator<Item = &'a Value>) -> (u32, u32) {
    let mut scratch = String::new();
    let widest = sample
        .into_iter()
        .take(SAMPLE_ROWS)
        .filter(|value| !value.is_null())
        .map(|value| char_count(display_text(value, &column.column_type, &mut scratch).text))
        .max()
        .unwrap_or(0);
    (header_chars(column), widest)
}

/// The sampled value with the most characters, as the cell draws it and
/// cut at the cap: a count of average characters runs short of capitals
/// and digits, so the caller measures this one. A number column is
/// measured in tabular digits instead.
pub fn widest_text<'a>(column: &GridColumn, sample: impl IntoIterator<Item = &'a Value>) -> Option<String> {
    if column.display() == CellDisplay::Number {
        return None;
    }
    let cap = usize::try_from(TEXT_MAX_CHARS).unwrap_or(usize::MAX);
    let mut scratch = String::new();
    sample
        .into_iter()
        .take(SAMPLE_ROWS)
        .filter(|value| !value.is_null())
        .map(|value| {
            display_text(value, &column.column_type, &mut scratch)
                .text
                .chars()
                .take(cap)
                .collect::<String>()
        })
        .max_by_key(|text| char_count(text))
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
    spelled(kind).into_iter().map(char_count).max()
}

fn char_count(text: &str) -> u32 {
    u32::try_from(text.chars().count()).unwrap_or(u32::MAX)
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
    fn text_widths_take_the_header_or_the_widest_value_within_bounds() {
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
            25
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
        assert_eq!(default_width_chars(&result_only("is_active", flag), &[]), 9);
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
            40,
            "the header, within the cap"
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
