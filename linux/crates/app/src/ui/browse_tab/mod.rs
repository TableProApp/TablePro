//! A table's rows in a workspace tab.
//!
//! The tab reads its own columns, pages and row count through the
//! session, one request of each kind at a time: a newer request stops
//! the one it replaces, and a reply to a replaced request is dropped.
//! A read that failed is asked again once the session reconnects. A
//! count is not: it runs only when the estimate or the user asks.

mod browse_actions;
mod browse_command;
mod browse_pager;
mod browse_request_kind;
mod column_recheck;
mod columns_fetch;
mod confirming_delete;
mod count_failure_text;
mod count_policy;
mod fetch;
mod imp;
#[cfg(test)]
mod load_tests;
mod page_reply;
mod page_state;
mod row_count;
mod row_deletion;
mod row_total;
mod selection_snapshot;
#[cfg(test)]
mod tests;
#[cfg(test)]
mod total_tests;

use std::cell::Cell;
use std::collections::{BTreeSet, VecDeque};
use std::rc::Rc;
use std::sync::Arc;

use gtk4 as gtk;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use gtk4::{gio, glib};
use libadwaita as adw;
use libadwaita::prelude::*;
use tablepro_core::dialect::SqlDialect;
use tablepro_core::edit::{CellInput, EditParseError, parse_edit_text};
use tablepro_core::meta::{PagePosition, RowIdentity, TableRef};
use tablepro_core::{ColumnInfo, QueryResult, Value};
use tablepro_session::operation::DeadlinePolicy;
use tablepro_session::runtime::{Tasks, WatchForwarder};
use tablepro_session::{LinkGeneration, Session};

use self::browse_actions::BrowseActions;
pub(crate) use self::browse_command::{BrowseCommand, ColumnsReply};
use self::browse_pager::BrowsePager;
pub(crate) use self::browse_request_kind::BrowseRequestKind;
use self::column_recheck::ColumnRecheck;
use self::columns_fetch::ColumnFreshness;
use self::confirming_delete::ConfirmingDelete;
pub(crate) use self::page_reply::PageReply;
use self::page_state::PageState;
use self::row_deletion::{RowDeletion, plan_row_deletion};
pub(crate) use self::row_total::RowTotal;
use self::selection_snapshot::SelectionSnapshot;
use super::format::format_thousands;
use super::grid::{
    CellPreset, ColumnWidthBinding, DeleteAvailability, GridContent, GridMsg, GridRowId, GridRowIndex, GridSink,
    GridSorting, RowJsonRequest, RowKeyBuilder, RowObject, RowSnapshot, TabGridContext, build_column_view,
    cell_editability, cell_presets, data_columns, delete_availability, edit_context, edit_row, export_snapshot,
    present_row_json,
};
use super::tab_load::{ContentLoad, ContentPage, LoadFailure, LoadPresentation, StaleBanner};
use crate::runtime::{FailedRequests, RequestSequencer};
use crate::services::change_origins::ChangeOrigins;
use crate::services::change_tracker::{RowKey, StatementSource, new_draft_cell, pk_identity};
use crate::services::column_relayout::ColumnRelayout;
use crate::services::save_batch::SaveTarget;
use crate::services::tab_tracker_handle::TabTrackerHandle;
use crate::services::tracker_delta::TrackerDelta;
use crate::services::tracker_edit::TrackerEdit;
use crate::ui::clipboard::{CopyKind, CopyRequest, InsertCopy, InsertRow};
use crate::ui::export::{ExportOffer, ExportOrigin, ExportQuery, ExportSource};

const PAGE_SIZE_OPTIONS: &[u64] = &[100, 500, 1_000, 5_000, 10_000];
const DEFAULT_PAGE_SIZE: u64 = 1_000;
/// Bulk-delete safety net: when the user marks at least this many
/// rows pending-delete in one shot, surface a confirmation dialog
/// before tracking. The marker is reversible via Discard / Ctrl+Z,
/// but a 200-row Ctrl+A → Delete sequence is destructive enough at
/// a glance that an explicit confirmation matches GNOME Files'
/// "Delete N items?" pattern.
const BULK_DELETE_CONFIRM_THRESHOLD: usize = 10;

glib::wrapper! {
    pub struct BrowseTab(ObjectSubclass<imp::BrowseTab>)
        @extends adw::Bin, gtk::Widget,
        @implements gtk::Accessible, gtk::Buildable, gtk::ConstraintTarget;
}

pub struct BrowseTabInit {
    pub tracker: TabTrackerHandle,
    pub schema: Option<String>,
    pub table: String,
    pub connection_id: Option<uuid::Uuid>,
    pub read_only: bool,
    pub page_size: u64,
    pub initial_offset: u64,
    pub initial_sort: Option<(usize, bool)>,
    pub column_widths: crate::persistence::ColumnWidthStore,
    pub filter_settings: crate::persistence::FilterSettingsStore,
    /// The session the tab reads through. The tab belongs to it and is
    /// closed before it shuts down.
    pub session: Arc<Session>,
    pub tasks: Tasks,
    /// The session's deadlines, which a count that ran out names.
    pub deadlines: Arc<dyn DeadlinePolicy>,
}

impl BrowseTab {
    pub fn new(init: BrowseTabInit) -> Self {
        let tab: Self = glib::Object::new();
        let imp = tab.imp();

        // Restore the saved filter for this (connection, schema, table)
        // up front so both the model and the inline strip start with the
        // same FilterSet.
        let initial_filter = init
            .connection_id
            .map(|id| init.filter_settings.filters(id, init.schema.as_deref(), &init.table))
            .unwrap_or_default();
        let table_label = qualified(init.schema.as_deref(), &init.table);
        imp.loading_page.set_description(Some(&crate::i18n::gettext_f(
            "Fetching rows from {table}",
            &[("table", &table_label)],
        )));
        imp.inner_stack.set_visible_child_name("loading");
        imp.read_only_banner.set_revealed(init.read_only);

        let page_size_labels: Vec<String> = PAGE_SIZE_OPTIONS.iter().map(|n| format_thousands(*n)).collect();
        let page_size_strs: Vec<&str> = page_size_labels.iter().map(String::as_str).collect();
        imp.page_size_dropdown
            .set_model(Some(&gtk::StringList::new(&page_size_strs)));
        let initial_idx = PAGE_SIZE_OPTIONS
            .iter()
            .position(|n| *n == init.page_size)
            .unwrap_or_else(|| {
                PAGE_SIZE_OPTIONS
                    .iter()
                    .position(|n| *n == DEFAULT_PAGE_SIZE)
                    .unwrap_or(2)
            });
        imp.page_size_dropdown
            .set_selected(u32::try_from(initial_idx).unwrap_or_default());

        // Filter strip: an inline editor that slides down above the grid.
        // It lives in this tab so the user's in-progress rules survive a
        // click into a cell or the SQL editor.
        let on_apply_filter: Rc<dyn Fn(tablepro_core::FilterSet)> = {
            let tab = tab.downgrade();
            Rc::new(move |set| {
                if let Some(tab) = tab.upgrade() {
                    tab.send(BrowseTabInput::FilterApplied(set));
                }
            })
        };
        let filter_strip = crate::ui::filter_strip::build(Vec::new(), initial_filter.clone(), on_apply_filter);
        imp.toolbar.add_top_bar(&filter_strip.widget);
        tab.collapse_top_bars_with(&filter_strip.widget);
        tab.connect_widgets();
        let stale_banner = StaleBanner::new(imp.stale_banner.get(), {
            let tab = tab.downgrade();
            move || {
                if let Some(tab) = tab.upgrade() {
                    tab.send(BrowseTabInput::Refresh);
                }
            }
        });
        let actions = browse_actions::install_browse_actions(&tab);

        // Handled at once: a tracked change redraws the cells bound to its
        // row in place, so the cell that sent it is still there for the
        // Tab that ended the edit to move focus from.
        let grid_sink: GridSink = {
            let tab = tab.downgrade();
            Rc::new(move |msg| {
                if let Some(tab) = tab.upgrade() {
                    tab.send(BrowseTabInput::from(msg));
                }
            })
        };
        let link_generation = init.session.link_generation();
        let dialect = init.session.current_dialect();
        let link_changes = init.session.link_changes();
        let model = BrowseModel {
            this: tab.downgrade(),
            session: init.session,
            tasks: init.tasks,
            sequencer: RequestSequencer::new(),
            failed: FailedRequests::new(),
            after_columns: BTreeSet::new(),
            recheck: ColumnRecheck::default(),
            issued_on: std::collections::BTreeMap::new(),
            link_generation,
            identity: None,
            dialect,
            tracker: init.tracker,
            schema: init.schema,
            table: init.table,
            connection_id: init.connection_id,
            read_only: init.read_only,
            column_widths: init.column_widths,
            filter_settings: init.filter_settings,
            pager: BrowsePager::new(init.page_size, init.initial_offset),
            deadlines: init.deadlines,
            current_sort: init.initial_sort,
            current_filter: initial_filter,
            current_columns: Vec::new(),
            page: None,
            shown_view: None,
            current_selection: None,
            total: RowTotal::Unknown,
            load: ContentLoad::default(),
            tab_loading: false,
            stale_banner,
            inner_stack: imp.inner_stack.get(),
            grid_holder: imp.grid_holder.get(),
            loading_page: imp.loading_page.get(),
            error_page: imp.error_page.get(),
            current_column_view: None,
            view_columns: Vec::new(),
            row_index: GridRowIndex::default(),
            rendered_columns: Vec::new(),
            read_only_banner: imp.read_only_banner.get(),
            no_pk_banner: imp.no_pk_banner.get(),
            was_dirty: Cell::new(false),
            pending_restore: None,
            paginator_label: imp.paginator_label.get(),
            count_button: imp.count_button.get(),
            count_spinner: imp.count_spinner.get(),
            count_label: imp.count_label.get(),
            selection_label: imp.selection_label.get(),
            first_button: imp.first_button.get(),
            prev_button: imp.prev_button.get(),
            next_button: imp.next_button.get(),
            last_button: imp.last_button.get(),
            filter_button: imp.filter_button.get(),
            filter_badge: imp.filter_badge.get(),
            filter_strip: Some(filter_strip),
            insert_button: imp.insert_button.get(),
            delete_button: imp.delete_button.get(),
            actions,
            saving: Cell::new(false),
            pending_revealer: imp.pending_revealer.get(),
            save_button: imp.save_button.get(),
            discard_button: imp.discard_button.get(),
            saving_spinner: imp.saving_spinner.get(),
            stop_button: imp.stop_button.get(),
            pending_label: imp.pending_label.get(),
            grid_sink,
            suppress_combo_emit: Cell::new(true),
            confirming_delete: None,
            next_confirmation: 0,
        };
        imp.model.replace(Some(model));
        imp.link_watch.replace(Some(WatchForwarder::new(
            link_changes,
            {
                let tab = tab.downgrade();
                move |generation: LinkGeneration| {
                    if let Some(tab) = tab.upgrade() {
                        tab.send(BrowseTabInput::LinkChanged(generation));
                    }
                }
            },
            |future| {
                glib::spawn_future_local(future);
            },
        )));
        tab.send(BrowseTabInput::Start);
        tab
    }

    /// Hand the tab an input. One that arrives while another is being
    /// handled, from a widget signal the handler set off, waits for it
    /// to finish rather than running inside it.
    pub(crate) fn send(&self, msg: BrowseTabInput) {
        let imp = self.imp();
        imp.queue.borrow_mut().push_back(msg);
        if imp.dispatching.replace(true) {
            return;
        }
        loop {
            let next = imp.queue.borrow_mut().pop_front();
            let Some(msg) = next else {
                break;
            };
            let mut effects = Effects::default();
            {
                let mut model = imp.model.borrow_mut();
                let Some(model) = model.as_mut() else {
                    imp.queue.borrow_mut().clear();
                    break;
                };
                model.update(msg, &mut effects);
            }
            for output in effects.outputs {
                self.emit_output(output);
            }
            imp.queue.borrow_mut().extend(effects.inputs);
        }
        imp.dispatching.set(false);
    }

    /// Stop every read the tab has running and stop following
    /// reconnects now, rather than at dispose, which waits for the last
    /// reference to the widget.
    pub fn shutdown(&self) {
        let imp = self.imp();
        imp.link_watch.take();
        if let Ok(mut model) = imp.model.try_borrow_mut()
            && let Some(model) = model.as_mut()
        {
            model.sequencer.cancel_all();
        }
    }

    /// `None` once the tab is closed, and while it is handling an input.
    fn read<T>(&self, read: impl FnOnce(&BrowseModel) -> T) -> Option<T> {
        self.imp().model.try_borrow().ok()?.as_ref().map(read)
    }

    pub fn columns(&self) -> Vec<ColumnInfo> {
        self.read(|model| model.current_columns.clone()).unwrap_or_default()
    }

    pub fn table_label(&self) -> String {
        self.read(|model| qualified(model.schema.as_deref(), &model.table))
            .unwrap_or_default()
    }

    pub fn table(&self) -> String {
        self.read(|model| model.table.clone()).unwrap_or_default()
    }

    pub fn current_offset(&self) -> u64 {
        self.read(|model| model.pager.start_ordinal()).unwrap_or_default()
    }

    pub fn page_size(&self) -> u64 {
        self.read(|model| model.pager.page_size()).unwrap_or(DEFAULT_PAGE_SIZE)
    }

    pub fn current_sort(&self) -> Option<(usize, bool)> {
        self.read(|model| model.current_sort).flatten()
    }

    /// A read of the tab's rows is running.
    pub fn is_loading(&self) -> bool {
        self.read(|model| model.tab_loading).unwrap_or(false)
    }

    pub fn connect_state_changed<F: Fn(&Self) + 'static>(&self, f: F) -> glib::SignalHandlerId {
        self.connect_closure("state-changed", false, glib::closure_local!(move |tab: &Self| f(tab)))
    }

    pub(crate) fn connect_export_results<F: Fn(&Self, ExportOffer) + 'static>(&self, f: F) -> glib::SignalHandlerId {
        self.connect_closure(
            "export-results",
            false,
            glib::closure_local!(move |tab: &Self, payload: glib::BoxedAnyObject| {
                f(tab, payload.borrow::<ExportOffer>().clone());
            }),
        )
    }

    pub fn connect_alert<F: Fn(&Self, String, String) + 'static>(&self, f: F) -> glib::SignalHandlerId {
        self.connect_closure(
            "alert",
            false,
            glib::closure_local!(move |tab: &Self, title: String, body: String| f(tab, title, body)),
        )
    }

    pub fn connect_toast<F: Fn(&Self, String) + 'static>(&self, f: F) -> glib::SignalHandlerId {
        self.connect_closure(
            "toast",
            false,
            glib::closure_local!(move |tab: &Self, text: String| f(tab, text)),
        )
    }

    /// The pending changes crossed the empty / non-empty boundary.
    pub fn connect_dirty_changed<F: Fn(&Self, bool) + 'static>(&self, f: F) -> glib::SignalHandlerId {
        self.connect_closure(
            "dirty-changed",
            false,
            glib::closure_local!(move |tab: &Self, dirty: bool| f(tab, dirty)),
        )
    }

    /// Save asked the window to write what the tab's tracker holds.
    pub fn connect_save_requested<F: Fn(&Self) + 'static>(&self, f: F) -> glib::SignalHandlerId {
        self.connect_closure("save-requested", false, glib::closure_local!(move |tab: &Self| f(tab)))
    }

    /// F5 asked the window to read the tab again.
    pub fn connect_refresh_requested<F: Fn(&Self) + 'static>(&self, f: F) -> glib::SignalHandlerId {
        self.connect_closure(
            "refresh-requested",
            false,
            glib::closure_local!(move |tab: &Self| f(tab)),
        )
    }

    /// Stop Saving asked the window to stop the tab's save.
    pub fn connect_stop_save_requested<F: Fn(&Self) + 'static>(&self, f: F) -> glib::SignalHandlerId {
        self.connect_closure(
            "stop-save-requested",
            false,
            glib::closure_local!(move |tab: &Self| f(tab)),
        )
    }

    /// A read of the tab's rows started or ended.
    pub fn connect_loading_changed<F: Fn(&Self, bool) + 'static>(&self, f: F) -> glib::SignalHandlerId {
        self.connect_closure(
            "loading-changed",
            false,
            glib::closure_local!(move |tab: &Self, loading: bool| f(tab, loading)),
        )
    }

    fn emit_output(&self, output: BrowseTabOutput) {
        match output {
            BrowseTabOutput::StateChanged => self.emit_by_name::<()>("state-changed", &[]),
            BrowseTabOutput::Copy(request) => self.copy(request),
            BrowseTabOutput::ShowRowJson(request) => {
                if let Some(tasks) = self.read(|model| model.tasks.clone()) {
                    let tab = self.clone().upcast();
                    glib::spawn_future_local(async move {
                        present_row_json(tab, tasks, request).await;
                    });
                }
            }
            BrowseTabOutput::Export(offer) => {
                self.emit_by_name::<()>("export-results", &[&glib::BoxedAnyObject::new(*offer)]);
            }
            BrowseTabOutput::ShowSelectionAlert { title, body } => {
                self.emit_by_name::<()>("alert", &[&title, &body]);
            }
            BrowseTabOutput::ShowToast(text) => self.emit_by_name::<()>("toast", &[&text]),
            BrowseTabOutput::DirtyChanged(dirty) => self.emit_by_name::<()>("dirty-changed", &[&dirty]),
            BrowseTabOutput::SaveRequested => self.emit_by_name::<()>("save-requested", &[]),
            BrowseTabOutput::StopSaveRequested => self.emit_by_name::<()>("stop-save-requested", &[]),
            BrowseTabOutput::LoadingChanged(loading) => self.emit_by_name::<()>("loading-changed", &[&loading]),
            BrowseTabOutput::RefreshRequested => self.emit_by_name::<()>("refresh-requested", &[]),
        }
    }

    /// Render a copy off the GTK thread, and toast how it went.
    fn copy(&self, request: CopyRequest) {
        let Some(tasks) = self.read(|model| model.tasks.clone()) else {
            return;
        };
        let tab = self.downgrade();
        crate::ui::clipboard::copy_rows(self, &tasks, request, move |text| {
            if let Some(tab) = tab.upgrade() {
                tab.emit_by_name::<()>("toast", &[&text]);
            }
        });
    }

    /// The top-bar slot draws a thin strip even when every banner in it
    /// is collapsed, so the slot itself is hidden unless one shows.
    fn collapse_top_bars_with(&self, filter: &gtk::Revealer) {
        let imp = self.imp();
        // The banners and the strip hold this through their notify
        // handlers, and the tab holds them, so it holds them all weakly.
        let sync: Rc<dyn Fn()> = {
            let toolbar = imp.toolbar.downgrade();
            let banners = [
                imp.stale_banner.downgrade(),
                imp.read_only_banner.downgrade(),
                imp.no_pk_banner.downgrade(),
            ];
            let filter = filter.downgrade();
            Rc::new(move || {
                let (Some(toolbar), Some(filter)) = (toolbar.upgrade(), filter.upgrade()) else {
                    return;
                };
                let banner_shown = banners
                    .iter()
                    .filter_map(glib::WeakRef::upgrade)
                    .any(|banner| banner.is_revealed());
                toolbar.set_reveal_top_bars(banner_shown || filter.reveals_child());
            })
        };
        sync();
        for banner in [&imp.stale_banner, &imp.read_only_banner, &imp.no_pk_banner] {
            let sync = sync.clone();
            banner.connect_revealed_notify(move |_| sync());
        }
        filter.connect_reveal_child_notify(move |_| sync());
    }

    fn connect_widgets(&self) {
        let imp = self.imp();
        let on_click = |button: &gtk::Button, msg: fn() -> BrowseTabInput| {
            let tab = self.downgrade();
            button.connect_clicked(move |_| {
                if let Some(tab) = tab.upgrade() {
                    tab.send(msg());
                }
            });
        };
        on_click(&imp.first_button, || BrowseTabInput::FirstPage);
        on_click(&imp.prev_button, || BrowseTabInput::PrevPage);
        on_click(&imp.next_button, || BrowseTabInput::NextPage);
        on_click(&imp.last_button, || BrowseTabInput::LastPage);
        on_click(&imp.export_button, || BrowseTabInput::Export(None));
        on_click(&imp.discard_button, || BrowseTabInput::DiscardAll);
        on_click(&imp.save_button, || BrowseTabInput::CommitSave);
        on_click(&imp.stop_button, || BrowseTabInput::StopSaving);
        on_click(&imp.retry_button, || BrowseTabInput::Refresh);
        on_click(&imp.count_button, || BrowseTabInput::CountRows);
        let tab = self.downgrade();
        imp.page_size_dropdown.connect_selected_notify(move |dropdown| {
            let index = usize::try_from(dropdown.selected()).unwrap_or(usize::MAX);
            if let (Some(tab), Some(&size)) = (tab.upgrade(), PAGE_SIZE_OPTIONS.get(index)) {
                tab.send(BrowseTabInput::PageSizeChanged(size));
            }
        });
    }
}

impl From<GridMsg> for BrowseTabInput {
    fn from(msg: GridMsg) -> Self {
        match msg {
            GridMsg::SortChanged(col_idx, ascending) => Self::SortChanged { col_idx, ascending },
            GridMsg::Edit { row, column, edit } => Self::GridEdit { row, column, edit },
            GridMsg::Copy(request) => Self::GridCopy(request),
            GridMsg::ShowRowJson(request) => Self::GridShowRowJson(request),
            GridMsg::ShowToast(text) => Self::GridShowToast(text),
            GridMsg::CopyRowsAsInsert { rows } => Self::GridCopyRowsAsInsert(rows),
            GridMsg::SetCellValue { row, column, preset } => Self::GridSetCellValue { row, column, preset },
            GridMsg::ExportResults(page) => Self::Export(Some(page)),
            GridMsg::DeleteRows { rows } => Self::DeleteRows(rows),
            GridMsg::InsertRow => Self::InsertRow,
            GridMsg::DuplicateRows { rows } => Self::DuplicateRows(rows),
        }
    }
}

/// What one input left to do once it was handled: signals to emit and
/// inputs to handle next.
#[derive(Default)]
pub(crate) struct Effects {
    outputs: Vec<BrowseTabOutput>,
    inputs: VecDeque<BrowseTabInput>,
    /// A bulk delete over rows in the running save says so once.
    told_edit_held: bool,
}

impl Effects {
    fn output(&mut self, output: BrowseTabOutput) {
        self.outputs.push(output);
    }

    fn input(&mut self, input: BrowseTabInput) {
        self.inputs.push_back(input);
    }
}

/// Which page of the table a read asks for.
#[derive(Debug, Clone, PartialEq)]
struct PageView {
    filter: tablepro_core::FilterSet,
    sort: Option<(usize, bool)>,
    offset: u64,
    limit: u64,
}

pub(crate) struct BrowseModel {
    this: glib::WeakRef<BrowseTab>,
    session: Arc<Session>,
    tasks: Tasks,
    sequencer: RequestSequencer<BrowseRequestKind>,
    failed: FailedRequests<BrowseRequestKind>,
    /// Reads that wait for the columns: a page is built from them, and
    /// the tab reads nothing else of a table whose columns it could not
    /// read.
    after_columns: BTreeSet<BrowseRequestKind>,
    recheck: ColumnRecheck,
    /// The connection each running request was issued on. A request
    /// that fails after the connection was replaced is asked again at
    /// once, since the reconnect it would wait for has already landed.
    issued_on: std::collections::BTreeMap<BrowseRequestKind, LinkGeneration>,
    /// The newest connection the tab has heard of, so the watch's first
    /// delivery, which is the one the tab opened on, changes nothing.
    link_generation: LinkGeneration,
    identity: Option<RowIdentity>,
    /// The current connection's dialect, which says whether a filter can
    /// be written for it. Read again after every reconnect.
    dialect: Option<Arc<dyn SqlDialect>>,

    tracker: TabTrackerHandle,
    schema: Option<String>,
    table: String,
    connection_id: Option<uuid::Uuid>,
    read_only: bool,
    column_widths: crate::persistence::ColumnWidthStore,
    filter_settings: crate::persistence::FilterSettingsStore,

    /// Where the page the tab reads starts, and how many rows it holds.
    pager: BrowsePager,
    deadlines: Arc<dyn DeadlinePolicy>,
    current_sort: Option<(usize, bool)>,
    /// The WHERE every page and count reads under, kept per connection,
    /// schema and table.
    current_filter: tablepro_core::FilterSet,
    current_columns: Vec<ColumnInfo>,
    /// The page on screen, whose rows the grid's store holds.
    page: Option<PageState>,
    /// What `page` was read under. A read that fails while asking for
    /// that same page again leaves it on screen.
    shown_view: Option<PageView>,
    current_selection: Option<gtk::MultiSelection>,
    /// The table's row count under the filter, as far as the tab knows.
    total: RowTotal,
    load: ContentLoad,
    /// What the tab bar was last told, so it hears only changes.
    tab_loading: bool,
    stale_banner: StaleBanner,

    inner_stack: gtk::Stack,
    grid_holder: gtk::Box,
    loading_page: adw::StatusPage,
    error_page: adw::StatusPage,
    current_column_view: Option<gtk::ColumnView>,
    /// The view's columns in the order of a row's cells, which a drag in
    /// the header leaves alone.
    view_columns: Vec<gtk::ColumnViewColumn>,
    /// The store's rows by tracker key, so a tracked change finds the
    /// row to redraw without a scan of the page.
    row_index: GridRowIndex,
    /// The columns the current view was built for. A page under the
    /// same columns reuses the view and only swaps its rows; a schema
    /// change that renames or retypes one builds the view again.
    rendered_columns: Vec<ColumnInfo>,
    /// Banners are for states the user cannot clear by saving; pending
    /// edits show in the footer and the tab title instead.
    read_only_banner: adw::Banner,
    no_pk_banner: adw::Banner,
    /// Last-emitted dirty state, so App hears only real transitions and
    /// not every count change (2 → 3).
    was_dirty: Cell<bool>,
    /// The selection and the focused cell before a sort, save or
    /// refresh, so the page read again puts them back.
    pending_restore: Option<SelectionSnapshot>,
    paginator_label: gtk::Label,
    count_button: gtk::Button,
    count_spinner: adw::Spinner,
    count_label: gtk::Label,
    selection_label: gtk::Label,
    first_button: gtk::Button,
    prev_button: gtk::Button,
    next_button: gtk::Button,
    last_button: gtk::Button,
    filter_button: gtk::Button,
    filter_badge: gtk::Label,
    filter_strip: Option<crate::ui::filter_strip::FilterStrip>,
    insert_button: gtk::Button,
    delete_button: gtk::Button,
    actions: BrowseActions,
    /// Between the save starting and settling.
    saving: Cell<bool>,
    pending_revealer: gtk::Revealer,
    save_button: gtk::Button,
    discard_button: gtk::Button,
    saving_spinner: adw::Spinner,
    stop_button: gtk::Button,
    pending_label: gtk::Label,
    grid_sink: GridSink,
    /// Set until the first page lands, so the page-size dropdown being
    /// set from a restored state does not count as the user choosing.
    suppress_combo_emit: Cell<bool>,
    confirming_delete: Option<ConfirmingDelete>,
    next_confirmation: u64,
}

#[derive(Debug)]
pub(crate) enum BrowseTabInput {
    /// The tab is built: read the columns, then the page and the count.
    Start,
    /// A reply to one of the tab's reads.
    Command(BrowseCommand),
    /// A reconnect replaced the session's connection.
    LinkChanged(LinkGeneration),
    /// The table's definition changed. The catalog has already dropped
    /// its columns, so they are read again before the page.
    SchemaChanged,
    /// F5.
    Refresh,
    /// Esc. A single selected row stays selected: clearing it would
    /// strand the keyboard focus indicator.
    ClearSelection,
    /// F5: the window asks first when the tab has unsaved changes.
    RequestRefresh,
    ToggleFilterStrip,
    /// The strip's rules, or an empty set for "Clear all".
    FilterApplied(tablepro_core::FilterSet),
    FirstPage,
    PrevPage,
    NextPage,
    LastPage,
    SortChanged {
        col_idx: usize,
        ascending: bool,
    },
    PageSizeChanged(u64),
    InsertRow,
    /// Queued after an insert, so the focus lands on the column view
    /// as it is once the insert is drawn.
    FocusInsertedDraft,
    DeleteRows(Vec<RowObject>),
    /// Checked against the cell's lock before the tracker takes it.
    GridEdit {
        row: RowObject,
        column: usize,
        edit: TrackerEdit,
    },
    /// A preset from a cell's menu or Ctrl+Backspace. The tab resolves it
    /// against the column, so both paths reach the same value.
    GridSetCellValue {
        row: RowObject,
        column: usize,
        preset: CellPreset,
    },
    GridShowToast(String),
    /// The paginator's Export button, or the grid's Export with the page
    /// as the grid holds it.
    Export(Option<ExportSource>),
    GridCopyRowsAsInsert(Vec<RowObject>),
    DuplicateRows(Vec<RowObject>),
    GridCopy(CopyRequest),
    GridShowRowJson(RowJsonRequest),
    Undo,
    Redo,
    CommitSave,
    /// The window started saving the tab's changes.
    SaveStarted,
    StopSaving,
    DiscardAll,
    DiscardAndRefresh,
    /// A delete the user confirmed, or one small enough to need no
    /// confirmation.
    MarkRowsDeleted(RowDeletion),
    /// The user answered the bulk delete confirmation `ticket` opened.
    BulkDeleteAnswered {
        ticket: u64,
        confirmed: bool,
    },
    /// The save landed, adding and removing these rows. Edits made
    /// while it ran stay pending.
    SaveCommitted(ChangeOrigins),
    /// Count Rows, or Try Again after a count failed.
    CountRows,
    /// The pending changes stay, so the user can fix the cause and
    /// save again.
    SaveFailed(String),
    /// The save may have landed. The changes stay, and the tracker
    /// refuses to save them again until the table is read again.
    SaveOutcomeUnknown(String),
    FlashErrorRow(StatementSource),
    /// The flash on a failed statement's row ran its course.
    ErrorFlashEnded(RowKey),
    CopySelectedRowsAsTsv,
    PasteNotSupported,
}

#[derive(Debug)]
pub(crate) enum BrowseTabOutput {
    /// Something the window keeps for the tab changed: the page, the
    /// sort, the page size.
    StateChanged,
    Copy(CopyRequest),
    ShowRowJson(RowJsonRequest),
    Export(Box<ExportOffer>),
    ShowSelectionAlert {
        title: String,
        body: String,
    },
    ShowToast(String),
    DirtyChanged(bool),
    SaveRequested,
    StopSaveRequested,
    /// A read of the tab's rows started or ended, for the tab bar.
    LoadingChanged(bool),
    /// F5 asked the window to read the tab again.
    RefreshRequested,
}

impl BrowseModel {
    /// The table a browse tab's rows came from, so an export can
    /// write them back as `INSERT` statements.
    fn sql_target(&self) -> crate::ui::export_dialog::SqlTarget {
        crate::ui::export_dialog::SqlTarget {
            table: self.table.clone(),
        }
    }

    fn table_ref(&self) -> TableRef {
        TableRef::new(self.schema.clone(), self.table.clone())
    }

    fn export_name(&self) -> String {
        qualified(self.schema.as_deref(), &self.table)
    }

    /// The tracker context the grid renders through. Copy and export
    /// read the same context, so what leaves the tab is what the user
    /// is looking at, pending edits included.
    fn grid_context(&self) -> TabGridContext {
        TabGridContext {
            tracker: Some(self.tracker.clone()),
            editable: !self.read_only,
            identity: pk_identity(&self.current_columns),
            column_widths: self.connection_id.map(|connection_id| ColumnWidthBinding {
                store: self.column_widths.clone(),
                connection_id,
                schema: self.schema.clone(),
                table: self.table.clone(),
            }),
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

    fn table_label(&self) -> String {
        qualified(self.schema.as_deref(), &self.table)
    }

    /// While a save runs, Save and Discard are off, so a double click
    /// cannot send two, and Stop Saving takes their place.
    fn show_saving(&self, saving: bool) {
        self.saving.set(saving);
        self.actions.follow_tracker(&self.tracker, saving);
        self.save_button.set_sensitive(!saving);
        self.discard_button.set_sensitive(!saving);
        self.saving_spinner.set_visible(saving);
        self.stop_button.set_visible(saving);
    }

    fn refresh_pending_bar(&self, count: usize) {
        let visible = count > 0;
        if visible {
            let label = if count == 1 {
                crate::i18n::gettext("1 unsaved change")
            } else {
                crate::i18n::ngettext_f(
                    "{n} unsaved change",
                    "{n} unsaved changes",
                    u32::try_from(count).unwrap_or(u32::MAX),
                    &[("n", &count.to_string())],
                )
            };
            self.pending_label.set_label(&label);
        }
        self.pending_revealer.set_reveal_child(visible);
        self.refresh_banner_visibility();
    }

    /// Apply what a tracker call changed: the draft rows the store gains
    /// or loses, then a redraw of each touched row, then the footer. A
    /// row keeps its object, so the selection and the focus stay on it.
    fn apply_tracker_delta(&mut self, delta: &TrackerDelta, fx: &mut Effects) {
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

    fn selected_rows(&self) -> Vec<RowObject> {
        self.current_selection.as_ref().map(selected_rows).unwrap_or_default()
    }

    /// GtkMultiSelection emits no selection-changed when its rows are
    /// spliced, so a page that drops the selected rows comes through here.
    fn sync_selection(&self) {
        let selected = self
            .current_selection
            .as_ref()
            .map_or(0, |sel| u32::try_from(sel.selection().size()).unwrap_or(u32::MAX));
        update_selection_chrome(&self.selection_label, selected);
        self.sync_delete_action();
    }

    /// The rows on screen can change under the selection without it
    /// changing, so this runs on every delta, page and load state too.
    /// Rows behind an error page count as none.
    fn sync_delete_action(&self) {
        let rows = match self.shown_page() {
            Some(_) => self.selected_rows(),
            None => Vec::new(),
        };
        self.actions
            .follow_selection(u32::try_from(rows.len()).unwrap_or(u32::MAX));
        show_delete_availability(&self.actions.delete_rows, &self.delete_button, &rows, self.read_only);
    }

    /// The page whose rows the grid shows. A failed read of another page
    /// leaves the rows it replaced in the store, behind the error page,
    /// where nothing may export, copy or delete them.
    fn shown_page(&self) -> Option<&PageState> {
        self.page.as_ref().filter(|_| self.load.has_content())
    }

    /// The footer and the tab's dirty flag, which App turns into the
    /// title bullet. App hears only real transitions.
    fn sync_pending_chrome(&self, count: usize, fx: &mut Effects) {
        self.refresh_pending_bar(count);
        self.actions.follow_tracker(&self.tracker, self.saving.get());
        let dirty = count > 0;
        if dirty != self.was_dirty.replace(dirty) {
            fx.output(BrowseTabOutput::DirtyChanged(dirty));
        }
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

    /// F5: read the columns again, in case the table changed under the
    /// tab, then the page and the count built from them. The rows on
    /// screen stay until the new page lands.
    fn reload(&mut self, fx: &mut Effects) {
        self.capture_selection();
        self.begin_read(fx);
        self.stop_count(true);
        self.reload_from_columns(ColumnFreshness::Refetch);
    }

    /// A read of the page the tab asks for starts. Rows read under the
    /// same filter, sort and offset stay through a failure; rows of
    /// another page do not, since they are not what the tab shows.
    fn begin_read(&mut self, fx: &mut Effects) {
        let presentation = match self.shown_view.as_ref() == Some(&self.page_view()) {
            true => self.load.begin(),
            false => self.load.begin_replacing(),
        };
        self.present(presentation, fx);
    }

    /// Put the read's state on screen: the spinner, the grid or the
    /// error page, the banner over rows that could not be read again,
    /// and the tab bar's spinner.
    fn present(&mut self, presentation: LoadPresentation, fx: &mut Effects) {
        match &presentation.page {
            ContentPage::Spinner => self.show_loading(),
            ContentPage::Content => self.inner_stack.set_visible_child_name("grid"),
            ContentPage::Error(failure) => {
                // The status page reads its description as markup.
                self.error_page
                    .set_description(Some(&glib::markup_escape_text(&failure.message())));
                self.inner_stack.set_visible_child_name("error");
            }
        }
        self.stale_banner.show(presentation.stale.as_ref());
        self.sync_total_chrome();
        self.sync_delete_action();
        if self.tab_loading != presentation.tab_loading {
            self.tab_loading = presentation.tab_loading;
            fx.output(BrowseTabOutput::LoadingChanged(presentation.tab_loading));
        }
    }

    /// Reveal at most ONE banner at a time. Read-only takes priority
    /// over no-PK because read-only blocks every kind of edit.
    fn refresh_banner_visibility(&self) {
        let read_only = self.read_only;
        let no_pk = !self.current_columns.is_empty() && !self.current_columns.iter().any(|c| c.primary_key);
        self.read_only_banner.set_revealed(read_only);
        self.no_pk_banner.set_revealed(!read_only && no_pk);
    }

    fn list_store(&self) -> Option<gtk::gio::ListStore> {
        let selection = self.current_selection.as_ref()?;
        selection.model()?.downcast::<gtk::gio::ListStore>().ok()
    }

    /// Scroll to the row behind a failed statement and flash it. A row
    /// paged, sorted or filtered away is not found, and the alert alone
    /// tells the user which statement failed.
    fn flash_error_row(&mut self, source: &StatementSource) {
        let key = match source {
            StatementSource::Insert { draft_id } => RowKey::Draft(*draft_id),
            StatementSource::Update { row_key } | StatementSource::Delete { row_key } => row_key.clone(),
        };
        let Some(store) = self.list_store() else {
            return;
        };
        let Some(row) = self.row_index.get(&key) else {
            return;
        };
        let Some(position) = store.find(&row) else {
            return;
        };
        if let Some(selection) = self.current_selection.as_ref() {
            selection.select_item(position, true);
        }
        if let Some(cv) = self.current_column_view.as_ref() {
            cv.scroll_to(
                position,
                None,
                gtk::ListScrollFlags::FOCUS | gtk::ListScrollFlags::SELECT,
                None,
            );
        }
        let generation = self.tracker.flash_error_row(key.clone());
        row.bump_revision();
        let tracker = self.tracker.clone();
        let tab = self.this.clone();
        // Matches the length of the flash animation in the stylesheet. The
        // row is looked up again then, since a reload may have replaced it.
        glib::timeout_add_local_once(std::time::Duration::from_millis(1800), move || {
            if tracker.clear_error_row_if(generation)
                && let Some(tab) = tab.upgrade()
            {
                tab.send(BrowseTabInput::ErrorFlashEnded(key));
            }
        });
    }

    /// Keep the selection and the focused cell by row key before a sort,
    /// save or refresh reads the page again.
    fn capture_selection(&mut self) {
        // A capture still pending (sort and save in quick succession)
        // is kept: the user was where the chain started.
        if self.pending_restore.is_some() {
            return;
        }
        let (Some(selection), Some(column_view)) = (self.current_selection.as_ref(), self.current_column_view.as_ref())
        else {
            return;
        };
        let snapshot = SelectionSnapshot::capture(selection, column_view);
        if !snapshot.is_empty() {
            self.pending_restore = Some(snapshot);
        }
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

    /// Put back the selection captured before the page was read again,
    /// on the rows that are still on it. The capture is used up either
    /// way, so it cannot steer a later read.
    fn restore_selection(&mut self) {
        let Some(snapshot) = self.pending_restore.take() else {
            return;
        };
        let (Some(store), Some(selection), Some(column_view)) = (
            self.list_store(),
            self.current_selection.clone(),
            self.current_column_view.clone(),
        ) else {
            return;
        };
        snapshot.restore(
            &mut self.row_index,
            &store,
            &selection,
            &column_view,
            &self.view_columns,
        );
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

        clear_box(&self.grid_holder);
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
        self.current_selection = Some(selection);
        self.current_column_view = Some(column_view.clone());
        self.view_columns = data_columns(&column_view);
        self.rendered_columns = self.current_columns.clone();

        // The selection model is new per rebuild, so the previous
        // handler goes with the old one. The tab holds the selection, so
        // the handler holds the tab's widgets weakly.
        if let Some(sel) = self.current_selection.as_ref() {
            let label = self.selection_label.downgrade();
            let button = self.delete_button.downgrade();
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
        browse_actions::install_grid_shortcuts(&column_view);

        self.reindex_rows();
        self.sync_selection();

        let scrolled = gtk::ScrolledWindow::builder()
            .child(&column_view)
            .hexpand(true)
            .vexpand(true)
            .build();
        self.grid_holder.append(&scrolled);
        self.refresh_grid_chrome();
        let presentation = self.load.succeed();
        self.present(presentation, fx);
        self.restore_selection();
        fx.output(BrowseTabOutput::StateChanged);
    }

    fn column_view_matches_current_columns(&self) -> bool {
        self.current_column_view.is_some() && self.rendered_columns == self.current_columns
    }

    /// A row event from a grid built for other columns names its cells
    /// by positions that now hold other columns.
    fn grid_is_stale(&self) -> bool {
        let stale = !self.column_view_matches_current_columns();
        if stale {
            tracing::debug!("dropped a row event from a grid built for other columns");
        }
        stale
    }

    /// The grid was built for columns the table no longer has, so it
    /// goes before a click or a key in it lands on a moved column.
    fn drop_grid(&mut self, fx: &mut Effects) {
        if self.current_column_view.take().is_none() {
            return;
        }
        clear_box(&self.grid_holder);
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
        self.first_button.set_sensitive(self.pager.first().is_some());
        self.prev_button.set_sensitive(self.pager.prev().is_some());
        self.next_button
            .set_sensitive(self.pager.next(self.rows_on_page()).is_some());
        self.sync_total_chrome();
        self.suppress_combo_emit.set(false);
    }

    fn rows_on_page(&self) -> u64 {
        self.page.as_ref().map_or(0, |page| page.row_count as u64)
    }

    fn has_primary_key(&self) -> bool {
        self.current_columns.iter().any(|c| c.primary_key)
    }

    fn refresh_crud_buttons(&self) {
        let has_columns = !self.current_columns.is_empty();
        let has_pk = self.has_primary_key();
        if self.read_only {
            self.insert_button.set_visible(false);
            self.actions.insert_row.set_enabled(false);
            return;
        }
        self.insert_button.set_visible(true);
        // No-PK tables don't get inline editing because RowKey can't be
        // formed without a PK. Disable instead of hide so the affordance
        // stays discoverable; the tooltip explains the gate.
        self.actions.insert_row.set_enabled(has_columns && has_pk);
        if has_columns && !has_pk {
            self.insert_button.set_tooltip_text(Some(&crate::i18n::gettext(
                "This table has no primary key. Inline editing is disabled.",
            )));
        } else {
            self.insert_button
                .set_tooltip_text(Some(&crate::i18n::gettext("Insert Row")));
        }
        self.refresh_banner_visibility();
    }

    fn refresh_filter_chrome(&self) {
        let n = self.current_filter.len();
        if n == 0 {
            self.filter_badge.set_visible(false);
            self.filter_badge.set_label("");
            self.filter_button
                .set_tooltip_text(Some(&crate::i18n::gettext("Filter rows")));
        } else {
            self.filter_badge.set_label(&n.to_string());
            self.filter_badge.set_visible(true);
            self.filter_button.set_tooltip_text(Some(&crate::i18n::ngettext_f(
                "{n} filter rule active. Click to edit",
                "{n} filter rules active. Click to edit",
                u32::try_from(n).unwrap_or(u32::MAX),
                &[("n", &n.to_string())],
            )));
        }
    }

    fn update_paginator_label(&self) {
        let Some(page) = self.shown_page() else {
            self.paginator_label.set_label("");
            return;
        };
        let n_rows = page.row_count;
        if n_rows == 0 {
            // Reachable when the user navigated past the end of a
            // table that shrank in another session, before the count
            // clamps the offset back.
            self.paginator_label
                .set_label(&crate::i18n::gettext("No rows on this page"));
            return;
        }
        let start = page.start_ordinal + 1;
        let end = page.start_ordinal + n_rows as u64;
        self.paginator_label.set_label(&self.total.paginator_label(start, end));
    }

    fn show_loading(&self) {
        self.loading_page.set_description(Some(&crate::i18n::gettext_f(
            "Fetching rows from {table}",
            &[("table", &self.table_label())],
        )));
        self.inner_stack.set_visible_child_name("loading");
    }

    /// Take the page apart into rows the store owns. Each row's cells
    /// move into it, and the identity cells after them name the row and
    /// are dropped, so nothing past the visible columns reaches a copy
    /// or an export. The tab's drafts stay on top.
    fn on_rows_loaded(&mut self, offset: u64, reply: PageReply, fx: &mut Effects) {
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

    /// A read failed. Rows read again for the same page stay, under the
    /// banner; with no rows, or rows of another page, the error page says
    /// why. The paginator stays, so the user can go back.
    fn on_load_failed(&mut self, failure: LoadFailure, fx: &mut Effects) {
        self.pending_restore = None;
        let presentation = self.load.fail(failure);
        self.present(presentation, fx);
    }

    fn on_columns_loaded(&mut self, columns: Vec<ColumnInfo>, fx: &mut Effects) {
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
        if let Some(strip) = self.filter_strip.as_ref() {
            strip.update_columns(columns);
        }
        self.render_grid_if_ready(fx);
    }

    fn update(&mut self, msg: BrowseTabInput, fx: &mut Effects) {
        match msg {
            BrowseTabInput::Start => {
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
            BrowseTabInput::Command(command) => self.on_command(command, fx),
            BrowseTabInput::LinkChanged(generation) => self.on_link_changed(generation, fx),
            BrowseTabInput::SchemaChanged => {
                self.capture_selection();
                self.begin_read(fx);
                self.stop_count(true);
                self.reload_from_columns(ColumnFreshness::Cached);
            }
            BrowseTabInput::Refresh => self.reload(fx),
            BrowseTabInput::DiscardAndRefresh => {
                let delta = self.tracker.discard();
                self.apply_tracker_delta(&delta, fx);
                self.reload(fx);
            }
            BrowseTabInput::ClearSelection => {
                let Some(sel) = self.current_selection.as_ref() else {
                    return;
                };
                // Only a true multi-row selection; clearing a single
                // focused row strands the focus indicator.
                if sel.selection().size() < 2 {
                    return;
                }
                sel.unselect_all();
            }
            BrowseTabInput::RequestRefresh => fx.output(BrowseTabOutput::RefreshRequested),
            BrowseTabInput::ToggleFilterStrip => {
                if let Some(strip) = self.filter_strip.as_ref() {
                    strip.toggle();
                }
            }
            BrowseTabInput::FilterApplied(set) => {
                // The same rules again would only duplicate F5.
                if set == self.current_filter {
                    return;
                }
                self.current_filter = set.clone();
                if let Some(conn_id) = self.connection_id {
                    self.filter_settings
                        .set_filters(conn_id, self.schema.as_deref(), &self.table, set.clone());
                }
                // Filtered counts shift, so back to page 1.
                self.pager.go_to(0);
                self.refresh_filter_chrome();
                if let Some(strip) = self.filter_strip.as_ref() {
                    strip.update_filter(set);
                }
                self.stop_count(false);
                self.fetch(BrowseRequestKind::Page, fx);
                self.fetch(BrowseRequestKind::Estimate, fx);
                fx.output(BrowseTabOutput::StateChanged);
            }
            BrowseTabInput::FirstPage => self.turn_page(self.pager.first(), fx),
            BrowseTabInput::PrevPage => self.turn_page(self.pager.prev(), fx),
            BrowseTabInput::NextPage => self.turn_page(self.pager.next(self.rows_on_page()), fx),
            BrowseTabInput::LastPage => self.turn_page(self.pager.last(&self.total), fx),
            BrowseTabInput::SortChanged { col_idx, ascending } => {
                // The sorter notifies twice for one click on a new column
                // (column, then order), with the same final pair.
                let next = (col_idx, ascending);
                if self.current_sort == Some(next) {
                    return;
                }
                self.current_sort = Some(next);
                self.pager.go_to(0);
                self.capture_selection();
                self.fetch(BrowseRequestKind::Page, fx);
                fx.output(BrowseTabOutput::StateChanged);
            }
            BrowseTabInput::PageSizeChanged(size) => {
                if self.suppress_combo_emit.get() || self.pager.page_size() == size {
                    return;
                }
                self.pager.resize(size);
                self.fetch(BrowseRequestKind::Page, fx);
                fx.output(BrowseTabOutput::StateChanged);
            }
            BrowseTabInput::DuplicateRows(rows) => {
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
                fx.input(BrowseTabInput::FocusInsertedDraft);
            }
            BrowseTabInput::InsertRow => {
                if self.read_only || self.current_columns.is_empty() {
                    return;
                }
                let cells = self.current_columns.iter().map(new_draft_cell).collect();
                self.apply_edit(TrackerEdit::InsertDrafts { rows: vec![cells] }, fx);
                fx.input(BrowseTabInput::FocusInsertedDraft);
            }
            BrowseTabInput::DeleteRows(rows) => self.delete_rows(&rows, fx),
            BrowseTabInput::GridEdit { row, column, edit } => {
                // The cell shows what was typed until its row is drawn again.
                if self.refuses_edit(&row, column) {
                    row.bump_revision();
                    return;
                }
                self.apply_edit(edit, fx);
            }
            BrowseTabInput::GridSetCellValue { row, column, preset } => {
                if self.refuses_edit(&row, column) {
                    return;
                }
                let input = match self.resolve_cell_preset(preset, &row, column) {
                    Some(Ok(input)) => input,
                    Some(Err(message)) => {
                        fx.output(BrowseTabOutput::ShowToast(message));
                        return;
                    }
                    None => return,
                };
                self.edit_cell(&row, column, input, fx);
            }
            BrowseTabInput::GridShowToast(message) => {
                fx.output(BrowseTabOutput::ShowToast(message));
            }
            BrowseTabInput::Export(page) => self.offer_export(page, fx),
            BrowseTabInput::GridCopyRowsAsInsert(rows) => {
                if !self.grid_is_stale() {
                    self.copy_rows_as_insert(&rows, fx);
                }
            }
            BrowseTabInput::GridCopy(request) => fx.output(BrowseTabOutput::Copy(request)),
            BrowseTabInput::GridShowRowJson(request) => fx.output(BrowseTabOutput::ShowRowJson(request)),
            BrowseTabInput::CopySelectedRowsAsTsv => self.copy_selected_rows(fx),
            BrowseTabInput::PasteNotSupported => {
                fx.output(BrowseTabOutput::ShowToast(crate::i18n::gettext(
                    "Pasting rows isn't supported yet",
                )));
            }
            BrowseTabInput::CommitSave => fx.output(BrowseTabOutput::SaveRequested),
            BrowseTabInput::SaveStarted => self.show_saving(true),
            BrowseTabInput::StopSaving => fx.output(BrowseTabOutput::StopSaveRequested),
            BrowseTabInput::DiscardAll => {
                let delta = self.tracker.discard();
                self.apply_tracker_delta(&delta, fx);
                self.fetch(BrowseRequestKind::Page, fx);
            }
            BrowseTabInput::BulkDeleteAnswered { ticket, confirmed } => {
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
                    fx.input(BrowseTabInput::MarkRowsDeleted(pending.deletion));
                }
            }
            BrowseTabInput::MarkRowsDeleted(deletion) => {
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
            BrowseTabInput::SaveCommitted(origins) => {
                self.show_saving(false);
                // The tracker already let go of what the save wrote. The
                // reload replaces every row; dropping the saved drafts
                // from the store first would blank them until it lands.
                self.sync_pending_chrome(self.tracker.pending_count(), fx);
                self.capture_selection();
                // The save says how the total moved, so nothing is
                // counted again. A delete that emptied the last page
                // leaves an exact total that moves the tab back a page.
                self.total
                    .adjust_after_save(origins.inserts, origins.deletes, !self.current_filter.is_empty());
                self.clamp_to_total(fx);
                self.sync_total_chrome();
                self.fetch(BrowseRequestKind::Page, fx);
            }
            BrowseTabInput::CountRows => {
                if let Some(problem) = self.filter_problem() {
                    fx.output(BrowseTabOutput::ShowToast(fetch::filter_failure(problem).message()));
                    return;
                }
                if self.total.exact().is_none() && !self.sequencer.is_pending(BrowseRequestKind::Count) {
                    self.start_count(self.total.estimate(), fx);
                }
            }
            BrowseTabInput::SaveFailed(message) => {
                self.show_saving(false);
                fx.output(BrowseTabOutput::ShowSelectionAlert {
                    title: crate::i18n::gettext("Save failed"),
                    body: message,
                });
            }
            BrowseTabInput::SaveOutcomeUnknown(message) => {
                self.show_saving(false);
                fx.output(BrowseTabOutput::ShowSelectionAlert {
                    title: crate::i18n::gettext("Save Result Unknown"),
                    body: message,
                });
            }
            BrowseTabInput::FlashErrorRow(source) => self.flash_error_row(&source),
            BrowseTabInput::ErrorFlashEnded(key) => {
                if let Some(row) = self.row_index.get(&key) {
                    row.bump_revision();
                }
            }
            BrowseTabInput::FocusInsertedDraft => self.focus_inserted_draft(),
            BrowseTabInput::Undo => {
                if let Some(delta) = self.tracker.undo() {
                    self.apply_tracker_delta(&delta, fx);
                }
            }
            BrowseTabInput::Redo => {
                if let Some(delta) = self.tracker.redo() {
                    self.apply_tracker_delta(&delta, fx);
                }
            }
        }
    }

    /// Read the page a paginator move landed on, if it moved.
    fn turn_page(&mut self, target: Option<(PagePosition, u64)>, fx: &mut Effects) {
        let Some((_, start)) = target else {
            return;
        };
        self.pager.go_to(start);
        self.fetch(BrowseRequestKind::Page, fx);
        fx.output(BrowseTabOutput::StateChanged);
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
            fx.input(BrowseTabInput::MarkRowsDeleted(deletion));
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
                tab.send(BrowseTabInput::BulkDeleteAnswered {
                    ticket,
                    confirmed: response == "delete",
                });
            }
        });
        dialog.present(Some(&self.inner_stack));
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
    fn rebase_confirming_delete(&mut self, fx: &mut Effects) {
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
    fn insert_rows(&self, rows: &[RowObject]) -> Vec<InsertRow> {
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

    /// Same request as the context menu's Copy as > Rows: one selection
    /// cannot produce two different clipboard payloads.
    fn copy_selected_rows(&self, fx: &mut Effects) {
        let (Some(selection), Some(_)) = (self.current_selection.as_ref(), self.shown_page()) else {
            return;
        };
        let ctx = self.grid_context();
        let rows: Vec<RowSnapshot> = super::grid::selected_positions(selection)
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

fn qualified(schema: Option<&str>, table: &str) -> String {
    match schema {
        Some(s) => format!("{s}.{table}"),
        None => table.to_owned(),
    }
}

/// The one place the store gains or loses draft rows.
fn apply_draft_changes(store: &gtk::gio::ListStore, index: &mut GridRowIndex, delta: &TrackerDelta) {
    for draft_id in &delta.removed_drafts {
        let key = RowKey::Draft(*draft_id);
        if let Some(position) = index.position_in(store, &key) {
            store.remove(position);
        }
        index.remove(&key);
    }
    for draft_id in &delta.inserted_drafts {
        let row = RowObject::draft(*draft_id);
        store.insert(0, &row);
        index.insert(&row);
    }
}

fn selected_rows(selection: &gtk::MultiSelection) -> Vec<RowObject> {
    super::grid::selected_positions(selection)
        .into_iter()
        .filter_map(|position| selection.item(position).and_downcast::<RowObject>())
        .collect()
}

/// The Delete key and button follow the action; the button's tooltip
/// says why it is off.
fn show_delete_availability(action: &gio::SimpleAction, button: &gtk::Button, rows: &[RowObject], read_only: bool) {
    let availability = delete_availability(rows.iter().map(RowObject::id), read_only);
    action.set_enabled(availability == DeleteAvailability::Available);
    let explanation = match availability {
        DeleteAvailability::Unavailable(block) => block.explanation(),
        DeleteAvailability::Available => None,
    };
    let tooltip = explanation.unwrap_or_else(|| crate::i18n::gettext("Delete Selected Rows"));
    button.set_tooltip_text(Some(&tooltip));
}

fn clear_box(b: &gtk::Box) {
    while let Some(child) = b.first_child() {
        b.remove(&child);
    }
}

/// Update the selection-count badge in response to a `MultiSelection`
/// change. Hidden for 0–1 rows; shows "{n} selected · press Delete to
/// remove" once the user multi-selects, so the affordance stays
/// discoverable without a toolbar Delete button.
fn update_selection_chrome(label: &gtk::Label, n: u32) {
    if n <= 1 {
        label.set_visible(false);
        return;
    }
    let count = n.to_string();
    label.set_label(&crate::i18n::gettext_f(
        "{n} selected · press Delete to remove",
        &[("n", &count)],
    ));
    label.set_visible(true);
}

/// The result-column view of a catalogue column list, for a result the
/// grid renders from the schema it already has.
fn result_columns(columns: &[tablepro_core::ColumnInfo]) -> std::sync::Arc<[tablepro_core::column::ResultColumn]> {
    columns.iter().map(|column| column.result_column()).collect()
}
