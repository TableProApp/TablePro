//! A table's rows in a workspace tab.
//!
//! The tab reads its own columns, pages and row count through the
//! session, one request of each kind at a time: a newer request stops
//! the one it replaces, and a reply to a replaced request is dropped.
//! A read that failed is asked again once the session reconnects. A
//! count is not: it runs only when the estimate or the user asks.
//!
//! An input belongs to the group of state it changes, and each group is
//! handled in its own `*_handlers` module.

mod browse_actions;
mod browse_command;
mod browse_pager;
mod browse_request_kind;
mod browse_tab_input;
mod browse_tab_widgets;
mod column_recheck;
mod columns_fetch;
mod command_handlers;
mod count_failure_text;
mod count_policy;
mod data_handlers;
mod data_input;
mod fetch;
mod grid_handlers;
mod grid_input;
mod imp;
mod layout;
mod page_label;
mod page_reply;
mod page_state;
mod pager_bar;
mod paging_handlers;
mod paging_input;
mod pending_changes_bar;
mod row_count;
mod row_total;
mod save_handlers;
mod save_input;
mod table_filter;
#[cfg(test)]
mod tests;

use std::cell::Cell;
use std::collections::BTreeSet;
use std::rc::Rc;
use std::sync::Arc;

use gtk4 as gtk;
use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use libadwaita as adw;
use tablepro_core::browse::RowReference;
use tablepro_core::dialect::{SqlDialect, TablePaging};
use tablepro_core::meta::{RowIdentity, TableRef};
use tablepro_core::{ColumnInfo, FilterSet};
use tablepro_session::operation::DeadlinePolicy;
use tablepro_session::runtime::{Tasks, WatchForwarder};
use tablepro_session::{LinkGeneration, Session};
use tablepro_storage::AppSettings;

use self::browse_actions::BrowseActions;
pub(crate) use self::browse_command::{BrowseCommand, ColumnsReply};
use self::browse_pager::BrowsePager;
pub(crate) use self::browse_request_kind::BrowseRequestKind;
pub(crate) use self::browse_tab_input::BrowseTabInput;
use self::browse_tab_widgets::BrowseTabWidgets;
use self::column_recheck::ColumnRecheck;
pub(crate) use self::data_input::DataInput;
use self::grid_input::GridInput;
pub(crate) use self::page_reply::PageReply;
use self::page_state::PageState;
#[cfg(test)]
pub(super) use self::pager_bar::PagerBar;
pub(crate) use self::paging_input::PagingInput;
#[cfg(test)]
pub(super) use self::pending_changes_bar::PendingChangesBar;
pub(crate) use self::row_total::RowTotal;
pub(crate) use self::save_input::SaveInput;
pub(crate) use self::table_filter::TableFilter;
use super::data_grid::{DataGrid, GridSorting, KeysHandle};
use super::filter_strip::FilterStrip;
use super::tab_load::{ContentLoad, FirstLoad, start_first_load};
use crate::runtime::{FailedRequests, RequestSequencer};
use crate::services::tab_tracker_handle::TabTrackerHandle;
use crate::ui::export::ExportOffer;

const PAGE_SIZE_OPTIONS: &[u64] = &[100, 500, 1_000, 5_000, 10_000];
const DEFAULT_PAGE_SIZE: u64 = 1_000;

glib::wrapper! {
    pub struct BrowseTab(ObjectSubclass<imp::BrowseTab>)
        @extends adw::BreakpointBin, gtk::Widget,
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
    pub filter: TableFilter,
    pub column_widths: crate::persistence::ColumnWidthStore,
    pub filter_settings: crate::persistence::FilterSettingsStore,
    /// The session the tab reads through. The tab belongs to it and is
    /// closed before it shuts down.
    pub session: Arc<Session>,
    pub tasks: Tasks,
    /// The session's deadlines, which a count that ran out names.
    pub deadlines: Arc<dyn DeadlinePolicy>,
    /// Read when the grid needs them, so a change in Preferences reaches
    /// open tabs.
    pub settings: Rc<AppSettings>,
    pub first_load: FirstLoad,
}

impl BrowseTab {
    pub fn new(init: BrowseTabInit) -> Self {
        let tab: Self = glib::Object::new();
        // The model and the inline strip start with the same FilterSet.
        let (initial_filter, reveal_filter) = init.filter.opening(|| {
            init.connection_id
                .map(|id| init.filter_settings.filters(id, init.schema.as_deref(), &init.table))
                .unwrap_or_default()
        });
        let table = TableRef::new(init.schema.clone(), init.table.clone());
        let table_label = qualified(init.schema.as_deref(), &init.table);
        let widgets = layout::build(
            &tab,
            &layout::LayoutInit {
                table_label: &table_label,
                read_only: init.read_only,
                page_size: init.page_size,
            },
        );
        let dialect = init.session.current_dialect();
        let filter_strip = layout::filter_strip(&tab, &initial_filter, dialect.clone());
        if reveal_filter {
            filter_strip.set_revealed(true);
        }
        let actions = browse_actions::install_browse_actions(&tab, init.page_size);
        // A sort saved with the tab cannot reach an engine that reads
        // in its own order.
        let initial_sort = init.initial_sort.filter(|_| sorts_rows(dialect.as_deref()));
        let keys = KeysHandle::new(table.clone());
        let grid = layout::grid(
            &tab,
            layout::GridInit {
                table,
                label: table_label,
                connection_id: init.connection_id,
                sorting: grid_sorting(dialect.as_deref(), initial_sort),
                tracker: init.tracker.clone(),
                settings: init.settings,
                layouts: init.column_widths.layouts().clone(),
                keys: keys.clone(),
                session: Arc::downgrade(&init.session),
                tasks: init.tasks.clone(),
            },
        );
        let link_changes = init.session.link_changes();
        let model = BrowseModel {
            this: tab.downgrade(),
            link_generation: init.session.link_generation(),
            session: init.session,
            tasks: init.tasks,
            sequencer: RequestSequencer::new(),
            failed: FailedRequests::new(),
            after_columns: BTreeSet::new(),
            recheck: ColumnRecheck::default(),
            issued_on: std::collections::BTreeMap::new(),
            identity: None,
            dialect,
            keys,
            tracker: init.tracker,
            schema: init.schema,
            table: init.table,
            connection_id: init.connection_id,
            read_only: init.read_only,
            filter_settings: init.filter_settings,
            pager: BrowsePager::new(init.page_size, init.initial_offset),
            deadlines: init.deadlines,
            current_sort: initial_sort,
            current_filter: initial_filter,
            current_columns: Vec::new(),
            page: None,
            shown_view: None,
            total: RowTotal::Unknown,
            load: ContentLoad::default(),
            tab_loading: false,
            content_had_focus: false,
            grid,
            grid_actions_shown: false,
            was_dirty: Cell::new(false),
            filter_strip,
            actions,
            saving: Cell::new(false),
            suppress_combo_emit: Cell::new(true),
            widgets,
        };
        tab.imp().model.replace(Some(model));
        tab.start(link_changes, init.first_load);
        tab
    }

    /// Follow reconnects for as long as the tab is open, and read the
    /// table once the tab is first shown, or at once.
    fn start(&self, link_changes: tokio::sync::watch::Receiver<LinkGeneration>, first_load: FirstLoad) {
        self.imp().link_watch.replace(Some(WatchForwarder::new(
            link_changes,
            {
                let tab = self.downgrade();
                move |generation: LinkGeneration| {
                    if let Some(tab) = tab.upgrade() {
                        tab.send(DataInput::LinkChanged(generation));
                    }
                }
            },
            |future| {
                glib::spawn_future_local(future);
            },
        )));
        start_first_load(self, first_load, {
            let tab = self.downgrade();
            move || {
                if let Some(tab) = tab.upgrade() {
                    tab.send(DataInput::Start);
                }
            }
        });
    }

    /// Hand the tab an input. One that arrives while another is being
    /// handled, from a widget signal the handler set off, waits for it
    /// to finish rather than running inside it.
    pub(crate) fn send(&self, msg: impl Into<BrowseTabInput>) {
        let imp = self.imp();
        imp.queue.borrow_mut().push_back(msg.into());
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

    /// Commit the cell edit open in the grid, as Return does, so the close
    /// prompts count what was typed.
    pub fn commit_cell_edit(&self) {
        if let Some(grid) = self.imp().grid.get() {
            grid.commit_edit();
        }
    }

    #[cfg(test)]
    pub(crate) fn grid(&self) -> DataGrid {
        self.imp().grid.get().cloned().expect("the tab builds its grid")
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

    /// The filter the rows on screen were read under, not what the strip
    /// holds before Apply.
    pub fn applied_filter(&self) -> FilterSet {
        self.read(|model| model.current_filter.clone()).unwrap_or_default()
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

    /// The grid asked to open the rows a foreign key leads to.
    pub(crate) fn connect_follow_reference<F: Fn(&Self, RowReference) + 'static>(&self, f: F) -> glib::SignalHandlerId {
        self.connect_closure(
            "follow-reference",
            false,
            glib::closure_local!(move |tab: &Self, payload: glib::BoxedAnyObject| {
                f(tab, payload.borrow::<RowReference>().clone());
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
            BrowseTabOutput::Export(offer) => {
                self.emit_by_name::<()>("export-results", &[&glib::BoxedAnyObject::new(*offer)]);
            }
            BrowseTabOutput::ShowAlert { title, body } => self.emit_by_name::<()>("alert", &[&title, &body]),
            BrowseTabOutput::ShowToast(text) => self.emit_by_name::<()>("toast", &[&text]),
            BrowseTabOutput::DirtyChanged(dirty) => self.emit_by_name::<()>("dirty-changed", &[&dirty]),
            BrowseTabOutput::SaveRequested => self.emit_by_name::<()>("save-requested", &[]),
            BrowseTabOutput::StopSaveRequested => self.emit_by_name::<()>("stop-save-requested", &[]),
            BrowseTabOutput::LoadingChanged(loading) => self.emit_by_name::<()>("loading-changed", &[&loading]),
            BrowseTabOutput::RefreshRequested => self.emit_by_name::<()>("refresh-requested", &[]),
            BrowseTabOutput::FollowReference(reference) => {
                self.emit_by_name::<()>("follow-reference", &[&glib::BoxedAnyObject::new(reference)]);
            }
        }
    }
}

/// The signals one input left to emit once it was handled.
#[derive(Default)]
pub(crate) struct Effects {
    outputs: Vec<BrowseTabOutput>,
}

impl Effects {
    fn output(&mut self, output: BrowseTabOutput) {
        self.outputs.push(output);
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
    /// The table's foreign keys, which the grid's menus read as they open.
    keys: KeysHandle,

    tracker: TabTrackerHandle,
    schema: Option<String>,
    table: String,
    connection_id: Option<uuid::Uuid>,
    read_only: bool,
    filter_settings: crate::persistence::FilterSettingsStore,

    /// Where the page the tab reads starts, and how many rows it holds.
    pager: BrowsePager,
    deadlines: Arc<dyn DeadlinePolicy>,
    current_sort: Option<(usize, bool)>,
    /// The WHERE every page and count reads under, kept per connection,
    /// schema and table.
    current_filter: tablepro_core::FilterSet,
    current_columns: Vec<ColumnInfo>,
    /// The page on screen, whose rows the grid holds.
    page: Option<PageState>,
    /// What `page` was read under. A read that fails while asking for
    /// that same page again leaves it on screen.
    shown_view: Option<PageView>,
    /// The table's row count under the filter, as far as the tab knows.
    total: RowTotal,
    load: ContentLoad,
    /// What the tab bar was last told, so it hears only changes.
    tab_loading: bool,
    /// The rows held the focus when the loading page, which has nothing
    /// to focus, took their place.
    content_had_focus: bool,

    /// The tab's one grid, for its whole life.
    grid: DataGrid,
    /// The grid's actions are on the tab, for its buttons and menu.
    grid_actions_shown: bool,
    /// Last-emitted dirty state, so App hears only real transitions and
    /// not every count change (2 → 3).
    was_dirty: Cell<bool>,
    filter_strip: FilterStrip,
    actions: BrowseActions,
    /// Between the save starting and settling.
    saving: Cell<bool>,
    /// Set until the first page lands, so the page-size dropdown being
    /// set from a restored state does not count as the user choosing.
    suppress_combo_emit: Cell<bool>,
    widgets: BrowseTabWidgets,
}

#[derive(Debug)]
pub(crate) enum BrowseTabOutput {
    /// Something the window keeps for the tab changed: the page, the
    /// sort, the page size.
    StateChanged,
    Export(Box<ExportOffer>),
    /// What a toast is too short to say, as why a save failed.
    ShowAlert {
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
    /// The grid asked to open the rows a foreign key leads to.
    FollowReference(RowReference),
}

impl BrowseModel {
    fn update(&mut self, msg: BrowseTabInput, fx: &mut Effects) {
        match msg {
            BrowseTabInput::Data(input) => self.on_data(input, fx),
            BrowseTabInput::Paging(input) => self.on_paging(input, fx),
            BrowseTabInput::Save(input) => self.on_save(input, fx),
            BrowseTabInput::Grid(input) => self.on_grid(input, fx),
        }
    }

    fn table_ref(&self) -> TableRef {
        TableRef::new(self.schema.clone(), self.table.clone())
    }

    fn sorts_rows(&self) -> bool {
        sorts_rows(self.dialect.as_deref())
    }

    fn grid_sorting(&self) -> GridSorting {
        grid_sorting(self.dialect.as_deref(), self.current_sort)
    }

    fn table_label(&self) -> String {
        qualified(self.schema.as_deref(), &self.table)
    }

    /// The page whose rows the grid shows. A failed read of another page
    /// leaves the rows it replaced in the grid, behind the error page,
    /// where nothing may export, copy or delete them.
    fn shown_page(&self) -> Option<&PageState> {
        self.page.as_ref().filter(|_| self.load.has_content())
    }

    fn rows_on_page(&self) -> u64 {
        self.shown_page().map_or(0, |page| page.row_count as u64)
    }

    fn has_primary_key(&self) -> bool {
        self.current_columns.iter().any(|c| c.primary_key)
    }
}

/// Whether a page of a table can be sorted on its engine. Without a
/// connection yet, a sort is kept for when one opens.
fn sorts_rows(dialect: Option<&dyn SqlDialect>) -> bool {
    dialect.is_none_or(|dialect| dialect.table_paging() == TablePaging::InStatement)
}

/// The server sorts the page, except on an engine that reads a table
/// only in its own order.
fn grid_sorting(dialect: Option<&dyn SqlDialect>, sort: Option<(usize, bool)>) -> GridSorting {
    match sorts_rows(dialect) {
        true => GridSorting::Server { initial: sort },
        false => GridSorting::None,
    }
}

/// A status page reads its description as markup, and a table's name
/// can hold an `&` or a `<`.
fn loading_description(table: &str) -> glib::GString {
    glib::markup_escape_text(&crate::i18n::gettext_f(
        "Fetching rows from {table}",
        &[("table", table)],
    ))
}

fn qualified(schema: Option<&str>, table: &str) -> String {
    match schema {
        Some(s) => format!("{s}.{table}"),
        None => table.to_owned(),
    }
}
