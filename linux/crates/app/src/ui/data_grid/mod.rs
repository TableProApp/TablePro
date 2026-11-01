//! The data grid every surface shows rows in: the table tab, the SQL
//! editor's results and a key-value engine's key tab.

mod client_sorter;
mod column_chooser;
mod columns;
mod copy;
mod edit;
mod find_bar;
mod grid_actions;
mod grid_cell;
mod grid_config;
mod grid_menu;
mod grid_request;
mod grid_row;
mod grid_store;
mod imp;
mod keys;
mod layout_binding;
mod pointer;
mod references;
mod reversed_list;
mod row_detail;
mod row_json_dialog;
mod row_number_column;
mod selection;
mod selection_summary;
mod server_sorter;
mod stripes;
mod table_keys;
#[cfg(test)]
pub(crate) mod test_grid;
#[cfg(test)]
mod tests;
mod tracked_values;

use std::sync::Arc;

use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use gtk4::{self as gtk, gio, glib};
use libadwaita as adw;
use tablepro_core::dialect::SqlDialect;

#[cfg(test)]
pub(crate) use self::column_chooser::ColumnChooser;
pub(crate) use self::edit::BULK_DELETE_CONFIRM_THRESHOLD;
pub(crate) use self::grid_cell::GridCell;
pub(crate) use self::grid_config::{DialectSource, EditRules, GridConfig, GridSorting};
pub(crate) use self::grid_request::GridRequest;
pub(crate) use self::grid_row::{GridRow, PinnedRow, RowData};
pub(crate) use self::grid_store::GridStore;
pub(crate) use self::layout_binding::LayoutBinding;
use self::reversed_list::ReversedList;
#[cfg(test)]
pub(crate) use self::row_detail::RowDetailPane;
pub(crate) use self::row_json_dialog::{RowJsonRequest, present_row_json};
pub(crate) use self::table_keys::{KeysHandle, TableKeys};
pub(crate) use self::tracked_values::{ServerValue, TrackedValues};
use crate::services::change_tracker::RowKey;
use crate::services::grid::GridColumn;
use crate::services::tracker_delta::TrackerDelta;
use crate::ui::export::ExportSource;

glib::wrapper! {
    pub struct DataGrid(ObjectSubclass<imp::DataGrid>)
        @extends adw::Bin, gtk::Widget,
        @implements gtk::Accessible, gtk::Buildable, gtk::ConstraintTarget;
}

impl DataGrid {
    pub fn new(config: GridConfig) -> Self {
        let grid: Self = glib::Object::new();
        let imp = grid.imp();
        let columns = config.columns.clone();
        let sorting = config.sorting;
        let rules = config.rules.clone();
        imp.column_view
            .update_property(&[gtk::accessible::Property::Label(&config.label)]);
        let _ = imp.config.set(config);
        grid.build_models();
        imp.edit.attach(&grid);
        grid.insert_action_group("grid", Some(&imp.actions));
        grid_actions::install(&grid);
        let _ = imp.menus.set(grid_menu::GridMenus::new(&grid));
        keys::install(&grid);
        pointer::install(&grid);
        row_number_column::install_row_factory(&grid);
        find_bar::install(&grid);
        imp.detail_pane.attach(&grid);
        grid.set_columns(columns, sorting, rules);
        grid.watch_fonts();
        grid.watch_stripes();
        grid
    }

    /// `None` only inside `glib::Object::new`, before `new` sets it.
    pub(crate) fn config(&self) -> Option<&GridConfig> {
        self.imp().config.get()
    }

    /// The connection's dialect, where the rows have an SQL spelling.
    pub(crate) fn sql_dialect(&self) -> Option<Arc<dyn SqlDialect>> {
        let dialect = (self.config()?.dialect.as_ref()?)()?;
        dialect.grammar().is_sql().then_some(dialect)
    }

    pub fn connect_request<F: Fn(&Self, GridRequest) + 'static>(&self, f: F) -> glib::SignalHandlerId {
        self.connect_closure(
            "request",
            false,
            // Each handler gets its own copy: a taken payload would reach
            // only the first.
            glib::closure_local!(move |grid: &Self, payload: glib::BoxedAnyObject| {
                let request = payload.borrow::<GridRequest>().clone();
                f(grid, request);
            }),
        )
    }

    pub fn connect_selection_changed<F: Fn(&Self) + 'static>(&self, f: F) -> glib::SignalHandlerId {
        self.connect_closure(
            "selection-changed",
            false,
            glib::closure_local!(move |grid: &Self| f(grid)),
        )
    }

    /// An inline or detail pane edit opened or closed. A host's Save stays
    /// on while one is open, so Ctrl+S reaches a first typed value.
    pub fn connect_editing_changed<F: Fn(&Self) + 'static>(&self, f: F) -> glib::SignalHandlerId {
        self.connect_closure(
            "editing-changed",
            false,
            glib::closure_local!(move |grid: &Self| f(grid)),
        )
    }

    pub fn is_editing(&self) -> bool {
        self.imp().editing.get()
    }

    pub(crate) fn set_editing(&self, editing: bool) {
        if self.imp().editing.replace(editing) != editing {
            self.refresh_actions();
            self.emit_by_name::<()>("editing-changed", &[]);
        }
    }

    pub(crate) fn request(&self, request: GridRequest) {
        self.emit_by_name::<()>("request", &[&glib::BoxedAnyObject::new(request)]);
    }

    pub(crate) fn toast(&self, text: impl Into<String>) {
        self.request(GridRequest::Toast(text.into()));
    }

    /// The `grid` actions, for a host to insert where its own buttons can
    /// reach them.
    pub fn actions(&self) -> gio::SimpleActionGroup {
        self.imp().actions.clone()
    }

    pub fn column_view(&self) -> gtk::ColumnView {
        self.imp().column_view.get()
    }

    pub fn selection(&self) -> gtk::MultiSelection {
        self.imp().selection.0.clone()
    }

    pub(crate) fn store(&self) -> &GridStore {
        &self.imp().store
    }

    pub(crate) fn edit(&self) -> &edit::EditController {
        &self.imp().edit
    }

    pub(crate) fn tracked(&self) -> TrackedValues {
        self.edit().tracked()
    }

    pub fn grid_columns(&self) -> Arc<[GridColumn]> {
        self.imp().columns.borrow().columns()
    }

    /// Build the columns for another column set, with what may change in
    /// its rows. The rows go, since they were read under the old columns.
    pub fn set_columns(&self, columns: Arc<[GridColumn]>, sorting: GridSorting, rules: Option<EditRules>) {
        self.commit_editors();
        self.store().clear();
        self.imp().summary.forget_column();
        self.edit().set_rules(self, rules);
        self.rebuild_columns(columns, sorting);
        self.show_rows_or_empty();
        self.refresh_actions();
    }

    /// Show `rows` under the drafts the tracker holds. The rows take the
    /// slots the grid has, and the selection and the focused cell follow
    /// their rows by key when the new rows hold them.
    pub fn replace_rows(&self, rows: Vec<RowData>, row_base: u64) {
        self.commit_editors();
        let restore = selection::Restore::capture(self);
        self.imp().row_base.set(row_base);
        let mut all = self.edit().draft_rows();
        all.extend(rows);
        self.write_rows(all);
        self.columns_took_rows();
        restore.apply(self);
        self.show_rows_or_empty();
        self.find_rows_changed();
        self.refresh_actions();
    }

    /// Add rows under the ones the grid holds, as Load More does.
    pub fn append_rows(&self, rows: Vec<RowData>) {
        self.store().append(rows);
        self.columns_took_rows();
        self.show_rows_or_empty();
        self.find_rows_changed();
        self.refresh_actions();
    }

    pub fn clear_rows(&self) {
        self.commit_editors();
        self.store().clear();
        self.show_rows_or_empty();
        self.refresh_actions();
    }

    pub fn row_count(&self) -> u32 {
        self.store().len()
    }

    pub fn selected_count(&self) -> u32 {
        self.selection().selection().size() as u32
    }

    pub(crate) fn row_base(&self) -> u64 {
        self.imp().row_base.get()
    }

    /// The placeholder shown while the grid holds no row.
    pub fn set_empty_text(&self, title: &str, description: Option<&str>) {
        let page = &self.imp().empty_page;
        page.set_title(title);
        page.set_description(description);
    }

    /// Commit the cell edit open in the grid or its detail pane, as Return
    /// does, so a save or a close counts what was typed.
    pub fn commit_edit(&self) {
        self.commit_editors();
    }

    /// Show what a tracker change outside the grid did: drafts come or go
    /// and changed rows draw again.
    pub fn apply_delta(&self, delta: &TrackerDelta) {
        self.edit().apply_delta(delta);
    }

    /// Bring the drafts and every row back in line with the tracker after
    /// a change whose delta was not kept, as a close prompt's Discard.
    pub fn resync(&self) {
        self.commit_editors();
        let saved: Vec<RowData> = self
            .store()
            .rows()
            .filter(|row| row.draft_id().is_none())
            .map(|row| row.data())
            .collect();
        let mut all = self.edit().draft_rows();
        all.extend(saved);
        self.write_rows(all);
        self.show_rows_or_empty();
        self.refresh_actions();
    }

    /// Commit the inline editor and the detail pane's, before any slot is
    /// written or the tracker is read.
    pub(crate) fn commit_editors(&self) {
        self.imp().detail_pane.commit_open_edit();
        self.edit().commit_open_edit();
    }

    pub fn undo(&self) {
        self.edit().undo();
    }

    pub fn redo(&self) {
        self.edit().redo();
    }

    pub fn discard(&self) {
        self.edit().discard();
    }

    /// Draw every row again after the tracker changed outside the grid,
    /// as a save settling does.
    pub fn redraw(&self) {
        for row in self.store().rows() {
            row.bump_revision();
        }
        self.refresh_actions();
    }

    /// Select, focus and scroll to the row `key` names, as a failed save
    /// does for the statement that failed. `false` when the grid does not
    /// hold it.
    pub fn reveal_row(&self, key: &RowKey) -> bool {
        let Some(row) = self.store().row_for(key) else {
            return false;
        };
        let Some(position) = self.view_position(&row) else {
            return false;
        };
        self.selection().select_item(position, true);
        self.column_view().scroll_to(
            position,
            None,
            gtk::ListScrollFlags::FOCUS | gtk::ListScrollFlags::SELECT,
            None,
        );
        row.bump_revision();
        true
    }

    /// The rows as the grid shows them, pending edits included, for an
    /// export of what the user is looking at.
    pub fn export_source(&self) -> ExportSource {
        copy::export_source(self)
    }

    /// Put the sort on the headers without asking for the rows again, as
    /// a restored tab does.
    pub fn set_sort(&self, sort: Option<(usize, bool)>) {
        self.apply_sort_quietly(sort);
    }

    /// Move the keyboard focus to the grid's focused cell, or its first.
    pub fn focus_rows(&self) -> bool {
        if self.store().is_empty() {
            return false;
        }
        self.column_view().grab_focus()
    }

    fn build_models(&self) {
        let imp = self.imp();
        let list: gio::ListModel = imp.store.list().clone().upcast();
        let sorting = self.config().map_or(GridSorting::None, |config| config.sorting);
        let model: gio::ListModel = match sorting {
            GridSorting::Client => {
                // At once rather than in steps, so a copy right after a
                // click takes the order on screen.
                let sorted = gtk::SortListModel::new(Some(list), None::<gtk::Sorter>);
                sorted.set_incremental(false);
                let shown = ReversedList::new(&sorted);
                let _ = imp.sort_model.set(sorted);
                let _ = imp.shown.set(shown.clone());
                shown.upcast()
            }
            GridSorting::Server { .. } | GridSorting::None => list,
        };
        let selection = &imp.selection.0;
        selection.set_model(Some(&model));
        selection.connect_selection_changed(glib::clone!(
            #[weak(rename_to = grid)]
            self,
            move |_, _, _| grid.selection_moved()
        ));
        imp.column_view.set_model(Some(selection));
        imp.store.list().connect_items_changed(glib::clone!(
            #[weak(rename_to = grid)]
            self,
            move |_, _, _, _| grid.show_rows_or_empty()
        ));
    }

    fn selection_moved(&self) {
        self.refresh_actions();
        self.imp().detail_pane.follow_focus();
        self.emit_by_name::<()>("selection-changed", &[]);
    }

    /// A sort model hears no write into a slot, so a grid that sorts what
    /// it holds takes new rows as new rows.
    fn write_rows(&self, rows: Vec<RowData>) {
        match self.imp().sort_model.get() {
            Some(_) => self.store().reset(rows),
            None => self.store().replace(rows),
        }
    }

    pub(crate) fn show_rows_or_empty(&self) {
        let imp = self.imp();
        imp.empty_page.set_visible(imp.store.is_empty());
    }
}
