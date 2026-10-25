use tablepro_core::edit::{EditText, edit_text};
use tablepro_core::{FilterOp, FilterRule, FilterValue, Value};

use super::{CellDisplay, GridColumn};

/// The rule for Filter by Value, or Exclude Value with `exclude`. The
/// value is written as a user would type it, so the rule reads back in
/// the filter strip. `None` where no rule could name the value.
pub fn cell_filter_rule(column: &GridColumn, value: &Value, exclude: bool) -> Option<FilterRule> {
    if !column.addressable {
        return None;
    }
    let (op, value) = match value {
        Value::Null => (if exclude { FilterOp::IsNotNull } else { FilterOp::IsNull }, None),
        _ if matches!(column.display(), CellDisplay::Binary | CellDisplay::Json) => return None,
        value => match edit_text(value, column.value_type()) {
            EditText::Editable(text) => (
                if exclude { FilterOp::NotEq } else { FilterOp::Eq },
                Some(FilterValue::Single(text)),
            ),
            EditText::ReadOnly(_) => return None,
        },
    };
    Some(FilterRule {
        column: column.name.clone(),
        op,
        value,
    })
}

#[cfg(test)]
mod tests {
    use tablepro_core::column::{ColumnKind, IntegerKind, IntegerWidth, TextLength};
    use tablepro_core::value::{JsonText, UndecodableReason, UndecodedValue};
    use tablepro_core::{FilterOp, FilterRule, FilterValue, Value};

    use super::cell_filter_rule;
    use crate::services::grid::GridColumn;
    use crate::services::grid::test_columns::{grid_of_kind, result_only};

    fn integer() -> ColumnKind {
        ColumnKind::Integer(IntegerKind {
            width: IntegerWidth::W32,
            signed: true,
        })
    }

    fn rule(column: &str, op: FilterOp, value: Option<&str>) -> Option<FilterRule> {
        Some(FilterRule {
            column: column.to_owned(),
            op,
            value: value.map(|text| FilterValue::Single(text.to_owned())),
        })
    }

    #[test]
    fn a_value_filters_by_its_typed_text() {
        let age = grid_of_kind("age", integer());
        let name = result_only(
            "name",
            ColumnKind::Text {
                length: TextLength::Unbounded,
            },
        );

        assert_eq!(
            cell_filter_rule(&age, &Value::Int(42), false),
            rule("age", FilterOp::Eq, Some("42"))
        );
        assert_eq!(
            cell_filter_rule(&age, &Value::Int(42), true),
            rule("age", FilterOp::NotEq, Some("42"))
        );
        assert_eq!(
            cell_filter_rule(&name, &Value::Text("Ada".into()), false),
            rule("name", FilterOp::Eq, Some("Ada"))
        );
    }

    #[test]
    fn null_filters_with_a_null_test() {
        let age = grid_of_kind("age", integer());
        let doc = grid_of_kind("doc", ColumnKind::Json { binary: true });

        assert_eq!(
            cell_filter_rule(&age, &Value::Null, false),
            rule("age", FilterOp::IsNull, None)
        );
        assert_eq!(
            cell_filter_rule(&age, &Value::Null, true),
            rule("age", FilterOp::IsNotNull, None)
        );
        assert_eq!(
            cell_filter_rule(&doc, &Value::Null, false),
            rule("doc", FilterOp::IsNull, None),
            "a document column can still test for NULL"
        );
    }

    #[test]
    fn binary_json_unreadable_and_unaddressable_values_give_no_rule() {
        let blob = grid_of_kind(
            "data",
            ColumnKind::Bytes {
                length: TextLength::Unbounded,
            },
        );
        let doc = grid_of_kind("doc", ColumnKind::Json { binary: true });
        let json = Value::Json(JsonText::parse("{\"a\":1}".to_owned()).expect("valid json"));
        let unreadable = Value::Undecodable(Box::new(UndecodedValue {
            type_name: "geography".to_owned(),
            reason: UndecodableReason::UnsupportedType,
        }));
        let dotted = GridColumn {
            addressable: false,
            ..grid_of_kind("a.b", integer())
        };

        assert_eq!(cell_filter_rule(&blob, &Value::Bytes(vec![1, 2]), false), None);
        assert_eq!(cell_filter_rule(&doc, &json, false), None);
        assert_eq!(
            cell_filter_rule(&grid_of_kind("g", ColumnKind::Other), &unreadable, false),
            None
        );
        assert_eq!(
            cell_filter_rule(&grid_of_kind("t", ColumnKind::Other), &Value::Bytes(vec![0]), false),
            None,
            "a blob in a column that types per row"
        );
        assert_eq!(cell_filter_rule(&dotted, &Value::Int(1), false), None);
        assert_eq!(cell_filter_rule(&dotted, &Value::Null, false), None);
    }

    #[test]
    fn a_value_with_no_text_form_gives_only_a_null_rule() {
        let shape = grid_of_kind("shape", ColumnKind::Spatial);

        assert_eq!(cell_filter_rule(&shape, &Value::Text("POINT(1 2)".into()), false), None);
        assert_eq!(
            cell_filter_rule(&shape, &Value::Null, false),
            rule("shape", FilterOp::IsNull, None)
        );
    }
}
