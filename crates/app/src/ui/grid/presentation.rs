use tablepro_core::{ColumnInfo, Value};

use super::display::value_is_inline_editable;
use super::types::{is_bool_type, is_bytes_type};

pub(super) fn column_is_editable(column: &ColumnInfo) -> bool {
    !column.primary_key
        && !column.is_generated
        && !column.is_auto_increment
        && !is_bytes_type(&column.data_type)
        && !column.data_type.eq_ignore_ascii_case("mixed")
}

/// Declared affinity is not a guarantee about a row's runtime value.
/// A checkbox must never turn an unrepresentable value into a boolean.
pub(crate) fn cell_allows_inline_edit(column: &ColumnInfo, value: &Value) -> bool {
    column_is_editable(column)
        && value_is_inline_editable(value)
        && (!is_bool_type(&column.data_type)
            || matches!(value, Value::Bool(_) | Value::Null)
            || (column.data_type.eq_ignore_ascii_case("bit(1)") && matches!(value, Value::Int(0 | 1))))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn runtime_values_and_column_ownership_both_gate_edits() {
        let mut column = ColumnInfo {
            name: "value".into(),
            data_type: "BOOLEAN".into(),
            nullable: true,
            primary_key: false,
            is_auto_increment: false,
            is_generated: false,
            comment: None,
            default_value: None,
            collation: None,
            enum_type: None,
            domain_type: None,
        };
        for value in [Value::Bytes(vec![1]), Value::Text("true".into()), Value::Int(2)] {
            assert!(!cell_allows_inline_edit(&column, &value));
        }
        for value in [Value::Null, Value::Bool(false), Value::Bool(true)] {
            assert!(cell_allows_inline_edit(&column, &value));
        }
        column.primary_key = true;
        assert!(!cell_allows_inline_edit(&column, &Value::Bool(true)));
    }

    #[test]
    fn an_undecodable_value_is_never_inline_editable() {
        let column = ColumnInfo {
            name: "amount".into(),
            data_type: "NUMERIC".into(),
            nullable: true,
            primary_key: false,
            is_auto_increment: false,
            is_generated: false,
            comment: None,
            default_value: None,
            collation: None,
            enum_type: None,
            domain_type: None,
        };
        assert!(cell_allows_inline_edit(&column, &Value::Null));
        assert!(!cell_allows_inline_edit(&column, &Value::Undecodable("NUMERIC".into())));
    }

    #[test]
    fn mixed_bson_columns_are_read_only() {
        let column = ColumnInfo {
            name: "value".into(),
            data_type: "mixed".into(),
            nullable: true,
            primary_key: false,
            is_auto_increment: false,
            is_generated: false,
            comment: None,
            default_value: None,
            collation: None,
            enum_type: None,
            domain_type: None,
        };
        assert!(!cell_allows_inline_edit(&column, &Value::Text("same text".into())));
        assert!(!column_is_editable(&column));
    }

    #[test]
    fn ordinary_text_columns_remain_editable() {
        let column = ColumnInfo {
            name: "note".into(),
            data_type: "VARCHAR".into(),
            nullable: true,
            primary_key: false,
            is_auto_increment: false,
            is_generated: false,
            comment: None,
            default_value: None,
            collation: None,
            enum_type: None,
            domain_type: None,
        };
        assert!(column_is_editable(&column));
        assert!(cell_allows_inline_edit(&column, &Value::Text("editable".into())));
    }

    #[test]
    fn mysql_bit_and_spatial_cells_follow_their_decoded_value_contract() {
        let bit1 = ColumnInfo {
            name: "tiny_bits".into(),
            data_type: "bit(1)".into(),
            nullable: true,
            primary_key: false,
            is_auto_increment: false,
            is_generated: false,
            comment: None,
            default_value: None,
            collation: None,
            enum_type: None,
            domain_type: None,
        };
        assert!(cell_allows_inline_edit(&bit1, &Value::Int(0)));
        assert!(cell_allows_inline_edit(&bit1, &Value::Int(1)));
        assert!(!cell_allows_inline_edit(&bit1, &Value::Int(2)));

        let bit8 = ColumnInfo {
            data_type: "bit(8)".into(),
            ..bit1.clone()
        };
        assert!(cell_allows_inline_edit(&bit8, &Value::Int(170)));

        for data_type in ["geometry", "point", "multipolygon"] {
            let spatial = ColumnInfo {
                data_type: data_type.into(),
                ..bit1.clone()
            };
            assert!(!column_is_editable(&spatial), "{data_type}");
            assert!(!cell_allows_inline_edit(&spatial, &Value::Bytes(vec![1, 2, 3])));
        }
        let too_wide = Value::Bytes(vec![0x80, 0, 0, 0, 0, 0, 0, 0]);
        assert!(!cell_allows_inline_edit(&bit8, &too_wide));
    }

    #[test]
    fn the_editability_gate_agrees_with_the_display_gate_on_every_runtime_value() {
        let column = ColumnInfo {
            name: "payload".into(),
            data_type: "TEXT".into(),
            nullable: true,
            primary_key: false,
            is_auto_increment: false,
            is_generated: false,
            comment: None,
            default_value: None,
            collation: None,
            enum_type: None,
            domain_type: None,
        };
        for value in [
            Value::Null,
            Value::Int(1),
            Value::Text("a".into()),
            Value::Bytes(vec![1]),
            Value::Undecodable("INTERVAL".into()),
        ] {
            assert_eq!(
                cell_allows_inline_edit(&column, &value),
                value_is_inline_editable(&value)
            );
        }
    }
}
