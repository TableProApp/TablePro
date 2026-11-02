use crate::column::ColumnType;
use crate::export::value_text;
use crate::value::{Value, same_value};

/// Whether an edit leaves the cell as it was, so it is not saved.
///
/// A dynamically typed column also compares the text forms: SQLite
/// hands back `1` for a cell the user retyped as `1`, and the parse of
/// that text may land in another variant without being a change.
pub fn is_unchanged(original: &Value, edited: &Value, column: &ColumnType) -> bool {
    if same_value(original, edited) {
        return true;
    }
    column.dynamic_storage
        && matches!(
            (value_text(original, column), value_text(edited, column)),
            (Some(original), Some(edited)) if original == edited
        )
}

#[cfg(test)]
mod tests {
    use crate::column::{ColumnKind, ReadForm, TextLength};

    use super::*;

    fn column(dynamic_storage: bool) -> ColumnType {
        ColumnType {
            name: "t".to_owned(),
            kind: ColumnKind::Text {
                length: TextLength::Unbounded,
            },
            catalog: None,
            dynamic_storage,
            read_form: ReadForm::Native,
        }
    }

    #[test]
    fn the_same_value_is_unchanged() {
        assert!(is_unchanged(&Value::Int(1), &Value::Int(1), &column(false)));
        assert!(is_unchanged(
            &Value::Float64(f64::NAN),
            &Value::Float64(f64::NAN),
            &column(false)
        ));
        assert!(!is_unchanged(&Value::Int(1), &Value::Int(2), &column(false)));
    }

    #[test]
    fn a_dynamic_column_compares_text_forms() {
        let typed = Value::Int(1);
        let retyped = Value::Text("1".to_owned());

        assert!(is_unchanged(&typed, &retyped, &column(true)));
        assert!(
            !is_unchanged(&typed, &retyped, &column(false)),
            "a declared column ignored the type"
        );
    }

    #[test]
    fn null_is_not_the_empty_string() {
        assert!(!is_unchanged(&Value::Null, &Value::Text(String::new()), &column(true)));
    }
}
