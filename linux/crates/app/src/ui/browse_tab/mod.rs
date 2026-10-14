//! A table's rows in a workspace tab.
//!
//! The tab reads its own columns, pages and row count through the
//! session, one request of each kind at a time: a newer request stops
//! the one it replaces, and a reply to a replaced request is dropped.
//! A read that failed is asked again once the session reconnects.

mod browse_command;
mod browse_request_kind;
mod fetch;
mod imp;
mod page_reply;
mod row_deletion;
#[cfg(test)]
mod tests;

use std::cell::{Cell, RefCell};
use std::collections::{BTreeSet, VecDeque};
use std::rc::Rc;
use std::sync::Arc;

use gtk4 as gtk;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use gtk4::{gdk, gio, glib};
use libadwaita as adw;
use libadwaita::prelude::*;
use tablepro_core::dialect::SqlDialect;
use tablepro_core::edit::{CellInput, EditParseError, parse_edit_text};
use tablepro_core::export::RenderInsertError;
use tablepro_core::meta::{RowIdentity, TableRef};
use tablepro_core::{ColumnInfo, QueryResult, Value};
use tablepro_session::runtime::{Tasks, WatchForwarder};
use tablepro_session::{LinkGeneration, Session};

pub(crate) use self::browse_command::{BrowseCommand, ColumnsReply};
pub(crate) use self::browse_request_kind::BrowseRequestKind;
pub(crate) use self::page_reply::PageReply;
use self::row_deletion::{RowDeletion, plan_row_deletion};
use super::grid::{
    CellPreset, ColumnWidthBinding, DeleteAvailability, GridCell, GridMsg, GridRowId, GridRowIndex, GridSink,
    RowObject, TabGridContext, build_column_view, cell_editability, cell_presets, delete_availability, edit_context,
};
use crate::runtime::{FailedRequests, RequestSequencer};
use crate::services::change_tracker::{RowKey, StatementSource, new_draft_cell, pk_identity};
use crate::services::save_batch::SaveTarget;
use crate::services::tab_tracker_handle::TabTrackerHandle;
use crate::services::tracker_delta::TrackerDelta;
use crate::services::tracker_edit::TrackerEdit;

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
}

/// Rows the user asked to write to a file, and what to call it.
#[derive(Debug, Clone)]
pub struct ExportRequest {
    pub result: QueryResult,
    pub name: String,
    pub target: Option<crate::ui::export_dialog::SqlTarget>,
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
        imp.delete_button.set_icon_name(crate::ui::icons::LIST_REMOVE);

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
        let delete_action = tab.install_delete_action();

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
            current_offset: init.initial_offset,
            page_size: init.page_size,
            current_sort: init.initial_sort,
            current_filter: initial_filter,
            current_columns: Vec::new(),
            current_result: None,
            shown_view: None,
            current_selection: None,
            current_total_rows: None,
            inner_stack: imp.inner_stack.get(),
            grid_holder: imp.grid_holder.get(),
            loading_page: imp.loading_page.get(),
            error_page: imp.error_page.get(),
            current_column_view: None,
            row_index: GridRowIndex::default(),
            rendered_columns: Vec::new(),
            read_only_banner: imp.read_only_banner.get(),
            no_pk_banner: imp.no_pk_banner.get(),
            was_dirty: Cell::new(false),
            pending_focus_restore: RefCell::new(None),
            paginator_label: imp.paginator_label.get(),
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
            delete_action,
            pending_revealer: imp.pending_revealer.get(),
            save_button: imp.save_button.get(),
            discard_button: imp.discard_button.get(),
            saving_spinner: imp.saving_spinner.get(),
            stop_button: imp.stop_button.get(),
            pending_label: imp.pending_label.get(),
            grid_sink,
            suppress_combo_emit: Cell::new(true),
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

    pub fn snapshot(&self) -> Option<QueryResult> {
        self.read(|model| model.current_result.clone()).flatten()
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
        self.read(|model| model.current_offset).unwrap_or_default()
    }

    pub fn page_size(&self) -> u64 {
        self.read(|model| model.page_size).unwrap_or(DEFAULT_PAGE_SIZE)
    }

    pub fn current_sort(&self) -> Option<(usize, bool)> {
        self.read(|model| model.current_sort).flatten()
    }

    pub fn connect_state_changed<F: Fn(&Self) + 'static>(&self, f: F) -> glib::SignalHandlerId {
        self.connect_closure("state-changed", false, glib::closure_local!(move |tab: &Self| f(tab)))
    }

    pub fn connect_copy_to_clipboard<F: Fn(&Self, String) + 'static>(&self, f: F) -> glib::SignalHandlerId {
        self.connect_closure(
            "copy-to-clipboard",
            false,
            glib::closure_local!(move |tab: &Self, text: String| f(tab, text)),
        )
    }

    pub fn connect_export_results<F: Fn(&Self, ExportRequest) + 'static>(&self, f: F) -> glib::SignalHandlerId {
        self.connect_closure(
            "export-results",
            false,
            glib::closure_local!(move |tab: &Self, payload: glib::BoxedAnyObject| {
                f(tab, payload.borrow::<ExportRequest>().clone());
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

    /// Stop Saving asked the window to stop the tab's save.
    pub fn connect_stop_save_requested<F: Fn(&Self) + 'static>(&self, f: F) -> glib::SignalHandlerId {
        self.connect_closure(
            "stop-save-requested",
            false,
            glib::closure_local!(move |tab: &Self| f(tab)),
        )
    }

    fn emit_output(&self, output: BrowseTabOutput) {
        match output {
            BrowseTabOutput::StateChanged => self.emit_by_name::<()>("state-changed", &[]),
            BrowseTabOutput::CopyToClipboard(text) => self.emit_by_name::<()>("copy-to-clipboard", &[&text]),
            BrowseTabOutput::ExportResults(request) => {
                self.emit_by_name::<()>("export-results", &[&glib::BoxedAnyObject::new(request)]);
            }
            BrowseTabOutput::ShowSelectionAlert { title, body } => {
                self.emit_by_name::<()>("alert", &[&title, &body]);
            }
            BrowseTabOutput::ShowToast(text) => self.emit_by_name::<()>("toast", &[&text]),
            BrowseTabOutput::DirtyChanged(dirty) => self.emit_by_name::<()>("dirty-changed", &[&dirty]),
            BrowseTabOutput::SaveRequested => self.emit_by_name::<()>("save-requested", &[]),
            BrowseTabOutput::StopSaveRequested => self.emit_by_name::<()>("stop-save-requested", &[]),
        }
    }

    /// The top-bar slot draws a thin strip even when every banner in it
    /// is collapsed, so the slot itself is hidden unless one shows.
    fn collapse_top_bars_with(&self, filter: &gtk::Revealer) {
        let imp = self.imp();
        // The banners and the strip hold this through their notify
        // handlers, and the tab holds them, so it holds all four weakly.
        let sync: Rc<dyn Fn()> = {
            let toolbar = imp.toolbar.downgrade();
            let read_only = imp.read_only_banner.downgrade();
            let no_pk = imp.no_pk_banner.downgrade();
            let filter = filter.downgrade();
            Rc::new(move || {
                let (Some(toolbar), Some(read_only), Some(no_pk), Some(filter)) = (
                    toolbar.upgrade(),
                    read_only.upgrade(),
                    no_pk.upgrade(),
                    filter.upgrade(),
                ) else {
                    return;
                };
                toolbar.set_reveal_top_bars(read_only.is_revealed() || no_pk.is_revealed() || filter.reveals_child());
            })
        };
        sync();
        let read_only_sync = sync.clone();
        imp.read_only_banner.connect_revealed_notify(move |_| read_only_sync());
        let no_pk_sync = sync.clone();
        imp.no_pk_banner.connect_revealed_notify(move |_| no_pk_sync());
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
        on_click(&imp.insert_button, || BrowseTabInput::InsertRow);
        on_click(&imp.first_button, || BrowseTabInput::FirstPage);
        on_click(&imp.prev_button, || BrowseTabInput::PrevPage);
        on_click(&imp.next_button, || BrowseTabInput::NextPage);
        on_click(&imp.last_button, || BrowseTabInput::LastPage);
        on_click(&imp.export_button, || BrowseTabInput::ExportCurrentPage);
        on_click(&imp.discard_button, || BrowseTabInput::DiscardAll);
        on_click(&imp.save_button, || BrowseTabInput::CommitSave);
        on_click(&imp.stop_button, || BrowseTabInput::StopSaving);
        let tab = self.downgrade();
        imp.page_size_dropdown.connect_selected_notify(move |dropdown| {
            let index = usize::try_from(dropdown.selected()).unwrap_or(usize::MAX);
            if let (Some(tab), Some(&size)) = (tab.upgrade(), PAGE_SIZE_OPTIONS.get(index)) {
                tab.send(BrowseTabInput::PageSizeChanged(size));
            }
        });
    }

    /// `tab.delete-rows`, which the Delete key and the Delete button
    /// both name. While it is disabled the key goes on to the window.
    fn install_delete_action(&self) -> gio::SimpleAction {
        let action = gio::SimpleAction::new("delete-rows", None);
        action.set_enabled(false);
        let tab = self.downgrade();
        action.connect_activate(move |_, _| {
            let Some(tab) = tab.upgrade() else {
                return;
            };
            let rows = tab.read(BrowseModel::selected_rows).unwrap_or_default();
            tab.send(BrowseTabInput::DeleteRows(rows));
        });
        let group = gio::SimpleActionGroup::new();
        group.add_action(&action);
        self.insert_action_group("tab", Some(&group));

        let shortcuts = gtk::ShortcutController::new();
        shortcuts.add_shortcut(gtk::Shortcut::new(
            Some(gtk::KeyvalTrigger::new(gdk::Key::Delete, gdk::ModifierType::empty())),
            Some(gtk::NamedAction::new("tab.delete-rows")),
        ));
        self.add_controller(shortcuts);
        action
    }

    /// Set the focused cell to NULL, for Ctrl+Shift+N. A locked cell
    /// lets the key go on.
    fn set_focused_cell_null(&self) -> glib::Propagation {
        // `RootExt::focus` would return the window itself.
        let focus = self
            .root()
            .and_downcast::<gtk::Window>()
            .and_then(|window| gtk::prelude::GtkWindowExt::focus(&window));
        let Some(cell) = focus.as_ref().and_then(GridCell::from_focus) else {
            return glib::Propagation::Proceed;
        };
        let (None, Some(row)) = (cell.lock(), cell.row()) else {
            return glib::Propagation::Proceed;
        };
        self.send(BrowseTabInput::GridSetCellValue {
            row,
            column: cell.column(),
            preset: CellPreset::Null,
        });
        glib::Propagation::Stop
    }
}

impl From<GridMsg> for BrowseTabInput {
    fn from(msg: GridMsg) -> Self {
        match msg {
            GridMsg::SortChanged(col_idx, ascending) => Self::SortChanged { col_idx, ascending },
            GridMsg::Edit { row, column, edit } => Self::GridEdit { row, column, edit },
            GridMsg::CopyToClipboard(text) => Self::GridCopyToClipboard(text),
            GridMsg::ShowToast(text) => Self::GridShowToast(text),
            GridMsg::CopyRowsAsInsert { rows } => Self::GridCopyRowsAsInsert(rows),
            GridMsg::SetCellValue { row, column, preset } => Self::GridSetCellValue { row, column, preset },
            GridMsg::ExportResults(result) => Self::GridExportResults(result),
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
    /// Reads that wait for the columns, because a page and a count are
    /// built from them.
    after_columns: BTreeSet<BrowseRequestKind>,
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

    current_offset: u64,
    page_size: u64,
    current_sort: Option<(usize, bool)>,
    /// The WHERE every page and count reads under, kept per connection,
    /// schema and table.
    current_filter: tablepro_core::FilterSet,
    current_columns: Vec<ColumnInfo>,
    current_result: Option<QueryResult>,
    /// What `current_result` was read under. A read that fails while
    /// asking for that same page again leaves it on screen.
    shown_view: Option<PageView>,
    current_selection: Option<gtk::MultiSelection>,
    current_total_rows: Option<u64>,

    inner_stack: gtk::Stack,
    grid_holder: gtk::Box,
    loading_page: adw::StatusPage,
    error_page: adw::StatusPage,
    current_column_view: Option<gtk::ColumnView>,
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
    /// The focused row before a sort, save or refresh, so the reloaded
    /// page selects it again.
    pending_focus_restore: RefCell<Option<RowKey>>,
    paginator_label: gtk::Label,
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
    /// `tab.delete-rows`, enabled while the selection can be deleted.
    delete_action: gio::SimpleAction,
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
    /// Delete over these rows, from the key, the button or the menu.
    DeleteRows(Vec<RowObject>),
    /// An edit the grid parsed for the column, which the tab checks
    /// against the cell's lock before the tracker takes it.
    GridEdit {
        row: RowObject,
        column: usize,
        edit: TrackerEdit,
    },
    /// A preset from a cell's menu or Ctrl+Shift+N. The tab resolves it
    /// against the column, so both paths reach the same value.
    GridSetCellValue {
        row: RowObject,
        column: usize,
        preset: CellPreset,
    },
    GridShowToast(String),
    GridExportResults(QueryResult),
    ExportCurrentPage,
    GridCopyRowsAsInsert(Vec<RowObject>),
    DuplicateRows(Vec<RowObject>),
    GridCopyToClipboard(String),
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
    /// The save landed. Edits made while it ran stay pending.
    SaveCommitted,
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
    SelectAllRows,
    GoToFirstRow,
    GoToLastRow,
}

#[derive(Debug)]
pub(crate) enum BrowseTabOutput {
    /// Something the window keeps for the tab changed: the page, the
    /// sort, the page size.
    StateChanged,
    CopyToClipboard(String),
    ExportResults(ExportRequest),
    ShowSelectionAlert {
        title: String,
        body: String,
    },
    ShowToast(String),
    DirtyChanged(bool),
    SaveRequested,
    StopSaveRequested,
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

    /// A page's rows, each named by its primary key, which is the key
    /// the tracker files its edits under.
    fn page_rows(&self, result: &QueryResult) -> Vec<RowObject> {
        let pk_indices = self.pk_indices();
        result
            .rows
            .iter()
            .map(|cells| RowObject::persisted(persisted_key(cells, &pk_indices), cells.clone().into()))
            .collect()
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

    fn pk_indices(&self) -> Vec<usize> {
        self.current_columns
            .iter()
            .enumerate()
            .filter(|(_, c)| c.primary_key)
            .map(|(i, _)| i)
            .collect()
    }

    /// What the paginator's Export button writes. Built from the live
    /// grid so it matches the context menu's Export Results row for
    /// row; falls back to the fetch itself before the grid exists.
    fn export_payload(&self) -> Option<QueryResult> {
        let current = self.current_result.as_ref()?;
        let Some(column_view) = self.current_column_view.as_ref() else {
            return Some(current.clone());
        };
        Some(super::grid::export_snapshot(
            column_view,
            &current.columns,
            current.truncated,
            &self.grid_context(),
        ))
    }

    /// Resolve a preset against the column it lands in. The menu offers
    /// only the ones the cell can take; the keyboard's Set NULL reaches
    /// here for any cell, and a column that refuses the value says why,
    /// as committing an empty cell would.
    fn resolve_cell_preset(&self, preset: CellPreset, row: &RowObject, col: usize) -> Result<CellInput, String> {
        let Some(column) = self.current_columns.get(col) else {
            return Err(crate::ui::error_text::edit_parse_message(&EditParseError::Required));
        };
        let presets = cell_presets(column, row.id());
        match preset {
            CellPreset::Empty => parse_edit_text("", column, edit_context(row.id()))
                .map_err(|error| crate::ui::error_text::edit_parse_message(&error)),
            CellPreset::Null if presets.null => Ok(CellInput::Value(Value::Null)),
            CellPreset::Null => Err(crate::ui::error_text::edit_parse_message(&EditParseError::Required)),
            CellPreset::Default if presets.default => Ok(CellInput::Default),
            CellPreset::Default => Err(crate::i18n::gettext("This cell can't take the column's default")),
        }
    }

    fn table_label(&self) -> String {
        qualified(self.schema.as_deref(), &self.table)
    }

    /// While a save runs, Save and Discard are off, so a double click
    /// cannot send two, and Stop Saving takes their place.
    fn show_saving(&self, saving: bool) {
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

    /// The rows on screen can change under the selection without it
    /// changing, so this runs on every delta and page as well.
    fn sync_delete_action(&self) {
        show_delete_availability(
            &self.delete_action,
            &self.delete_button,
            &self.selected_rows(),
            self.read_only,
        );
    }

    /// The footer and the tab's dirty flag, which App turns into the
    /// title bullet. App hears only real transitions.
    fn sync_pending_chrome(&self, count: usize, fx: &mut Effects) {
        self.refresh_pending_bar(count);
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
    /// tab, then the page and the count built from them.
    fn reload(&mut self) {
        self.capture_focus_for_restore();
        self.show_loading();
        self.reload_from_columns(true);
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

    /// Snapshot the currently focused/first-selected row's identity
    /// before an operation that reloads the page (sort flip, save, F5),
    /// so the view re-anchors to the same row after the new page.
    fn capture_focus_for_restore(&self) {
        // A capture still pending (sort and save in quick succession)
        // is kept: the first visible focus should anchor to where the
        // user was before the chain started.
        if self.pending_focus_restore.borrow().is_some() {
            return;
        }
        let Some(selection) = self.current_selection.as_ref() else {
            return;
        };
        let bitset = selection.selection();
        if bitset.size() == 0 {
            return;
        }
        let Some(row) = selection.item(bitset.nth(0)).and_downcast::<RowObject>() else {
            return;
        };
        *self.pending_focus_restore.borrow_mut() = row.id().tracker_key();
    }

    /// Scroll + focus + select the freshly-prepended draft row, then
    /// open its first editable cell for input. Queued on idle so the
    /// inner-stack flip (empty → grid) has time to allocate the
    /// ScrolledWindow's adjustments before `cv.scroll_to(...)` runs:
    /// in the same tick GTK aborts with
    /// `gtk_list_base_update_adjustments: bounds.y == 0`.
    fn focus_inserted_draft(&self) {
        let Some(cv) = self.current_column_view.clone() else {
            return;
        };
        let selection = self.current_selection.clone();
        glib::idle_add_local_once(move || {
            // The column view may be detached by now (F5 between the
            // insert and this idle). The row was inserted; only the
            // auto-edit is missed.
            if cv.root().is_none() {
                return;
            }
            // New drafts always land at position 0 (prepended).
            if let Some(sel) = selection.as_ref() {
                sel.select_item(0, true);
            }
            cv.scroll_to(
                0,
                None,
                gtk::ListScrollFlags::FOCUS | gtk::ListScrollFlags::SELECT,
                None,
            );
            let Some(window) = cv.root().and_then(|r| r.dynamic_cast::<gtk::Window>().ok()) else {
                return;
            };
            let Some(focused) = gtk::prelude::GtkWindowExt::focus(&window) else {
                return;
            };
            if let Some(cell) = GridCell::from_focus(&focused) {
                super::grid::begin_edit(&cell);
            }
        });
    }

    /// Select the row captured before the reload again, if it is still on
    /// the page. The capture is used up either way, so it cannot steer a
    /// later reload.
    fn restore_focused_row(&mut self) {
        let Some(key) = self.pending_focus_restore.borrow_mut().take() else {
            return;
        };
        let Some(store) = self.list_store() else {
            return;
        };
        let Some(position) = self.row_index.position_in(&store, &key) else {
            return;
        };
        if let Some(selection) = self.current_selection.as_ref() {
            selection.select_item(position, true);
        }
        if let Some(cv) = self.current_column_view.as_ref() {
            cv.scroll_to(position, None, gtk::ListScrollFlags::FOCUS, None);
        }
    }

    /// Build the `ColumnView` once both the columns and the current
    /// page are in. Until then the stack stays on the loading page, so
    /// the user cannot edit cells whose editability is not known yet.
    fn render_grid_if_ready(&mut self, fx: &mut Effects) {
        let Some(result) = self.current_result.clone() else {
            return;
        };
        if self.current_columns.is_empty() {
            return;
        }

        // Same columns as the last render (sort flips, page changes,
        // save reloads): keep the `ColumnView` and only refresh the
        // `ListStore`.
        if self.column_view_matches_current_columns()
            && let Some(store) = self.list_store()
        {
            self.refresh_grid_data(&result, &store);
            self.refresh_grid_chrome(&result);
            self.restore_focused_row();
            fx.output(BrowseTabOutput::StateChanged);
            return;
        }

        clear_box(&self.grid_holder);
        let tab_ctx = self.grid_context();
        let (column_view, selection) = build_column_view(
            &result,
            self.page_rows(&result),
            &self.current_columns,
            self.grid_sink.clone(),
            self.current_sort,
            true,
            tab_ctx,
        );
        self.current_selection = Some(selection);
        self.current_column_view = Some(column_view.clone());
        self.rendered_columns = self.current_columns.clone();

        // The selection model is new per rebuild, so the previous
        // handler goes with the old one. The tab holds the selection, so
        // the handler holds the tab's widgets weakly.
        if let Some(sel) = self.current_selection.as_ref() {
            let label = self.selection_label.downgrade();
            let button = self.delete_button.downgrade();
            let action = self.delete_action.clone();
            let read_only = self.read_only;
            sel.connect_selection_changed(move |sel, _, _| {
                let (Some(label), Some(button)) = (label.upgrade(), button.upgrade()) else {
                    return;
                };
                let n = u32::try_from(sel.selection().size()).unwrap_or(u32::MAX);
                update_selection_chrome(&label, n);
                show_delete_availability(&action, &button, &selected_rows(sel), read_only);
            });
            update_selection_chrome(&self.selection_label, 0);
        }

        // Pending draft rows survive page changes, sort flips and F5:
        // the tracker holds them, and the rebuilt store would not.
        self.reprepend_drafts();
        self.reindex_rows();
        self.sync_delete_action();

        let scrolled = gtk::ScrolledWindow::builder()
            .child(&column_view)
            .hexpand(true)
            .vexpand(true)
            .build();
        self.grid_holder.append(&scrolled);
        self.refresh_grid_chrome(&result);
        self.restore_focused_row();
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
    fn drop_grid(&mut self) {
        if self.current_column_view.take().is_none() {
            return;
        }
        clear_box(&self.grid_holder);
        self.current_selection = None;
        self.rendered_columns.clear();
        self.row_index = GridRowIndex::default();
        update_selection_chrome(&self.selection_label, 0);
        self.sync_delete_action();
        self.show_loading();
    }

    /// New rows under the same columns. The drafts go back on top so
    /// they survive the swap.
    fn refresh_grid_data(&mut self, result: &QueryResult, store: &gtk::gio::ListStore) {
        store.remove_all();
        for row in self.page_rows(result) {
            store.append(&row);
        }
        self.reprepend_drafts();
        self.reindex_rows();
        self.sync_delete_action();
    }

    fn reindex_rows(&mut self) {
        match self.list_store() {
            Some(store) => self.row_index.rebuild(&store),
            None => self.row_index = GridRowIndex::default(),
        }
    }

    /// Paginator label, button sensitivity and stack child: chrome that
    /// depends on the result but not the column structure.
    fn refresh_grid_chrome(&self, result: &QueryResult) {
        self.refresh_crud_buttons();
        self.update_paginator_label();
        let on_first_page = self.current_offset == 0;
        self.first_button.set_sensitive(!on_first_page);
        self.prev_button.set_sensitive(!on_first_page);
        let n_rows = result.rows.len() as u64;
        self.next_button.set_sensitive(n_rows == self.page_size);
        // Last only enables when the total is known and the tab is not
        // already on the last page.
        let last_target = self
            .current_total_rows
            .filter(|t| *t > 0)
            .map(|t| (t - 1) / self.page_size * self.page_size);
        self.last_button
            .set_sensitive(last_target.is_some_and(|target| self.current_offset != target));

        self.refresh_inner_stack_visibility();
        self.suppress_combo_emit.set(false);
    }

    /// Switch the inner stack to the grid once the first page has
    /// loaded, and stay there whatever the row count: an empty-list
    /// status page hid the column view, and inserting a draft into it
    /// then scrolled a view with no allocated adjustments.
    fn refresh_inner_stack_visibility(&self) {
        if self.current_result.is_some() {
            self.inner_stack.set_visible_child_name("grid");
        }
    }

    fn reprepend_drafts(&self) {
        let Some(store) = self.list_store() else {
            return;
        };
        for draft in self.tracker.drafts() {
            store.insert(0, &RowObject::draft(draft.draft_id));
        }
    }

    fn has_primary_key(&self) -> bool {
        self.current_columns.iter().any(|c| c.primary_key)
    }

    fn refresh_crud_buttons(&self) {
        let has_columns = !self.current_columns.is_empty();
        let has_pk = self.has_primary_key();
        if self.read_only {
            self.insert_button.set_visible(false);
            return;
        }
        self.insert_button.set_visible(true);
        // No-PK tables don't get inline editing because RowKey can't be
        // formed without a PK. Disable instead of hide so the affordance
        // stays discoverable; the tooltip explains the gate.
        self.insert_button.set_sensitive(has_columns && has_pk);
        if has_columns && !has_pk {
            self.insert_button.set_tooltip_text(Some(&crate::i18n::gettext(
                "This table has no primary key. Inline editing is disabled.",
            )));
        } else {
            self.insert_button
                .set_tooltip_text(Some(&crate::i18n::gettext("Insert row (Ctrl+N)")));
        }
        self.refresh_banner_visibility();
    }

    fn refresh_filter_chrome(&self) {
        let n = self.current_filter.len();
        if n == 0 {
            self.filter_badge.set_visible(false);
            self.filter_badge.set_label("");
            self.filter_button
                .set_tooltip_text(Some(&crate::i18n::gettext("Filter rows (Ctrl+F)")));
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
        let Some(result) = self.current_result.as_ref() else {
            self.paginator_label.set_label("");
            return;
        };
        let n_rows = result.rows.len();
        if n_rows == 0 {
            // Reachable when the user navigated past the end of a
            // table that shrank in another session, before the count
            // clamps the offset back.
            self.paginator_label
                .set_label(&crate::i18n::gettext("No rows on this page"));
            return;
        }
        let start = self.current_offset + 1;
        let end = self.current_offset + n_rows as u64;
        let start_s = format_thousands(start);
        let end_s = format_thousands(end);
        let label = match self.current_total_rows {
            Some(total) => crate::i18n::gettext_f(
                "Rows {start} – {end} of {total}",
                &[
                    ("start", &start_s),
                    ("end", &end_s),
                    ("total", &format_thousands(total)),
                ],
            ),
            None => crate::i18n::gettext_f("Rows {start} – {end}", &[("start", &start_s), ("end", &end_s)]),
        };
        self.paginator_label.set_label(&label);
    }

    fn show_loading(&self) {
        self.loading_page.set_description(Some(&crate::i18n::gettext_f(
            "Fetching rows from {table}",
            &[("table", &self.table_label())],
        )));
        self.inner_stack.set_visible_child_name("loading");
    }

    /// Show why no rows could be read. The page and the count from
    /// before are dropped, so a later reload does not render against
    /// them before its own page arrives.
    fn show_error(&mut self, message: &str) {
        self.current_result = None;
        self.shown_view = None;
        self.current_total_rows = None;
        self.paginator_label.set_label("");
        self.first_button.set_sensitive(false);
        self.prev_button.set_sensitive(false);
        self.next_button.set_sensitive(false);
        self.last_button.set_sensitive(false);
        self.error_page.set_description(Some(message));
        self.inner_stack.set_visible_child_name("error");
    }

    fn on_rows_loaded(&mut self, offset: u64, mut result: QueryResult, fx: &mut Effects) {
        self.current_offset = offset;
        // A zero-row page has no columns of its own; the catalog's list
        // lets the headers render anyway.
        if result.columns.is_empty() && !self.current_columns.is_empty() {
            result.columns = result_columns(&self.current_columns);
        }
        self.current_result = Some(result);
        self.shown_view = Some(self.page_view());
        self.render_grid_if_ready(fx);
    }

    fn page_view(&self) -> PageView {
        PageView {
            filter: self.current_filter.clone(),
            sort: self.current_sort,
            offset: self.current_offset,
            limit: self.page_size,
        }
    }

    /// A read failed. When it asked again for the page on screen, as F5
    /// and a schema change do, the page stays and a toast says why; any
    /// other page on screen no longer matches what the tab asks for.
    fn on_read_failed(&mut self, message: &str, fx: &mut Effects) {
        if self.current_result.is_some() && self.shown_view.as_ref() == Some(&self.page_view()) {
            self.refresh_inner_stack_visibility();
            fx.output(BrowseTabOutput::ShowToast(crate::i18n::gettext_f(
                "Couldn't refresh the rows: {error}",
                &[("error", message)],
            )));
            return;
        }
        self.show_error(message);
    }

    fn on_columns_loaded(&mut self, columns: Vec<ColumnInfo>, fx: &mut Effects) {
        // A page read under other columns would put their names in the
        // headers, so the grid waits for the page read under these.
        if self.current_columns != columns {
            self.current_result = None;
            self.shown_view = None;
            self.drop_grid();
        }
        self.current_columns = columns.clone();
        let delta = self.tracker.set_target(SaveTarget {
            table: self.table_ref(),
            columns: columns.clone(),
        });
        self.apply_tracker_delta(&delta, fx);
        if let Some(result) = self.current_result.as_mut()
            && result.columns.is_empty()
        {
            result.columns = result_columns(&columns);
        }
        self.refresh_crud_buttons();
        // Operator lists narrow per type, so the strip rebuilds against
        // the new columns.
        if let Some(strip) = self.filter_strip.as_ref() {
            strip.update_columns(columns);
        }
        self.render_grid_if_ready(fx);
    }

    fn on_row_count_loaded(&mut self, count: u64, fx: &mut Effects) {
        self.current_total_rows = Some(count);
        // A saved offset past the end goes back to the last full page,
        // for rows another session deleted since.
        if self.current_offset > 0 && count > 0 && self.current_offset >= count {
            let last_page_offset = count.saturating_sub(1) / self.page_size * self.page_size;
            if last_page_offset != self.current_offset {
                self.current_offset = last_page_offset;
                self.fetch(BrowseRequestKind::Page, fx);
                fx.output(BrowseTabOutput::StateChanged);
            }
        }
        self.update_paginator_label();
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
                self.reload_from_columns(true);
            }
            BrowseTabInput::Command(command) => self.on_command(command, fx),
            BrowseTabInput::LinkChanged(generation) => self.on_link_changed(generation, fx),
            BrowseTabInput::SchemaChanged => {
                self.capture_focus_for_restore();
                self.reload_from_columns(false);
            }
            BrowseTabInput::Refresh => self.reload(),
            BrowseTabInput::DiscardAndRefresh => {
                let delta = self.tracker.discard();
                self.apply_tracker_delta(&delta, fx);
                self.reload();
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
                self.current_offset = 0;
                self.refresh_filter_chrome();
                if let Some(strip) = self.filter_strip.as_ref() {
                    strip.update_filter(set);
                }
                self.fetch(BrowseRequestKind::Page, fx);
                self.fetch(BrowseRequestKind::Count, fx);
                fx.output(BrowseTabOutput::StateChanged);
            }
            BrowseTabInput::FirstPage => {
                if self.current_offset > 0 {
                    self.current_offset = 0;
                    self.fetch(BrowseRequestKind::Page, fx);
                    fx.output(BrowseTabOutput::StateChanged);
                }
            }
            BrowseTabInput::PrevPage => {
                if self.current_offset >= self.page_size {
                    self.current_offset -= self.page_size;
                    self.fetch(BrowseRequestKind::Page, fx);
                    fx.output(BrowseTabOutput::StateChanged);
                }
            }
            BrowseTabInput::NextPage => {
                self.current_offset += self.page_size;
                self.fetch(BrowseRequestKind::Page, fx);
                fx.output(BrowseTabOutput::StateChanged);
            }
            BrowseTabInput::LastPage => {
                // The button stays disabled until the count is known.
                let Some(total) = self.current_total_rows else {
                    return;
                };
                if total == 0 {
                    return;
                }
                let last_page_offset = (total - 1) / self.page_size * self.page_size;
                if self.current_offset != last_page_offset {
                    self.current_offset = last_page_offset;
                    self.fetch(BrowseRequestKind::Page, fx);
                    fx.output(BrowseTabOutput::StateChanged);
                }
            }
            BrowseTabInput::SortChanged { col_idx, ascending } => {
                // The sorter notifies twice for one click on a new column
                // (column, then order), with the same final pair.
                let next = (col_idx, ascending);
                if self.current_sort == Some(next) {
                    return;
                }
                self.current_sort = Some(next);
                self.current_offset = 0;
                self.capture_focus_for_restore();
                self.fetch(BrowseRequestKind::Page, fx);
                fx.output(BrowseTabOutput::StateChanged);
            }
            BrowseTabInput::PageSizeChanged(size) => {
                if self.suppress_combo_emit.get() || self.page_size == size {
                    return;
                }
                self.page_size = size;
                self.current_offset = 0;
                self.fetch(BrowseRequestKind::Page, fx);
                fx.output(BrowseTabOutput::StateChanged);
            }
            BrowseTabInput::DuplicateRows(rows) => {
                if self.current_columns.is_empty() || self.grid_is_stale() || rows.is_empty() {
                    return;
                }
                let ctx = self.grid_context();
                for row in &rows {
                    // With its pending edits, since the copy is of the row
                    // the user is looking at.
                    let source_cells = ctx.effective_cells(row);
                    // The duplicate is a new row, so values the database
                    // owns (key, identity, generated) are left to it.
                    let cells: Vec<CellInput> = self
                        .current_columns
                        .iter()
                        .enumerate()
                        .map(|(i, col)| {
                            if col.primary_key || col.is_auto_increment || col.is_generated {
                                new_draft_cell(col)
                            } else {
                                CellInput::Value(source_cells.get(i).cloned().unwrap_or(Value::Null))
                            }
                        })
                        .collect();
                    self.apply_edit(TrackerEdit::InsertDraft { cells }, fx);
                }
                self.refresh_inner_stack_visibility();
                fx.input(BrowseTabInput::FocusInsertedDraft);
            }
            BrowseTabInput::InsertRow => {
                if self.current_columns.is_empty() {
                    return;
                }
                let cells = self.current_columns.iter().map(new_draft_cell).collect();
                self.apply_edit(TrackerEdit::InsertDraft { cells }, fx);
                self.refresh_inner_stack_visibility();
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
                    Ok(input) => input,
                    Err(message) => {
                        fx.output(BrowseTabOutput::ShowToast(message));
                        return;
                    }
                };
                self.edit_cell(&row, column, input, fx);
            }
            BrowseTabInput::GridShowToast(message) => {
                fx.output(BrowseTabOutput::ShowToast(message));
            }
            BrowseTabInput::GridExportResults(mut result) => {
                // The grid owns the rows it shows; whether the fetch was
                // cut short belongs to the tab.
                result.truncated = self.current_result.as_ref().is_some_and(|r| r.truncated);
                fx.output(BrowseTabOutput::ExportResults(ExportRequest {
                    result,
                    name: self.export_name(),
                    target: Some(self.sql_target()),
                }));
            }
            BrowseTabInput::ExportCurrentPage => {
                let Some(result) = self.export_payload() else {
                    fx.output(BrowseTabOutput::ShowToast(crate::i18n::gettext("Nothing to export")));
                    return;
                };
                fx.output(BrowseTabOutput::ExportResults(ExportRequest {
                    result,
                    name: self.export_name(),
                    target: Some(self.sql_target()),
                }));
            }
            BrowseTabInput::GridCopyRowsAsInsert(rows) => {
                if !self.grid_is_stale() {
                    self.copy_rows_as_insert(&rows, fx);
                }
            }
            BrowseTabInput::GridCopyToClipboard(text) => {
                fx.output(BrowseTabOutput::CopyToClipboard(text));
            }
            BrowseTabInput::CopySelectedRowsAsTsv => self.copy_selected_rows(fx),
            BrowseTabInput::PasteNotSupported => {
                fx.output(BrowseTabOutput::ShowToast(crate::i18n::gettext(
                    "Pasting rows isn't supported yet",
                )));
            }
            BrowseTabInput::SelectAllRows => {
                if let Some(selection) = self.current_selection.as_ref()
                    && selection.n_items() > 0
                {
                    selection.select_all();
                }
            }
            BrowseTabInput::GoToFirstRow => self.scroll_to_row(|_| Some(0)),
            BrowseTabInput::GoToLastRow => self.scroll_to_row(|n| n.checked_sub(1)),
            BrowseTabInput::CommitSave => fx.output(BrowseTabOutput::SaveRequested),
            BrowseTabInput::SaveStarted => self.show_saving(true),
            BrowseTabInput::StopSaving => fx.output(BrowseTabOutput::StopSaveRequested),
            BrowseTabInput::DiscardAll => {
                let delta = self.tracker.discard();
                self.apply_tracker_delta(&delta, fx);
                self.fetch(BrowseRequestKind::Page, fx);
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
            BrowseTabInput::SaveCommitted => {
                self.show_saving(false);
                // The tracker already let go of what the save wrote. The
                // reload replaces every row; dropping the saved drafts
                // from the store first would blank them until it lands.
                self.sync_pending_chrome(self.tracker.pending_count(), fx);
                self.capture_focus_for_restore();
                self.fetch(BrowseRequestKind::Page, fx);
                self.fetch(BrowseRequestKind::Count, fx);
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

    fn scroll_to_row(&self, target: impl FnOnce(u32) -> Option<u32>) {
        let Some(cv) = self.current_column_view.as_ref() else {
            return;
        };
        let n = self.current_selection.as_ref().map(|s| s.n_items()).unwrap_or(0);
        let Some(position) = target(n).filter(|position| *position < n) else {
            return;
        };
        cv.scroll_to(
            position,
            None,
            gtk::ListScrollFlags::FOCUS | gtk::ListScrollFlags::SELECT,
            None,
        );
    }

    /// Mark saved rows for deletion and drop drafts. Nothing leaves the
    /// tab until Save. The action is off for rows this cannot delete, so
    /// such rows reaching here is a bug, which changes nothing.
    fn delete_rows(&self, rows: &[RowObject], fx: &mut Effects) {
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

    fn confirm_delete(&self, deletion: RowDeletion) {
        let count = deletion.len();
        let title = crate::i18n::ngettext_f(
            "Delete {n} row?",
            "Delete {n} rows?",
            u32::try_from(count).unwrap_or(u32::MAX),
            &[("n", &count.to_string())],
        );
        let body =
            crate::i18n::gettext("These rows will be marked for deletion. They aren't removed until you click Save.");
        let dialog = adw::AlertDialog::new(Some(&title), Some(&body));
        dialog.add_response("cancel", &crate::i18n::gettext("Cancel"));
        dialog.add_response("delete", &crate::i18n::gettext("Delete"));
        dialog.set_response_appearance("delete", adw::ResponseAppearance::Destructive);
        dialog.set_default_response(Some("cancel"));
        dialog.set_close_response("cancel");
        let tab = self.this.clone();
        let parent = self.inner_stack.clone();
        glib::spawn_future_local(async move {
            let response = dialog.choose_future(Some(&parent)).await;
            if response == "delete"
                && let Some(tab) = tab.upgrade()
            {
                tab.send(BrowseTabInput::MarkRowsDeleted(deletion));
            }
        });
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
        let ctx = self.grid_context();
        let mut statements = Vec::with_capacity(rows.len());
        for row in rows {
            let cells = match row.id() {
                GridRowId::Draft(draft_id) => self
                    .tracker
                    .draft_cells(*draft_id, &self.current_columns)
                    .unwrap_or_default(),
                _ => ctx.effective_cells(row).into_iter().map(CellInput::Value).collect(),
            };
            match tablepro_core::export::render_insert(&*dialect, &self.table_ref(), &self.current_columns, &cells) {
                Ok(sql) => statements.push(sql),
                Err(error) => {
                    tracing::debug!(%error, "a row could not be written as an INSERT");
                    let message = match error {
                        RenderInsertError::Literal(_) => {
                            crate::i18n::gettext("This row has a value that can't be written as SQL")
                        }
                        RenderInsertError::NoValues => {
                            crate::i18n::gettext("This row has no value to put in an INSERT")
                        }
                    };
                    fx.output(BrowseTabOutput::ShowToast(message));
                    return;
                }
            }
        }
        if !statements.is_empty() {
            fx.output(BrowseTabOutput::CopyToClipboard(statements.join("\n")));
        }
    }

    /// Same renderer as the context menu's Copy as > Rows: one
    /// selection cannot produce two different clipboard payloads.
    fn copy_selected_rows(&self, fx: &mut Effects) {
        let Some(selection) = self.current_selection.as_ref() else {
            return;
        };
        let positions = super::grid::selected_positions(selection);
        if positions.is_empty() {
            return;
        }
        let ctx = self.grid_context();
        let rows: Vec<Vec<Value>> = positions
            .iter()
            .filter_map(|position| selection.item(*position).and_downcast::<RowObject>())
            .map(|row| ctx.effective_cells(&row))
            .collect();
        if rows.is_empty() {
            return;
        }
        match tablepro_core::export::render_tsv(&result_columns(&self.current_columns), &rows, false) {
            Ok(tsv) => fx.output(BrowseTabOutput::CopyToClipboard(tsv)),
            Err(error) => fx.output(BrowseTabOutput::ShowToast(crate::i18n::gettext_f(
                "Couldn't copy the selection: {error}",
                &[("error", &error.to_string())],
            ))),
        }
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
    let tooltip = explanation.unwrap_or_else(|| crate::i18n::gettext("Delete selected rows (Delete)"));
    button.set_tooltip_text(Some(&tooltip));
}

fn clear_box(b: &gtk::Box) {
    while let Some(child) = b.first_child() {
        b.remove(&child);
    }
}

/// A fetched row's key from its primary key cells, in the table's
/// column order. `None` when the table has no primary key or the row is
/// too short to hold it.
fn persisted_key(cells: &[Value], pk_indices: &[usize]) -> Option<RowKey> {
    let pk_values: Vec<Value> = pk_indices
        .iter()
        .map(|&i| cells.get(i).cloned())
        .collect::<Option<_>>()?;
    RowKey::from_pk_values(&pk_values)
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

/// Format a positive integer with thousands separators (1000 → 1,000).
/// Used for page-size dropdown labels so they read naturally instead
/// of the abbreviated "1 K" / "5 K" form.
fn format_thousands(n: u64) -> String {
    let s = n.to_string();
    let bytes = s.as_bytes();
    let len = bytes.len();
    let mut out = String::with_capacity(len + len / 3);
    for (i, b) in bytes.iter().enumerate() {
        if i > 0 && (len - i).is_multiple_of(3) {
            out.push(',');
        }
        out.push(*b as char);
    }
    out
}

/// The result-column view of a catalogue column list, for a result the
/// grid renders from the schema it already has.
fn result_columns(columns: &[tablepro_core::ColumnInfo]) -> std::sync::Arc<[tablepro_core::column::ResultColumn]> {
    columns.iter().map(|column| column.result_column()).collect()
}
