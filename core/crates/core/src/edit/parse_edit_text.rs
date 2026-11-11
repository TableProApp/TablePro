use crate::column::ColumnInfo;
use crate::value::Value;

use super::parse_literal_text::parse_as_read;
use super::{CellInput, EditContext, EditParseError, EmptyInputMeaning, empty_input_meaning, parse_literal_text};

pub fn parse_edit_text(
    input: &str,
    column: &ColumnInfo,
    context: EditContext,
    read: Option<&Value>,
) -> Result<CellInput, EditParseError> {
    let accepts_empty = column.column_type.kind.accepts_empty_string();
    let empty = input.is_empty() || (!accepts_empty && input.trim().is_empty());
    if !empty {
        if let Some(value) = read.and_then(|read| parse_as_read(input, read, &column.column_type)) {
            return Ok(CellInput::Value(value));
        }
        return parse_literal_text(input, &column.column_type).map(CellInput::Value);
    }
    match empty_input_meaning(column, context) {
        EmptyInputMeaning::EmptyText => Ok(CellInput::Value(Value::Text(String::new()))),
        EmptyInputMeaning::Default => Ok(CellInput::Default),
        EmptyInputMeaning::Null => Ok(CellInput::Value(Value::Null)),
        EmptyInputMeaning::Required => Err(EditParseError::Required),
    }
}

#[cfg(test)]
mod tests {
    use crate::column::{
        ColumnDefault, ColumnKind, ColumnType, FloatWidth, IntegerKind, IntegerWidth, ReadForm, SqlExpression,
        TextLength,
    };

    use super::*;

    fn column(kind: ColumnKind, nullable: bool) -> ColumnInfo {
        ColumnInfo {
            name: "c".to_owned(),
            column_type: ColumnType {
                name: "t".to_owned(),
                kind,
                catalog: None,
                dynamic_storage: false,
                read_form: ReadForm::Native,
            },
            nullable,
            primary_key: false,
            is_auto_increment: false,
            is_generated: false,
            partition_scoped: false,
            default: ColumnDefault::None,
            comment: None,
        }
    }

    fn integer(nullable: bool) -> ColumnInfo {
        column(
            ColumnKind::Integer(IntegerKind {
                width: IntegerWidth::W32,
                signed: true,
            }),
            nullable,
        )
    }

    #[test]
    fn empty_text_is_a_value_where_the_column_can_hold_it() {
        let text = column(
            ColumnKind::Text {
                length: TextLength::Unbounded,
            },
            false,
        );

        for context in [EditContext::InsertDraft, EditContext::UpdateRow] {
            assert_eq!(
                parse_edit_text("", &text, context, None),
                Ok(CellInput::Value(Value::Text(String::new())))
            );
        }
        assert_eq!(
            parse_edit_text("  ", &text, EditContext::UpdateRow, None),
            Ok(CellInput::Value(Value::Text("  ".to_owned()))),
            "spaces in a text column were thrown away"
        );
    }

    #[test]
    fn an_empty_set_is_a_value_and_an_empty_enum_is_not() {
        let set = column(
            ColumnKind::Enum {
                labels: vec!["a".to_owned(), "b".to_owned()],
                multiple: true,
            },
            true,
        );
        let enumeration = column(
            ColumnKind::Enum {
                labels: vec!["a".to_owned(), "b".to_owned()],
                multiple: false,
            },
            true,
        );

        assert_eq!(
            parse_edit_text("", &set, EditContext::UpdateRow, None),
            Ok(CellInput::Value(Value::Text(String::new()))),
            "clearing a set wrote NULL instead of the empty set"
        );
        assert_eq!(
            parse_edit_text("", &enumeration, EditContext::UpdateRow, None),
            Ok(CellInput::Value(Value::Null))
        );
    }

    #[test]
    fn an_empty_draft_cell_asks_for_the_servers_default() {
        let mut defaulted = integer(false);
        defaulted.default = ColumnDefault::Expression(SqlExpression::from_catalog_text("0"));
        let mut serial = integer(false);
        serial.is_auto_increment = true;

        assert_eq!(
            parse_edit_text("", &defaulted, EditContext::InsertDraft, None),
            Ok(CellInput::Default)
        );
        assert_eq!(
            parse_edit_text(" ", &serial, EditContext::InsertDraft, None),
            Ok(CellInput::Default)
        );
        assert_eq!(
            parse_edit_text("", &integer(true), EditContext::InsertDraft, None),
            Ok(CellInput::Value(Value::Null))
        );
        assert_eq!(
            parse_edit_text("", &integer(false), EditContext::InsertDraft, None),
            Err(EditParseError::Required)
        );
    }

    #[test]
    fn an_existing_row_never_gets_a_default_from_an_empty_cell() {
        let mut defaulted = integer(false);
        defaulted.default = ColumnDefault::Expression(SqlExpression::from_catalog_text("0"));

        assert_eq!(
            parse_edit_text("", &defaulted, EditContext::UpdateRow, None),
            Err(EditParseError::Required),
            "an UPDATE writing NULL into a NOT NULL column"
        );
        assert_eq!(
            parse_edit_text("", &integer(true), EditContext::UpdateRow, None),
            Ok(CellInput::Value(Value::Null))
        );
    }

    #[test]
    fn typed_text_parses_as_the_columns_type() {
        assert_eq!(
            parse_edit_text("42", &integer(false), EditContext::UpdateRow, None),
            Ok(CellInput::Value(Value::Int(42)))
        );
        assert_eq!(
            parse_edit_text("4x", &integer(false), EditContext::UpdateRow, None),
            Err(EditParseError::InvalidInteger)
        );
    }

    fn edited(input: &str, column: &ColumnInfo, read: Value) -> Result<CellInput, EditParseError> {
        parse_edit_text(input, column, EditContext::UpdateRow, Some(&read))
    }

    fn decimal(text: &str) -> Value {
        Value::Decimal(text.parse().expect("a decimal"))
    }

    #[test]
    fn a_number_a_sampled_column_does_not_type_parses_as_the_number_it_is() {
        let double = column(ColumnKind::Float(FloatWidth::F64), true);
        let decimal_column = column(
            ColumnKind::Decimal {
                precision: Some(34),
                scale: None,
            },
            true,
        );

        assert_eq!(
            edited("4", &double, Value::Int32(3)),
            Ok(CellInput::Value(Value::Int32(4)))
        );
        assert_eq!(
            edited("4.5", &double, Value::Int32(3)),
            Ok(CellInput::Value(Value::Float64(4.5)))
        );
        assert_eq!(
            edited("9007199254740995", &double, Value::Int(9_007_199_254_740_993)),
            Ok(CellInput::Value(Value::Int(9_007_199_254_740_995))),
            "a long in a double field lost its digits"
        );
        assert_eq!(
            edited("0.1", &decimal_column, Value::Float64(2.5)),
            Ok(CellInput::Value(Value::Float64(0.1)))
        );
        assert_eq!(
            edited("9007199254740993", &decimal_column, Value::Float64(2.5)),
            Ok(CellInput::Value(decimal("9007199254740993"))),
            "a number no double holds was rounded to one"
        );
    }

    #[test]
    fn a_long_past_the_sample_of_an_int_field_is_not_refused() {
        assert_eq!(
            edited("5000000001", &integer(true), Value::Int(5_000_000_000)),
            Ok(CellInput::Value(Value::Int(5_000_000_001)))
        );
        assert_eq!(
            edited("5000000001", &integer(true), Value::Int(1)),
            Err(EditParseError::IntegerOutOfRange {
                kind: IntegerKind {
                    width: IntegerWidth::W32,
                    signed: true,
                },
            }),
            "a value the column holds lifted the column's range"
        );
        assert_eq!(
            edited("5000000001", &integer(true), Value::Null),
            parse_edit_text("5000000001", &integer(true), EditContext::UpdateRow, None)
        );
    }
}
