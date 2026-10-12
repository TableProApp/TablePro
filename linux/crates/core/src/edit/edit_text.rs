use crate::column::{ColumnKind, ColumnType};
use crate::export::value_text;
use crate::value::Value;

use super::ReadOnlyReason;

/// What a cell editor starts from.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum EditText {
    Editable(String),
    ReadOnly(ReadOnlyReason),
}

/// The full text of a value, for filling an editor.
///
/// Never the grid's display text: that is truncated and shortened, and
/// committing it would write the shortened form back. A value with no
/// text form the parser could read back is read-only.
pub fn edit_text(value: &Value, column: &ColumnType) -> EditText {
    if let Some(reason) = read_only_kind(&column.kind) {
        return EditText::ReadOnly(reason);
    }
    match value {
        Value::Null => EditText::Editable(String::new()),
        Value::Undecodable(_) => EditText::ReadOnly(ReadOnlyReason::Undecodable),
        // A dynamically typed column can hold a blob whatever it
        // declares.
        Value::Bytes(_) => EditText::ReadOnly(ReadOnlyReason::Bytes),
        other => match value_text(other, column) {
            Some(text) => EditText::Editable(text),
            None => EditText::ReadOnly(ReadOnlyReason::Undecodable),
        },
    }
}

/// The kinds whose values have no text the parser takes back. Matches
/// what `parse_literal_text` refuses, so a cell that opens can commit.
fn read_only_kind(kind: &ColumnKind) -> Option<ReadOnlyReason> {
    match kind {
        ColumnKind::Bytes { .. } => Some(ReadOnlyReason::Bytes),
        ColumnKind::Spatial => Some(ReadOnlyReason::Spatial),
        ColumnKind::Variant => Some(ReadOnlyReason::Variant),
        ColumnKind::Array { .. } | ColumnKind::Composite => Some(ReadOnlyReason::Composite),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use crate::column::{FloatWidth, ReadForm, TemporalZone, TextLength};
    use crate::value::{Temporal, UndecodableReason, UndecodedValue};

    use super::*;

    fn column(kind: ColumnKind) -> ColumnType {
        ColumnType {
            name: "t".to_owned(),
            kind,
            catalog: None,
            dynamic_storage: false,
            read_form: ReadForm::Native,
        }
    }

    #[test]
    fn edit_text_is_never_truncated() {
        let long = "x".repeat(20_000);
        let text = column(ColumnKind::Text {
            length: TextLength::Unbounded,
        });

        assert_eq!(edit_text(&Value::Text(long.clone()), &text), EditText::Editable(long));
    }

    #[test]
    fn a_timestamp_keeps_its_declared_fraction() {
        let stamp = column(ColumnKind::Timestamp {
            fractional_digits: Some(6),
            zone: TemporalZone::Naive,
        });
        let value = Value::Timestamp(Temporal::Finite(
            chrono::NaiveDate::from_ymd_opt(2024, 6, 15)
                .and_then(|date| date.and_hms_micro_opt(12, 0, 0, 100_000))
                .expect("a timestamp"),
        ));

        assert_eq!(
            edit_text(&value, &stamp),
            EditText::Editable("2024-06-15 12:00:00.100000".to_owned())
        );
    }

    #[test]
    fn a_float_round_trips_in_its_shortest_form() {
        let float = column(ColumnKind::Float(FloatWidth::F64));

        assert_eq!(
            edit_text(&Value::Float64(0.1), &float),
            EditText::Editable("0.1".to_owned())
        );
    }

    #[test]
    fn values_without_a_text_form_are_read_only() {
        let text = column(ColumnKind::Text {
            length: TextLength::Unbounded,
        });
        let undecodable = Value::Undecodable(Box::new(UndecodedValue {
            type_name: "geography".to_owned(),
            reason: UndecodableReason::UnsupportedType,
        }));

        assert_eq!(
            edit_text(&undecodable, &text),
            EditText::ReadOnly(ReadOnlyReason::Undecodable)
        );
        assert_eq!(
            edit_text(&Value::Bytes(vec![1]), &text),
            EditText::ReadOnly(ReadOnlyReason::Bytes)
        );
        assert_eq!(
            edit_text(&Value::Null, &column(ColumnKind::Spatial)),
            EditText::ReadOnly(ReadOnlyReason::Spatial)
        );
        assert_eq!(edit_text(&Value::Null, &text), EditText::Editable(String::new()));
    }
}
