use std::sync::Arc;

use gtk4::glib;
use gtk4::prelude::*;
use libadwaita as adw;
use libadwaita::prelude::*;
use tablepro_core::Value;
use tablepro_core::edit::{CellInput, EditParseError, parse_edit_text};

use super::confirming_delete::ConfirmingDelete;
use super::row_deletion::{RowDeletion, plan_row_deletion};
use super::{BULK_DELETE_CONFIRM_THRESHOLD, BrowseModel, BrowseTabOutput, EditInput, Effects, apply_draft_changes};
use crate::services::change_tracker::{RowKey, new_draft_cell, pk_identity};
use crate::services::column_relayout::ColumnRelayout;
use crate::services::tracker_delta::TrackerDelta;
use crate::services::tracker_edit::TrackerEdit;
use crate::ui::grid::{CellPreset, GridRowId, RowObject, cell_editability, cell_presets, edit_context, edit_row};

impl BrowseModel {
    pub(super) fn on_edit(&mut self, input: EditInput, fx: &mut Effects) {
        match input {
            EditInput::InsertRow => {
                if self.read_only || self.current_columns.is_empty() {
                    return;
                }
                let cells = self.current_columns.iter().map(new_draft_cell).collect();
                self.apply_edit(TrackerEdit::InsertDrafts { rows: vec![cells] }, fx);
                fx.input(EditInput::FocusInsertedDraft);
            }
            EditInput::FocusInsertedDraft => self.focus_inserted_draft(),
            EditInput::DeleteRows(rows) => self.delete_rows(&rows, fx),
            EditInput::GridEdit { row, column, edit } => {
                // The cell shows what was typed until its row is drawn again.
                if self.refuses_edit(&row, column) {
                    row.bump_revision();
                    return;
                }
                self.apply_edit(edit, fx);
            }
            EditInput::GridSetCellValue { row, column, preset } => self.set_cell_value(&row, column, preset, fx),
            EditInput::DuplicateRows(rows) => self.duplicate_rows(&rows, fx),
            EditInput::Undo => {
                if let Some(delta) = self.tracker.undo() {
                    self.apply_tracker_delta(&delta, fx);
                }
            }
            EditInput::Redo => {
                if let Some(delta) = self.tracker.redo() {
                    self.apply_tracker_delta(&delta, fx);
                }
            }
            EditInput::MarkRowsDeleted(deletion) => {
                self.apply_edit(
                    TrackerEdit::DeleteRows {
                        persisted: deletion.persisted,
                        drafts: deletion.drafts,
                    },
                    fx,
                );
                // A bulk action ends the selection it acted on.
                if let Some(selection) = self.current_selection.as_ref() {
                    selection.unselect_all();
                }
            }
            EditInput::BulkDeleteAnswered { ticket, confirmed } => self.bulk_delete_answered(ticket, confirmed, fx),
        }
    }

    fn set_cell_value(&mut self, row: &RowObject, column: usize, preset: CellPreset, fx: &mut Effects) {
        if self.refuses_edit(row, column) {
            return;
        }
        let input = match self.resolve_cell_preset(preset, row, column) {
            Some(Ok(input)) => input,
            Some(Err(message)) => {
                fx.output(BrowseTabOutput::ShowToast(message));
                return;
            }
            None => return,
        };
        self.edit_cell(row, column, input, fx);
    }

    fn duplicate_rows(&mut self, rows: &[RowObject], fx: &mut Effects) {
        if self.read_only || self.current_columns.is_empty() || self.grid_is_stale() || rows.is_empty() {
            return;
        }
        let ctx = self.grid_context();
        let copies = rows
            .iter()
            .map(|row| {
                // With its pending edits, since the copy is of the
                // row the user is looking at.
                let source = ctx.effective_inputs(row);
                // The duplicate is a new row, so values the database
                // owns (key, identity, generated) are left to it.
                self.current_columns
                    .iter()
                    .enumerate()
                    .map(|(i, col)| {
                        if col.primary_key || col.is_auto_increment || col.is_generated {
                            new_draft_cell(col)
                        } else {
                            source.get(i).cloned().unwrap_or(CellInput::Value(Value::Null))
                        }
                    })
                    .collect()
            })
            .collect();
        self.apply_edit(TrackerEdit::InsertDrafts { rows: copies }, fx);
        fx.input(EditInput::FocusInsertedDraft);
    }

    fn bulk_delete_answered(&mut self, ticket: u64, confirmed: bool, fx: &mut Effects) {
        // An answer to a confirmation the tab already cancelled
        // or replaced.
        if self
            .confirming_delete
            .as_ref()
            .is_none_or(|pending| pending.ticket != ticket)
        {
            return;
        }
        if !confirmed {
            self.confirming_delete = None;
            return;
        }
        self.rebase_confirming_delete(fx);
        if let Some(pending) = self.confirming_delete.take() {
            fx.input(EditInput::MarkRowsDeleted(pending.deletion));
        }
    }

    /// Checked again here because a keyboard shortcut or a late event
    /// can reach a locked cell.
    fn refuses_edit(&self, row: &RowObject, column: usize) -> bool {
        if self.grid_is_stale() {
            return true;
        }
        let Some(info) = self.current_columns.get(column) else {
            return true;
        };
        let locked = cell_editability(info, row.id(), &pk_identity(&self.current_columns), self.read_only);
        if let Err(lock) = locked {
            tracing::debug!(?lock, column, "refused an edit to a locked cell");
            return true;
        }
        false
    }

    /// Resolve a preset against the column it lands in. The menu offers
    /// only the ones the cell can take; the keyboard's Set NULL reaches
    /// here for any cell, and a column that refuses the value says why,
    /// as committing an empty cell would.
    fn resolve_cell_preset(
        &self,
        preset: CellPreset,
        row: &RowObject,
        col: usize,
    ) -> Option<Result<CellInput, String>> {
        let Some(column) = self.current_columns.get(col) else {
            tracing::error!(col, "a preset reached a column the tab does not have");
            return None;
        };
        let presets = cell_presets(column, row.id());
        Some(match preset {
            CellPreset::Empty => parse_edit_text("", column, edit_context(row.id()))
                .map_err(|error| crate::ui::error_text::edit_parse_message(&error)),
            CellPreset::Null if presets.null => Ok(CellInput::Value(Value::Null)),
            CellPreset::Null => Err(crate::ui::error_text::edit_parse_message(&EditParseError::Required)),
            CellPreset::Default if presets.default => Ok(CellInput::Default),
            CellPreset::Default => Err(crate::i18n::gettext("This cell can't take the column's default")),
        })
    }

    /// Apply what a tracker call changed: the draft rows the store gains
    /// or loses, then a redraw of each touched row, then the footer. A
    /// row keeps its object, so the selection and the focus stay on it.
    pub(super) fn apply_tracker_delta(&mut self, delta: &TrackerDelta, fx: &mut Effects) {
        if let Some(store) = self.list_store() {
            apply_draft_changes(&store, &mut self.row_index, delta);
        }
        for key in &delta.changed {
            if let Some(row) = self.row_index.get(key) {
                row.bump_revision();
            }
        }
        self.sync_pending_chrome(delta.pending_count, fx);
        self.sync_delete_action();
    }

    fn apply_edit(&mut self, edit: TrackerEdit, fx: &mut Effects) {
        if self.tracker.refuses(&edit) && !std::mem::replace(&mut fx.told_edit_held, true) {
            fx.output(BrowseTabOutput::ShowToast(crate::i18n::gettext(
                "This row is being saved. Change it again once the save finishes.",
            )));
        }
        let delta = self.tracker.apply(edit);
        self.apply_tracker_delta(&delta, fx);
    }

    /// A preset value for one cell, against the row the edit was made
    /// on, wherever it sits now.
    fn edit_cell(&mut self, row: &RowObject, col: usize, input: CellInput, fx: &mut Effects) {
        match (row.id(), input) {
            (GridRowId::Draft(draft_id), input) => {
                self.apply_edit(
                    TrackerEdit::DraftCell {
                        draft_id: *draft_id,
                        col,
                        input,
                    },
                    fx,
                );
            }
            (GridRowId::Persisted(row_key), CellInput::Value(value)) => {
                let Some(original) = row.cell(col).cloned() else {
                    return;
                };
                self.apply_edit(
                    TrackerEdit::Cell {
                        row_key: row_key.clone(),
                        col,
                        original,
                        value,
                    },
                    fx,
                );
            }
            (GridRowId::Persisted(_), CellInput::Default) | (GridRowId::Result | GridRowId::Unkeyed, _) => {}
        }
    }

    pub(super) fn refresh_crud_buttons(&self) {
        let has_columns = !self.current_columns.is_empty();
        let has_pk = self.has_primary_key();
        if self.read_only {
            self.widgets.insert_button.set_visible(false);
            self.actions.insert_row.set_enabled(false);
            return;
        }
        self.widgets.insert_button.set_visible(true);
        // No-PK tables don't get inline editing because RowKey can't be
        // formed without a PK. Disable instead of hide so the affordance
        // stays discoverable; the tooltip explains the gate.
        self.actions.insert_row.set_enabled(has_columns && has_pk);
        if has_columns && !has_pk {
            self.widgets.insert_button.set_tooltip_text(Some(&crate::i18n::gettext(
                "This table has no primary key. Inline editing is disabled.",
            )));
        } else {
            self.widgets
                .insert_button
                .set_tooltip_text(Some(&crate::i18n::gettext("Insert Row")));
        }
        self.refresh_banner_visibility();
    }

    /// Edit the first editable cell of the new draft, which is always
    /// the top row. Queued on idle so the inner-stack flip (empty to
    /// grid) has allocated the ScrolledWindow's adjustments before the
    /// grid scrolls: in the same tick GTK aborts with
    /// `gtk_list_base_update_adjustments: bounds.y == 0`.
    fn focus_inserted_draft(&self) {
        let Some(cv) = self.current_column_view.clone() else {
            return;
        };
        glib::idle_add_local_once(move || {
            // F5 between the insert and this idle detaches the column
            // view, and a failed read hides it behind the error page. The
            // row was inserted; only the edit is missed.
            if cv.is_mapped() {
                edit_row(&cv, 0);
            }
        });
    }

    /// Mark saved rows for deletion and drop drafts. Nothing leaves the
    /// tab until Save. The action is off for rows this cannot delete, so
    /// such rows reaching here is a bug, which changes nothing.
    fn delete_rows(&mut self, rows: &[RowObject], fx: &mut Effects) {
        if self.grid_is_stale() {
            return;
        }
        if self.read_only {
            tracing::error!("Delete reached a read-only tab");
            return;
        }
        let deletion = plan_row_deletion(rows);
        if deletion.unkeyed > 0 {
            tracing::error!(unkeyed = deletion.unkeyed, "Delete reached rows with no key");
            return;
        }
        if deletion.is_empty() {
            return;
        }
        if deletion.len() < BULK_DELETE_CONFIRM_THRESHOLD {
            fx.input(EditInput::MarkRowsDeleted(deletion));
            return;
        }
        self.confirm_delete(deletion);
    }

    fn confirm_delete(&mut self, deletion: RowDeletion) {
        let count = deletion.len();
        let title = crate::i18n::ngettext_f(
            "Delete {n} row?",
            "Delete {n} rows?",
            u32::try_from(count).unwrap_or(u32::MAX),
            &[("n", &count.to_string())],
        );
        let body = deletion.confirmation_body();
        let dialog = adw::AlertDialog::new(Some(&title), Some(&body));
        dialog.add_response("cancel", &crate::i18n::gettext("Cancel"));
        dialog.add_response("delete", &crate::i18n::gettext("Delete"));
        dialog.set_response_appearance("delete", adw::ResponseAppearance::Destructive);
        dialog.set_default_response(Some("cancel"));
        dialog.set_close_response("cancel");
        // A second Delete while one waits replaces it.
        self.cancel_confirming_delete();
        let ticket = self.next_confirmation;
        self.next_confirmation += 1;
        let tab = self.this.clone();
        dialog.connect_response(None, move |_, response| {
            if let Some(tab) = tab.upgrade() {
                tab.send(EditInput::BulkDeleteAnswered {
                    ticket,
                    confirmed: response == "delete",
                });
            }
        });
        dialog.present(Some(&self.widgets.inner_stack));
        self.confirming_delete = Some(ConfirmingDelete {
            ticket,
            deletion,
            columns: self.current_columns.clone(),
            dialog,
        });
    }

    fn cancel_confirming_delete(&mut self) {
        if let Some(pending) = self.confirming_delete.take() {
            pending.dialog.force_close();
        }
    }

    /// Moves a waiting delete's rows onto the columns the tab read
    /// since. A key read under another primary key can name another
    /// row, so then the delete is cancelled rather than sent with it.
    pub(super) fn rebase_confirming_delete(&mut self, fx: &mut Effects) {
        let Some(pending) = self.confirming_delete.as_mut() else {
            return;
        };
        if pending.columns == self.current_columns {
            return;
        }
        let layout = ColumnRelayout::new(&pending.columns, &self.current_columns);
        let moved: Option<Vec<(RowKey, Arc<[Value]>)>> = pending
            .deletion
            .persisted
            .iter()
            .map(|(key, values)| {
                layout
                    .key(key)
                    .ok()
                    .map(|()| (key.clone(), layout.fetched(values).into()))
            })
            .collect();
        match moved {
            Some(rows) => {
                pending.deletion.persisted = rows;
                pending.columns = self.current_columns.clone();
            }
            None => {
                self.cancel_confirming_delete();
                fx.output(BrowseTabOutput::ShowToast(crate::i18n::gettext(
                    "The table's primary key changed, so no rows were marked for deletion. Select them again.",
                )));
            }
        }
    }
}
