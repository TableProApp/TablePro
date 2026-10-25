use gtk4::prelude::*;
use gtk4::{self as gtk, glib};
use tablepro_core::Value;
use tablepro_core::column::{BoolStorage, ColumnKind};
use tablepro_core::edit::{CellInput, EditParseError, new_draft_cell, parse_edit_text};

use super::cell_editor::Plan;
use super::{EditController, edit_start};
use crate::i18n::gettext;
use crate::services::change_tracker::RowKey;
use crate::services::grid::{
    CellPreset, CommitResult, EditStart, GridColumn, cell_presets, commit_input, edit_context,
};
use crate::services::tracker_edit::TrackerEdit;
use crate::ui::data_grid::{DataGrid, GridRow};
use crate::ui::error_text::edit_parse_message;

impl EditController {
    /// Write the column's own spelling of the opposite value.
    pub(super) fn toggle(&self, grid: &DataGrid, row: &GridRow, column: usize) {
        let Some(grid_column) = self.unlocked_column(grid, row, column) else {
            return;
        };
        let ColumnKind::Bool(storage) = grid_column.value_type().kind else {
            return;
        };
        grid.commit_editors();
        let tracked = self.tracked();
        let next = tracked.with_value(row, column, |value, default| toggled(value, default, storage));
        let start = edit_start(&tracked, row, column);
        self.commit_input(grid, &grid_column, &start, CellInput::Value(next));
    }

    pub(super) fn toggle_target(&self, grid: &DataGrid) {
        if let Some((row, column)) = grid.target().and_then(|target| target.cell) {
            self.toggle(grid, &row, column);
        }
    }

    /// Set to Empty, NULL or DEFAULT on the cell an action names. The
    /// menu offers only what the cell takes; a column that refuses the
    /// value says why, as committing an empty cell would.
    pub(super) fn set_preset(&self, grid: &DataGrid, preset: CellPreset) {
        let Some((row, column)) = grid.target().and_then(|target| target.cell) else {
            return;
        };
        let Some(grid_column) = self.unlocked_column(grid, &row, column) else {
            return;
        };
        let Some(catalog) = grid_column.catalog.as_ref() else {
            return;
        };
        let presets = cell_presets(&grid_column, &row.id());
        let input = match preset {
            CellPreset::Empty => {
                parse_edit_text("", catalog, edit_context(&row.id())).map_err(|error| edit_parse_message(&error))
            }
            CellPreset::Null if presets.null => Ok(CellInput::Value(Value::Null)),
            CellPreset::Null => Err(edit_parse_message(&EditParseError::Required)),
            CellPreset::Default if presets.default => Ok(CellInput::Default),
            CellPreset::Default => Err(gettext("This cell can't take the column's default")),
        };
        match input {
            Ok(input) => {
                grid.commit_editors();
                let start = edit_start(&self.tracked(), &row, column);
                self.commit_input(grid, &grid_column, &start, input);
            }
            Err(message) => grid.toast(message),
        }
    }

    /// Only a table whose rows can be saved takes a new one (D1).
    pub(super) fn insert_row(&self, grid: &DataGrid) {
        if self.policy().is_none_or(|policy| policy.insert.is_err()) {
            return;
        }
        let columns = grid.grid_columns();
        if columns.is_empty() {
            return;
        }
        let cells = columns
            .iter()
            .map(|column| {
                column
                    .catalog
                    .as_ref()
                    .map_or(CellInput::Value(Value::Null), new_draft_cell)
            })
            .collect();
        if let Some(draft_id) = self.insert_drafts(grid, vec![cells]) {
            self.edit_new_row_soon(grid, draft_id);
        }
    }

    /// Copies of the rows as the user sees them, pending edits included.
    /// What the database owns (key, identity, generated) is left to it.
    pub(super) fn duplicate_rows(&self, grid: &DataGrid) {
        if self.policy().is_none_or(|policy| policy.duplicate.is_err()) {
            return;
        }
        let Some(target) = grid.target().filter(|target| !target.rows.is_empty()) else {
            return;
        };
        let columns = grid.grid_columns();
        let tracked = self.tracked();
        let copies = target
            .rows
            .iter()
            .map(|row| {
                let source = tracked.inputs(row);
                columns
                    .iter()
                    .map(|column| match &column.catalog {
                        Some(catalog) if catalog.primary_key || catalog.is_auto_increment || catalog.is_generated => {
                            new_draft_cell(catalog)
                        }
                        Some(_) | None => source
                            .get(column.index)
                            .cloned()
                            .unwrap_or(CellInput::Value(Value::Null)),
                    })
                    .collect()
            })
            .collect();
        if let Some(draft_id) = self.insert_drafts(grid, copies) {
            self.edit_new_row_soon(grid, draft_id);
        }
    }

    /// New drafts, one undo step. Returns the one shown on top.
    pub(super) fn insert_drafts(&self, grid: &DataGrid, rows: Vec<Vec<CellInput>>) -> Option<u64> {
        let tracker = self.tracked().tracker().cloned()?;
        grid.commit_editors();
        let delta = tracker.apply(TrackerEdit::InsertDrafts { rows });
        let top = delta.inserted_drafts.last().copied();
        self.apply_delta(&delta);
        top
    }

    /// In an idle callback: GTK aborts updating the list's adjustments
    /// when it scrolls in the tick a first row appears in an empty grid.
    fn edit_new_row_soon(&self, grid: &DataGrid, draft_id: u64) {
        let weak = grid.downgrade();
        glib::idle_add_local_once(move || {
            if let Some(grid) = weak.upgrade()
                && grid.is_mapped()
            {
                grid.edit().edit_row(&grid, &RowKey::Draft(draft_id));
            }
        });
    }

    /// Select the row and edit its first cell that edits inline. A row
    /// with none keeps the focus on the cell the row gave it.
    pub(super) fn edit_row(&self, grid: &DataGrid, key: &RowKey) {
        let Some(row) = grid.store().row_for(key) else {
            return;
        };
        let Some(position) = grid.view_position(&row) else {
            return;
        };
        let view = grid.column_view();
        view.scroll_to(
            position,
            None,
            gtk::ListScrollFlags::FOCUS | gtk::ListScrollFlags::SELECT,
            None,
        );
        // `scroll_to` only marks the row while the focus is outside the
        // list; the grab then takes it there.
        view.grab_focus();
        let column = grid
            .shown_columns()
            .into_iter()
            .find(|column| matches!(self.plan(grid, &row, *column), Plan::Inline(_)));
        if let Some(cell) = column.and_then(|column| grid.focus_cell(position, column)) {
            self.edit_cell(&cell);
        }
    }

    /// Select the first `count` rows, where new rows land, and focus the
    /// first, once the grid has drawn them.
    pub(super) fn select_top_rows_soon(&self, grid: &DataGrid, count: u32) {
        let weak = grid.downgrade();
        glib::idle_add_local_once(move || {
            let Some(grid) = weak.upgrade().filter(|grid| grid.is_mapped()) else {
                return;
            };
            let selection = grid.selection();
            let count = count.min(selection.n_items());
            if count == 0 {
                return;
            }
            selection.select_range(0, count, true);
            let view = grid.column_view();
            view.scroll_to(0, None, gtk::ListScrollFlags::FOCUS, None);
            view.grab_focus();
        });
    }

    pub(super) fn commit_input(&self, grid: &DataGrid, column: &GridColumn, start: &EditStart, input: CellInput) {
        match commit_input(column, start, input) {
            CommitResult::Edit(edit) => self.apply_edit(grid, edit),
            CommitResult::Unchanged => {}
            CommitResult::Rejected(error) => grid.toast(edit_parse_message(&error)),
        }
    }

    /// The column, while the cell takes a value: checked again here, as
    /// a key or a late event can reach a cell locked since.
    pub(super) fn unlocked_column(&self, grid: &DataGrid, row: &GridRow, column: usize) -> Option<GridColumn> {
        let policy = self.policy()?;
        let grid_column = grid.grid_columns().get(column).cloned()?;
        match (policy.cells, self.tracked().lock(&grid_column, row)) {
            (Ok(()), None) => Some(grid_column),
            (_, lock) => {
                tracing::debug!(?lock, column, "refused a change to a locked cell");
                None
            }
        }
    }
}

/// NULL, DEFAULT and a number other than 0 and 1 are neither true nor
/// false, and toggle to true.
pub(super) fn toggled(value: &Value, default: bool, storage: BoolStorage) -> Value {
    let truth = match (default, value) {
        (true, _) => None,
        (false, Value::Bool(flag)) => Some(*flag),
        (false, Value::Int(0) | Value::UInt(0)) => Some(false),
        (false, Value::Int(1) | Value::UInt(1)) => Some(true),
        (false, _) => None,
    };
    let next = truth.is_none_or(|truth| !truth);
    match storage {
        BoolStorage::Native => Value::Bool(next),
        // `tinyint(1)` keeps any integer, so a toggle writes 0 or 1.
        BoolStorage::Integer => Value::Int(i64::from(next)),
    }
}
