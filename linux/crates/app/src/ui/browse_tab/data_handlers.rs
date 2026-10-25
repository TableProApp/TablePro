use std::sync::Arc;

use gtk4 as gtk;
use gtk4::glib;
use gtk4::prelude::*;
use tablepro_core::column::ResultColumn;
use tablepro_core::sql_syntax::SqlGrammar;
use tablepro_core::sql_syntax::mongo::is_addressable_field;
use tablepro_core::{ColumnInfo, QueryResult};
use tablepro_session::LinkGeneration;

use super::columns_fetch::ColumnFreshness;
use super::{BrowseModel, BrowseTabOutput, DataInput, Effects, PageReply, PageState, PageView, loading_description};
use crate::services::change_tracker::pk_identity;
use crate::services::grid::{GridColumn, RowKeyBuilder, grid_columns};
use crate::services::save_batch::SaveTarget;
use crate::ui::data_grid::{EditRules, RowData};
use crate::ui::tab_load::{ContentPage, LoadFailure, LoadPresentation};

impl BrowseModel {
    pub(super) fn on_data(&mut self, input: DataInput, fx: &mut Effects) {
        match input {
            DataInput::Start => {
                self.refresh_crud_buttons();
                self.refresh_pending_bar(0);
                // A saved filter shows on the button before the first page
                // returns.
                self.refresh_filter_chrome();
                // DDL from the SQL editor or another client never reaches
                // the catalog, so a tab that opens asks the server.
                self.begin_read(fx);
                self.reload_from_columns(ColumnFreshness::Refetch);
            }
            DataInput::Command(command) => self.on_command(command, fx),
            DataInput::LinkChanged(generation) => self.on_link_changed(generation, fx),
            DataInput::SchemaChanged => {
                self.begin_read(fx);
                self.stop_count(true);
                self.reload_from_columns(ColumnFreshness::Cached);
            }
        }
    }

    /// The session reconnected. Reads that failed are asked again on the
    /// new connection; a tab whose reads all landed keeps its rows.
    fn on_link_changed(&mut self, generation: LinkGeneration, fx: &mut Effects) {
        if generation <= self.link_generation {
            return;
        }
        self.link_generation = generation;
        self.dialect = self.session.current_dialect();
        self.filter_strip.set_dialect(self.dialect.clone());
        if !self.sorts_rows() {
            self.current_sort = None;
            self.grid.set_sort(None);
        }
        self.retry_failed(fx);
    }

    /// A read of the page the tab asks for starts. Rows read under the
    /// same filter, sort and offset stay through a failure; rows of
    /// another page do not, since they are not what the tab shows.
    pub(super) fn begin_read(&mut self, fx: &mut Effects) {
        let presentation = match self.shown_view.as_ref() == Some(&self.page_view()) {
            true => self.load.begin(),
            false => self.load.begin_replacing(),
        };
        self.present(presentation, fx);
    }

    /// Put the read's state on screen: the spinner, the grid or the
    /// error page, the banner over rows that could not be read again,
    /// and the tab bar's spinner.
    pub(super) fn present(&mut self, presentation: LoadPresentation, fx: &mut Effects) {
        let content_had_focus =
            std::mem::take(&mut self.content_had_focus) || crate::ui::a11y::holds_focus(&self.widgets.inner_stack);
        match &presentation.page {
            ContentPage::Spinner => {
                self.content_had_focus = content_had_focus;
                self.show_loading();
            }
            ContentPage::Content => self.widgets.inner_stack.set_visible_child_name("grid"),
            ContentPage::Error(failure) => {
                let message = failure.message();
                // The status page reads its description as markup.
                self.widgets
                    .error_page
                    .set_description(Some(&glib::markup_escape_text(&message)));
                // The page takes the place of the rows the focus was in, so
                // the focus goes to Try Again and the reason is said.
                self.widgets.inner_stack.set_visible_child_name("error");
                if content_had_focus && let Some(retry) = self.widgets.error_page.child() {
                    retry.grab_focus();
                }
                crate::ui::a11y::announce(
                    &self.widgets.error_page,
                    &format!("{}. {message}", self.widgets.error_page.title()),
                    gtk::AccessibleAnnouncementPriority::High,
                );
            }
        }
        self.widgets.stale_banner.show(presentation.stale.as_ref());
        self.show_grid_actions();
        self.sync_pager_buttons();
        self.sync_total_chrome();
        self.sync_selection();
        if self.tab_loading != presentation.tab_loading {
            self.tab_loading = presentation.tab_loading;
            fx.output(BrowseTabOutput::LoadingChanged(presentation.tab_loading));
        }
    }

    /// The grid's actions reach the tab's buttons only while its rows are
    /// on screen: rows behind the loading or the error page are not what
    /// the table holds under the tab's filter.
    fn show_grid_actions(&mut self) {
        let shown = self.load.has_content();
        if self.grid_actions_shown == shown {
            return;
        }
        self.grid_actions_shown = shown;
        if let Some(tab) = self.this.upgrade() {
            let actions = shown.then(|| self.grid.actions());
            tab.insert_action_group("grid", actions.as_ref());
        }
    }

    /// Reveal at most ONE banner at a time. Read-only takes priority
    /// over no-PK because read-only blocks every kind of edit.
    pub(super) fn refresh_banner_visibility(&self) {
        let read_only = self.read_only;
        let no_pk = !self.current_columns.is_empty() && !self.current_columns.iter().any(|c| c.primary_key);
        self.widgets.read_only_banner.set_revealed(read_only);
        self.widgets.no_pk_banner.set_revealed(!read_only && no_pk);
    }

    fn show_loading(&self) {
        self.widgets
            .loading_page
            .set_description(Some(&loading_description(&self.table_label())));
        self.widgets.inner_stack.set_visible_child_name("loading");
    }

    /// A read failed. Rows read again for the same page stay, under the
    /// banner; with no rows, or rows of another page, the error page says
    /// why. The paginator stays, so the user can go back.
    pub(super) fn on_load_failed(&mut self, failure: LoadFailure, fx: &mut Effects) {
        let presentation = self.load.fail(failure);
        self.present(presentation, fx);
    }

    pub(super) fn on_columns_loaded(&mut self, columns: Vec<ColumnInfo>, fx: &mut Effects) {
        if self.current_columns != columns {
            self.page = None;
            self.shown_view = None;
            self.pager.forget_paging_states();
            self.current_columns = columns.clone();
            // The grid takes the new columns before the tracker does, so an
            // edit still open is filed under the columns it was typed in.
            // A page read under the old ones would put their names in the
            // headers, so the rows wait for the page read under these.
            let catalog: Vec<ResultColumn> = columns.iter().map(ColumnInfo::result_column).collect();
            self.show_columns(self.grid_columns_for(&catalog));
            let presentation = self.load.drop_content();
            self.present(presentation, fx);
        }
        let delta = self.tracker.set_target(SaveTarget {
            table: self.table_ref(),
            columns: columns.clone(),
        });
        self.grid.apply_delta(&delta);
        self.refresh_crud_buttons();
        // Operator lists narrow per type, so the strip rebuilds against
        // the new columns.
        self.filter_strip.set_columns(columns);
        self.render_grid_if_ready(fx);
    }

    /// Take the page apart into rows the grid owns. Each row's cells
    /// move into it, and the identity cells after them name the row and
    /// are dropped, so nothing past the visible columns reaches a copy
    /// or an export.
    pub(super) fn on_rows_loaded(&mut self, offset: u64, reply: PageReply, fx: &mut Effects) {
        let PageReply {
            position,
            result,
            layout,
            edges,
            seeks,
        } = reply;
        self.pager.land(offset, position, edges, seeks);
        let QueryResult { columns, rows, .. } = result;
        // The tracker saves a row by its primary key, so that is what
        // names it here too.
        let keys = RowKeyBuilder::for_page(&pk_identity(&self.current_columns), &self.current_columns, &layout);
        let row_count = rows.len();
        let visible_end = layout.visible.end;
        let rows: Vec<RowData> = rows
            .into_iter()
            .map(|mut cells| {
                let identity = cells.split_off(visible_end.min(cells.len()));
                let key = keys.as_ref().and_then(|keys| keys.key_for(&cells, &identity));
                RowData::persisted(key, cells.into())
            })
            .collect();
        let visible = columns.get(layout.visible.clone()).unwrap_or_default();
        self.show_columns(self.grid_columns_for(visible));
        self.page = Some(PageState {
            row_count,
            start_ordinal: offset,
            filtered: !self.current_filter.is_empty(),
        });
        self.shown_view = Some(self.page_view());
        self.show_page(rows, offset, fx);
    }

    fn page_view(&self) -> PageView {
        PageView {
            filter: self.current_filter.clone(),
            sort: self.current_sort,
            offset: self.pager.start_ordinal(),
            limit: self.pager.page_size(),
        }
    }

    /// The grid's columns for `result`, each with the catalogue entry at
    /// its place. A document's field whose name a filter, a sort or an
    /// update cannot spell takes none of them (ADR 0026).
    fn grid_columns_for(&self, result: &[ResultColumn]) -> Arc<[GridColumn]> {
        let documents = self
            .dialect
            .as_ref()
            .is_some_and(|dialect| dialect.grammar() == SqlGrammar::Mongo);
        grid_columns(result, &self.current_columns, |name| {
            !documents || is_addressable_field(name)
        })
    }

    /// Give the grid `columns` when it shows others. Its rows go with the
    /// columns they were read under.
    fn show_columns(&self, columns: Arc<[GridColumn]>) {
        if *self.grid.grid_columns() == *columns {
            return;
        }
        let rules = EditRules {
            identity: pk_identity(&self.current_columns),
            policy: self.edit_policy(),
        };
        self.grid.set_columns(columns, self.grid_sorting(), Some(rules));
    }

    /// The columns came back the same, so the page on screen still
    /// stands under them: only the chrome follows.
    fn render_grid_if_ready(&mut self, fx: &mut Effects) {
        if self.page.is_none() {
            return;
        }
        self.refresh_grid_chrome();
        fx.output(BrowseTabOutput::StateChanged);
    }

    /// Put a page's rows on screen. They take the slots the grid has, so
    /// no row or cell widget is built again, and the selection and the
    /// focused cell stay on their rows by key.
    fn show_page(&mut self, rows: Vec<RowData>, row_base: u64, fx: &mut Effects) {
        self.grid.replace_rows(rows, row_base);
        self.refresh_grid_chrome();
        let presentation = self.load.succeed();
        self.present(presentation, fx);
        fx.output(BrowseTabOutput::StateChanged);
    }

    /// Paginator label, button sensitivity and stack child: chrome that
    /// depends on the page but not the column structure.
    fn refresh_grid_chrome(&self) {
        self.refresh_crud_buttons();
        self.sync_pager_buttons();
        self.sync_total_chrome();
        self.suppress_combo_emit.set(false);
    }
}
