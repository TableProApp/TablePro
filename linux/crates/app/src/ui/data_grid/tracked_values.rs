use std::sync::Arc;

use tablepro_core::Value;
use tablepro_core::edit::CellInput;
use tablepro_core::meta::RowIdentity;

use super::GridRow;
use crate::services::change_tracker::{CellState, RowKey, RowState};
use crate::services::grid::{CellLock, GridColumn, GridRowId, RowSnapshot, cell_editability};
use crate::services::tab_tracker_handle::TabTrackerHandle;
use crate::ui::icons;

/// A row's pending change, as the grid shows it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RowPendingState {
    Unchanged,
    Modified,
    Inserted,
    MarkedForDeletion,
    /// The row produced the statement a save failed on.
    SaveFailed,
}

impl RowPendingState {
    fn new(state: RowState, save_failed: bool) -> Self {
        if save_failed {
            return Self::SaveFailed;
        }
        match state {
            RowState::Clean => Self::Unchanged,
            RowState::Modified => Self::Modified,
            RowState::InsertDraft => Self::Inserted,
            RowState::PendingDelete => Self::MarkedForDeletion,
        }
    }

    pub fn icon(self) -> Option<&'static str> {
        match self {
            Self::Unchanged => None,
            Self::Modified => Some(icons::DOCUMENT_EDIT),
            Self::Inserted => Some(icons::LIST_ADD),
            Self::MarkedForDeletion => Some(icons::EDIT_DELETE),
            Self::SaveFailed => Some(icons::DIALOG_ERROR),
        }
    }

    pub fn text(self) -> Option<String> {
        let text = match self {
            Self::Unchanged => return None,
            Self::Modified => crate::i18n::gettext("Modified"),
            Self::Inserted => crate::i18n::gettext("New row"),
            Self::MarkedForDeletion => crate::i18n::gettext("Marked for deletion"),
            Self::SaveFailed => crate::i18n::gettext("Not saved"),
        };
        Some(text)
    }

    /// What a screen reader adds to a row. An edited row says nothing of
    /// its own: its edited cells do.
    pub fn row_description(self) -> Option<String> {
        match self {
            Self::Modified => None,
            other => other.text(),
        }
    }
}

/// What a screen reader adds to a cell's value. A NULL is named, since it
/// reads as the text "NULL" would.
pub fn cell_description(state: CellState, null: bool) -> Option<String> {
    let text = match (state, null) {
        (CellState::Modified, true) => crate::i18n::gettext("Modified, NULL value"),
        (CellState::Modified, false) => crate::i18n::gettext("Modified"),
        (_, true) => crate::i18n::gettext("NULL value"),
        (_, false) => return None,
    };
    Some(text)
}

/// How one cell draws its pending change.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CellMark {
    pub state: CellState,
    pub row_deleted: bool,
}

/// The values a grid shows: what was read, under what its tracker holds.
/// Every draw, copy, export and editor reads through here, so what leaves
/// the grid is what the user is looking at.
#[derive(Debug, Clone)]
pub struct TrackedValues {
    tracker: Option<TabTrackerHandle>,
    identity: RowIdentity,
    read_only: bool,
}

impl Default for TrackedValues {
    fn default() -> Self {
        Self::untracked()
    }
}

impl TrackedValues {
    pub fn untracked() -> Self {
        Self {
            tracker: None,
            identity: RowIdentity::Unordered,
            read_only: true,
        }
    }

    pub fn tracked(tracker: TabTrackerHandle, identity: RowIdentity) -> Self {
        Self {
            tracker: Some(tracker),
            identity,
            read_only: false,
        }
    }

    /// On a read-only connection every cell is locked, and says why.
    pub fn on_read_only_connection(mut self, read_only: bool) -> Self {
        self.read_only = read_only;
        self
    }

    pub fn tracker(&self) -> Option<&TabTrackerHandle> {
        self.tracker.as_ref()
    }

    pub fn identity(&self) -> &RowIdentity {
        &self.identity
    }

    pub fn tracks_changes(&self) -> bool {
        !self.read_only && self.tracker.is_some()
    }

    fn tracked_key(&self, row: &GridRow) -> Option<(&TabTrackerHandle, RowKey)> {
        Some((self.tracker.as_ref()?, row.tracker_key()?))
    }

    /// Why the cell cannot change, `None` when it can.
    pub fn lock(&self, column: &GridColumn, row: &GridRow) -> Option<CellLock> {
        let row_deleted = self.mark(row, column.index).row_deleted;
        self.lock_marked(column, row, row_deleted)
    }

    /// `lock` for a cell whose mark the caller already read.
    pub fn lock_marked(&self, column: &GridColumn, row: &GridRow, row_deleted: bool) -> Option<CellLock> {
        if let Err(lock) = cell_editability(column, &row.id(), &self.identity, self.read_only, row_deleted) {
            return Some(lock);
        }
        self.tracked_key(row)
            .is_some_and(|(tracker, key)| tracker.cell_is_saving(&key, column.index))
            .then_some(CellLock::Saving)
    }

    pub fn row_state(&self, row: &GridRow) -> RowPendingState {
        self.tracked_key(row)
            .map_or(RowPendingState::Unchanged, |(tracker, key)| {
                RowPendingState::new(tracker.row_state(&key), tracker.is_error_row(&key))
            })
    }

    pub fn mark(&self, row: &GridRow, column: usize) -> CellMark {
        match self.tracked_key(row) {
            Some((tracker, key)) => {
                let marks = tracker.cell_marks(&key, column);
                CellMark {
                    state: marks.state,
                    row_deleted: marks.row_deleted,
                }
            }
            None => CellMark {
                state: CellState::Clean,
                row_deleted: false,
            },
        }
    }

    /// Calls `f` with the value the cell shows. `default` is set for a
    /// draft's cell left to the server, which then reads as NULL.
    pub fn with_value<R>(&self, row: &GridRow, column: usize, f: impl FnOnce(&Value, bool) -> R) -> R {
        let pending = self
            .tracked_key(row)
            .and_then(|(tracker, key)| tracker.cell_overlay(&key, column).pending);
        match pending {
            Some(CellInput::Value(value)) => f(&value, false),
            Some(CellInput::Default) => f(&Value::Null, true),
            None => match row.cells() {
                Some(cells) => f(cells.get(column).unwrap_or(&Value::Null), false),
                None => f(&Value::Null, false),
            },
        }
    }

    /// What an editor opens on: a draft's cell as the tracker holds it, a
    /// saved row's pending value, else the value as it was read.
    pub fn edit_input(&self, row: &GridRow, column: usize) -> CellInput {
        self.with_value(row, column, |value, default| match default {
            true => CellInput::Default,
            false => CellInput::Value(value.clone()),
        })
    }

    /// The row as the grid shows it. A draft's cell left to the server
    /// reads as NULL.
    pub fn snapshot(&self, row: &GridRow) -> RowSnapshot {
        if let (GridRowId::Draft(draft_id), Some(tracker)) = (row.id(), self.tracker.as_ref()) {
            return RowSnapshot::new(tracker.draft_values(draft_id).unwrap_or_default().into(), Vec::new());
        }
        let cells = row.cells().unwrap_or_else(|| Arc::from([]));
        let overrides = self
            .tracked_key(row)
            .map(|(tracker, key)| tracker.pending_values(&key, cells.len()))
            .unwrap_or_default();
        RowSnapshot::new(cells, overrides)
    }

    /// Like `snapshot`, except a draft's cell left to the server stays
    /// `Default`.
    pub fn inputs(&self, row: &GridRow) -> Vec<CellInput> {
        if let (GridRowId::Draft(draft_id), Some(tracker)) = (row.id(), self.tracker.as_ref()) {
            return tracker.draft_inputs(draft_id).unwrap_or_default();
        }
        self.snapshot(row)
            .to_values()
            .into_iter()
            .map(CellInput::Value)
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use tablepro_core::Value;
    use tablepro_core::edit::CellInput;

    use super::*;
    use crate::services::tracker_edit::TrackerEdit;
    use crate::ui::data_grid::RowData;

    fn key(id: i64) -> RowKey {
        RowKey::from_pk_values(&[Value::Int(id)]).expect("a key")
    }

    fn keyed() -> RowIdentity {
        RowIdentity::UniqueKey {
            columns: vec!["id".to_owned()],
        }
    }

    #[test]
    fn an_untracked_row_reads_as_it_was_read() {
        let values = TrackedValues::untracked();
        let row = GridRow::new(RowData::result(Arc::from([Value::Int(1), Value::Text("a".into())])));

        assert_eq!(values.row_state(&row), RowPendingState::Unchanged);
        assert!(values.with_value(&row, 1, |value, _| *value == Value::Text("a".into())));
        assert_eq!(
            values.snapshot(&row).to_values(),
            [Value::Int(1), Value::Text("a".into())]
        );
    }

    #[test]
    fn a_pending_edit_shows_over_the_value_read() {
        let tracker = TabTrackerHandle::default();
        let values = TrackedValues::tracked(tracker.clone(), keyed());
        let row = GridRow::new(RowData::persisted(
            Some(key(1)),
            Arc::from([Value::Int(1), Value::Int(5)]),
        ));
        let _delta = tracker.apply(TrackerEdit::Cell {
            row_key: key(1),
            col: 1,
            original: Value::Int(5),
            value: Value::Int(6),
        });

        assert!(values.with_value(&row, 1, |value, _| *value == Value::Int(6)));
        assert_eq!(values.edit_input(&row, 1), CellInput::Value(Value::Int(6)));
        assert_eq!(values.row_state(&row), RowPendingState::Modified);
        assert_eq!(values.mark(&row, 1).state, CellState::Modified);
    }

    #[test]
    fn every_pending_state_has_an_icon_and_a_sentence() {
        for state in [
            RowPendingState::Modified,
            RowPendingState::Inserted,
            RowPendingState::MarkedForDeletion,
            RowPendingState::SaveFailed,
        ] {
            assert!(state.icon().is_some() && state.text().is_some(), "{state:?}");
        }
        assert!(RowPendingState::Unchanged.icon().is_none());
    }
}
