use gtk4::prelude::*;

use super::{BrowseModel, BrowseTabOutput, ClipboardInput, Effects, qualified};
use crate::ui::clipboard::{CopyKind, CopyRequest, InsertCopy, InsertRow};
use crate::ui::export::{ExportOffer, ExportOrigin, ExportQuery, ExportSource};
use crate::ui::grid::{GridRowId, RowObject, RowSnapshot, export_snapshot};

impl BrowseModel {
    pub(super) fn on_clipboard(&self, input: ClipboardInput, fx: &mut Effects) {
        match input {
            ClipboardInput::Export(page) => self.offer_export(page, fx),
            ClipboardInput::GridCopy(request) => fx.output(BrowseTabOutput::Copy(request)),
            ClipboardInput::GridCopyRowsAsInsert(rows) => {
                if !self.grid_is_stale() {
                    self.copy_rows_as_insert(&rows, fx);
                }
            }
            ClipboardInput::GridCopyInClause(values) => match self.session.current_dialect() {
                Some(dialect) => fx.output(BrowseTabOutput::Copy(CopyRequest::InClause { dialect, values })),
                None => fx.output(BrowseTabOutput::ShowToast(crate::i18n::gettext(
                    "Connect to a database first.",
                ))),
            },
            ClipboardInput::CopySelectedRowsAsTsv => self.copy_selected_rows(fx),
            ClipboardInput::PasteNotSupported => {
                fx.output(BrowseTabOutput::ShowToast(crate::i18n::gettext(
                    "Pasting rows isn't supported yet",
                )));
            }
            ClipboardInput::GridShowRowJson(request) => fx.output(BrowseTabOutput::ShowRowJson(request)),
            ClipboardInput::GridShowToast(message) => fx.output(BrowseTabOutput::ShowToast(message)),
            ClipboardInput::GridFollowReference(reference) => fx.output(BrowseTabOutput::FollowReference(reference)),
        }
    }

    /// The table a browse tab's rows came from, so an export can
    /// write them back as `INSERT` statements.
    fn sql_target(&self) -> crate::ui::export::dialog::SqlTarget {
        crate::ui::export::dialog::SqlTarget {
            table: self.table_ref(),
            generated: self
                .current_columns
                .iter()
                .filter(|column| column.is_generated)
                .map(|column| column.name.clone())
                .collect(),
        }
    }

    fn export_name(&self) -> String {
        qualified(self.schema.as_deref(), &self.table)
    }

    /// The page the paginator's Export button writes: the grid's rows,
    /// so it matches the context menu's Export row for row.
    fn export_payload(&self) -> Option<ExportSource> {
        let page = self.shown_page()?;
        let rows = self
            .current_column_view
            .as_ref()
            .map(|column_view| export_snapshot(column_view, &self.grid_context()))
            .unwrap_or_default();
        Some(ExportSource::Rows {
            columns: page.result_columns.clone(),
            rows,
        })
    }

    /// Ask the window to export the page, or every row the filter
    /// selects. Rows behind an error page are not what the table holds
    /// under the current filter, so they are never offered.
    fn offer_export(&self, page: Option<ExportSource>, fx: &mut Effects) {
        let page = match (self.shown_page(), page) {
            (Some(_), Some(page)) => Some(page),
            (Some(_), None) => self.export_payload(),
            (None, _) => None,
        };
        let (Some(page), Some(table)) = (page, self.table_export()) else {
            fx.output(BrowseTabOutput::ShowToast(crate::i18n::gettext("Nothing to export")));
            return;
        };
        fx.output(BrowseTabOutput::Export(Box::new(ExportOffer {
            origin: ExportOrigin::Browse {
                page,
                query: ExportQuery::Table(table),
                total: self.total.clone(),
                has_unsaved_changes: self.tracker.pending_count() > 0,
            },
            session: Some(self.session.clone()),
            name: self.export_name(),
            target: Some(self.sql_target()),
        })));
    }

    /// Each row as an INSERT for the server the tab is connected to,
    /// pending edits included. A draft's is the INSERT its save would
    /// run, so the columns the server fills stay out of it.
    fn copy_rows_as_insert(&self, rows: &[RowObject], fx: &mut Effects) {
        let Some(dialect) = self.session.current_dialect() else {
            fx.output(BrowseTabOutput::ShowToast(crate::i18n::gettext(
                "Connect to a database first.",
            )));
            return;
        };
        fx.output(BrowseTabOutput::Copy(CopyRequest::Insert(InsertCopy {
            dialect,
            table: self.table_ref(),
            columns: self.current_columns.iter().cloned().collect(),
            rows: self.insert_rows(rows),
        })));
    }

    /// The rows an INSERT copy renders off the GTK thread. A saved row
    /// shares the page's cells; only a draft's are copied here.
    pub(super) fn insert_rows(&self, rows: &[RowObject]) -> Vec<InsertRow> {
        let ctx = self.grid_context();
        rows.iter()
            .map(|row| match row.id() {
                GridRowId::Draft(draft_id) => InsertRow::Draft(
                    self.tracker
                        .draft_cells(*draft_id, &self.current_columns)
                        .unwrap_or_default(),
                ),
                _ => InsertRow::Saved(ctx.snapshot(row)),
            })
            .collect()
    }

    /// Same request as the context menu's Copy As > Rows: one selection
    /// cannot produce two different clipboard payloads.
    fn copy_selected_rows(&self, fx: &mut Effects) {
        let (Some(selection), Some(_)) = (self.current_selection.as_ref(), self.shown_page()) else {
            return;
        };
        let ctx = self.grid_context();
        let rows: Vec<RowSnapshot> = crate::ui::grid::selected_positions(selection)
            .iter()
            .filter_map(|position| selection.item(*position).and_downcast::<RowObject>())
            .map(|row| ctx.snapshot(&row))
            .collect();
        if rows.is_empty() {
            return;
        }
        fx.output(BrowseTabOutput::Copy(CopyRequest::Rows {
            columns: result_columns(&self.current_columns),
            rows,
            kind: CopyKind::Rows,
        }));
    }
}

/// The result-column view of a catalogue column list, for a result the
/// grid renders from the schema it already has.
fn result_columns(columns: &[tablepro_core::ColumnInfo]) -> std::sync::Arc<[tablepro_core::column::ResultColumn]> {
    columns.iter().map(|column| column.result_column()).collect()
}
