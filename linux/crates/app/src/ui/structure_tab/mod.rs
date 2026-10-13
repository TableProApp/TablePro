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
//! The tab edits a `TableDraft` started from the table's definition as
//! one read returned it. Every edit diffs the draft against that
//! definition, plans the change through the connection's `DdlDialect`
//! for the preview, and hands the pending structure to the tab's
//! tracker, where the window's close and save paths read it. Each
//! control is on only where the dialect allows its change, with the
//! reason in its tooltip where it does not. Discard copies the
//! definition back over the draft; there is no per-change undo.
//!
//! The tab reads the table's definition itself, one request at a time,
//! and reads it again once the session reconnects if the last read
//! failed.

mod columns;
mod ddl_text;
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
use tablepro_core::column::ColumnDefault;
use tablepro_core::ddl::{
    ColumnCapabilities, DdlCapabilities, DdlDialect, DraftColumn, DraftType, Permission, RefusalReason, TableChanges,
    TableDefinition, TableDraft, default_text, diff_table, parse_default, primary_key_permission,
};
use tablepro_core::dialect::SqlDialect;
use tablepro_core::meta::TableRef;
use tablepro_core::{ForeignKeyInfo, IndexInfo};
use tablepro_session::runtime::{Tasks, WatchForwarder};
use tablepro_session::{LinkGeneration, OperationError, OperationKind, Session};

use self::columns::{ColumnRowContext, build_column_expander_row};
pub(crate) use self::ddl_text::{build_error_text, save_blocker_text};
use self::fks::build_fk_row;
use self::indexes::build_index_row;
pub(crate) use self::structure_command::{LoadedStructure, StructureCommand, StructureRequestKind};
use crate::runtime::{FailedRequests, RequestSequencer, RequestTicket, Stamped};
use crate::services::pending_structure::PendingStructure;
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
    /// The session the tab reads through. A draft takes its dialect
    /// from it for the SQL preview.
    pub session: Arc<Session>,
    pub tasks: Tasks,
}

/// Holds the tab weakly, so a row's or a dialog's closure never keeps a
/// closed tab alive.
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
            dialect: match init.mode {
                // A draft has no table to read the dialect back with.
                StructureMode::New => init.session.current_dialect(),
                StructureMode::Edit => None,
            },
            session: init.session,
            tasks: init.tasks,
            sequencer: RequestSequencer::new(),
            failed: FailedRequests::new(),
            issued_on: BTreeMap::new(),
            tracker: init.tracker,
            mode: init.mode,
            definition: None,
            draft: Rc::new(RefCell::new(TableDraft::new(TableRef::new(init.schema, init.table)))),
            invalid_defaults: BTreeMap::new(),
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
            saving_spinner: imp.saving_spinner.get(),
            stop_button: imp.stop_button.get(),
            saving: false,
            last_dirty: false,
            suppress_emit: imp.suppress_emit.clone(),
            next_column_seq: 1,
            column_popovers: Rc::new(RefCell::new(Vec::new())),
            refetching: false,
            definition_shown: false,
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

    /// Stop the read the tab has running and stop following reconnects
    /// now, rather than at dispose, which waits for the last reference
    /// to the widget.
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
            StructureTabOutput::SaveRequested => self.emit_by_name::<()>("save-requested", &[]),
            StructureTabOutput::StopSaveRequested => self.emit_by_name::<()>("stop-save-requested", &[]),
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
        on_click(&imp.stop_button, || StructureTabInput::StopSaving);
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
    mode: StructureMode,
    /// The table as the last read returned it, which Save plans against
    /// and Discard restores. `None` for a new table.
    definition: Option<TableDefinition>,
    /// What the user is editing. Shared with the dialogs, which list its
    /// columns.
    draft: Rc<RefCell<TableDraft>>,
    /// Default text the engine's parser refused, by column, kept so a
    /// rebuild shows what the user typed. Save waits until it is empty.
    invalid_defaults: BTreeMap<usize, (String, String)>,
    /// The connection's dialect, which plans the DDL. `None` until the
    /// first read, and the SQL cannot be written before then.
    dialect: Option<Arc<dyn SqlDialect>>,

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
    saving_spinner: adw::Spinner,
    stop_button: gtk::Button,
    /// A save of the tab is running, so Save and Discard stay off.
    saving: bool,

    last_dirty: bool,
    /// Suppress reentrant rebuilds: programmatic `set_text` /
    /// `set_active` while seeding row widgets fires `changed` /
    /// `notify::active` signals synchronously. Without this guard,
    /// the row's connect_* callbacks would treat seeding as a user
    /// edit and shift the draft away from the definition, surfacing
    /// phantom pending changes. `Cell` (not `RefCell`) because GTK can
    /// fire those signals re-entrantly during `clear_box` while
    /// another `borrow_mut` is still live on the stack.
    suppress_emit: Rc<Cell<bool>>,
    /// Monotonic counter for the "Add Column" placeholder name, so a
    /// removed column does not leave its name to be handed out twice.
    next_column_seq: usize,
    /// The type suggestion popovers of the column rows. A rebuild pops
    /// them down before it removes the rows, so no menu stays open over
    /// a row that is gone.
    column_popovers: Rc<RefCell<Vec<gtk::Popover>>>,
    /// True between `SaveCompleted` and the read that follows. The draft
    /// is already committed while the definition still holds the
    /// pre-save state, so diffing them would surface phantom pending
    /// changes; `recompute_dirty_state` waits it out.
    refetching: bool,
    /// The editor shows a definition the draft still started from, so a
    /// read of it that fails can leave it on screen.
    definition_shown: bool,
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
    /// The window started saving the tab's pending structure.
    SaveStarted,
    StopSaving,
    Discard,
    /// Read the table again and drop the draft, for a save whose outcome
    /// nobody knows.
    Reload,
    DropTableRequested,
    SaveCompleted {
        new_table_name: Option<String>,
    },
    SaveFailed(String),
    /// The save may have landed; the tracker refuses to save again until
    /// the table is read again or the draft is discarded.
    SaveOutcomeUnknown(String),
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
    /// SQL text; empty is no default.
    Default(String),
    Comment(Option<String>),
}

#[derive(Debug)]
pub(crate) enum StructureTabOutput {
    DirtyChanged(bool),
    /// Save asked the window to write the tracker's pending structure.
    SaveRequested,
    StopSaveRequested,
    DropTableRequested {
        schema: Option<String>,
        table: String,
    },
    ShowToast(String),
    ShowAlert {
        title: String,
        body: String,
    },
}

impl StructureModel {
    fn sender(&self) -> StructureTabSender {
        StructureTabSender { tab: self.this.clone() }
    }

    fn ddl(&self) -> Option<&dyn DdlDialect> {
        self.dialect.as_deref().and_then(|dialect| dialect.ddl())
    }

    /// What Save would write: a new table, or the changes between the
    /// definition and the draft.
    fn pending(&self) -> PendingStructure {
        let draft = self.draft.borrow().clone();
        let original = match self.mode {
            StructureMode::New => None,
            StructureMode::Edit => self.definition.clone(),
        };
        let changes = match &original {
            Some(original) => diff_table(original, &draft),
            None => TableChanges::default(),
        };
        let unparsed_defaults = self
            .invalid_defaults
            .keys()
            .filter_map(|row| draft.columns.get(*row))
            .map(|column| column.name.clone())
            .collect();
        PendingStructure {
            original,
            draft,
            changes,
            unparsed_defaults,
        }
    }

    /// The action bar, the preview and the tracker after an edit. The
    /// tracker holds the pending structure so the window's close and save
    /// paths read it without the tab.
    ///
    /// Waits while `refetching`: between `SaveCompleted` and the read
    /// after it, the definition is stale.
    fn recompute_dirty_state(&mut self, fx: &mut StructureEffects) {
        if self.refetching {
            return;
        }
        let pending = self.pending();
        let dirty = pending.has_changes();
        self.refresh_buttons(pending.change_count());
        self.regenerate_sql_preview(&pending);
        self.tracker.set_pending(Some(pending));
        if self.last_dirty != dirty {
            self.last_dirty = dirty;
            fx.output(StructureTabOutput::DirtyChanged(dirty));
        }
    }

    fn refresh_buttons(&self, pending_count: usize) {
        let has_pending = pending_count > 0 && !self.saving;
        self.save_button
            .set_sensitive(has_pending && self.invalid_defaults.is_empty());
        self.discard_button.set_sensitive(has_pending);
        if has_pending {
            let label = crate::i18n::ngettext_f(
                "{n} pending change",
                "{n} pending changes",
                u32::try_from(pending_count).unwrap_or(u32::MAX),
                &[("n", &pending_count.to_string())],
            );
            self.pending_label.set_label(&label);
            self.pending_label.set_visible(true);
        } else {
            self.pending_label.set_visible(false);
        }
    }

    fn regenerate_sql_preview(&self, pending: &PendingStructure) {
        let text = match (&self.dialect, self.ddl()) {
            (None, _) => crate::i18n::gettext("-- Connect to a database to see the SQL."),
            (Some(_), None) => crate::i18n::gettext("-- This database's structure can't be edited here."),
            (Some(_), Some(_)) if !self.invalid_defaults.is_empty() => {
                crate::i18n::gettext("-- Fix the highlighted fields to see the SQL.")
            }
            (Some(_), Some(_)) if !pending.has_changes() => crate::i18n::gettext("-- No pending changes."),
            (Some(_), Some(ddl)) => match pending.plan(ddl) {
                Ok(plan) => plan.preview(),
                Err(error) => format!("-- {}", build_error_text(&error)),
            },
        };
        self.sql_buffer.set_text(&text);
    }

    fn capabilities(&self) -> DdlCapabilities {
        self.ddl().map(|ddl| *ddl.capabilities()).unwrap_or_default()
    }

    /// Which changes the row of `column` offers. A column the user added
    /// in this tab is only a draft, so everything about it can change,
    /// apart from joining the primary key of a table whose key is held.
    fn column_permissions(&self, column: &DraftColumn) -> ColumnCapabilities {
        let capabilities = self.capabilities();
        let (Some(ddl), Some(definition), Some(original)) = (
            self.ddl(),
            self.definition.as_ref().filter(|_| self.mode == StructureMode::Edit),
            column.original.as_ref(),
        ) else {
            let primary_key = match (self.mode, &self.definition) {
                (StructureMode::Edit, Some(definition)) => primary_key_permission(&capabilities, definition),
                _ => Permission::Allowed,
            };
            return ColumnCapabilities {
                rename: Permission::Allowed,
                drop: Permission::Allowed,
                alter_type: Permission::Allowed,
                alter_nullability: Permission::Allowed,
                alter_default: Permission::Allowed,
                alter_primary_key: primary_key,
                alter_auto_increment: Permission::Allowed,
                alter_comment: Permission::unless(capabilities.column_comments, RefusalReason::EngineUnsupported),
            };
        };
        ddl.column_capabilities(definition, original)
    }

    /// The type a default's literal is read against: the column's own, or
    /// the one the user typed once it parses.
    fn default_column_type(&self, column: &DraftColumn) -> Option<tablepro_core::column::ColumnType> {
        let dialect = self.dialect.as_deref()?;
        column.column_type.column_type(dialect, &column.name).ok()
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
        let capabilities = self.capabilities();
        let type_suggestions = self.ddl().map(|ddl| ddl.type_suggestions()).unwrap_or_default();

        let list = boxed_list();
        let columns = self.draft.borrow().columns.clone();
        for (i, col) in columns.iter().enumerate() {
            let (default_text, default_error) = match self.invalid_defaults.get(&i) {
                Some((text, error)) => (text.clone(), Some(error.clone())),
                None => (self.default_text(col), None),
            };
            let context = ColumnRowContext {
                permissions: self.column_permissions(col),
                type_suggestions,
                dialect: self.dialect.clone(),
                default_text,
                default_error,
            };
            list.append(&build_column_expander_row(
                i,
                col,
                context,
                self.sender(),
                self.suppress_emit.clone(),
                self.column_popovers.clone(),
            ));
        }
        let can_add = match self.mode {
            StructureMode::New => true,
            StructureMode::Edit => capabilities.add_column,
        };
        if can_add {
            let sender_for_add = self.sender();
            append_add_button(&list, &crate::i18n::gettext("Add Column"), move || {
                sender_for_add.input(StructureTabInput::AddColumn);
            });
        }
        self.columns_box.append(&list);

        let suppress = self.suppress_emit.clone();
        glib::idle_add_local_once(move || {
            suppress.set(false);
        });
    }

    fn default_text(&self, column: &DraftColumn) -> String {
        match (self.dialect.as_deref(), self.default_column_type(column)) {
            (Some(dialect), Some(column_type)) => default_text(dialect, &column.default, &column_type),
            _ => match &column.default {
                ColumnDefault::None => String::new(),
                ColumnDefault::Literal(value) => tablepro_core::export::value_to_text(value).unwrap_or_default(),
                ColumnDefault::Expression(expression) => expression.as_sql().to_owned(),
            },
        }
    }

    /// A draft's indexes and foreign keys are only entries in it, so the
    /// engine's limits apply to a table that exists.
    fn table_permission(&self, allowed: bool) -> Permission {
        match self.mode {
            StructureMode::New => Permission::Allowed,
            StructureMode::Edit => Permission::unless(allowed, RefusalReason::EngineUnsupported),
        }
    }

    fn rebuild_indexes_view(&self) {
        clear_box(&self.indexes_box);
        let capabilities = self.capabilities();
        let removable = self.table_permission(capabilities.drop_index);
        let list = boxed_list();
        for (i, idx) in self.draft.borrow().indexes.iter().enumerate() {
            list.append(&build_index_row(i, idx, &removable, self.sender()));
        }
        if capabilities.create_index {
            let draft_for_dialog = self.draft.clone();
            let sender_for_add = self.sender();
            let parent_box = self.indexes_box.downgrade();
            append_add_button(&list, &crate::i18n::gettext("Add Index…"), move || {
                if let Some(parent_box) = parent_box.upgrade() {
                    present_index_dialog(
                        parent_box.upcast_ref(),
                        &draft_for_dialog.borrow().columns,
                        sender_for_add.clone(),
                    );
                }
            });
        }
        self.indexes_box.append(&list);
    }

    fn rebuild_fks_view(&self) {
        clear_box(&self.fks_box);
        let capabilities = self.capabilities();
        let removable = self.table_permission(capabilities.drop_foreign_key);
        let list = boxed_list();
        for (i, fk) in self.draft.borrow().foreign_keys.iter().enumerate() {
            list.append(&build_fk_row(i, fk, &removable, self.sender()));
        }
        // A new table declares its keys inside CREATE TABLE, which every
        // engine that creates tables takes.
        let can_add = match self.mode {
            StructureMode::New => capabilities.create_table,
            StructureMode::Edit => capabilities.add_foreign_key,
        };
        if let Some(actions) = self.ddl().map(|ddl| ddl.referential_actions()).filter(|_| can_add) {
            let draft_for_dialog = self.draft.clone();
            let sender_for_add = self.sender();
            let parent_box = self.fks_box.downgrade();
            append_add_button(&list, &crate::i18n::gettext("Add Foreign Key…"), move || {
                if let Some(parent_box) = parent_box.upgrade() {
                    present_fk_dialog(
                        parent_box.upcast_ref(),
                        &draft_for_dialog.borrow().columns,
                        actions,
                        sender_for_add.clone(),
                    );
                }
            });
        }
        self.fks_box.append(&list);
    }

    fn table_ref(&self) -> TableRef {
        self.draft.borrow().table.clone()
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
        self.dialect = Some(loaded.dialect);
        *self.draft.borrow_mut() = TableDraft::from_definition(&loaded.definition);
        self.definition = Some(loaded.definition);
        self.invalid_defaults.clear();
        self.inner_stack.set_visible_child_name("editor");
        self.definition_shown = true;
        // The definition is current again, so the diff counts; it is
        // empty now, which also clears anything typed during the read.
        self.refetching = false;
        self.recompute_dirty_state(fx);
        fx.input(StructureTabInput::Refresh);
    }

    fn on_load_failed(&mut self, message: &str, fx: &mut StructureEffects) {
        if self.definition_shown {
            self.inner_stack.set_visible_child_name("editor");
            fx.output(StructureTabOutput::ShowToast(crate::i18n::gettext_f(
                "Couldn't refresh the structure: {error}",
                &[("error", message)],
            )));
            return;
        }
        // Inline on the status page: a modal alert would say the same
        // and make the user dismiss it before seeing the page.
        self.error_status.set_description(Some(message));
        self.inner_stack.set_visible_child_name("error");
        // A retry from the error page must not find dirty tracking still
        // frozen.
        self.refetching = false;
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
                self.on_load_failed(&crate::ui::error_text::operation_error_message(&error), fx);
                let issued = self.issued_on.get(&StructureRequestKind::Definition).copied();
                if issued.is_some_and(|issued| self.session.link_generation() > issued) {
                    self.retry_failed();
                }
            }
        }
    }

    /// The session reconnected: a draft takes the new connection's
    /// dialect, and a read that failed is asked again.
    fn on_link_changed(&mut self, generation: LinkGeneration, fx: &mut StructureEffects) {
        if generation <= self.link_generation {
            return;
        }
        self.link_generation = generation;
        if self.mode == StructureMode::New {
            self.dialect = self.session.current_dialect();
            self.recompute_dirty_state(fx);
            fx.input(StructureTabInput::Refresh);
        }
        self.retry_failed();
    }

    fn retry_failed(&mut self) {
        if self.failed.take().contains(&StructureRequestKind::Definition) {
            if !self.definition_shown {
                self.show_loading();
            }
            self.fetch_definition();
        }
    }

    fn update(&mut self, msg: StructureTabInput, fx: &mut StructureEffects) {
        match msg {
            StructureTabInput::Start => {
                if self.mode == StructureMode::Edit {
                    self.fetch_definition();
                }
                fx.input(StructureTabInput::Refresh);
            }
            StructureTabInput::Command(command) => self.on_command(command, fx),
            StructureTabInput::LinkChanged(generation) => self.on_link_changed(generation, fx),
            StructureTabInput::SchemaChanged => {
                // Reading the table again replaces the draft, so a tab
                // with edits of its own keeps them.
                if self.mode == StructureMode::Edit && !self.last_dirty {
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
                self.regenerate_sql_preview(&self.pending());
            }
            StructureTabInput::TableNameEdited(text) => {
                if self.draft.borrow().table.name == text {
                    return;
                }
                self.draft.borrow_mut().table.name = text;
                self.recompute_dirty_state(fx);
            }
            StructureTabInput::ColumnEdited { index, field } => self.edit_column(index, field, fx),
            StructureTabInput::AddColumn => {
                let name = format!("column_{}", self.next_column_seq);
                self.next_column_seq += 1;
                let column_type = self.ddl().map_or("text", |ddl| ddl.default_column_type());
                self.draft
                    .borrow_mut()
                    .columns
                    .push(DraftColumn::new(name, DraftType::Typed(column_type.to_owned())));
                self.recompute_dirty_state(fx);
                fx.input(StructureTabInput::Refresh);
            }
            StructureTabInput::RemoveColumn(index) => {
                {
                    let mut draft = self.draft.borrow_mut();
                    if index >= draft.columns.len() {
                        return;
                    }
                    draft.columns.remove(index);
                }
                // The rows after it move up one.
                self.invalid_defaults = std::mem::take(&mut self.invalid_defaults)
                    .into_iter()
                    .filter(|(row, _)| *row != index)
                    .map(|(row, invalid)| (if row > index { row - 1 } else { row }, invalid))
                    .collect();
                self.recompute_dirty_state(fx);
                fx.input(StructureTabInput::Refresh);
            }
            StructureTabInput::AddIndex(index) => {
                self.draft.borrow_mut().indexes.push(index);
                self.recompute_dirty_state(fx);
                fx.input(StructureTabInput::Refresh);
            }
            StructureTabInput::RemoveIndex(position) => {
                {
                    let mut draft = self.draft.borrow_mut();
                    if position >= draft.indexes.len() {
                        return;
                    }
                    draft.indexes.remove(position);
                }
                self.recompute_dirty_state(fx);
                fx.input(StructureTabInput::Refresh);
            }
            StructureTabInput::AddForeignKey(fk) => {
                self.draft.borrow_mut().foreign_keys.push(fk);
                self.recompute_dirty_state(fx);
                fx.input(StructureTabInput::Refresh);
            }
            StructureTabInput::RemoveForeignKey(position) => {
                {
                    let mut draft = self.draft.borrow_mut();
                    if position >= draft.foreign_keys.len() {
                        return;
                    }
                    draft.foreign_keys.remove(position);
                }
                self.recompute_dirty_state(fx);
                fx.input(StructureTabInput::Refresh);
            }
            StructureTabInput::Save => self.save(fx),
            StructureTabInput::SaveStarted => self.show_saving(true),
            StructureTabInput::StopSaving => fx.output(StructureTabOutput::StopSaveRequested),
            StructureTabInput::Reload => {
                // A table the save may have created has nothing to read
                // yet, so a new one is only cleared.
                match self.mode {
                    StructureMode::Edit => {
                        self.show_loading();
                        self.fetch_definition();
                    }
                    StructureMode::New => fx.input(StructureTabInput::Discard),
                }
            }
            StructureTabInput::Discard => {
                // This also lets go of a save whose outcome was unknown.
                self.tracker.clear();
                // New mode clears everything, since a new table starts
                // empty.
                let restored = match (self.mode, &self.definition) {
                    (StructureMode::Edit, Some(definition)) => TableDraft::from_definition(definition),
                    _ => {
                        let mut draft = TableDraft::new(self.table_ref());
                        draft.table.name = self.draft.borrow().table.name.clone();
                        draft
                    }
                };
                *self.draft.borrow_mut() = restored;
                self.invalid_defaults.clear();
                self.recompute_dirty_state(fx);
                fx.input(StructureTabInput::Refresh);
            }
            StructureTabInput::DropTableRequested => {
                let table = match &self.definition {
                    Some(definition) => definition.table.clone(),
                    None => self.table_ref(),
                };
                fx.output(StructureTabOutput::DropTableRequested {
                    schema: table.schema,
                    table: table.name,
                });
            }
            StructureTabInput::SaveCompleted { new_table_name } => self.save_completed(new_table_name, fx),
            StructureTabInput::SaveFailed(message) => {
                self.show_saving(false);
                self.recompute_dirty_state(fx);
                fx.output(StructureTabOutput::ShowAlert {
                    title: crate::i18n::gettext("Save failed"),
                    body: message,
                });
            }
            StructureTabInput::SaveOutcomeUnknown(message) => {
                self.show_saving(false);
                self.recompute_dirty_state(fx);
                fx.output(StructureTabOutput::ShowAlert {
                    title: crate::i18n::gettext("Save Result Unknown"),
                    body: message,
                });
            }
        }
    }

    fn edit_column(&mut self, index: usize, field: ColumnField, fx: &mut StructureEffects) {
        let Some(previous) = self.draft.borrow().columns.get(index).cloned() else {
            return;
        };
        let mut column = previous.clone();
        match field {
            ColumnField::Name(name) => column.name = name,
            ColumnField::Type(text) => {
                // Retyping the declaration keeps the catalogue's type,
                // which is never parsed again.
                column.column_type = match column.original.as_ref() {
                    Some(original) if DraftType::Catalog(original.info.column_type.clone()).text() == text => {
                        DraftType::Catalog(original.info.column_type.clone())
                    }
                    _ => DraftType::Typed(text),
                };
            }
            ColumnField::Nullable(nullable) => column.nullable = nullable,
            ColumnField::PrimaryKey(primary_key) => {
                column.primary_key = primary_key;
                // Every engine numbers only a key column, and the switch
                // only greys out, so the model drops it here.
                if !primary_key {
                    column.auto_increment = false;
                }
            }
            ColumnField::AutoIncrement(auto_increment) => column.auto_increment = auto_increment,
            ColumnField::Default(text) => match self.parse_default(&column, &text) {
                Ok(default) => {
                    self.invalid_defaults.remove(&index);
                    column.default = default;
                }
                Err(error) => {
                    self.invalid_defaults.insert(index, (text, error));
                }
            },
            ColumnField::Comment(comment) => column.comment = comment,
        }
        // A rebuild sets each widget to the value the model already has,
        // which is no edit. A default the parser refused is no edit
        // either, but the tracker has to learn of it, or a close prompt
        // would save without it.
        if column == previous {
            self.recompute_dirty_state(fx);
            return;
        }
        if let Some(slot) = self.draft.borrow_mut().columns.get_mut(index) {
            *slot = column;
        }
        self.recompute_dirty_state(fx);
    }

    /// The default the user typed, as the engine's parser reads it. The
    /// text the row showed for the loaded default gives that default
    /// back, so seeing it again is no edit.
    fn parse_default(&self, column: &DraftColumn, text: &str) -> Result<ColumnDefault, String> {
        if let Some(original) = column.original.as_ref().filter(|original| {
            let loaded = DraftColumn::from_definition((*original).clone());
            self.default_text(&loaded) == text
        }) {
            return Ok(original.info.default.clone());
        }
        let Some(dialect) = self.dialect.as_deref() else {
            return Err(crate::i18n::gettext("Connect to a database to check the default."));
        };
        let column_type = self
            .default_column_type(column)
            .unwrap_or_else(|| tablepro_core::column::ColumnType::untyped_text(column.column_type.text()));
        parse_default(dialect, text, &column_type).map_err(|error| error.to_string())
    }

    fn save(&mut self, fx: &mut StructureEffects) {
        let pending = self.pending();
        if let Err(blocker) = pending.check() {
            fx.output(StructureTabOutput::ShowToast(save_blocker_text(&blocker)));
            return;
        }
        if !pending.has_changes() {
            fx.output(StructureTabOutput::ShowToast(crate::i18n::gettext("Nothing to save.")));
            return;
        }
        let Some(ddl) = self.ddl() else {
            fx.output(StructureTabOutput::ShowToast(crate::i18n::gettext(
                "Connect to a database first.",
            )));
            return;
        };
        // Planned here only to refuse early in the user's words: the
        // window plans again with the connection that runs the save.
        match pending.plan(ddl) {
            Ok(_) => {
                self.tracker.set_pending(Some(pending));
                fx.output(StructureTabOutput::SaveRequested);
            }
            Err(error) => fx.output(StructureTabOutput::ShowAlert {
                title: crate::i18n::gettext("Cannot save"),
                body: build_error_text(&error),
            }),
        }
    }

    /// While a save runs, Save and Discard are off, so a double click
    /// cannot send two, and Stop Saving takes their place.
    fn show_saving(&mut self, saving: bool) {
        self.saving = saving;
        self.saving_spinner.set_visible(saving);
        self.stop_button.set_visible(saving);
        if saving {
            self.save_button.set_sensitive(false);
            self.discard_button.set_sensitive(false);
        }
    }

    fn save_completed(&mut self, new_table_name: Option<String>, fx: &mut StructureEffects) {
        self.show_saving(false);
        if let Some(name) = new_table_name {
            self.mode = StructureMode::Edit;
            self.draft.borrow_mut().table.name = name.clone();
            self.name_entry.set_text(&name);
            self.drop_button.set_visible(true);
            self.name_row.set_visible(false);
        }
        if self.mode != StructureMode::Edit {
            return;
        }
        // The diff against the pre-save definition would show the changes
        // just committed as still pending until the read lands, and a
        // close in that window would offer to save them again. So the
        // dirty state goes to zero now, and so does a CREATE TABLE left
        // in the preview by a draft that just became the table.
        self.tracker.clear();
        self.refresh_buttons(0);
        self.sql_buffer
            .set_text(&crate::i18n::gettext("-- No pending changes."));
        if self.last_dirty {
            self.last_dirty = false;
            fx.output(StructureTabOutput::DirtyChanged(false));
        }
        self.refetching = true;
        self.definition_shown = false;
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
