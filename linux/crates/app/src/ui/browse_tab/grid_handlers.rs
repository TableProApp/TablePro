use gtk4::prelude::*;
use tablepro_core::browse::{ExportFields, ExportRequest, build_view_sql};

use super::{BrowseModel, BrowseTabOutput, Effects, GridInput, qualified};
use crate::i18n::gettext;
use crate::services::grid::{
    DeleteAvailability, EditPolicy, EditRefusal, GridRowId, delete_availability, edit_policy, selection_hint,
};
use crate::services::share_subject::ShareSubject;
use crate::services::share_table::TableShare;
use crate::ui::data_grid::{GridRequest, GridRow};
use crate::ui::export::{ExportOffer, ExportOrigin, ExportQuery, ExportSource};

/// What the grid asks of the tab, and the tab's chrome that follows it.
impl BrowseModel {
    pub(super) fn on_grid(&mut self, input: GridInput, fx: &mut Effects) {
        match input {
            GridInput::Request(request) => self.on_grid_request(request, fx),
            GridInput::SelectionChanged => self.sync_selection(),
            GridInput::EditingChanged => self.follow_tracker(),
            GridInput::Export => self.offer_export(None, fx),
            GridInput::Undo => self.grid.undo(),
            GridInput::Redo => self.grid.redo(),
        }
    }

    fn on_grid_request(&mut self, request: GridRequest, fx: &mut Effects) {
        match request {
            GridRequest::Sort(sort) => self.sort_by(sort, fx),
            GridRequest::Export(source) => self.offer_export(Some(source), fx),
            GridRequest::FollowReference(reference) => fx.output(BrowseTabOutput::FollowReference(reference)),
            GridRequest::FilterByValue(rule) => self.filter_strip.add_and_apply(rule),
            GridRequest::Toast(text) => fx.output(BrowseTabOutput::ShowToast(text)),
            GridRequest::Share(_) => self.offer_share(fx),
            GridRequest::PendingChanged => {
                self.sync_pending_chrome(self.tracker.pending_count(), fx);
                self.sync_selection();
            }
        }
    }

    /// What the grid may change in the table's rows, which the toolbar
    /// explains with the grid's own sentences.
    pub(super) fn edit_policy(&self) -> EditPolicy {
        edit_policy(self.read_only, self.has_primary_key(), !self.current_columns.is_empty())
    }

    pub(super) fn follow_tracker(&self) {
        self.actions
            .follow_tracker(&self.tracker, self.saving.get(), self.grid.is_editing());
    }

    /// A read-only tab hides Insert. A table without a key keeps it,
    /// greyed out, with the reason on its tooltip, so the affordance stays
    /// discoverable.
    pub(super) fn refresh_crud_buttons(&self) {
        let insert = &self.widgets.insert_button;
        insert.set_visible(!self.read_only);
        let reason = self.edit_policy().insert.err().and_then(EditRefusal::message);
        insert.set_tooltip_text(Some(&reason.unwrap_or_else(|| gettext("Insert Row"))));
        self.refresh_banner_visibility();
    }

    /// The count in the bottom bar and the Delete button's reason when it
    /// is off. GtkMultiSelection says nothing when a page takes the
    /// selected rows away, so a page and a load state come through here
    /// too. Rows behind an error page count as none.
    pub(super) fn sync_selection(&self) {
        let rows: Vec<GridRow> = match self.shown_page() {
            Some(_) => self.grid.selected_rows(),
            None => Vec::new(),
        };
        let policy = self.edit_policy();
        let hint = selection_hint(rows.len(), policy.delete);
        let label = &self.widgets.selection_label;
        label.set_label(hint.as_deref().unwrap_or_default());
        label.set_visible(hint.is_some());
        self.grid.selection_summary().set_visible(self.shown_page().is_some());
        let ids: Vec<GridRowId> = rows.iter().map(GridRow::id).collect();
        let blocked = match delete_availability(&ids, self.read_only) {
            DeleteAvailability::Unavailable(block) => block.explanation(),
            DeleteAvailability::Available => None,
        };
        let reason = blocked.or_else(|| policy.delete.err().and_then(EditRefusal::message));
        self.widgets
            .delete_button
            .set_tooltip_text(Some(&reason.unwrap_or_else(|| gettext("Delete Selected Rows"))));
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
            numbered: self
                .current_columns
                .iter()
                .filter(|column| column.is_auto_increment)
                .map(|column| column.name.clone())
                .collect(),
        }
    }

    /// Ask the window to export the page, as the grid shows it unless the
    /// grid's own Export hands it over, or every row the filter selects.
    /// Rows behind an error page are not what the table holds under the
    /// current filter, so they are never offered.
    pub(super) fn offer_export(&self, page: Option<ExportSource>, fx: &mut Effects) {
        let page = self
            .shown_page()
            .map(|_| page.unwrap_or_else(|| self.grid.export_source()));
        let (Some(page), Some(table)) = (page, self.table_export()) else {
            fx.output(BrowseTabOutput::ShowToast(gettext("Nothing to export")));
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
            name: qualified(self.schema.as_deref(), &self.table),
            target: Some(self.sql_target()),
        })));
    }

    // From the first row, as the tab filters and sorts it, read up to the plan's rows once the sheet knows them.
    pub(super) fn offer_share(&self, fx: &mut Effects) {
        let Some(export) = self.table_export() else {
            fx.output(BrowseTabOutput::ShowToast(gettext("Nothing to share")));
            return;
        };
        let view = ExportRequest {
            table: &export.table,
            columns: &export.columns,
            filter: &export.filter,
            sort: &export.sort,
            identity: &export.identity,
            fields: ExportFields::Listed,
        };
        let sql = self.dialect.as_deref().and_then(|dialect| {
            build_view_sql(dialect, &view)
                .inspect_err(|error| tracing::debug!(%error, "the table view has no SQL of its own"))
                .ok()
        });
        let no_sql = sql
            .is_none()
            .then(|| gettext("This view has no SQL of its own, so the link shares its rows without it."));
        let table = TableShare {
            session: self.session.clone(),
            table: export.table,
            columns: export.columns,
            shown: self.grid.shown_columns(),
            filter: export.filter,
            sort: export.sort,
            identity: export.identity,
            // An estimate would name a count no one made as the link's whole.
            total: self.total.exact(),
        };
        fx.output(BrowseTabOutput::Share(Box::new(ShareSubject {
            title: String::new(),
            sql: sql.unwrap_or_default(),
            dialect: Some(self.session.metadata().driver_id.clone()),
            rows: None,
            table: Some(table),
            no_sql,
        })));
    }
}
