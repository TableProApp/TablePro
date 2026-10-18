use crate::column::ColumnInfo;
use crate::value::Value;

use super::{CellInput, EditContext, EditParseError, EmptyInputMeaning, empty_input_meaning, parse_literal_text};

/// Turn what the user typed into a cell into the input to save.
///
/// Empty input follows `empty_input_meaning`. Whitespace alone is empty
/// for a column that cannot hold the empty string, and a value for one
/// that can.
pub fn parse_edit_text(input: &str, column: &ColumnInfo, context: EditContext) -> Result<CellInput, EditParseError> {
    let accepts_empty = column.column_type.kind.accepts_empty_string();
    let empty = input.is_empty() || (!accepts_empty && input.trim().is_empty());
    if !empty {
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
        ColumnDefault, ColumnKind, ColumnType, IntegerKind, IntegerWidth, ReadForm, SqlExpression, TextLength,
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
                parse_edit_text("", &text, context),
                Ok(CellInput::Value(Value::Text(String::new())))
            );
        }
        assert_eq!(
            parse_edit_text("  ", &text, EditContext::UpdateRow),
            Ok(CellInput::Value(Value::Text("  ".to_owned()))),
            "spaces in a text column were thrown away"
        );
    }

    #[test]
    fn an_empty_draft_cell_asks_for_the_servers_default() {
        let mut defaulted = integer(false);
        defaulted.default = ColumnDefault::Expression(SqlExpression::from_catalog_text("0"));
        let mut serial = integer(false);
        serial.is_auto_increment = true;

        assert_eq!(
            parse_edit_text("", &defaulted, EditContext::InsertDraft),
            Ok(CellInput::Default)
        );
        assert_eq!(
            parse_edit_text(" ", &serial, EditContext::InsertDraft),
            Ok(CellInput::Default)
        );
        assert_eq!(
            parse_edit_text("", &integer(true), EditContext::InsertDraft),
            Ok(CellInput::Value(Value::Null))
        );
        assert_eq!(
            parse_edit_text("", &integer(false), EditContext::InsertDraft),
            Err(EditParseError::Required)
        );
    }

    #[test]
    fn an_existing_row_never_gets_a_default_from_an_empty_cell() {
        let mut defaulted = integer(false);
        defaulted.default = ColumnDefault::Expression(SqlExpression::from_catalog_text("0"));

        assert_eq!(
            parse_edit_text("", &defaulted, EditContext::UpdateRow),
            Err(EditParseError::Required),
            "an UPDATE writing NULL into a NOT NULL column"
        );
        assert_eq!(
            parse_edit_text("", &integer(true), EditContext::UpdateRow),
            Ok(CellInput::Value(Value::Null))
        );
    }

    #[test]
    fn typed_text_parses_as_the_columns_type() {
        assert_eq!(
            parse_edit_text("42", &integer(false), EditContext::UpdateRow),
            Ok(CellInput::Value(Value::Int(42)))
        );
        assert_eq!(
            parse_edit_text("4x", &integer(false), EditContext::UpdateRow),
            Err(EditParseError::InvalidInteger)
        );
    }
}
