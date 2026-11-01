use std::collections::HashSet;
use std::sync::Arc;

use tablepro_core::Value;
use tablepro_core::edit::CellInput;

use super::text;
use crate::services::change_tracker::{CellState, RowKey};
use crate::services::grid::{GridRowId, cell_editability, grid_columns};
use crate::services::tab_tracker_handle::TabTrackerHandle;
use crate::services::tracker_edit::TrackerEdit;
use crate::ui::data_grid::test_grid::{col, key, keyed_by_id};
use crate::ui::data_grid::tracked_values::{RowPendingState, cell_description};
use crate::ui::data_grid::{GridRow, GridStore, RowData, TrackedValues};
use crate::ui::icons;

fn tracked(tracker: &TabTrackerHandle) -> TrackedValues {
    TrackedValues::tracked(tracker.clone(), keyed_by_id())
}

fn insert_draft(tracker: &TabTrackerHandle, inputs: Vec<CellInput>) -> GridRow {
    let delta = tracker.apply(TrackerEdit::InsertDrafts { rows: vec![inputs] });
    let draft_id = delta
        .inserted_drafts
        .first()
        .copied()
        .expect("an insert adds a draft row");
    GridRow::new(RowData::draft(draft_id))
}

fn saved(id: i64, cells: Vec<Value>) -> GridRow {
    GridRow::new(RowData::persisted(Some(key(id)), cells.into()))
}

fn rename(tracker: &TabTrackerHandle, id: i64) {
    let _ = tracker.apply(TrackerEdit::Cell {
        row_key: key(id),
        col: 1,
        original: text("old"),
        value: CellInput::Value(text("new")),
    });
}

#[test]
fn a_tracked_draft_reads_its_cells_from_the_tracker() {
    let tracker = TabTrackerHandle::default();
    let draft = insert_draft(&tracker, vec![CellInput::Value(Value::Int(4))]);

    assert_eq!(tracked(&tracker).edit_input(&draft, 0), CellInput::Value(Value::Int(4)));
    assert_eq!(tracked(&tracker).row_state(&draft), RowPendingState::Inserted);
}

#[test]
fn a_clean_cell_is_drawn_from_the_row_itself() {
    let tracker = TabTrackerHandle::default();
    rename(&tracker, 1);
    let row = saved(1, vec![Value::Int(1), text("old")]);
    let cells = row.cells().expect("a saved row's cells");

    let borrowed = tracked(&tracker).with_value(&row, 0, |value, _| std::ptr::eq(value, &cells[0]));
    let pending = tracked(&tracker).with_value(&row, 1, |value, default| (value.clone(), default));

    assert!(borrowed, "an unedited cell was copied out of its row");
    assert_eq!(pending, (text("new"), None));
}

#[test]
fn snapshots_include_pending_edits_and_draft_cells() {
    let tracker = TabTrackerHandle::default();
    rename(&tracker, 1);
    let draft = insert_draft(
        &tracker,
        vec![CellInput::Value(Value::Null), CellInput::Value(text("draft"))],
    );
    let row = saved(1, vec![Value::Int(1), text("old")]);

    assert_eq!(
        tracked(&tracker).snapshot(&row).to_values(),
        [Value::Int(1), text("new")]
    );
    assert_eq!(
        tracked(&tracker).snapshot(&draft).to_values(),
        [Value::Null, text("draft")]
    );
}

/// A copy has no value to give a default.
#[test]
fn a_draft_cell_left_to_the_server_opens_as_the_default() {
    let tracker = TabTrackerHandle::default();
    let draft = insert_draft(&tracker, vec![CellInput::Default, CellInput::Value(Value::Int(3))]);

    assert_eq!(tracked(&tracker).edit_input(&draft, 0), CellInput::Default);
    assert_eq!(tracked(&tracker).edit_input(&draft, 1), CellInput::Value(Value::Int(3)));
    assert_eq!(
        tracked(&tracker).snapshot(&draft).to_values(),
        [Value::Null, Value::Int(3)]
    );
    assert_eq!(
        tracked(&tracker).inputs(&draft),
        [CellInput::Default, CellInput::Value(Value::Int(3))]
    );
}

#[test]
fn row_state_icons_are_distinct_and_described() {
    let pending = [
        RowPendingState::Modified,
        RowPendingState::Inserted,
        RowPendingState::MarkedForDeletion,
        RowPendingState::SaveFailed,
    ];

    let shown: Vec<(Option<&str>, Option<String>)> = pending.iter().map(|state| (state.icon(), state.text())).collect();

    assert_eq!(
        shown,
        [
            (Some(icons::DOCUMENT_EDIT), Some("Modified".to_owned())),
            (Some(icons::LIST_ADD), Some("New row".to_owned())),
            (Some(icons::EDIT_DELETE), Some("Marked for deletion".to_owned())),
            (Some(icons::DIALOG_ERROR), Some("Not saved".to_owned())),
        ]
    );
    let distinct: HashSet<Option<&str>> = shown.iter().map(|(icon, _)| *icon).collect();
    assert_eq!(distinct.len(), pending.len());
    assert_eq!(RowPendingState::Unchanged.icon(), None);
    assert_eq!(RowPendingState::Unchanged.text(), None);
}

#[test]
fn a_failed_save_outranks_the_rows_change() {
    let tracker = TabTrackerHandle::default();
    rename(&tracker, 1);
    let edited = saved(1, vec![Value::Int(1), text("old")]);
    let _ = tracker.apply(TrackerEdit::DeleteRows {
        persisted: vec![(key(2), Arc::from([Value::Int(2), text("gone")]))],
        drafts: Vec::new(),
    });
    let deleted = saved(2, vec![Value::Int(2), text("gone")]);
    let draft = insert_draft(&tracker, vec![CellInput::Value(Value::Null)]);
    let clean = saved(3, vec![Value::Int(3), text("as read")]);
    assert_eq!(tracked(&tracker).row_state(&edited), RowPendingState::Modified);

    let _ = tracker.mark_error_row(key(1));

    assert_eq!(tracked(&tracker).row_state(&edited), RowPendingState::SaveFailed);
    assert_eq!(
        tracked(&tracker).row_state(&deleted),
        RowPendingState::MarkedForDeletion
    );
    assert_eq!(tracked(&tracker).row_state(&draft), RowPendingState::Inserted);
    assert_eq!(tracked(&tracker).row_state(&clean), RowPendingState::Unchanged);
}

#[test]
fn cell_and_row_descriptions() {
    assert_eq!(
        cell_description(CellState::Modified, false).as_deref(),
        Some("Modified")
    );
    assert_eq!(cell_description(CellState::Clean, false), None);
    assert_eq!(cell_description(CellState::InsertDraft, false), None);
    assert_eq!(RowPendingState::Inserted.row_description().as_deref(), Some("New row"));
    assert_eq!(
        RowPendingState::MarkedForDeletion.row_description().as_deref(),
        Some("Marked for deletion")
    );
    assert_eq!(
        RowPendingState::SaveFailed.row_description().as_deref(),
        Some("Not saved")
    );
    assert_eq!(RowPendingState::Unchanged.row_description(), None);
    assert_eq!(
        RowPendingState::Modified.row_description(),
        None,
        "an edited row says nothing its edited cells do not"
    );
}

#[test]
fn cell_description_marks_null_and_modified() {
    assert_eq!(
        cell_description(CellState::Modified, true).as_deref(),
        Some("Modified, NULL value")
    );
    assert_eq!(cell_description(CellState::Clean, true).as_deref(), Some("NULL value"));
    assert_eq!(
        cell_description(CellState::InsertDraft, true).as_deref(),
        Some("NULL value")
    );
    assert_eq!(cell_description(CellState::Clean, false), None);
}

#[test]
fn a_row_keeps_the_identity_it_was_made_with() {
    let persisted = saved(2, vec![Value::Int(2)]);
    let unkeyed = GridRow::new(RowData::persisted(None, Arc::from([Value::Int(2)])));
    let result = GridRow::new(RowData::result(Arc::from([Value::Int(2)])));
    let draft = GridRow::new(RowData::draft(5));

    assert_eq!(persisted.key(), Some(key(2)));
    assert_eq!(persisted.cells().as_deref(), Some(&[Value::Int(2)][..]));
    assert_eq!(unkeyed.id(), GridRowId::Unkeyed);
    assert_eq!(unkeyed.tracker_key(), None, "a row with no key took an edit");
    assert_eq!(result.id(), GridRowId::Result);
    assert_eq!(draft.draft_id(), Some(5));
    assert_eq!(draft.tracker_key(), Some(RowKey::Draft(5)));
    assert!(draft.cells().is_none(), "a draft's cells are the tracker's");
}

#[test]
fn drafts_are_found_by_their_draft_key_and_unkeyed_rows_not_at_all() {
    let store = GridStore::default();
    store.replace(vec![
        RowData::draft(7),
        RowData::persisted(Some(key(1)), Arc::from([Value::Int(1)])),
        RowData::persisted(None, Arc::from([Value::Int(3)])),
    ]);

    let position = |row_key: &RowKey| store.row_for(row_key).and_then(|row| store.position_of(&row));

    assert_eq!(position(&RowKey::Draft(7)), Some(0));
    assert_eq!(position(&key(1)), Some(1));
    assert_eq!(store.draft_count(), 1);
    store.remove_drafts(&[7]);
    assert_eq!(position(&RowKey::Draft(7)), None);
    assert_eq!(position(&key(1)), Some(0));
}

#[test]
fn a_draft_is_never_taken_for_a_saved_row_with_the_same_number() {
    let store = GridStore::default();
    store.replace(vec![RowData::persisted(Some(key(3)), Arc::from([Value::Int(3)]))]);
    store.insert_drafts(&[3]);

    let draft = store.row_for(&RowKey::Draft(3)).expect("the draft");
    let row = store.row_for(&key(3)).expect("the saved row");

    assert_ne!(draft, row);
    assert_eq!(draft.draft_id(), Some(3));
    assert_eq!(row.key(), Some(key(3)));
}

/// Clearing a text cell stores the empty string; clearing a number or a
/// date can only mean NULL.
#[test]
fn only_columns_with_an_empty_value_accept_an_empty_string() {
    for text in ["text", "VARCHAR(255)", "char(3)", "longtext"] {
        assert!(
            col(text, false).column_type.kind.accepts_empty_string(),
            "{text} should accept an empty string"
        );
    }
    for other in [
        "integer",
        "bigint",
        "numeric(10,2)",
        "date",
        "timestamp",
        "uuid",
        "boolean",
    ] {
        assert!(
            !col(other, false).column_type.kind.accepts_empty_string(),
            "{other} should not accept an empty string"
        );
    }
}

#[test]
fn a_blob_is_never_editable_whatever_the_engine_calls_it() {
    let editable = |data_type: &str| {
        let info = col(data_type, false);
        let columns = grid_columns(&[info.result_column()], &[info], |_| true);
        // A draft has the fewest locks: a column a draft cannot edit, no
        // row can.
        cell_editability(&columns[0], &GridRowId::Draft(0), &keyed_by_id(), false, false).is_ok()
    };

    for name in [
        "BYTEA",
        "blob",
        "LONGBLOB",
        "mediumblob",
        "tinyblob",
        "VARBINARY",
        "binary",
    ] {
        assert!(!editable(name), "{name} was offered as an editable cell");
    }
    assert!(editable("text"));
    assert!(editable("integer"));
}
