use tablepro_core::Value;
use tablepro_core::edit::{
    CellInput, EditContext, EditParseError, EditText, EmptyInputMeaning, edit_text, empty_input_meaning, is_unchanged,
    parse_edit_text,
};

use super::{GridColumn, GridRowId};
use crate::services::tracker_edit::TrackerEdit;

/// An edit as it stood when it began. The commit goes to `row`, not to
/// whatever row the cell shows by then.
#[derive(Debug, Clone, PartialEq)]
pub struct EditStart {
    pub row: GridRowId,
    /// The cell as the page read it, which the tracker saves against.
    pub read: Value,
    /// The cell with any pending edit, which the editor opened with.
    pub original: CellInput,
}

/// What committing an editor's text comes to.
#[derive(Debug, Clone, PartialEq)]
pub enum CommitResult {
    Edit(TrackerEdit),
    Unchanged,
    /// The text is not a value of the column. The UI words the error.
    Rejected(EditParseError),
}

/// Only a new row can leave a column to the server.
pub fn edit_context(row: &GridRowId) -> EditContext {
    match row {
        GridRowId::Draft(_) => EditContext::InsertDraft,
        GridRowId::Result | GridRowId::Unkeyed | GridRowId::Persisted(_) => EditContext::UpdateRow,
    }
}

/// The text an editor ends with, as an edit of the row it began on.
/// Text left as the editor opened it is no edit: NULL and the empty
/// string open as the same empty field, and must not turn into each other.
pub fn commit_edit(column: &GridColumn, start: &EditStart, input: &str) -> CommitResult {
    let Some(catalog) = column.catalog.as_ref() else {
        return CommitResult::Unchanged;
    };
    let opened_with = match &start.original {
        CellInput::Value(value) => edit_text(value, &catalog.column_type),
        CellInput::Default => EditText::Editable(String::new()),
    };
    if matches!(&opened_with, EditText::Editable(text) if text == input) {
        return CommitResult::Unchanged;
    }
    match parse_edit_text(input, catalog, edit_context(&start.row)) {
        Ok(parsed) => commit_input(column, start, parsed),
        Err(error) => {
            tracing::debug!(%error, column = %catalog.name, "refused an edit");
            CommitResult::Rejected(error)
        }
    }
}

/// `input` as an edit of the row `start` names, or no edit when it
/// leaves the cell as it was.
pub fn commit_input(column: &GridColumn, start: &EditStart, input: CellInput) -> CommitResult {
    let unchanged = match (&start.original, &input) {
        (CellInput::Value(original), CellInput::Value(value)) => is_unchanged(original, value, column.value_type()),
        (CellInput::Default, CellInput::Default) => true,
        _ => false,
    };
    if unchanged {
        return CommitResult::Unchanged;
    }
    match (&start.row, input) {
        (GridRowId::Draft(draft_id), input) => CommitResult::Edit(TrackerEdit::DraftCell {
            draft_id: *draft_id,
            col: column.index,
            input,
        }),
        (GridRowId::Persisted(row_key), CellInput::Value(value)) => CommitResult::Edit(TrackerEdit::Cell {
            row_key: row_key.clone(),
            col: column.index,
            original: start.read.clone(),
            value,
        }),
        (GridRowId::Persisted(_), CellInput::Default) => {
            tracing::error!("a saved row's cell was given the server's default");
            CommitResult::Unchanged
        }
        (GridRowId::Result | GridRowId::Unkeyed, _) => CommitResult::Unchanged,
    }
}

/// What an empty editor commits, said where the text would be. The
/// keywords are SQL and stay untranslated.
pub fn empty_placeholder(column: &GridColumn, row: &GridRowId) -> Option<String> {
    let catalog = column.catalog.as_ref()?;
    match empty_input_meaning(catalog, edit_context(row)) {
        EmptyInputMeaning::EmptyText => None,
        EmptyInputMeaning::Default => Some("DEFAULT".to_owned()),
        EmptyInputMeaning::Null => Some("NULL".to_owned()),
        EmptyInputMeaning::Required => Some(crate::i18n::gettext("Required")),
    }
}

#[cfg(test)]
mod tests {
    use tablepro_core::column::{ColumnDefault, ColumnKind};
    use tablepro_core::edit::{CellInput, EditParseError};
    use tablepro_core::{ColumnInfo, Value};

    use super::{CommitResult, EditStart, commit_edit, empty_placeholder};
    use crate::services::change_tracker::RowKey;
    use crate::services::grid::test_columns::{grid, info, persisted, result_only};
    use crate::services::grid::{GridColumn, GridRowId};
    use crate::services::tracker_edit::TrackerEdit;

    #[expect(
        clippy::disallowed_methods,
        reason = "a test fixture stands in for the catalogue, which is where this text comes from in production"
    )]
    fn column(data_type: &str, nullable: bool, default: Option<&str>) -> GridColumn {
        let mut column = grid(ColumnInfo {
            nullable,
            default: match default {
                Some(text) => ColumnDefault::Expression(tablepro_core::column::SqlExpression::from_catalog_text(text)),
                None => ColumnDefault::None,
            },
            ..info("c", data_type)
        });
        column.index = 1;
        column
    }

    fn saved(value: Value) -> EditStart {
        EditStart {
            row: persisted(),
            read: value.clone(),
            original: CellInput::Value(value),
        }
    }

    fn draft(original: CellInput) -> EditStart {
        EditStart {
            row: GridRowId::Draft(3),
            read: Value::Null,
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
        assert_eq!(
            commit_edit(&stamped, &saved(Value::Int(1)), ""),
            CommitResult::Rejected(EditParseError::Required),
            "an UPDATE cannot ask for the default"
        );
    }

    #[test]
    fn a_commit_names_the_row_and_the_value_it_was_read_with() {
        let text = column("text", true, None);
        let start = EditStart {
            row: persisted(),
            read: Value::Text("read".into()),
            original: CellInput::Value(Value::Text("old".into())),
        };

        let result = commit_edit(&text, &start, "new");

        assert_eq!(
            result,
            CommitResult::Edit(TrackerEdit::Cell {
                row_key: RowKey::from_pk_values(&[Value::Int(1)]).expect("a key"),
                col: 1,
                original: Value::Text("read".into()),
                value: Value::Text("new".into()),
            })
        );
        assert_eq!(commit_edit(&text, &start, "old"), CommitResult::Unchanged);
    }

    #[test]
    fn a_value_the_column_cannot_hold_is_refused_with_its_reason() {
        let integer = column("integer", false, None);

        assert_eq!(
            commit_edit(&integer, &saved(Value::Int(1)), "thirty"),
            CommitResult::Rejected(EditParseError::InvalidInteger)
        );
    }

    #[test]
    fn a_cell_that_has_no_row_to_write_to_records_nothing() {
        let text = column("text", true, None);
        let start = EditStart {
            row: GridRowId::Result,
            read: Value::Text("a".into()),
            original: CellInput::Value(Value::Text("a".into())),
        };

        assert_eq!(commit_edit(&text, &start, "b"), CommitResult::Unchanged);
        assert_eq!(
            commit_edit(
                &result_only("c", ColumnKind::Other),
                &saved(Value::Text("a".into())),
                "b"
            ),
            CommitResult::Unchanged,
            "a column the catalogue does not know"
        );
    }

    #[test]
    fn the_placeholder_says_what_empty_commits() {
        let saved_row = persisted();
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
        assert_eq!(
            empty_placeholder(&result_only("c", ColumnKind::Other), &saved_row),
            None
        );
    }
}
