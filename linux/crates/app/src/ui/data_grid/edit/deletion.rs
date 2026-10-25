use std::sync::Arc;

use libadwaita as adw;
use libadwaita::prelude::*;
use tablepro_core::{ColumnInfo, Value};

use super::{EditController, catalog_columns, on_answer};
use crate::i18n::{gettext, ngettext_f};
use crate::services::change_tracker::RowKey;
use crate::services::column_relayout::ColumnRelayout;
use crate::services::grid::{DeleteAvailability, GridRowId, delete_availability};
use crate::services::tracker_edit::TrackerEdit;
use crate::ui::data_grid::{DataGrid, GridRow};

/// A Delete of this many rows asks first, while Preferences say so.
pub(crate) const BULK_DELETE_CONFIRM_THRESHOLD: usize = 10;

/// The rows a Delete takes, each saved row with its cells as read.
#[derive(Debug, Clone, Default, PartialEq)]
pub(super) struct RowDeletion {
    pub(super) persisted: Vec<(RowKey, Arc<[Value]>)>,
    pub(super) drafts: Vec<u64>,
}

impl RowDeletion {
    /// `None` when a row has no key a DELETE could name it by.
    pub(super) fn plan(rows: &[GridRow]) -> Option<Self> {
        let mut deletion = Self::default();
        for row in rows {
            match row.id() {
                GridRowId::Draft(draft_id) => deletion.drafts.push(draft_id),
                GridRowId::Persisted(key) => deletion
                    .persisted
                    .push((key, row.cells().unwrap_or_else(|| Arc::from([])))),
                GridRowId::Unkeyed | GridRowId::Result => return None,
            }
        }
        Some(deletion)
    }

    pub(super) fn len(&self) -> usize {
        self.persisted.len() + self.drafts.len()
    }

    /// A draft goes at once with its undo history, so a set that holds
    /// one cannot be described as waiting for Save.
    pub(super) fn confirmation_body(&self) -> String {
        match (self.persisted.is_empty(), self.drafts.is_empty()) {
            (_, true) => gettext("These rows will be marked for deletion. They aren't removed until you click Save."),
            (true, false) => {
                gettext("These rows were never saved. They're removed now, and Undo won't bring them back.")
            }
            (false, false) => gettext(
                "Saved rows will be marked for deletion and aren't removed until you click Save. Rows never saved are removed now, and Undo won't bring them back.",
            ),
        }
    }
}

impl EditController {
    /// Mark saved rows for deletion and drop drafts. Nothing leaves the
    /// table until Save.
    pub(super) fn delete_rows(&self, grid: &DataGrid) {
        if self.policy().is_none_or(|policy| policy.delete.is_err()) {
            return;
        }
        let Some(target) = grid.target() else {
            return;
        };
        let ids: Vec<GridRowId> = target.rows.iter().map(GridRow::id).collect();
        if delete_availability(&ids, false) != DeleteAvailability::Available {
            return;
        }
        let Some(deletion) = RowDeletion::plan(&target.rows) else {
            return;
        };
        let asks = grid
            .config()
            .is_some_and(|config| config.settings.confirm_bulk_delete());
        match deletion.len() >= BULK_DELETE_CONFIRM_THRESHOLD && asks {
            true => self.confirm_delete(grid, deletion),
            false => self.mark_deleted(grid, deletion),
        }
    }

    fn mark_deleted(&self, grid: &DataGrid, deletion: RowDeletion) {
        grid.commit_editors();
        self.apply_edit(
            grid,
            TrackerEdit::DeleteRows {
                persisted: deletion.persisted,
                drafts: deletion.drafts,
            },
        );
        // A bulk action ends the selection it acted on.
        grid.selection().unselect_all();
    }

    fn confirm_delete(&self, grid: &DataGrid, deletion: RowDeletion) {
        let count = deletion.len();
        let title = ngettext_f(
            "Delete {n} Row?",
            "Delete {n} Rows?",
            u32::try_from(count).unwrap_or(u32::MAX),
            &[("n", &count.to_string())],
        );
        let dialog = adw::AlertDialog::new(Some(&title), Some(&deletion.confirmation_body()));
        dialog.add_response("cancel", &gettext("Cancel"));
        dialog.add_response("delete", &gettext("Delete"));
        dialog.set_response_appearance("delete", adw::ResponseAppearance::Destructive);
        dialog.set_default_response(Some("cancel"));
        dialog.set_close_response("cancel");
        let asked_under = catalog_columns(grid);
        let ticket = self.ask(&dialog);
        on_answer(grid, dialog, ticket, move |grid, response| {
            if response == "delete" {
                grid.edit().delete_confirmed(grid, deletion, asked_under.as_deref());
            }
        });
    }

    /// The rows are keyed by the primary key of the columns they were
    /// read under, so columns read while the question was open move them,
    /// or cancel the delete when the key changed.
    fn delete_confirmed(&self, grid: &DataGrid, mut deletion: RowDeletion, asked_under: Option<&[ColumnInfo]>) {
        let current = catalog_columns(grid);
        if let (Some(asked), Some(current)) = (asked_under, current.as_deref())
            && asked != current
        {
            let layout = ColumnRelayout::new(asked, current);
            let moved: Option<Vec<(RowKey, Arc<[Value]>)>> = deletion
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
                Some(rows) => deletion.persisted = rows,
                None => {
                    grid.toast(gettext(
                        "The table's primary key changed, so no rows were marked for deletion. Select them again.",
                    ));
                    return;
                }
            }
        }
        self.mark_deleted(grid, deletion);
    }
}
