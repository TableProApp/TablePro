//! The Structure workspace tab: CREATE, DROP and ALTER TABLE, indexes
//! and foreign keys.
//!
//! Layout (adw::ToolbarView, no internal HeaderBar):
//!
//!   ┌─ Content ────────────────────────────────────────────────┐
//!   │   (New mode) AdwPreferencesGroup { name entry }          │
//!   │   Centred AdwViewSwitcher: Columns | Indexes | FKs |     │
//!   │                            Options | SQL                 │
//!   │ ┌─ ViewStack ─────────────────────────────────────────┐  │
//!   │ │ Columns: boxed-list of AdwExpanderRow (per column,  │  │
//!   │ │   header = Name + summary, body = Name/Type/Charset/│  │
//!   │ │   Collation/Null/Default/PK/AutoInc rows), then an  │  │
//!   │ │   Add Column row                                    │  │
//!   │ │ Indexes: boxed-list (Name, Cols, Unique, trash)     │  │
//!   │ │ FKs: boxed-list (Name, Cols, Refs, RefCols, trash)  │  │
//!   │ │ Options (where the engine has them): Character Set, │  │
//!   │ │   Collation, Convert, Next Auto Increment           │  │
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
//! failed. The server's character sets are a read of their own after
//! it, and a tab whose read of them failed edits everything else. A
//! change to the table from elsewhere reads the definition again too,
//! unless the draft has edits: then Discard reads it, and a plan that
//! writes the table again from the old definition refuses to save. A
//! read that fails with a definition on screen leaves it there under a
//! banner with Retry.
//!
//! An input belongs to the group of state it changes, and each group is
//! handled in its own `*_handlers` module.

mod character_set_choices;
mod character_set_fetch;
mod column_handlers;
mod columns;
mod columns_input;
mod context;
mod draft_column_object;
mod draft_column_object_imp;
mod fks;
mod foreign_key_dialog;
mod foreign_key_draft;
mod foreign_key_handlers;
mod foreign_key_object;
mod foreign_keys_input;
mod form_dialog;
mod imp;
mod index_dialog;
mod index_draft;
mod index_handlers;
mod index_object;
mod indexes;
mod indexes_input;
mod layout;
mod load_handlers;
mod load_input;
mod referential_action_label;
pub(crate) mod review_dialog;
mod save_gate;
mod save_handlers;
mod save_input;
mod sql_preview;
mod structure_actions;
mod structure_command;
mod structure_fetch;
mod structure_tab_input;
mod structure_tab_widgets;
mod table_choice_object;
mod table_handlers;
mod table_input;
mod table_options;
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
use tablepro_core::ddl::{DraftColumn, DraftTableOptions, TableChanges, TableDraft, diff_table};
use tablepro_core::meta::TableRef;
use tablepro_session::runtime::{Tasks, WatchForwarder};
use tablepro_session::{LinkGeneration, Session};

pub(crate) use self::columns_input::{ColumnField, ColumnsInput};
use self::context::{CharacterSets, StructureContext};
use self::draft_column_object::DraftColumnObject;
use self::foreign_key_object::ForeignKeyObject;
pub(crate) use self::foreign_keys_input::ForeignKeysInput;
use self::index_object::IndexObject;
pub(crate) use self::indexes_input::IndexesInput;
pub(crate) use self::load_input::LoadInput;
pub(crate) use self::save_input::SaveInput;
pub(crate) use self::structure_command::{LoadedStructure, StructureCommand, StructureRequestKind};
pub(crate) use self::structure_tab_input::StructureTabInput;
use self::structure_tab_widgets::StructureTabWidgets;
pub(crate) use self::table_input::TableInput;
use self::table_options::NextAutoIncrement;
use crate::runtime::{FailedRequests, RequestSequencer};
use crate::services::pending_structure::PendingStructure;
use crate::services::structure_tracker_handle::StructureTrackerHandle;
use crate::ui::tab_load::{ContentLoad, FirstLoad, start_first_load};

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
    pub first_load: FirstLoad,
}

/// Holds the tab weakly, so a row's or a dialog's closure never keeps a
/// closed tab alive.
#[derive(Clone)]
pub(crate) struct StructureTabSender {
    tab: glib::WeakRef<StructureTab>,
}

impl StructureTabSender {
    pub(crate) fn input(&self, msg: impl Into<StructureTabInput>) {
        if let Some(tab) = self.tab.upgrade() {
            tab.send(msg);
        }
    }

    fn tab(&self) -> Option<StructureTab> {
        self.tab.upgrade()
    }
}

impl StructureTab {
    pub fn new(init: StructureTabInit) -> Self {
        let tab: Self = glib::Object::new();
        let imp = tab.imp();
        let read_only = init.session.read_only();
        let context = Rc::new(RefCell::new(StructureContext {
            mode: init.mode,
            dialect: match init.mode {
                // A draft has no table to read the dialect back with.
                StructureMode::New => init.session.current_dialect(),
                StructureMode::Edit => None,
            },
            definition: None,
            character_sets: CharacterSets::Unread,
        }));
        let columns = gio::ListStore::new::<DraftColumnObject>();
        let indexes = gio::ListStore::new::<IndexObject>();
        let foreign_keys = gio::ListStore::new::<ForeignKeyObject>();
        let widgets = layout::build(
            &tab,
            layout::LayoutInit {
                table: &init.table,
                schema: init.schema.clone(),
                mode: init.mode,
                read_only,
                session: &init.session,
                tasks: &init.tasks,
            },
            &context,
            &layout::DraftStores {
                columns: &columns,
                indexes: &indexes,
                foreign_keys: &foreign_keys,
            },
        );
        tab.install_actions();

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
            options: None,
            next_auto_increment: NextAutoIncrement::default(),
            read_only,
            saving: false,
            last_dirty: false,
            refetching: false,
            load: match init.mode {
                // A new table's draft is the content from the start.
                StructureMode::New => ContentLoad::Loaded,
                StructureMode::Edit => ContentLoad::default(),
            },
            tab_loading: false,
            definition_stale: false,
            widgets,
        };
        imp.model.replace(Some(model));
        imp.link_watch.replace(Some(WatchForwarder::new(
            link_changes,
            {
                let tab = tab.downgrade();
                move |generation: LinkGeneration| {
                    if let Some(tab) = tab.upgrade() {
                        tab.send(LoadInput::LinkChanged(generation));
                    }
                }
            },
            |future| {
                glib::spawn_future_local(future);
            },
        )));
        start_first_load(&tab, init.first_load, {
            let tab = tab.downgrade();
            move || {
                if let Some(tab) = tab.upgrade() {
                    tab.send(LoadInput::Start);
                }
            }
        });
        tab
    }

    pub(crate) fn sender(&self) -> StructureTabSender {
        StructureTabSender { tab: self.downgrade() }
    }

    /// Hand the tab an input. One that arrives while another is being
    /// handled, from a widget signal the handler set off, waits for it
    /// to finish rather than running inside it.
    pub(crate) fn send(&self, msg: impl Into<StructureTabInput>) {
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

    pub fn connect_open_in_editor<F: Fn(&Self, String) + 'static>(&self, f: F) -> glib::SignalHandlerId {
        self.connect_closure(
            "open-in-editor",
            false,
            glib::closure_local!(move |tab: &Self, sql: String| f(tab, sql)),
        )
    }

    /// A read of the table's definition started or ended.
    pub fn connect_loading_changed<F: Fn(&Self, bool) + 'static>(&self, f: F) -> glib::SignalHandlerId {
        self.connect_closure(
            "loading-changed",
            false,
            glib::closure_local!(move |tab: &Self, loading: bool| f(tab, loading)),
        )
    }

    /// A read of the table's definition is running.
    pub fn is_loading(&self) -> bool {
        self.imp()
            .model
            .try_borrow()
            .ok()
            .and_then(|model| model.as_ref().map(|model| model.tab_loading))
            .unwrap_or(false)
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
            StructureTabOutput::LoadingChanged(loading) => self.emit_by_name::<()>("loading-changed", &[&loading]),
            StructureTabOutput::OpenInEditor(sql) => self.emit_by_name::<()>("open-in-editor", &[&sql]),
        }
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

    fn input(&mut self, input: impl Into<StructureTabInput>) {
        self.inputs.push_back(input.into());
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
    /// The draft's own options, on an engine whose tables have them.
    options: Option<DraftTableOptions>,
    next_auto_increment: NextAutoIncrement,
    /// The connection refuses writes, so Drop is not offered.
    read_only: bool,
    /// A save of the tab is running, so Save and Discard stay off.
    saving: bool,

    last_dirty: bool,
    /// True between `SaveCompleted` and the read that follows. The draft
    /// is already committed while the definition still holds the
    /// pre-save state, so diffing them would surface phantom pending
    /// changes; `recompute_dirty_state` waits it out.
    refetching: bool,
    /// Where the read of the definition stands. A failed read with a
    /// definition on screen leaves it there under the banner.
    load: ContentLoad,
    /// What the tab bar was last told, so it hears only changes.
    tab_loading: bool,
    /// The table changed after `definition` was read, while the draft
    /// had edits that a read would replace. Discard reads it again
    /// rather than restoring it.
    definition_stale: bool,
    widgets: StructureTabWidgets,
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
    /// A read of the definition started or ended, for the tab bar.
    LoadingChanged(bool),
    OpenInEditor(String),
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
            options: self.options.clone(),
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
            invalid_auto_increment: self.next_auto_increment.error.is_some(),
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
        self.sync_next_auto_increment();
        let pending = self.pending();
        let dirty = pending.has_changes();
        self.refresh_buttons(pending.change_count(), pending.typed_values_hold());
        self.regenerate_sql_preview(&pending);
        self.tracker.set_pending(Some(pending));
        if self.last_dirty != dirty {
            self.last_dirty = dirty;
            fx.output(StructureTabOutput::DirtyChanged(dirty));
        }
    }

    fn regenerate_sql_preview(&self, pending: &PendingStructure) {
        let text = sql_preview::preview_text(&self.context.borrow(), pending);
        self.widgets.sql_buffer.set_text(&text);
    }

    /// The Add rows the engine allows on the table as it stands.
    fn sync_add_rows(&self) {
        let context = self.context.borrow();
        self.widgets.add_column_row.set_visible(context.can_add_column());
        self.widgets.add_index_row.set_visible(context.can_add_index());
        self.widgets.add_fk_row.set_visible(context.can_add_foreign_key());
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
        self.next_auto_increment = NextAutoIncrement::showing(draft.options.as_ref());
        self.options = draft.options;
        self.show_table_options();
    }

    /// The lists build every row again, keeping the items, for rows
    /// whose controls depend on a context that changed.
    fn rebuild_rows(&self) {
        replace_items(&self.columns, items::<DraftColumnObject>(&self.columns));
        replace_items(&self.indexes, items::<IndexObject>(&self.indexes));
        replace_items(&self.foreign_keys, items::<ForeignKeyObject>(&self.foreign_keys));
    }

    fn update(&mut self, msg: StructureTabInput, fx: &mut StructureEffects) {
        if msg.edits_draft() && self.edits_locked() {
            self.refuse_edit(&msg, fx);
            return;
        }
        match msg {
            StructureTabInput::Load(input) => self.on_load(input, fx),
            StructureTabInput::Columns(input) => self.on_columns(input, fx),
            StructureTabInput::Indexes(input) => self.on_indexes(input, fx),
            StructureTabInput::ForeignKeys(input) => self.on_foreign_keys(input, fx),
            StructureTabInput::Table(input) => self.on_table(input, fx),
            StructureTabInput::Save(input) => self.on_save(input, fx),
        }
    }
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
