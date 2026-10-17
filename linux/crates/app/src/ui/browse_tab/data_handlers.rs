use std::sync::Arc;

use gtk4 as gtk;
use gtk4::glib;
use gtk4::prelude::*;
use tablepro_core::{ColumnInfo, QueryResult};
use tablepro_session::LinkGeneration;

use super::browse_actions::install_grid_shortcuts;
use super::columns_fetch::ColumnFreshness;
use super::selection_handlers::{selected_rows, show_delete_availability, update_selection_chrome};
use super::{BrowseModel, BrowseTabOutput, DataInput, Effects, PageReply, PageState, PageView, loading_description};
use crate::services::change_tracker::pk_identity;
use crate::services::save_batch::SaveTarget;
use crate::ui::grid::{
    GridContent, GridRowIndex, GridSorting, RowKeyBuilder, RowObject, build_column_view, data_columns,
};
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
                self.capture_selection();
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
        self.sync_pager_buttons();
        self.sync_total_chrome();
        self.sync_delete_action();
        if self.tab_loading != presentation.tab_loading {
            self.tab_loading = presentation.tab_loading;
            fx.output(BrowseTabOutput::LoadingChanged(presentation.tab_loading));
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
        self.pending_restore = None;
        let presentation = self.load.fail(failure);
        self.present(presentation, fx);
    }

    pub(super) fn on_columns_loaded(&mut self, columns: Vec<ColumnInfo>, fx: &mut Effects) {
        // A page read under other columns would put their names in the
        // headers, so the grid waits for the page read under these.
        if self.current_columns != columns {
            self.page = None;
            self.shown_view = None;
            self.drop_grid(fx);
        }
        self.current_columns = columns.clone();
        self.rebase_confirming_delete(fx);
        let delta = self.tracker.set_target(SaveTarget {
            table: self.table_ref(),
            columns: columns.clone(),
        });
        self.apply_tracker_delta(&delta, fx);
        self.refresh_crud_buttons();
        // Operator lists narrow per type, so the strip rebuilds against
        // the new columns.
        self.filter_strip.set_columns(columns);
        self.render_grid_if_ready(fx);
    }

    /// Take the page apart into rows the store owns. Each row's cells
    /// move into it, and the identity cells after them name the row and
    /// are dropped, so nothing past the visible columns reaches a copy
    /// or an export. The tab's drafts stay on top.
    pub(super) fn on_rows_loaded(&mut self, offset: u64, reply: PageReply, fx: &mut Effects) {
        self.pager.go_to(offset);
        let PageReply { result, layout, .. } = reply;
        let QueryResult { columns, rows, .. } = result;
        // The tracker saves a row by its primary key, so that is what
        // names it here too.
        let keys = RowKeyBuilder::for_page(&pk_identity(&self.current_columns), &self.current_columns, &layout);
        let row_count = rows.len();
        let drafts = self.tracker.drafts();
        let mut objects = Vec::with_capacity(drafts.len() + row_count);
        objects.extend(drafts.iter().rev().map(|draft| RowObject::draft(draft.draft_id)));
        let visible_end = layout.visible.end;
        objects.extend(rows.into_iter().map(|mut cells| {
            let identity = cells.split_off(visible_end.min(cells.len()));
            let key = keys.as_ref().and_then(|keys| keys.key_for(&cells, &identity));
            RowObject::persisted(key, cells.into())
        }));
        let result_columns = match columns.len() == layout.visible.len() {
            true => columns,
            false => columns.get(layout.visible.clone()).map(Arc::from).unwrap_or_default(),
        };
        self.page = Some(PageState {
            result_columns,
            row_count,
            start_ordinal: offset,
        });
        self.shown_view = Some(self.page_view());
        self.show_page(objects, fx);
    }

    fn page_view(&self) -> PageView {
        PageView {
            filter: self.current_filter.clone(),
            sort: self.current_sort,
            offset: self.pager.start_ordinal(),
            limit: self.pager.page_size(),
        }
    }

    /// The columns came back the same, so the page on screen still
    /// stands under them: only the chrome follows.
    fn render_grid_if_ready(&mut self, fx: &mut Effects) {
        if self.page.is_none() || !self.column_view_matches_current_columns() {
            return;
        }
        self.refresh_grid_chrome();
        fx.output(BrowseTabOutput::StateChanged);
    }

    /// Put a page's rows on screen. Under the same columns the store
    /// takes them in one splice, which the column view sees as a single
    /// change; otherwise the view is built for them.
    fn show_page(&mut self, rows: Vec<RowObject>, fx: &mut Effects) {
        let Some(page) = self.page.as_ref() else {
            return;
        };
        if self.column_view_matches_current_columns()
            && let Some(store) = self.list_store()
        {
            store.splice(0, store.n_items(), &rows);
            self.reindex_rows();
            self.sync_selection();
            self.refresh_grid_chrome();
            let presentation = self.load.succeed();
            self.present(presentation, fx);
            self.restore_selection();
            fx.output(BrowseTabOutput::StateChanged);
            return;
        }

        clear_box(&self.widgets.grid_holder);
        let content = GridContent {
            columns: page.result_columns.clone(),
            rows,
        };
        let (column_view, selection) = build_column_view(
            content,
            &self.current_columns,
            self.grid_sink.clone(),
            GridSorting::Server {
                initial: self.current_sort,
            },
            self.grid_context(),
        );
        // A screen reader names the grid as the tab does.
        column_view.update_property(&[gtk::accessible::Property::Label(&self.table_label())]);
        self.current_selection = Some(selection);
        self.current_column_view = Some(column_view.clone());
        self.view_columns = data_columns(&column_view);
        self.rendered_columns = self.current_columns.clone();

        // The selection model is new per rebuild, so the previous
        // handler goes with the old one. The tab holds the selection, so
        // the handler holds the tab's widgets weakly.
        if let Some(sel) = self.current_selection.as_ref() {
            let label = self.widgets.selection_label.downgrade();
            let button = self.widgets.delete_button.downgrade();
            let actions = self.actions.clone();
            let read_only = self.read_only;
            sel.connect_selection_changed(move |sel, _, _| {
                let (Some(label), Some(button)) = (label.upgrade(), button.upgrade()) else {
                    return;
                };
                let n = u32::try_from(sel.selection().size()).unwrap_or(u32::MAX);
                update_selection_chrome(&label, n);
                actions.follow_selection(n);
                show_delete_availability(&actions.delete_rows, &button, &selected_rows(sel), read_only);
            });
        }
        install_grid_shortcuts(&column_view);

        self.reindex_rows();
        self.sync_selection();

        let scrolled = gtk::ScrolledWindow::builder()
            .child(&column_view)
            .hexpand(true)
            .vexpand(true)
            .build();
        self.widgets.grid_holder.append(&scrolled);
        self.refresh_grid_chrome();
        let presentation = self.load.succeed();
        self.present(presentation, fx);
        self.restore_selection();
        fx.output(BrowseTabOutput::StateChanged);
    }

    /// The grid was built for columns the table no longer has, so it
    /// goes before a click or a key in it lands on a moved column.
    fn drop_grid(&mut self, fx: &mut Effects) {
        if self.current_column_view.take().is_none() {
            return;
        }
        clear_box(&self.widgets.grid_holder);
        self.current_selection = None;
        self.view_columns.clear();
        self.rendered_columns.clear();
        self.row_index = GridRowIndex::default();
        self.pending_restore = None;
        self.sync_selection();
        let presentation = self.load.drop_content();
        self.present(presentation, fx);
    }

    fn reindex_rows(&mut self) {
        match self.list_store() {
            Some(store) => self.row_index.rebuild(&store),
            None => self.row_index = GridRowIndex::default(),
        }
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

fn clear_box(b: &gtk::Box) {
    while let Some(child) = b.first_child() {
        b.remove(&child);
    }
}
