use tablepro_core::edit::{
    CellInput, EditContext, EditText, EmptyInputMeaning, edit_text, empty_input_meaning, is_unchanged, parse_edit_text,
};
use tablepro_core::{ColumnInfo, Value};

use super::{EditSnapshot, GridCell, GridMsg, GridRowId};
use crate::services::tracker_edit::TrackerEdit;
use crate::ui::error_text::edit_parse_message;

/// What committing an editor's text comes to.
#[derive(Debug, Clone, PartialEq)]
pub enum CommitResult {
    Edit(TrackerEdit),
    Unchanged,
    /// The text is not a value of the column, with what to tell the user.
    Rejected(String),
}

/// Only a new row can leave a column to the server.
pub fn edit_context(row: &GridRowId) -> EditContext {
    match row {
        GridRowId::Draft(_) => EditContext::InsertDraft,
        GridRowId::Result | GridRowId::Unkeyed | GridRowId::Persisted(_) => EditContext::UpdateRow,
    }
}

/// The text an editor ends with, as an edit of the row it began on.
/// Every editor commits through here, and none reads the cell's display.
///
/// Text left as the editor opened it is no edit: NULL and the empty
/// string open as the same empty field, and committing it untouched must
/// not turn one into the other.
pub fn commit_edit(column: &ColumnInfo, snapshot: &EditSnapshot, input: &str) -> CommitResult {
    let opened_with = match &snapshot.original {
        CellInput::Value(value) => edit_text(value, &column.column_type),
        CellInput::Default => EditText::Editable(String::new()),
    };
    if matches!(&opened_with, EditText::Editable(text) if text == input) {
        return CommitResult::Unchanged;
    }
    match parse_edit_text(input, column, edit_context(snapshot.row.id())) {
        Ok(parsed) => commit_input(column, snapshot, parsed),
        Err(error) => {
            tracing::debug!(%error, column = %column.name, "refused an edit");
            CommitResult::Rejected(edit_parse_message(&error))
        }
    }
}

/// `input` as an edit of the row the snapshot names, or no edit when it
/// leaves the cell as it was.
pub fn commit_input(column: &ColumnInfo, snapshot: &EditSnapshot, input: CellInput) -> CommitResult {
    let unchanged = match (&snapshot.original, &input) {
        (CellInput::Value(original), CellInput::Value(value)) => is_unchanged(original, value, &column.column_type),
        (CellInput::Default, CellInput::Default) => true,
        _ => false,
    };
    if unchanged {
        return CommitResult::Unchanged;
    }
    match (snapshot.row.id(), input) {
        (GridRowId::Draft(draft_id), input) => CommitResult::Edit(TrackerEdit::DraftCell {
            draft_id: *draft_id,
            col: snapshot.column,
            input,
        }),
        (GridRowId::Persisted(row_key), CellInput::Value(value)) => CommitResult::Edit(TrackerEdit::Cell {
            row_key: row_key.clone(),
            col: snapshot.column,
            original: snapshot.row.cell(snapshot.column).cloned().unwrap_or(Value::Null),
            value,
        }),
        (GridRowId::Persisted(_), CellInput::Default) => {
            tracing::error!("a saved row's cell was given the server's default");
            CommitResult::Unchanged
        }
        (GridRowId::Result | GridRowId::Unkeyed, _) => CommitResult::Unchanged,
    }
}

/// Hand the outcome to the tab. A refused value is said in a toast and
/// the cell draws its value again.
pub(super) fn send_commit(cell: &GridCell, snapshot: EditSnapshot, result: CommitResult) {
    let Some(sink) = cell.sink() else {
        return;
    };
    match result {
        CommitResult::Edit(edit) => sink(GridMsg::Edit {
            row: snapshot.row,
            column: snapshot.column,
            edit,
        }),
        CommitResult::Unchanged => {}
        CommitResult::Rejected(message) => {
            sink(GridMsg::ShowToast(message));
            cell.render();
        }
    }
}

/// What an empty editor commits, said where the text would be. The
/// keywords are SQL and stay untranslated.
pub fn empty_placeholder(column: &ColumnInfo, row: &GridRowId) -> Option<String> {
    match empty_input_meaning(column, edit_context(row)) {
        EmptyInputMeaning::EmptyText => None,
        EmptyInputMeaning::Default => Some("DEFAULT".to_owned()),
        EmptyInputMeaning::Null => Some("NULL".to_owned()),
        EmptyInputMeaning::Required => Some(crate::i18n::gettext("Required")),
    }
}

#[cfg(test)]
mod tests {
    use tablepro_core::column::{ColumnDefault, ColumnType};
    use tablepro_core::edit::CellInput;
    use tablepro_core::{ColumnInfo, Value};

    use super::{CommitResult, commit_edit, empty_placeholder};
    use crate::services::change_tracker::RowKey;
    use crate::services::tracker_edit::TrackerEdit;
    use crate::ui::grid::{EditSnapshot, GridRowId, RowObject};

    #[expect(
        clippy::disallowed_methods,
        reason = "a test fixture stands in for the catalogue, which is where this text comes from in production"
    )]
    fn column(data_type: &str, nullable: bool, default: Option<&str>) -> ColumnInfo {
        let kind = tablepro_core::column::classify_type_name(data_type);
        ColumnInfo {
            name: "c".to_owned(),
            column_type: ColumnType {
                kind,
                ..ColumnType::untyped_text(data_type)
            },
            nullable,
            primary_key: false,
            is_auto_increment: false,
            is_generated: false,
            default: match default {
                Some(text) => ColumnDefault::Expression(tablepro_core::column::SqlExpression::from_catalog_text(text)),
                None => ColumnDefault::None,
            },
            comment: None,
        }
    }

    fn saved(value: Value) -> EditSnapshot {
        let key = RowKey::from_pk_values(&[Value::Int(1)]).expect("a key");
        EditSnapshot {
            row: RowObject::persisted(Some(key), vec![Value::Int(1), value.clone()].into()),
            column: 1,
            original: CellInput::Value(value),
        }
    }

    fn draft(original: CellInput) -> EditSnapshot {
        EditSnapshot {
            row: RowObject::draft(3),
            column: 1,
            original,
        }
    }

    fn value_of(result: CommitResult) -> Option<CellInput> {
        match result {
            CommitResult::Edit(TrackerEdit::Cell { value, .. }) => Some(CellInput::Value(value)),
            CommitResult::Edit(TrackerEdit::DraftCell { input, .. }) => Some(input),
            _ => None,
        }
    }

    #[test]
    fn text_left_as_it_opened_is_no_edit() {
        let text = column("text", true, None);
        let stamped = column("timestamp", false, Some("now()"));

        assert_eq!(
            commit_edit(&text, &saved(Value::Null), ""),
            CommitResult::Unchanged,
            "an untouched NULL became the empty string"
        );
        assert_eq!(
            commit_edit(&stamped, &draft(CellInput::Default), ""),
            CommitResult::Unchanged
        );
        assert_eq!(
            value_of(commit_edit(&text, &saved(Value::Null), "a")),
            Some(CellInput::Value(Value::Text("a".into())))
        );
    }

    #[test]
    fn clearing_a_cell_means_what_the_column_makes_of_empty() {
        let text = column("text", true, None);
        let stamp = column("timestamp", true, None);
        let stamped = column("timestamp", false, Some("now()"));

        assert_eq!(
            value_of(commit_edit(&text, &saved(Value::Text("a".into())), "")),
            Some(CellInput::Value(Value::Text(String::new())))
        );
        assert_eq!(
            value_of(commit_edit(&stamp, &saved(Value::Int(1)), "")),
            Some(CellInput::Value(Value::Null))
        );
        assert_eq!(
            value_of(commit_edit(&stamped, &draft(CellInput::Value(Value::Int(1))), "")),
            Some(CellInput::Default),
            "a new row leaves an empty cell to the server"
        );
        assert!(
            matches!(
                commit_edit(&stamped, &saved(Value::Int(1)), ""),
                CommitResult::Rejected(_)
            ),
            "an UPDATE cannot ask for the default"
        );
    }

    #[test]
    fn a_commit_names_the_row_and_the_value_it_was_read_with() {
        let text = column("text", true, None);
        let snapshot = saved(Value::Text("old".into()));

        let result = commit_edit(&text, &snapshot, "new");

        assert_eq!(
            result,
            CommitResult::Edit(TrackerEdit::Cell {
                row_key: RowKey::from_pk_values(&[Value::Int(1)]).expect("a key"),
                col: 1,
                original: Value::Text("old".into()),
                value: Value::Text("new".into()),
            })
        );
        assert_eq!(commit_edit(&text, &snapshot, "old"), CommitResult::Unchanged);
    }

    #[test]
    fn a_value_the_column_cannot_hold_is_refused_with_its_reason() {
        let integer = column("integer", false, None);

        let CommitResult::Rejected(message) = commit_edit(&integer, &saved(Value::Int(1)), "thirty") else {
            panic!("text in an integer column was accepted");
        };

        assert_eq!(message, "Enter a whole number");
    }

    #[test]
    fn a_cell_that_has_no_row_to_write_to_records_nothing() {
        let text = column("text", true, None);
        let snapshot = EditSnapshot {
            row: RowObject::result(vec![Value::Text("a".into())].into()),
            column: 0,
            original: CellInput::Value(Value::Text("a".into())),
        };

        assert_eq!(commit_edit(&text, &snapshot, "b"), CommitResult::Unchanged);
    }

    #[test]
    fn the_placeholder_says_what_empty_commits() {
        let saved_row = GridRowId::Persisted(RowKey::from_pk_values(&[Value::Int(1)]).expect("a key"));
        let draft_row = GridRowId::Draft(1);

        assert_eq!(empty_placeholder(&column("text", true, None), &saved_row), None);
        assert_eq!(
            empty_placeholder(&column("integer", true, None), &saved_row).as_deref(),
            Some("NULL")
        );
        assert_eq!(
            empty_placeholder(&column("integer", false, Some("0")), &draft_row).as_deref(),
            Some("DEFAULT")
        );
        assert_eq!(
            empty_placeholder(&column("integer", false, None), &saved_row).as_deref(),
            Some("Required")
        );
    }
}
