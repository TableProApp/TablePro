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
//!   │ │   Default/PK/AutoInc rows), then an Add Column row  │  │
//!   │ │ Indexes: boxed-list (Name, Cols, Unique, trash)     │  │
//!   │ │ FKs: boxed-list (Name, Cols, Refs, RefCols, trash)  │  │
//!   │ │ SQL Preview: SourceView5 (read-only, sql highlight) │  │
//!   │ └─────────────────────────────────────────────────────┘  │
//!   ├─ ActionBar { pending count | Discard | Save | Drop } ────┤
//!   └──────────────────────────────────────────────────────────┘
//!
//! The tab edits a draft started from the table's definition as one
//! read returned it. The draft's columns, indexes and foreign keys are
//! the items of three list stores, each shown by a list bound to it, so
//! an edit changes one item and its row, and every other row stays as
//! it is. Every edit diffs the draft against the definition, plans the
//! change through the connection's `DdlDialect` for the preview, and
//! hands the pending structure to the tab's tracker, where the window's
//! close and save paths read it. Each control is on only where the
//! dialect allows its change, with the reason in its tooltip where it
//! does not. Discard puts the definition's items back in the stores;
//! there is no per-change undo.
//!
//! The tab reads the table's definition itself, one request at a time,
//! and reads it again once the session reconnects if the last read
//! failed. A change to the table from elsewhere reads it again too,
//! unless the draft has edits: then Discard reads it, and a plan that
//! writes the table again from the old definition refuses to save.

mod columns;
mod context;
mod draft_column_object;
mod draft_column_object_imp;
mod fks;
mod foreign_key_object;
mod imp;
mod index_object;
mod indexes;
mod structure_command;
#[cfg(test)]
mod tests;

use std::cell::RefCell;
use std::collections::{BTreeMap, VecDeque};
use std::rc::Rc;
use std::sync::Arc;

use gtk4 as gtk;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use gtk4::{gio, glib};
use libadwaita as adw;
use sourceview5::prelude::BufferExt;
use tablepro_core::ddl::{DraftColumn, DraftType, TableChanges, TableDraft, diff_table};
use tablepro_core::meta::TableRef;
use tablepro_core::{ForeignKeyInfo, IndexInfo};
use tablepro_session::runtime::{Tasks, WatchForwarder};
use tablepro_session::{LinkGeneration, OperationError, OperationKind, Session};

use self::columns::build_column_row;
use self::context::StructureContext;
use self::draft_column_object::{DraftColumnObject, UnparsedDefault};
use self::fks::build_fk_row;
use self::foreign_key_object::ForeignKeyObject;
use self::index_object::IndexObject;
use self::indexes::build_index_row;
pub(crate) use self::structure_command::{LoadedStructure, StructureCommand, StructureRequestKind};
use crate::runtime::{FailedRequests, RequestSequencer, RequestTicket, Stamped};
use crate::services::pending_structure::PendingStructure;
use crate::services::structure_tracker_handle::StructureTrackerHandle;
use crate::ui::error_text::{build_error_text, save_blocker_text};
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
        let name_changed = tab.connect_widgets();

        let context = Rc::new(RefCell::new(StructureContext {
            mode: init.mode,
            dialect: match init.mode {
                // A draft has no table to read the dialect back with.
                StructureMode::New => init.session.current_dialect(),
                StructureMode::Edit => None,
            },
            definition: None,
        }));
        let columns = gio::ListStore::new::<DraftColumnObject>();
        let indexes = gio::ListStore::new::<IndexObject>();
        let foreign_keys = gio::ListStore::new::<ForeignKeyObject>();
        tab.bind_lists(&context, &columns, &indexes, &foreign_keys);

        let link_changes = init.session.link_changes();
        let model = StructureModel {
            this: tab.downgrade(),
            link_generation: init.session.link_generation(),
            session: init.session,
            tasks: init.tasks,
            sequencer: RequestSequencer::new(),
            failed: FailedRequests::new(),
            issued_on: BTreeMap::new(),
            tracker: init.tracker,
            context,
            table: TableRef::new(init.schema, init.table),
            columns,
            indexes,
            foreign_keys,
            inner_stack: imp.inner_stack.get(),
            error_status: imp.error_status.get(),
            name_entry: imp.name_entry.get(),
            name_row: imp.name_row.get(),
            name_changed,
            columns_box: imp.columns_box.get(),
            indexes_box: imp.indexes_box.get(),
            fks_box: imp.fks_box.get(),
            add_column_row: imp.add_column_row.get(),
            add_index_row: imp.add_index_row.get(),
            add_fk_row: imp.add_fk_row.get(),
            sql_buffer,
            pending_label: imp.pending_label.get(),
            save_button: imp.save_button.get(),
            discard_button: imp.discard_button.get(),
            drop_button: imp.drop_button.get(),
            saving_spinner: imp.saving_spinner.get(),
            stop_button: imp.stop_button.get(),
            saving: false,
            last_dirty: false,
            refetching: false,
            definition_shown: false,
            definition_stale: false,
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

    /// Connects the template's controls, and gives back the name entry's
    /// handler, which the tab blocks while it writes the name itself.
    fn connect_widgets(&self) -> glib::SignalHandlerId {
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
        imp.add_column_row
            .connect_activated(move |_| sender.input(StructureTabInput::AddColumn));
        // An add row that is hidden would leave its list's frame behind.
        for (row, list) in [
            (&imp.add_column_row, &imp.add_column_list),
            (&imp.add_index_row, &imp.add_index_list),
            (&imp.add_fk_row, &imp.add_fk_list),
        ] {
            row.bind_property("visible", &**list, "visible").sync_create().build();
        }
        let sender = self.sender();
        imp.name_entry.connect_changed(move |entry| {
            sender.input(StructureTabInput::TableNameEdited(entry.text().to_string()));
        })
    }

    /// Each list builds a row for an item from the item and the context
    /// alone, since the stores change while the tab's model is borrowed.
    fn bind_lists(
        &self,
        context: &Rc<RefCell<StructureContext>>,
        columns: &gio::ListStore,
        indexes: &gio::ListStore,
        foreign_keys: &gio::ListStore,
    ) {
        let imp = self.imp();
        let (context_for_columns, sender) = (context.clone(), self.sender());
        bind_list(&imp.columns_list, columns, move |column: &DraftColumnObject| {
            build_column_row(column, &context_for_columns.borrow(), &sender)
        });
        let (context_for_indexes, sender) = (context.clone(), self.sender());
        bind_list(&imp.indexes_list, indexes, move |index: &IndexObject| {
            let context = context_for_indexes.borrow();
            let removable = context.table_permission(context.capabilities().drop_index);
            build_index_row(index, &removable, &sender)
        });
        let (context_for_keys, sender) = (context.clone(), self.sender());
        bind_list(&imp.fks_list, foreign_keys, move |key: &ForeignKeyObject| {
            let context = context_for_keys.borrow();
            let removable = context.table_permission(context.capabilities().drop_foreign_key);
            build_fk_row(key, &removable, &sender)
        });

        // The dialogs list the columns the draft has when they open.
        let (columns_for_index, sender) = (columns.downgrade(), self.sender());
        imp.add_index_row.connect_activated(move |row| {
            if let Some(columns) = columns_for_index.upgrade() {
                present_index_dialog(row.upcast_ref(), &draft_columns(&columns), sender.clone());
            }
        });
        let (columns_for_key, context_for_key, sender) = (columns.downgrade(), context.clone(), self.sender());
        imp.add_fk_row.connect_activated(move |row| {
            let actions = context_for_key.borrow().ddl().map(|ddl| ddl.referential_actions());
            if let (Some(columns), Some(actions)) = (columns_for_key.upgrade(), actions) {
                present_fk_dialog(row.upcast_ref(), &draft_columns(&columns), actions, sender.clone());
            }
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
    /// Whether the table exists, its definition and the dialect, shared
    /// with the lists, which read it as they build rows.
    context: Rc<RefCell<StructureContext>>,
    /// The table the draft names, renamed as the user types a new
    /// table's name.
    table: TableRef,
    /// The draft's columns, indexes and foreign keys, which the lists
    /// show. An edit finds its item here by identity.
    columns: gio::ListStore,
    indexes: gio::ListStore,
    foreign_keys: gio::ListStore,

    inner_stack: gtk::Stack,
    /// The status page shown when the read fails, with the driver's
    /// error as its description.
    error_status: adw::StatusPage,
    name_entry: adw::EntryRow,
    /// The group around `name_entry`, visible only in New mode.
    name_row: adw::PreferencesGroup,
    /// Blocked while the tab writes the draft's name into the entry,
    /// which is no edit.
    name_changed: glib::SignalHandlerId,
    columns_box: gtk::Box,
    indexes_box: gtk::Box,
    fks_box: gtk::Box,
    add_column_row: adw::ButtonRow,
    add_index_row: adw::ButtonRow,
    add_fk_row: adw::ButtonRow,
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
    /// True between `SaveCompleted` and the read that follows. The draft
    /// is already committed while the definition still holds the
    /// pre-save state, so diffing them would surface phantom pending
    /// changes; `recompute_dirty_state` waits it out.
    refetching: bool,
    /// The editor shows a definition the draft still started from, so a
    /// read of it that fails can leave it on screen.
    definition_shown: bool,
    /// The table changed after `definition` was read, while the draft
    /// had edits that a read would replace. Discard reads it again
    /// rather than restoring it.
    definition_stale: bool,
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
    /// The save found the table changed since the tab read it, and left
    /// it as it was.
    TableChangedBeforeSave,
    /// The save may have landed; the tracker refuses to save again until
    /// the table is read again or the draft is discarded.
    SaveOutcomeUnknown(String),
    ColumnEdited {
        column: DraftColumnObject,
        field: ColumnField,
    },
    AddColumn,
    RemoveColumn(DraftColumnObject),
    AddIndex(IndexInfo),
    RemoveIndex(IndexObject),
    AddForeignKey(ForeignKeyInfo),
    RemoveForeignKey(ForeignKeyObject),
    TableNameEdited(String),
}

impl StructureTabInput {
    fn edits_draft(&self) -> bool {
        matches!(
            self,
            Self::TableNameEdited(_)
                | Self::ColumnEdited { .. }
                | Self::AddColumn
                | Self::RemoveColumn(_)
                | Self::AddIndex(_)
                | Self::RemoveIndex(_)
                | Self::AddForeignKey(_)
                | Self::RemoveForeignKey(_)
        )
    }
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
    fn mode(&self) -> StructureMode {
        self.context.borrow().mode
    }

    /// The draft as the lists hold it.
    fn draft(&self) -> TableDraft {
        TableDraft {
            table: self.table.clone(),
            columns: draft_columns(&self.columns),
            indexes: items::<IndexObject>(&self.indexes)
                .iter()
                .map(|index| index.info().clone())
                .collect(),
            foreign_keys: items::<ForeignKeyObject>(&self.foreign_keys)
                .iter()
                .map(|key| key.info().clone())
                .collect(),
        }
    }

    /// What Save would write: a new table, or the changes between the
    /// definition and the draft.
    fn pending(&self) -> PendingStructure {
        let draft = self.draft();
        let original = self.context.borrow().original().cloned();
        let changes = match &original {
            Some(original) => diff_table(original, &draft),
            None => TableChanges::default(),
        };
        let unparsed_defaults = items::<DraftColumnObject>(&self.columns)
            .iter()
            .filter(|column| column.unparsed_default().is_some())
            .map(DraftColumnObject::name)
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
        self.refresh_buttons(pending.change_count(), pending.unparsed_defaults.is_empty());
        self.regenerate_sql_preview(&pending);
        self.tracker.set_pending(Some(pending));
        if self.last_dirty != dirty {
            self.last_dirty = dirty;
            fx.output(StructureTabOutput::DirtyChanged(dirty));
        }
    }

    fn refresh_buttons(&self, pending_count: usize, defaults_parsed: bool) {
        let has_pending = pending_count > 0 && !self.saving;
        self.save_button.set_sensitive(has_pending && defaults_parsed);
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
        let context = self.context.borrow();
        let text = match (&context.dialect, context.ddl()) {
            (None, _) => crate::i18n::gettext("-- Connect to a database to see the SQL."),
            (Some(_), None) => crate::i18n::gettext("-- This database's structure can't be edited here."),
            (Some(_), Some(_)) if !pending.unparsed_defaults.is_empty() => {
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

    /// The Add rows the engine allows on the table as it stands.
    fn sync_add_rows(&self) {
        let context = self.context.borrow();
        self.add_column_row.set_visible(context.can_add_column());
        self.add_index_row.set_visible(context.can_add_index());
        self.add_fk_row.set_visible(context.can_add_foreign_key());
    }

    /// Put `draft` in the lists. Each store changes once, so each list
    /// builds its rows once.
    fn show_draft(&mut self, draft: TableDraft) {
        self.table = draft.table;
        replace_items(&self.columns, draft.columns.into_iter().map(DraftColumnObject::new));
        replace_items(&self.indexes, draft.indexes.into_iter().map(IndexObject::new));
        replace_items(
            &self.foreign_keys,
            draft.foreign_keys.into_iter().map(ForeignKeyObject::new),
        );
    }

    /// The lists build every row again, keeping the items, for rows
    /// whose controls depend on a context that changed.
    fn rebuild_rows(&self) {
        replace_items(&self.columns, items::<DraftColumnObject>(&self.columns));
        replace_items(&self.indexes, items::<IndexObject>(&self.indexes));
        replace_items(&self.foreign_keys, items::<ForeignKeyObject>(&self.foreign_keys));
    }

    /// `column_N` with the first N that no column of the draft is named.
    fn placeholder_column_name(&self) -> String {
        let names: Vec<String> = items::<DraftColumnObject>(&self.columns)
            .iter()
            .map(DraftColumnObject::name)
            .collect();
        (1_usize..)
            .map(|n| format!("column_{n}"))
            .find(|candidate| !names.iter().any(|name| name.eq_ignore_ascii_case(candidate)))
            .unwrap_or_default()
    }

    /// Write the draft's name into the entry without it reading as an
    /// edit.
    fn show_table_name(&self) {
        if self.name_entry.text() == self.table.name {
            return;
        }
        self.name_entry.block_signal(&self.name_changed);
        self.name_entry.set_text(&self.table.name);
        self.name_entry.unblock_signal(&self.name_changed);
    }

    /// Read the table's definition in one call, so the tab rebuilds
    /// once with columns, indexes and foreign keys from the same moment.
    fn fetch_definition(&mut self) {
        self.issued_on
            .insert(StructureRequestKind::Definition, self.session.link_generation());
        let RequestTicket { stamp, cancel } = self.sequencer.issue(StructureRequestKind::Definition);
        let session = self.session.clone();
        let table = self.table.clone();
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
        let draft = TableDraft::from_definition(&loaded.definition);
        {
            let mut context = self.context.borrow_mut();
            context.dialect = Some(loaded.dialect);
            context.definition = Some(loaded.definition);
        }
        self.show_draft(draft);
        self.sync_add_rows();
        self.inner_stack.set_visible_child_name("editor");
        self.definition_shown = true;
        self.definition_stale = false;
        // The definition is current again, so the diff counts.
        self.refetching = false;
        self.sync_editable();
        self.recompute_dirty_state(fx);
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
        self.sync_editable();
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
        if self.mode() == StructureMode::New {
            self.context.borrow_mut().dialect = self.session.current_dialect();
            self.rebuild_rows();
            self.sync_add_rows();
            self.recompute_dirty_state(fx);
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
        if msg.edits_draft() && self.edits_locked() {
            self.refuse_edit(&msg, fx);
            return;
        }
        match msg {
            StructureTabInput::Start => {
                if self.mode() == StructureMode::Edit {
                    self.fetch_definition();
                }
                self.sync_add_rows();
                self.regenerate_sql_preview(&self.pending());
            }
            StructureTabInput::Command(command) => self.on_command(command, fx),
            StructureTabInput::LinkChanged(generation) => self.on_link_changed(generation, fx),
            StructureTabInput::SchemaChanged => {
                // Reading the table again replaces the draft, so a tab
                // with edits of its own keeps them until Discard.
                if self.mode() == StructureMode::Edit {
                    match self.last_dirty {
                        true => self.definition_stale = true,
                        false => self.fetch_definition(),
                    }
                }
            }
            StructureTabInput::Retry => {
                // Without the loading page the click reads as a no-op
                // until the reply arrives.
                self.show_loading();
                self.fetch_definition();
            }
            StructureTabInput::TableNameEdited(text) => {
                if self.table.name == text {
                    return;
                }
                self.table.name = text;
                self.recompute_dirty_state(fx);
            }
            StructureTabInput::ColumnEdited { column, field } => self.edit_column(&column, field, fx),
            StructureTabInput::AddColumn => {
                let column_type = self
                    .context
                    .borrow()
                    .ddl()
                    .map_or("text", |ddl| ddl.default_column_type())
                    .to_owned();
                let column = DraftColumn::new(self.placeholder_column_name(), DraftType::Typed(column_type));
                self.columns.append(&DraftColumnObject::new(column));
                self.recompute_dirty_state(fx);
            }
            StructureTabInput::RemoveColumn(column) => {
                if let Some(position) = self.columns.find(&column) {
                    self.columns.remove(position);
                    self.recompute_dirty_state(fx);
                }
            }
            StructureTabInput::AddIndex(index) => {
                self.indexes.append(&IndexObject::new(index));
                self.recompute_dirty_state(fx);
            }
            StructureTabInput::RemoveIndex(index) => {
                if let Some(position) = self.indexes.find(&index) {
                    self.indexes.remove(position);
                    self.recompute_dirty_state(fx);
                }
            }
            StructureTabInput::AddForeignKey(key) => {
                self.foreign_keys.append(&ForeignKeyObject::new(key));
                self.recompute_dirty_state(fx);
            }
            StructureTabInput::RemoveForeignKey(key) => {
                if let Some(position) = self.foreign_keys.find(&key) {
                    self.foreign_keys.remove(position);
                    self.recompute_dirty_state(fx);
                }
            }
            StructureTabInput::Save => self.save(fx),
            StructureTabInput::SaveStarted => self.show_saving(true),
            StructureTabInput::StopSaving => fx.output(StructureTabOutput::StopSaveRequested),
            StructureTabInput::Reload => {
                // A table the save may have created has nothing to read
                // yet, so a new one is only cleared.
                match self.mode() {
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
                if self.mode() == StructureMode::Edit && self.definition_stale {
                    fx.input(StructureTabInput::Reload);
                    return;
                }
                // New mode clears everything but the name, since a new
                // table starts empty.
                let restored = match self.context.borrow().original() {
                    Some(definition) => TableDraft::from_definition(definition),
                    None => TableDraft::new(self.table.clone()),
                };
                self.show_draft(restored);
                self.recompute_dirty_state(fx);
            }
            StructureTabInput::DropTableRequested => {
                let table = match &self.context.borrow().definition {
                    Some(definition) => definition.table.clone(),
                    None => self.table.clone(),
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
            StructureTabInput::TableChangedBeforeSave => {
                self.definition_stale = true;
                self.show_saving(false);
                self.recompute_dirty_state(fx);
                fx.output(StructureTabOutput::ShowAlert {
                    title: crate::i18n::gettext("Save failed"),
                    body: crate::i18n::gettext(
                        "The table changed after this tab read it, so nothing was saved. Discard the changes to read the table again, then make them again.",
                    ),
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

    fn edit_column(&mut self, column: &DraftColumnObject, field: ColumnField, fx: &mut StructureEffects) {
        // A row of a column the draft no longer holds.
        if self.columns.find(column).is_none() {
            return;
        }
        match field {
            ColumnField::Name(name) => column.update(|draft| draft.name = name),
            ColumnField::Type(text) => column.update(|draft| {
                // Retyping the declaration keeps the catalogue's type,
                // which is never parsed again.
                draft.column_type = match draft.original.as_ref() {
                    Some(original) if DraftType::Catalog(original.info.column_type.clone()).text() == text => {
                        DraftType::Catalog(original.info.column_type.clone())
                    }
                    _ => DraftType::Typed(text),
                };
            }),
            ColumnField::Nullable(nullable) => column.update(|draft| draft.nullable = nullable),
            // The row's Nullable and Auto increment switches follow the
            // key and send their own edits.
            ColumnField::PrimaryKey(primary_key) => column.update(|draft| draft.primary_key = primary_key),
            ColumnField::AutoIncrement(auto_increment) => column.update(|draft| draft.auto_increment = auto_increment),
            ColumnField::Default(text) => {
                let parsed = self.context.borrow().parse_default(&column.column(), &text);
                match parsed {
                    Ok(default) => {
                        column.set_unparsed_default(None);
                        column.update(|draft| draft.default = default);
                    }
                    // No edit of the column, but the tracker has to learn
                    // of it, or a close prompt would save without it.
                    Err(error) => column.set_unparsed_default(Some(UnparsedDefault { text, error })),
                }
            }
            ColumnField::Comment(comment) => column.update(|draft| draft.comment = comment),
        }
        self.recompute_dirty_state(fx);
    }

    fn save(&self, fx: &mut StructureEffects) {
        let pending = self.pending();
        if let Err(blocker) = pending.check() {
            fx.output(StructureTabOutput::ShowToast(save_blocker_text(&blocker)));
            return;
        }
        if !pending.has_changes() {
            fx.output(StructureTabOutput::ShowToast(crate::i18n::gettext("Nothing to save.")));
            return;
        }
        let context = self.context.borrow();
        let Some(ddl) = context.ddl() else {
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
        self.sync_editable();
    }

    /// The draft holds still from the moment a save takes it until the
    /// table is read again after a commit. That read replaces the draft,
    /// so an edit made before it would be lost without a prompt.
    fn edits_locked(&self) -> bool {
        self.saving || self.refetching || self.tracker.is_saving()
    }

    fn sync_editable(&self) {
        let editable = !self.saving && !self.refetching;
        for widget in [
            self.name_row.upcast_ref::<gtk::Widget>(),
            self.columns_box.upcast_ref(),
            self.indexes_box.upcast_ref(),
            self.fks_box.upcast_ref(),
        ] {
            widget.set_sensitive(editable);
        }
    }

    /// An edit that reached the tab while its draft was locked, from a
    /// dialog opened before the save or a row the save had not turned
    /// off yet: the controls go back to what the draft holds.
    fn refuse_edit(&self, msg: &StructureTabInput, fx: &mut StructureEffects) {
        self.show_table_name();
        if let StructureTabInput::ColumnEdited { column, .. } = msg
            && let Some(position) = self.columns.find(column)
        {
            self.columns.splice(position, 1, std::slice::from_ref(column));
        }
        fx.output(StructureTabOutput::ShowToast(crate::i18n::gettext(
            "Wait for the save to finish, then make the change again.",
        )));
    }

    fn save_completed(&mut self, new_table_name: Option<String>, fx: &mut StructureEffects) {
        self.show_saving(false);
        if let Some(name) = new_table_name {
            self.context.borrow_mut().mode = StructureMode::Edit;
            self.table.name = name;
            self.show_table_name();
            self.drop_button.set_visible(true);
            self.name_row.set_visible(false);
        }
        if self.mode() != StructureMode::Edit {
            return;
        }
        // The diff against the pre-save definition would show the changes
        // just committed as still pending until the read lands, and a
        // close in that window would offer to save them again. So the
        // dirty state goes to zero now, and so does a CREATE TABLE left
        // in the preview by a draft that just became the table.
        self.tracker.clear();
        self.refresh_buttons(0, true);
        self.sql_buffer
            .set_text(&crate::i18n::gettext("-- No pending changes."));
        if self.last_dirty {
            self.last_dirty = false;
            fx.output(StructureTabOutput::DirtyChanged(false));
        }
        self.refetching = true;
        self.sync_editable();
        self.definition_shown = false;
        self.fetch_definition();
    }
}

/// Show `store` in `list`, a row for each item built by `build`. An empty
/// boxed list would still draw its frame, so the list hides while the
/// store is empty.
fn bind_list<T, W>(list: &gtk::ListBox, store: &gio::ListStore, build: impl Fn(&T) -> W + 'static)
where
    T: IsA<glib::Object>,
    W: IsA<gtk::Widget>,
{
    store
        .bind_property("n-items", list, "visible")
        .transform_to(|_, items: u32| Some(items > 0))
        .sync_create()
        .build();
    list.bind_model(Some(store), move |item| match item.downcast_ref::<T>() {
        Some(item) => build(item).upcast(),
        // The store takes only `T`.
        None => gtk::ListBoxRow::new().upcast(),
    });
}

fn items<T: IsA<glib::Object>>(store: &gio::ListStore) -> Vec<T> {
    (0..store.n_items())
        .filter_map(|position| store.item(position).and_downcast::<T>())
        .collect()
}

fn draft_columns(store: &gio::ListStore) -> Vec<DraftColumn> {
    items::<DraftColumnObject>(store)
        .iter()
        .map(DraftColumnObject::column)
        .collect()
}

fn replace_items<T: IsA<glib::Object>>(store: &gio::ListStore, items: impl IntoIterator<Item = T>) {
    let items: Vec<T> = items.into_iter().collect();
    store.splice(0, store.n_items(), &items);
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
