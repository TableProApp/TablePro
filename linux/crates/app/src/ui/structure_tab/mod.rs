//! The Structure workspace tab: CREATE, DROP and ALTER TABLE, indexes
//! and foreign keys.
//!
//! Layout (adw::ToolbarView, no internal HeaderBar):
//!
//!   ┌─ Content ────────────────────────────────────────────────┐
//!   │   (New mode) AdwPreferencesGroup { name entry }          │
//!   │   Centred AdwViewSwitcher: Columns | Indexes | FKs | SQL │
//!   │ ┌─ ViewStack ─────────────────────────────────────────┐  │
//!   │ │ Columns: boxed-list of AdwExpanderRow (per column,  │  │
//!   │ │   header = Name + summary, body = Name/Type/Null/   │  │
//!   │ │   Default/PK/AutoInc rows) + AdwButtonRow add row   │  │
//!   │ │ Indexes: boxed-list (Name, Cols, Unique, trash)     │  │
//!   │ │ FKs: boxed-list (Name, Cols, Refs, RefCols, trash)  │  │
//!   │ │ SQL Preview: SourceView5 (read-only, sql highlight) │  │
//!   │ └─────────────────────────────────────────────────────┘  │
//!   ├─ ActionBar { pending count | Discard | Save | Drop } ────┤
//!   └──────────────────────────────────────────────────────────┘
//!
//! Editing flow (snapshot + diff). On load we capture the canonical
//! schema into `original_*` snapshots. Every cell mutation updates
//! the live model and calls `recompute_dirty_state`, which runs
//! `sql_ddl::diff_to_ops` against the snapshot, regenerates the SQL
//! preview from the resulting `Vec<StructureOp>`, and stores those
//! ops in a passive per-tab `StructureChangeTracker` so out-of-band
//! callers (close-with-pending dialog, save dispatcher) can read the
//! current dirty state without touching the UI. There is no per-op
//! undo or redo: the snapshot is the only restore point, exposed via
//! the Discard button. Save calls `materialize_ops` against the same
//! diff and asks the window to run the statements.
//!
//! The tab reads the table's definition itself, one request at a time,
//! and reads it again once the session reconnects if the last read
//! failed.

mod columns;
mod fks;
mod imp;
mod indexes;
mod structure_command;
#[cfg(test)]
mod tests;

use std::cell::{Cell, RefCell};
use std::collections::{BTreeMap, VecDeque};
use std::rc::Rc;
use std::sync::Arc;

use gtk4 as gtk;
use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use libadwaita as adw;
use sourceview5::prelude::BufferExt;
use tablepro_core::ddl::{ColumnDefinition, TableDefinition};
use tablepro_core::dialect::SqlDialect;
use tablepro_core::meta::TableRef;
use tablepro_core::sql_ddl::{BuildDdlError, DraftColumn, StructureOp, diff_to_ops, materialize_ops};
use tablepro_core::{ForeignKeyInfo, IndexInfo};
use tablepro_session::runtime::{Tasks, WatchForwarder};
use tablepro_session::{LinkGeneration, OperationError, OperationKind, Session};

use self::columns::{build_column_expander_row, default_type_for};
use self::fks::build_fk_row;
use self::indexes::build_index_row;
pub(crate) use self::structure_command::{LoadedStructure, StructureCommand, StructureRequestKind};
use crate::runtime::{FailedRequests, RequestSequencer, RequestTicket, Stamped};
use crate::services::structure_tracker_handle::StructureTrackerHandle;
use crate::ui::handler_guard::HandlerGuard;
use crate::ui::structure_tab_dialogs::{present_fk_dialog, present_index_dialog};

glib::wrapper! {
    pub struct StructureTab(ObjectSubclass<imp::StructureTab>)
        @extends adw::Bin, gtk::Widget,
        @implements gtk::Accessible, gtk::Buildable, gtk::ConstraintTarget;
}

/// Whether the Structure tab is editing an existing table or
/// drafting a brand-new one.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StructureMode {
    New,
    Edit,
}

pub struct StructureTabInit {
    pub tracker: StructureTrackerHandle,
    pub schema: Option<String>,
    pub table: String,
    pub mode: StructureMode,
    pub driver_id: String,
    /// The session the tab reads through. A draft takes its dialect
    /// from it for the SQL preview.
    pub session: Arc<Session>,
    pub tasks: Tasks,
}

/// What the rows and dialogs of a tab use to reach it. It holds the tab
/// weakly, so a row's closure never keeps a closed tab alive.
#[derive(Clone)]
pub(crate) struct StructureTabSender {
    tab: glib::WeakRef<StructureTab>,
}

impl StructureTabSender {
    pub(crate) fn input(&self, msg: StructureTabInput) {
        if let Some(tab) = self.tab.upgrade() {
            tab.send(msg);
        }
    }

    pub(crate) fn output(&self, output: StructureTabOutput) {
        if let Some(tab) = self.tab.upgrade() {
            tab.emit_output(output);
        }
    }
}

impl StructureTab {
    pub fn new(init: StructureTabInit) -> Self {
        let tab: Self = glib::Object::new();
        let imp = tab.imp();

        let sql_buffer = match sourceview5::LanguageManager::default().language("sql") {
            Some(language) => sourceview5::Buffer::with_language(&language),
            None => sourceview5::Buffer::new(None),
        };
        imp.sql_view.set_buffer(Some(&sql_buffer));
        apply_sql_scheme(&sql_buffer);
        let style_manager = adw::StyleManager::default();
        let buffer_for_theme = sql_buffer.downgrade();
        let theme_handler = HandlerGuard::new(
            &style_manager,
            style_manager.connect_dark_notify(move |_| {
                if let Some(buffer) = buffer_for_theme.upgrade() {
                    apply_sql_scheme(&buffer);
                }
            }),
        );
        // Saves the user clicking into the preview, selecting all and
        // copying every time they want the DDL in another tool.
        let buffer_for_copy = sql_buffer.downgrade();
        imp.copy_sql_button.connect_clicked(move |button| {
            if let Some(buffer) = buffer_for_copy.upgrade() {
                let text = buffer.text(&buffer.start_iter(), &buffer.end_iter(), false);
                button.clipboard().set_text(text.as_str());
            }
        });

        imp.name_entry.set_text(&init.table);
        imp.name_row.set_visible(matches!(init.mode, StructureMode::New));
        imp.drop_button.set_visible(matches!(init.mode, StructureMode::Edit));
        imp.inner_stack.set_visible_child_name(match init.mode {
            StructureMode::New => "editor",
            StructureMode::Edit => "loading",
        });
        tab.connect_widgets();

        let link_changes = init.session.link_changes();
        let model = StructureModel {
            this: tab.downgrade(),
            link_generation: init.session.link_generation(),
            dialect: Rc::new(RefCell::new(match init.mode {
                // A draft has no table to read the dialect back with.
                StructureMode::New => init.session.current_dialect(),
                StructureMode::Edit => None,
            })),
            session: init.session,
            tasks: init.tasks,
            sequencer: RequestSequencer::new(),
            failed: FailedRequests::new(),
            issued_on: BTreeMap::new(),
            tracker: init.tracker,
            schema: init.schema,
            original_table_name: Rc::new(RefCell::new(init.table.clone())),
            table_name: Rc::new(RefCell::new(init.table)),
            mode: Rc::new(RefCell::new(init.mode)),
            driver_id: init.driver_id,
            columns: Rc::new(RefCell::new(Vec::new())),
            indexes: Rc::new(RefCell::new(Vec::new())),
            foreign_keys: Rc::new(RefCell::new(Vec::new())),
            original_columns: Rc::new(RefCell::new(Vec::new())),
            original_indexes: Rc::new(RefCell::new(Vec::new())),
            original_fks: Rc::new(RefCell::new(Vec::new())),
            inner_stack: imp.inner_stack.get(),
            error_status: imp.error_status.get(),
            name_entry: imp.name_entry.get(),
            name_row: imp.name_row.get(),
            columns_box: imp.columns_box.get(),
            indexes_box: imp.indexes_box.get(),
            fks_box: imp.fks_box.get(),
            sql_buffer,
            pending_label: imp.pending_label.get(),
            save_button: imp.save_button.get(),
            discard_button: imp.discard_button.get(),
            drop_button: imp.drop_button.get(),
            last_dirty: Rc::new(RefCell::new(false)),
            suppress_emit: imp.suppress_emit.clone(),
            next_column_seq: Rc::new(RefCell::new(1)),
            column_popovers: Rc::new(RefCell::new(Vec::new())),
            refetching: Rc::new(Cell::new(false)),
            _theme_handler: theme_handler,
        };
        imp.model.replace(Some(model));
        imp.link_watch.replace(Some(WatchForwarder::new(
            link_changes,
            {
                let tab = tab.downgrade();
                move |generation: LinkGeneration| {
                    if let Some(tab) = tab.upgrade() {
                        tab.send(StructureTabInput::LinkChanged(generation));
                    }
                }
            },
            |future| {
                glib::spawn_future_local(future);
            },
        )));
        tab.send(StructureTabInput::Start);
        tab
    }

    pub(crate) fn sender(&self) -> StructureTabSender {
        StructureTabSender { tab: self.downgrade() }
    }

    /// Hand the tab an input. One that arrives while another is being
    /// handled, from a widget signal the handler set off, waits for it
    /// to finish rather than running inside it.
    pub(crate) fn send(&self, msg: StructureTabInput) {
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
            let mut effects = StructureEffects::default();
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

    /// Stop the read the tab has running and stop following reconnects.
    pub fn shutdown(&self) {
        let imp = self.imp();
        imp.link_watch.take();
        if let Ok(mut model) = imp.model.try_borrow_mut()
            && let Some(model) = model.as_mut()
        {
            model.sequencer.cancel_all();
        }
    }

    pub fn connect_dirty_changed<F: Fn(&Self, bool) + 'static>(&self, f: F) -> glib::SignalHandlerId {
        self.connect_closure(
            "dirty-changed",
            false,
            glib::closure_local!(move |tab: &Self, dirty: bool| f(tab, dirty)),
        )
    }

    /// Save asked the window to run these statements.
    pub fn connect_execute<F: Fn(&Self, Vec<String>) + 'static>(&self, f: F) -> glib::SignalHandlerId {
        self.connect_closure(
            "execute",
            false,
            glib::closure_local!(move |tab: &Self, statements: glib::BoxedAnyObject| {
                f(tab, statements.borrow::<Vec<String>>().clone());
            }),
        )
    }

    pub fn connect_drop_table_requested<F: Fn(&Self, Option<String>, String) + 'static>(
        &self,
        f: F,
    ) -> glib::SignalHandlerId {
        self.connect_closure(
            "drop-table-requested",
            false,
            glib::closure_local!(move |tab: &Self, schema: Option<String>, table: String| f(tab, schema, table)),
        )
    }

    pub fn connect_toast<F: Fn(&Self, String) + 'static>(&self, f: F) -> glib::SignalHandlerId {
        self.connect_closure(
            "toast",
            false,
            glib::closure_local!(move |tab: &Self, text: String| f(tab, text)),
        )
    }

    pub fn connect_alert<F: Fn(&Self, String, String) + 'static>(&self, f: F) -> glib::SignalHandlerId {
        self.connect_closure(
            "alert",
            false,
            glib::closure_local!(move |tab: &Self, title: String, body: String| f(tab, title, body)),
        )
    }

    fn emit_output(&self, output: StructureTabOutput) {
        match output {
            StructureTabOutput::DirtyChanged(dirty) => self.emit_by_name::<()>("dirty-changed", &[&dirty]),
            StructureTabOutput::ExecuteTransaction { statements } => {
                self.emit_by_name::<()>("execute", &[&glib::BoxedAnyObject::new(statements)]);
            }
            StructureTabOutput::DropTableRequested { schema, table } => {
                self.emit_by_name::<()>("drop-table-requested", &[&schema, &table]);
            }
            StructureTabOutput::ShowToast(text) => self.emit_by_name::<()>("toast", &[&text]),
            StructureTabOutput::ShowAlert { title, body } => self.emit_by_name::<()>("alert", &[&title, &body]),
        }
    }

    fn connect_widgets(&self) {
        let imp = self.imp();
        let on_click = |button: &gtk::Button, msg: fn() -> StructureTabInput| {
            let sender = self.sender();
            button.connect_clicked(move |_| sender.input(msg()));
        };
        on_click(&imp.save_button, || StructureTabInput::Save);
        on_click(&imp.discard_button, || StructureTabInput::Discard);
        on_click(&imp.drop_button, || StructureTabInput::DropTableRequested);
        // Without a retry a transient network blip on a remote database
        // would force the user to close the tab and open it again.
        on_click(&imp.retry_button, || StructureTabInput::Retry);
        let sender = self.sender();
        let suppress = imp.suppress_emit.clone();
        imp.name_entry.connect_changed(move |entry| {
            if suppress.get() {
                return;
            }
            sender.input(StructureTabInput::TableNameEdited(entry.text().to_string()));
        });
    }
}

#[derive(Default)]
pub(crate) struct StructureEffects {
    outputs: Vec<StructureTabOutput>,
    inputs: VecDeque<StructureTabInput>,
}

impl StructureEffects {
    fn output(&mut self, output: StructureTabOutput) {
        self.outputs.push(output);
    }

    fn input(&mut self, input: StructureTabInput) {
        self.inputs.push_back(input);
    }
}

pub(crate) struct StructureModel {
    this: glib::WeakRef<StructureTab>,
    session: Arc<Session>,
    tasks: Tasks,
    sequencer: RequestSequencer<StructureRequestKind>,
    failed: FailedRequests<StructureRequestKind>,
    /// The connection each running read was issued on. A read that
    /// fails after the connection was replaced is asked again at once,
    /// since the reconnect it would wait for has already landed.
    issued_on: BTreeMap<StructureRequestKind, LinkGeneration>,
    /// The newest connection the tab has heard of.
    link_generation: LinkGeneration,
    tracker: StructureTrackerHandle,
    schema: Option<String>,
    table_name: Rc<RefCell<String>>,
    mode: Rc<RefCell<StructureMode>>,
    driver_id: String,
    columns: Rc<RefCell<Vec<DraftColumn>>>,
    indexes: Rc<RefCell<Vec<IndexInfo>>>,
    foreign_keys: Rc<RefCell<Vec<ForeignKeyInfo>>>,
    /// The table as the last read returned it. Save writes the diff
    /// between these and the live fields, and Discard copies these back
    /// over them.
    original_table_name: Rc<RefCell<String>>,
    original_columns: Rc<RefCell<Vec<ColumnDefinition>>>,
    original_indexes: Rc<RefCell<Vec<IndexInfo>>>,
    original_fks: Rc<RefCell<Vec<ForeignKeyInfo>>>,
    /// The connection's dialect, which spells renames and default drops
    /// per server. `None` until the first read, and the SQL cannot be
    /// written before then.
    dialect: Rc<RefCell<Option<Arc<dyn SqlDialect>>>>,

    inner_stack: gtk::Stack,
    /// The status page shown when the read fails, with the driver's
    /// error as its description.
    error_status: adw::StatusPage,
    name_entry: adw::EntryRow,
    /// The group around `name_entry`, visible only in New mode.
    name_row: adw::PreferencesGroup,
    columns_box: gtk::Box,
    indexes_box: gtk::Box,
    fks_box: gtk::Box,
    sql_buffer: sourceview5::Buffer,
    pending_label: gtk::Label,
    save_button: gtk::Button,
    discard_button: gtk::Button,
    drop_button: gtk::Button,

    last_dirty: Rc<RefCell<bool>>,
    /// Suppress reentrant rebuilds: programmatic `set_text` /
    /// `set_active` while seeding row widgets fires `changed` /
    /// `notify::active` signals synchronously. Without this guard,
    /// the row's connect_* callbacks would treat seeding as a user
    /// edit and shift the live model away from the snapshot, surfacing
    /// phantom pending changes. `Cell` (not `RefCell`) because GTK can
    /// fire those signals re-entrantly during `clear_box` while
    /// another `borrow_mut` is still live on the stack.
    suppress_emit: Rc<Cell<bool>>,
    /// Monotonic counter for the "Add Column" placeholder name, so a
    /// removed column does not leave its name to be handed out twice.
    next_column_seq: Rc<RefCell<usize>>,
    /// The type suggestion popovers of the column rows. A rebuild pops
    /// them down before it removes the rows, so no menu stays open over
    /// a row that is gone.
    column_popovers: Rc<RefCell<Vec<gtk::Popover>>>,
    /// True between `SaveCompleted` and the read that follows. The live
    /// model is already committed while the `original_*` snapshots
    /// still hold the pre-save state, so diffing them would surface
    /// phantom pending ops; `recompute_dirty_state` waits it out.
    refetching: Rc<Cell<bool>>,
    /// The SQL preview follows the desktop theme through the app-wide
    /// style manager, which would keep the handler past the tab.
    _theme_handler: HandlerGuard,
}

#[derive(Debug)]
pub(crate) enum StructureTabInput {
    /// The tab is built: read the table, or draw an empty draft.
    Start,
    /// A reply to the tab's read.
    Command(StructureCommand),
    /// A reconnect replaced the session's connection.
    LinkChanged(LinkGeneration),
    /// The table's definition changed elsewhere.
    SchemaChanged,
    /// The error page's Try Again.
    Retry,
    Save,
    Discard,
    DropTableRequested,
    SaveCompleted {
        new_table_name: Option<String>,
    },
    SaveFailed(String),
    /// Rebuild the lists and the preview from the model.
    Refresh,
    ColumnEdited {
        index: usize,
        field: ColumnField,
    },
    AddColumn,
    RemoveColumn(usize),
    AddIndex(IndexInfo),
    RemoveIndex(usize),
    AddForeignKey(ForeignKeyInfo),
    RemoveForeignKey(usize),
    TableNameEdited(String),
}

#[derive(Debug, Clone)]
pub enum ColumnField {
    Name(String),
    Type(String),
    Nullable(bool),
    PrimaryKey(bool),
    AutoIncrement(bool),
    Default(Option<String>),
    Comment(Option<String>),
}

#[derive(Debug)]
pub(crate) enum StructureTabOutput {
    DirtyChanged(bool),
    ExecuteTransaction { statements: Vec<String> },
    DropTableRequested { schema: Option<String>, table: String },
    ShowToast(String),
    ShowAlert { title: String, body: String },
}

impl StructureModel {
    fn sender(&self) -> StructureTabSender {
        StructureTabSender { tab: self.this.clone() }
    }

    /// What Save would write: the diff against the snapshot, or one
    /// CREATE TABLE for a draft with columns.
    fn current_diff_ops(&self) -> Vec<StructureOp> {
        if matches!(*self.mode.borrow(), StructureMode::New) {
            let columns = self.columns.borrow().clone();
            if columns.is_empty() {
                return Vec::new();
            }
            return vec![StructureOp::CreateTable {
                schema: self.schema.clone(),
                table: self.table_name.borrow().clone(),
                columns,
                indexes: self.indexes.borrow().clone(),
                fks: self.foreign_keys.borrow().clone(),
            }];
        }
        diff_to_ops(
            self.schema.as_deref(),
            &self.original_table_name.borrow(),
            &self.table_name.borrow(),
            &self.original_columns.borrow(),
            &self.columns.borrow(),
            &self.original_indexes.borrow(),
            &self.indexes.borrow(),
            &self.original_fks.borrow(),
            &self.foreign_keys.borrow(),
        )
    }

    /// The action bar, the preview and the tracker after an edit. The
    /// tracker holds the ops so the window's close and save paths read
    /// them without the tab.
    ///
    /// Waits while `refetching`: between `SaveCompleted` and the read
    /// after it, `original_*` is stale.
    fn recompute_dirty_state(&self, fx: &mut StructureEffects) {
        if self.refetching.get() {
            return;
        }
        let ops = self.current_diff_ops();
        let count = ops.len();
        self.refresh_buttons(count);
        self.regenerate_sql_preview_from(&ops);
        self.tracker.set_ops(ops);

        let dirty = count > 0;
        let mut last = self.last_dirty.borrow_mut();
        if *last != dirty {
            *last = dirty;
            fx.output(StructureTabOutput::DirtyChanged(dirty));
        }
    }

    fn refresh_buttons(&self, pending_count: usize) {
        let has_pending = pending_count > 0;
        self.save_button.set_sensitive(has_pending);
        self.discard_button.set_sensitive(has_pending);
        if has_pending {
            let label = if pending_count == 1 {
                crate::i18n::gettext("1 pending change")
            } else {
                crate::i18n::ngettext_f(
                    "{n} pending change",
                    "{n} pending changes",
                    u32::try_from(pending_count).unwrap_or(u32::MAX),
                    &[("n", &pending_count.to_string())],
                )
            };
            self.pending_label.set_label(&label);
            self.pending_label.set_visible(true);
        } else {
            self.pending_label.set_visible(false);
        }
    }

    /// The statements `ops` become on this connection, or `None` while
    /// the tab has no dialect to spell them in.
    fn materialize(&self, ops: &[StructureOp]) -> Option<Result<Vec<String>, BuildDdlError>> {
        let dialect = self.dialect.borrow().clone()?;
        Some(materialize_ops(ops, &self.driver_id, &*dialect))
    }

    fn regenerate_sql_preview_from(&self, ops: &[StructureOp]) {
        let text = match self.materialize(ops) {
            Some(Ok(stmts)) if !stmts.is_empty() => stmts.join(";\n\n") + ";",
            Some(Ok(_)) => crate::i18n::gettext("-- No pending changes."),
            Some(Err(e)) => format!("-- {e}"),
            None => crate::i18n::gettext("-- Connect to a database to see the SQL."),
        };
        self.sql_buffer.set_text(&text);
    }

    fn rebuild_columns_view(&self) {
        // Seeding the new rows' widgets fires their change signals,
        // which must not count as user edits; emit comes back on the
        // next idle tick.
        self.suppress_emit.set(true);
        {
            let mut popovers = self.column_popovers.borrow_mut();
            for p in popovers.drain(..) {
                p.popdown();
            }
        }
        clear_box(&self.columns_box);
        let driver_id = self.driver_id.clone();

        let list = boxed_list();
        for (i, col) in self.columns.borrow().iter().enumerate() {
            list.append(&build_column_expander_row(
                i,
                col,
                &driver_id,
                self.sender(),
                self.suppress_emit.clone(),
                self.column_popovers.clone(),
            ));
        }
        let sender_for_add = self.sender();
        append_add_button(&list, &crate::i18n::gettext("Add Column"), move || {
            sender_for_add.input(StructureTabInput::AddColumn);
        });
        self.columns_box.append(&list);

        let suppress = self.suppress_emit.clone();
        glib::idle_add_local_once(move || {
            suppress.set(false);
        });
    }

    fn rebuild_indexes_view(&self) {
        clear_box(&self.indexes_box);
        let list = boxed_list();
        for (i, idx) in self.indexes.borrow().iter().enumerate() {
            list.append(&build_index_row(i, idx, self.sender()));
        }
        let columns_for_dialog = self.columns.clone();
        let sender_for_add = self.sender();
        let parent_box = self.indexes_box.downgrade();
        append_add_button(&list, &crate::i18n::gettext("Add Index…"), move || {
            if let Some(parent_box) = parent_box.upgrade() {
                present_index_dialog(
                    parent_box.upcast_ref(),
                    &columns_for_dialog.borrow(),
                    sender_for_add.clone(),
                );
            }
        });
        self.indexes_box.append(&list);
    }

    fn rebuild_fks_view(&self) {
        clear_box(&self.fks_box);
        let driver_id = self.driver_id.clone();
        let list = boxed_list();
        for (i, fk) in self.foreign_keys.borrow().iter().enumerate() {
            list.append(&build_fk_row(i, fk, &driver_id, self.sender()));
        }
        let columns_for_dialog = self.columns.clone();
        let sender_for_add = self.sender();
        let parent_box = self.fks_box.downgrade();
        let driver_id_for_dialog = driver_id.clone();
        append_add_button(&list, &crate::i18n::gettext("Add Foreign Key…"), move || {
            if let Some(parent_box) = parent_box.upgrade() {
                present_fk_dialog(
                    parent_box.upcast_ref(),
                    &columns_for_dialog.borrow(),
                    &driver_id_for_dialog,
                    sender_for_add.clone(),
                );
            }
        });
        self.fks_box.append(&list);
    }

    fn table_ref(&self) -> TableRef {
        TableRef::new(self.schema.clone(), self.table_name.borrow().clone())
    }

    /// Read the table's definition in one call, so the tab rebuilds
    /// once with columns, indexes and foreign keys from the same moment.
    fn fetch_definition(&mut self) {
        self.issued_on
            .insert(StructureRequestKind::Definition, self.session.link_generation());
        let RequestTicket { stamp, cancel } = self.sequencer.issue(StructureRequestKind::Definition);
        let session = self.session.clone();
        let table = self.table_ref();
        let work = async move {
            session
                .run_cancellable(OperationKind::Metadata, &cancel, move |lease, options| {
                    let table = table.clone();
                    async move {
                        let definition = lease.fetch_table_definition(&table, options).await?;
                        Ok(LoadedStructure {
                            definition,
                            dialect: lease.dialect(),
                        })
                    }
                })
                .await
        };
        let tab = self.this.clone();
        let _delivery = crate::runtime::spawn_and_deliver(&self.tasks, work, move |joined| {
            let value = joined.unwrap_or_else(|failure| Err(OperationError::from(failure)));
            if let Some(tab) = tab.upgrade() {
                tab.send(StructureTabInput::Command(StructureCommand::Loaded(Stamped {
                    stamp,
                    value,
                })));
            }
        });
    }

    fn show_loading(&self) {
        self.inner_stack.set_visible_child_name("loading");
    }

    fn on_loaded(&mut self, loaded: LoadedStructure, fx: &mut StructureEffects) {
        // Every list goes into `original_*` too, so Discard restores the
        // loaded state without a read, including columns the user later
        // removed.
        let TableDefinition {
            columns,
            indexes,
            foreign_keys,
            ..
        } = loaded.definition;
        *self.dialect.borrow_mut() = Some(loaded.dialect);
        *self.original_columns.borrow_mut() = columns.clone();
        *self.columns.borrow_mut() = columns.into_iter().map(DraftColumn::from_definition).collect();
        *self.indexes.borrow_mut() = indexes.clone();
        *self.original_indexes.borrow_mut() = indexes;
        *self.foreign_keys.borrow_mut() = foreign_keys.clone();
        *self.original_fks.borrow_mut() = foreign_keys;
        self.inner_stack.set_visible_child_name("editor");
        // The snapshots are current again, so the diff counts; it is
        // empty now, which also clears anything typed during the read.
        self.refetching.set(false);
        self.recompute_dirty_state(fx);
        fx.input(StructureTabInput::Refresh);
    }

    fn on_load_failed(&self, message: &str) {
        // Inline on the status page: a modal alert would say the same
        // and make the user dismiss it before seeing the page.
        self.error_status.set_description(Some(message));
        self.inner_stack.set_visible_child_name("error");
        // A retry from the error page must not find dirty tracking still
        // frozen.
        self.refetching.set(false);
    }

    fn on_command(&mut self, command: StructureCommand, fx: &mut StructureEffects) {
        let StructureCommand::Loaded(Stamped { stamp, value }) = command;
        if !self.sequencer.accept(StructureRequestKind::Definition, stamp) {
            return;
        }
        self.failed.record(StructureRequestKind::Definition, &value);
        match value {
            Ok(loaded) => self.on_loaded(loaded, fx),
            Err(error) => {
                self.on_load_failed(&crate::ui::error_text::operation_error_message(&error));
                let issued = self.issued_on.get(&StructureRequestKind::Definition).copied();
                if issued.is_some_and(|issued| self.session.link_generation() > issued) {
                    self.retry_failed();
                }
            }
        }
    }

    /// The session reconnected: a draft takes the new connection's
    /// dialect, and a read that failed is asked again.
    fn on_link_changed(&mut self, generation: LinkGeneration) {
        if generation <= self.link_generation {
            return;
        }
        self.link_generation = generation;
        if matches!(*self.mode.borrow(), StructureMode::New) {
            *self.dialect.borrow_mut() = self.session.current_dialect();
            self.regenerate_sql_preview_from(&self.current_diff_ops());
        }
        self.retry_failed();
    }

    fn retry_failed(&mut self) {
        if self.failed.take().contains(&StructureRequestKind::Definition) {
            self.show_loading();
            self.fetch_definition();
        }
    }

    fn update(&mut self, msg: StructureTabInput, fx: &mut StructureEffects) {
        match msg {
            StructureTabInput::Start => {
                if matches!(*self.mode.borrow(), StructureMode::Edit) {
                    self.fetch_definition();
                }
                fx.input(StructureTabInput::Refresh);
            }
            StructureTabInput::Command(command) => self.on_command(command, fx),
            StructureTabInput::LinkChanged(generation) => self.on_link_changed(generation),
            StructureTabInput::SchemaChanged => {
                // Reading the table again replaces the live model, so a
                // tab with edits of its own keeps them.
                if matches!(*self.mode.borrow(), StructureMode::Edit) && !*self.last_dirty.borrow() {
                    self.fetch_definition();
                }
            }
            StructureTabInput::Retry => {
                // Without the loading page the click reads as a no-op
                // until the reply arrives.
                self.show_loading();
                self.fetch_definition();
            }
            StructureTabInput::Refresh => {
                self.rebuild_columns_view();
                self.rebuild_indexes_view();
                self.rebuild_fks_view();
                self.regenerate_sql_preview_from(&self.current_diff_ops());
            }
            StructureTabInput::TableNameEdited(text) => {
                let prev = self.table_name.borrow().clone();
                if prev == text {
                    return;
                }
                *self.table_name.borrow_mut() = text;
                self.recompute_dirty_state(fx);
            }
            StructureTabInput::ColumnEdited { index, field } => {
                let mut cols = self.columns.borrow_mut();
                let Some(col) = cols.get_mut(index) else {
                    return;
                };
                let prev = col.clone();
                match field {
                    ColumnField::Name(s) => col.name = s,
                    ColumnField::Type(s) => col.data_type = s,
                    ColumnField::Nullable(b) => col.nullable = b,
                    ColumnField::PrimaryKey(b) => {
                        col.primary_key = b;
                        // Auto-increment requires a key in every supported
                        // driver; the checkbox only greys out, so the
                        // model drops it here.
                        if !b {
                            col.auto_increment = false;
                        }
                    }
                    ColumnField::AutoIncrement(b) => col.auto_increment = b,
                    ColumnField::Default(s) => col.default_value = s,
                    ColumnField::Comment(s) => col.comment = s,
                }
                let new_col = col.clone();
                drop(cols);
                // A rebuild sets each widget to the value the model
                // already has, which is no edit.
                if prev == new_col {
                    return;
                }
                self.recompute_dirty_state(fx);
            }
            StructureTabInput::AddColumn => {
                let new_col = DraftColumn {
                    original: None,
                    name: {
                        let mut seq = self.next_column_seq.borrow_mut();
                        let name = format!("column_{}", *seq);
                        *seq += 1;
                        name
                    },
                    data_type: default_type_for(&self.driver_id),
                    nullable: true,
                    primary_key: false,
                    auto_increment: false,
                    default_value: None,
                    comment: None,
                };
                self.columns.borrow_mut().push(new_col);
                self.recompute_dirty_state(fx);
                fx.input(StructureTabInput::Refresh);
            }
            StructureTabInput::RemoveColumn(index) => {
                {
                    let mut cols = self.columns.borrow_mut();
                    if index >= cols.len() {
                        return;
                    }
                    cols.remove(index);
                }
                self.recompute_dirty_state(fx);
                fx.input(StructureTabInput::Refresh);
            }
            StructureTabInput::AddIndex(index) => {
                self.indexes.borrow_mut().push(index);
                self.recompute_dirty_state(fx);
                fx.input(StructureTabInput::Refresh);
            }
            StructureTabInput::RemoveIndex(idx_pos) => {
                {
                    let mut idxs = self.indexes.borrow_mut();
                    if idx_pos >= idxs.len() {
                        return;
                    }
                    idxs.remove(idx_pos);
                }
                self.recompute_dirty_state(fx);
                fx.input(StructureTabInput::Refresh);
            }
            StructureTabInput::AddForeignKey(fk) => {
                self.foreign_keys.borrow_mut().push(fk);
                self.recompute_dirty_state(fx);
                fx.input(StructureTabInput::Refresh);
            }
            StructureTabInput::RemoveForeignKey(idx_pos) => {
                {
                    let mut fks = self.foreign_keys.borrow_mut();
                    if idx_pos >= fks.len() {
                        return;
                    }
                    fks.remove(idx_pos);
                }
                self.recompute_dirty_state(fx);
                fx.input(StructureTabInput::Refresh);
            }
            StructureTabInput::Save => self.save(fx),
            StructureTabInput::Discard => {
                // Snapshot+diff model: Discard = current state ←
                // original snapshot. New mode clears everything since
                // the snapshot itself is empty.
                let mode = *self.mode.borrow();
                if matches!(mode, StructureMode::New) {
                    self.columns.borrow_mut().clear();
                    self.indexes.borrow_mut().clear();
                    self.foreign_keys.borrow_mut().clear();
                } else {
                    *self.table_name.borrow_mut() = self.original_table_name.borrow().clone();
                    *self.columns.borrow_mut() = self
                        .original_columns
                        .borrow()
                        .iter()
                        .cloned()
                        .map(DraftColumn::from_definition)
                        .collect();
                    *self.indexes.borrow_mut() = self.original_indexes.borrow().clone();
                    *self.foreign_keys.borrow_mut() = self.original_fks.borrow().clone();
                }
                self.recompute_dirty_state(fx);
                fx.input(StructureTabInput::Refresh);
            }
            StructureTabInput::DropTableRequested => {
                fx.output(StructureTabOutput::DropTableRequested {
                    schema: self.schema.clone(),
                    table: self.table_name.borrow().clone(),
                });
            }
            StructureTabInput::SaveCompleted { new_table_name } => self.save_completed(new_table_name, fx),
            StructureTabInput::SaveFailed(message) => {
                self.recompute_dirty_state(fx);
                fx.output(StructureTabOutput::ShowAlert {
                    title: crate::i18n::gettext("Save failed"),
                    body: message,
                });
            }
        }
    }

    fn save(&self, fx: &mut StructureEffects) {
        let table = self.table_name.borrow().clone();
        let mode = *self.mode.borrow();
        let columns = self.columns.borrow().clone();
        if let Err(message) = validate_save(&table, &columns, mode) {
            fx.output(StructureTabOutput::ShowToast(message));
            return;
        }
        let ops = self.current_diff_ops();
        match self.materialize(&ops) {
            Some(Ok(statements)) if !statements.is_empty() => {
                self.save_button.set_sensitive(false);
                self.discard_button.set_sensitive(false);
                fx.output(StructureTabOutput::ExecuteTransaction { statements });
            }
            Some(Ok(_)) => {
                fx.output(StructureTabOutput::ShowToast(crate::i18n::gettext("Nothing to save.")));
            }
            None => {
                fx.output(StructureTabOutput::ShowToast(crate::i18n::gettext(
                    "Connect to a database first.",
                )));
            }
            Some(Err(BuildDdlError::SqliteNotSupported(detail))) => {
                fx.output(StructureTabOutput::ShowAlert {
                    title: crate::i18n::gettext("Cannot save"),
                    body: crate::i18n::gettext_f("SQLite doesn't support: {detail}", &[("detail", detail)]),
                });
            }
            Some(Err(e)) => {
                fx.output(StructureTabOutput::ShowAlert {
                    title: crate::i18n::gettext("Cannot save"),
                    body: format!("{e}"),
                });
            }
        }
    }

    fn save_completed(&mut self, new_table_name: Option<String>, fx: &mut StructureEffects) {
        if let Some(name) = new_table_name {
            *self.mode.borrow_mut() = StructureMode::Edit;
            *self.table_name.borrow_mut() = name.clone();
            *self.original_table_name.borrow_mut() = name.clone();
            self.name_entry.set_text(&name);
            self.drop_button.set_visible(true);
            self.name_row.set_visible(false);
        }
        if !matches!(*self.mode.borrow(), StructureMode::Edit) {
            return;
        }
        // The diff against the pre-save snapshot would show the changes
        // just committed as still pending until the read lands, and a
        // close in that window would offer to save them again. So the
        // dirty state goes to zero now, and so does a CREATE TABLE left
        // in the preview by a draft that just became the table.
        self.tracker.clear();
        self.refresh_buttons(0);
        self.regenerate_sql_preview_from(&[]);
        let mut last = self.last_dirty.borrow_mut();
        if *last {
            *last = false;
            fx.output(StructureTabOutput::DirtyChanged(false));
        }
        drop(last);
        self.refetching.set(true);
        self.fetch_definition();
    }
}

fn boxed_list() -> gtk::ListBox {
    let list = gtk::ListBox::builder()
        .selection_mode(gtk::SelectionMode::None)
        .margin_start(12)
        .margin_end(12)
        .margin_top(6)
        .margin_bottom(6)
        .build();
    list.add_css_class("boxed-list");
    list
}

fn clear_box(b: &gtk::Box) {
    while let Some(child) = b.first_child() {
        b.remove(&child);
    }
}

/// A trailing `adw::ButtonRow`, the GNOME pattern for "Add another
/// item" rows in Settings and Builder.
fn append_add_button(list: &gtk::ListBox, label: &str, on_activate: impl Fn() + 'static) {
    let row = adw::ButtonRow::builder()
        .title(label)
        .start_icon_name(crate::ui::icons::LIST_ADD)
        .build();
    row.connect_activated(move |_| on_activate());
    list.append(&row);
}

/// The first reason the model cannot be saved, in the user's words.
fn validate_save(table_name: &str, columns: &[DraftColumn], mode: StructureMode) -> Result<(), String> {
    if matches!(mode, StructureMode::New) && table_name.trim().is_empty() {
        return Err(crate::i18n::gettext("Table name is required."));
    }
    // In Edit mode too: removing every column would otherwise save as a
    // statement that drops them all.
    if columns.is_empty() {
        return Err(crate::i18n::gettext("At least one column is required."));
    }
    let mut seen: std::collections::HashSet<&str> = std::collections::HashSet::new();
    for col in columns {
        if col.name.trim().is_empty() {
            return Err(crate::i18n::gettext("Every column needs a name."));
        }
        if !seen.insert(col.name.as_str()) {
            return Err(crate::i18n::gettext_f(
                "Duplicate column name: {name}",
                &[("name", &col.name)],
            ));
        }
        if col.data_type.trim().is_empty() {
            return Err(crate::i18n::gettext_f(
                "Column {name} needs a type.",
                &[("name", &col.name)],
            ));
        }
        if col.primary_key && col.nullable {
            return Err(crate::i18n::gettext_f(
                "Primary key columns must be NOT NULL: {name}",
                &[("name", &col.name)],
            ));
        }
    }
    Ok(())
}

fn apply_sql_scheme(buffer: &sourceview5::Buffer) {
    let scheme_name = if adw::StyleManager::default().is_dark() {
        "Adwaita-dark"
    } else {
        "Adwaita"
    };
    if let Some(scheme) = sourceview5::StyleSchemeManager::default().scheme(scheme_name) {
        buffer.set_style_scheme(Some(&scheme));
    }
}
