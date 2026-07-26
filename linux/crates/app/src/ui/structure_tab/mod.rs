//! Structure workspace tab — full schema-management UI for CREATE /
//! DROP / ALTER TABLE, indexes, and foreign keys.
//!
//! Layout (adw::ToolbarView, no internal HeaderBar — the wrapper's
//! Data/Structure HeaderBar already provides one toolbar strip):
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
//! undo / redo — the snapshot is the only restore point, exposed via
//! the Discard button. Save calls `materialize_ops` against the same
//! diff and dispatches `ExecuteTransaction` to App.

use std::cell::{Cell, RefCell};
use std::rc::Rc;

use relm4::adw::prelude::*;
use relm4::{ComponentParts, ComponentSender, SimpleComponent, adw, gtk};
use sourceview5::prelude::BufferExt;

use tablepro_core::sql_ddl::{BuildDdlError, DraftColumn};
use tablepro_core::{ColumnInfo, ForeignKeyInfo, IndexInfo};
use uuid::Uuid;

use crate::services::structure_tracker;
use crate::ui::structure_tab_dialogs::{present_fk_dialog, present_index_dialog};
use tablepro_core::sql_ddl::{StructureOp, diff_to_ops, materialize_ops};

mod columns;
mod fks;
mod indexes;

use columns::{build_column_expander_row, default_type_for};
use fks::build_fk_row;
use indexes::build_index_row;

/// Whether the Structure tab is editing an existing table or
/// drafting a brand-new one.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StructureMode {
    New,
    Edit,
}

#[derive(Debug)]
pub struct StructureTabInit {
    pub tab_id: Uuid,
    pub schema: Option<String>,
    pub table: String,
    pub mode: StructureMode,
    pub driver_id: String,
    /// When `true`, skip the auto-`FetchStructure` fired at the end of
    /// init. Used by `append_table_tab` for Data-mode opens — the
    /// Structure pane is alive but invisible, so introspection is
    /// deferred until the user actually switches to it. Without this,
    /// restoring N Table tabs from disk fires N parallel three-query
    /// introspection bursts that delay first paint and saturate the
    /// driver pool.
    pub defer_initial_fetch: bool,
}

pub struct StructureTab {
    tab_id: Uuid,
    schema: Option<String>,
    table_name: Rc<RefCell<String>>,
    mode: Rc<RefCell<StructureMode>>,
    driver_id: String,
    columns: Rc<RefCell<Vec<DraftColumn>>>,
    indexes: Rc<RefCell<Vec<IndexInfo>>>,
    foreign_keys: Rc<RefCell<Vec<ForeignKeyInfo>>>,
    /// Snapshot of the columns / indexes / FKs / table name the
    /// driver returned at load time. The "edit" surface is the diff
    /// between these and the live `columns` / `indexes` /
    /// `foreign_keys` / `table_name` fields — `materialize_ops`
    /// produces SQL by walking that diff. Discard simply copies the
    /// snapshots back over the live fields.
    original_table_name: Rc<RefCell<String>>,
    original_columns: Rc<RefCell<Vec<tablepro_core::ColumnInfo>>>,
    original_indexes: Rc<RefCell<Vec<IndexInfo>>>,
    original_fks: Rc<RefCell<Vec<ForeignKeyInfo>>>,

    // Widget refs we touch from `update`.
    inner_stack: gtk::Stack,
    /// `AdwStatusPage` shown when initial structure fetch fails.
    /// Holding a reference so `LoadFailed` can set its description
    /// to the driver error inline — replaces the previous redundant
    /// modal `ShowAlert` that double-surfaced the same text.
    error_status: adw::StatusPage,
    name_entry: adw::EntryRow,
    /// The PreferencesGroup wrapping `name_entry` — visible only in
    /// New mode. Hidden after SaveCompleted promotes the tab to Edit.
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
    /// another `borrow_mut` is still live on the stack — a
    /// `RefCell::borrow` racing it would panic.
    suppress_emit: Rc<Cell<bool>>,
    /// Monotonic counter for the "Add Column" placeholder name. Using
    /// `vec.len() + 1` produced duplicate `column_1` after the user
    /// removed a column; a forever-incrementing counter avoids the
    /// collision (validate_save rejects duplicates anyway, but the
    /// confusing UX is worse than the no-op rename the user has to
    /// do afterwards).
    next_column_seq: Rc<RefCell<usize>>,
    /// Popovers attached to column rows (currently only the type
    /// suggestions popover). Each `rebuild_columns_view` call must
    /// `popdown` and clear this list before `clear_box`, otherwise an
    /// open popover keeps a strong reference to the now-detached
    /// AdwEntryRow and a click on a suggestion `set_text`s a stale
    /// widget. The detached entry's `changed` handler then dispatches
    /// `ColumnEdited` with whatever index was captured at build time —
    /// which may now point at a different (or nonexistent) column.
    column_popovers: Rc<RefCell<Vec<gtk::Popover>>>,
    /// True between `SaveCompleted` and the matching `StructureLoaded`
    /// (or `LoadFailed`). During this window the live model has been
    /// committed to the database but `original_*` snapshots still hold
    /// the pre-save state. Diffing the live model against the stale
    /// snapshot would surface phantom pending ops — visible to the user
    /// as a spurious "Save changes?" prompt if they close the tab
    /// mid-refetch. `recompute_dirty_state` short-circuits while this
    /// flag is set; `StructureLoaded` flips it back and triggers a
    /// fresh recompute against the up-to-date snapshots.
    refetching: Rc<Cell<bool>>,
}

#[derive(Debug)]
pub enum StructureTabInput {
    StructureLoaded {
        columns: Vec<ColumnInfo>,
        indexes: Vec<IndexInfo>,
        fks: Vec<ForeignKeyInfo>,
    },
    LoadFailed(String),
    Save,
    Discard,
    DropTableRequested,
    SaveCompleted {
        new_table_name: Option<String>,
    },
    SaveFailed(String),
    /// Re-render the columns / indexes / FKs lists + SQL preview from
    /// the current model state. Fired after every UI mutation so the
    /// rendered grid matches what materialize() will produce.
    Refresh,
    /// User edited a column's field; push the matching StructureOp.
    ColumnEdited {
        index: usize,
        field: ColumnField,
    },
    /// User clicked "Add Column" — append a placeholder draft column,
    /// push AddColumn op, focus the new row's name entry.
    AddColumn,
    /// User clicked the trash icon on a column row.
    RemoveColumn(usize),
    /// User clicked "Add Index…" → AlertDialog returned with values.
    AddIndex(IndexInfo),
    RemoveIndex(usize),
    AddForeignKey(ForeignKeyInfo),
    RemoveForeignKey(usize),
    /// User edited the table-name entry.
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
}

#[derive(Debug)]
pub enum StructureTabOutput {
    DirtyChanged(bool),
    FetchStructure,
    ExecuteTransaction { statements: Vec<String> },
    DropTableRequested { schema: Option<String>, table: String },
    ShowToast(String),
    ShowAlert { title: String, body: String },
}

impl StructureTab {
    /// Compute the pending-op list from the diff between original
    /// snapshot and current model state. The single source of truth
    /// for "what will Save emit?". Pure function on the live state.
    ///
    /// New-mode short-circuits to a single `CreateTable` op (or zero
    /// ops when the column list is empty).
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

    /// Refresh action-bar state + SQL preview + emit `DirtyChanged`
    /// based on the current diff. Called after every model mutation.
    /// Also populates the per-tab tracker cache so out-of-band
    /// callers (close-with-pending, save-by-id) can read the same op
    /// list without re-deriving it from the tab's model.
    ///
    /// No-op while `refetching` is set: between `SaveCompleted` and
    /// `StructureLoaded`, `original_*` is stale, so diffing the live
    /// model would produce ops for changes that were already
    /// committed. The cache is left at whatever `SaveCompleted`
    /// cleared it to (empty); `StructureLoaded` flips the flag and
    /// runs a fresh recompute against the up-to-date snapshots.
    fn recompute_dirty_state(&self, sender: &ComponentSender<Self>) {
        if self.refetching.get() {
            return;
        }
        let ops = self.current_diff_ops();
        let count = ops.len();
        self.refresh_buttons(count);
        self.regenerate_sql_preview_from(&ops);

        let ops_for_cache = ops.clone();
        structure_tracker::with_tab(self.tab_id, |t| t.set_ops(ops_for_cache));

        let dirty = count > 0;
        let mut last = self.last_dirty.borrow_mut();
        if *last != dirty {
            *last = dirty;
            let _ = sender.output(StructureTabOutput::DirtyChanged(dirty));
        }
    }

    fn refresh_buttons(&self, pending_count: usize) {
        let has_pending = pending_count > 0;
        self.save_button.set_sensitive(has_pending);
        self.discard_button.set_sensitive(has_pending);
        if has_pending {
            let label = if pending_count == 1 {
                crate::tr!("1 pending change")
            } else {
                crate::tr!("{n} pending changes").replace("{n}", &pending_count.to_string())
            };
            self.pending_label.set_label(&label);
            self.pending_label.set_visible(true);
        } else {
            self.pending_label.set_visible(false);
        }
    }

    fn regenerate_sql_preview_from(&self, ops: &[StructureOp]) {
        let text = match materialize_ops(ops, &self.driver_id) {
            Ok(stmts) if !stmts.is_empty() => stmts.join(";\n\n") + ";",
            Ok(_) => crate::tr!("-- No pending changes."),
            Err(e) => format!("-- {e}"),
        };
        self.sql_buffer.set_text(&text);
    }

    fn rebuild_columns_view(&self, sender: ComponentSender<Self>) {
        // Tear down + rebuild. Editing happens infrequently enough
        // that rebuilding the whole layout per change is cheap.
        //
        // suppress_emit must be true while we tear down + recreate
        // the row widgets: AdwEntryRow::set_text and SwitchRow::set_active
        // for the initial values fire `changed` / `notify::active`
        // signals synchronously, and the row's connect_* callbacks
        // (registered earlier in the build) would treat those as user
        // edits — every Edit-mode reload would shift the live model
        // away from the snapshot and surface phantom pending changes.
        // We re-enable emit on the next idle tick so legitimate user
        // input afterwards flows through.
        self.suppress_emit.set(true);
        // Popdown + drop any popovers attached to the previous rows
        // before they're unparented. An open suggestions popover holds
        // the old AdwEntryRow alive via a closure clone; without this
        // step a click on a suggestion after a Refresh would `set_text`
        // a detached widget and dispatch `ColumnEdited` with a stale
        // index (see `column_popovers` doc on `StructureTab`).
        {
            let mut popovers = self.column_popovers.borrow_mut();
            for p in popovers.drain(..) {
                p.popdown();
            }
        }
        clear_box(&self.columns_box);
        let driver_id = self.driver_id.clone();

        // Native column editor: boxed-list `gtk::ListBox` of one
        // `adw::ExpanderRow` per column. Each expander's collapsed
        // header reads as a row in a Settings-style list (column
        // name + summary subtitle); expanding reveals AdwEntryRow /
        // AdwSwitchRow children for the editable attributes. Add
        // Column appears as the trailing AdwButtonRow inside the
        // same boxed-list — the GNOME pattern matching Settings's
        // "Add Network" or Builder's run-config list.
        let list = boxed_list();
        for (i, col) in self.columns.borrow().iter().enumerate() {
            list.append(&build_column_expander_row(
                i,
                col,
                &driver_id,
                sender.clone(),
                self.suppress_emit.clone(),
                self.column_popovers.clone(),
            ));
        }
        let sender_for_add = sender.clone();
        append_add_button(&list, &crate::tr!("Add Column"), move || {
            sender_for_add.input(StructureTabInput::AddColumn);
        });
        self.columns_box.append(&list);

        let suppress = self.suppress_emit.clone();
        relm4::gtk::glib::idle_add_local_once(move || {
            suppress.set(false);
        });
    }

    fn rebuild_indexes_view(&self, sender: ComponentSender<Self>) {
        clear_box(&self.indexes_box);
        let list = boxed_list();
        for (i, idx) in self.indexes.borrow().iter().enumerate() {
            list.append(&build_index_row(i, idx, sender.clone()));
        }
        let columns_for_dialog = self.columns.clone();
        let sender_for_add = sender.clone();
        let parent_box = self.indexes_box.clone();
        append_add_button(&list, &crate::tr!("Add Index…"), move || {
            present_index_dialog(
                parent_box.upcast_ref(),
                &columns_for_dialog.borrow(),
                sender_for_add.clone(),
            );
        });
        self.indexes_box.append(&list);
    }

    fn rebuild_fks_view(&self, sender: ComponentSender<Self>) {
        clear_box(&self.fks_box);
        let driver_id = self.driver_id.clone();
        let list = boxed_list();
        for (i, fk) in self.foreign_keys.borrow().iter().enumerate() {
            list.append(&build_fk_row(i, fk, &driver_id, sender.clone()));
        }
        let columns_for_dialog = self.columns.clone();
        let sender_for_add = sender.clone();
        let parent_box = self.fks_box.clone();
        let driver_id_for_dialog = driver_id.clone();
        append_add_button(&list, &crate::tr!("Add Foreign Key…"), move || {
            present_fk_dialog(
                parent_box.upcast_ref(),
                &columns_for_dialog.borrow(),
                &driver_id_for_dialog,
                sender_for_add.clone(),
            );
        });
        self.fks_box.append(&list);
    }
}

/// Build a `gtk::ListBox` with the `.boxed-list` HIG style class. Used
/// for the columns / indexes / FKs sections of the Structure tab so
/// rows pick up the standard Adwaita rounded-corner + row-separator
/// treatment used in GNOME Settings, Files, etc.
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

/// Append a trailing `adw::ButtonRow` to a boxed-list — the GNOME
/// pattern for "Add another item" rows in Settings / Builder. The
/// caller's closure runs on activation; what it dispatches (a model
/// mutation for Add Column, a dialog launcher for Add Index / Add
/// Foreign Key) is the only thing that varies between the columns,
/// indexes, and FKs views.
fn append_add_button(list: &gtk::ListBox, label: &str, on_activate: impl Fn() + 'static) {
    let row = adw::ButtonRow::builder()
        .title(label)
        .start_icon_name("list-add-symbolic")
        .build();
    row.connect_activated(move |_| on_activate());
    list.append(&row);
}

/// Validate the model against driver constraints before Save. Returns
/// the first user-visible error string, or None if all checks pass.
fn validate_save(table_name: &str, columns: &[DraftColumn], mode: StructureMode) -> Result<(), String> {
    if matches!(mode, StructureMode::New) && table_name.trim().is_empty() {
        return Err(crate::tr!("Table name is required."));
    }
    // Empty-columns guard applies in BOTH modes. In Edit mode, the
    // user pressing the trash on every row would otherwise produce
    // a Save that drops every column — most drivers either reject
    // this with an opaque error or silently degenerate the table.
    if columns.is_empty() {
        return Err(crate::tr!("At least one column is required."));
    }
    let mut seen: std::collections::HashSet<&str> = std::collections::HashSet::new();
    for col in columns {
        if col.name.trim().is_empty() {
            return Err(crate::tr!("Every column needs a name."));
        }
        if !seen.insert(col.name.as_str()) {
            return Err(crate::tr!("Duplicate column name: {name}").replace("{name}", &col.name));
        }
        if col.data_type.trim().is_empty() {
            return Err(crate::tr!("Column {name} needs a type.").replace("{name}", &col.name));
        }
        if col.primary_key && col.nullable {
            return Err(crate::tr!("Primary key columns must be NOT NULL: {name}").replace("{name}", &col.name));
        }
    }
    Ok(())
}

impl SimpleComponent for StructureTab {
    type Init = StructureTabInit;
    type Input = StructureTabInput;
    type Output = StructureTabOutput;
    type Root = adw::ToolbarView;
    type Widgets = ();

    fn init_root() -> Self::Root {
        adw::ToolbarView::new()
    }

    fn init(init: Self::Init, root: Self::Root, sender: ComponentSender<Self>) -> ComponentParts<Self> {
        structure_tracker::open_tab(init.tab_id);

        let view_stack = adw::ViewStack::new();

        let columns_box = gtk::Box::builder()
            .orientation(gtk::Orientation::Vertical)
            .spacing(0)
            .build();
        let columns_scroll = gtk::ScrolledWindow::builder().child(&columns_box).vexpand(true).build();
        let columns_page = view_stack.add_titled_with_icon(
            &columns_scroll,
            Some("columns"),
            &crate::tr!("Columns"),
            "view-list-symbolic",
        );
        let _ = columns_page;

        let indexes_box = gtk::Box::builder()
            .orientation(gtk::Orientation::Vertical)
            .spacing(0)
            .build();
        let indexes_scroll = gtk::ScrolledWindow::builder().child(&indexes_box).vexpand(true).build();
        let indexes_page = view_stack.add_titled_with_icon(
            &indexes_scroll,
            Some("indexes"),
            &crate::tr!("Indexes"),
            "view-sort-ascending-symbolic",
        );
        let _ = indexes_page;

        let fks_box = gtk::Box::builder()
            .orientation(gtk::Orientation::Vertical)
            .spacing(0)
            .build();
        let fks_scroll = gtk::ScrolledWindow::builder().child(&fks_box).vexpand(true).build();
        let fks_page = view_stack.add_titled_with_icon(
            &fks_scroll,
            Some("fks"),
            &crate::tr!("Foreign Keys"),
            "emblem-shared-symbolic",
        );
        let _ = fks_page;

        // SQL preview page — sourceview5 read-only with sql highlighting.
        let lang_manager = sourceview5::LanguageManager::default();
        let sql_buffer = if let Some(lang) = lang_manager.language("sql") {
            sourceview5::Buffer::with_language(&lang)
        } else {
            sourceview5::Buffer::new(None)
        };
        let sql_view = sourceview5::View::with_buffer(&sql_buffer);
        sql_view.set_editable(false);
        sql_view.set_monospace(true);
        sql_view.set_wrap_mode(gtk::WrapMode::Word);
        sql_view.set_top_margin(6);
        sql_view.set_left_margin(6);
        sql_view.set_right_margin(6);
        sql_view.set_bottom_margin(6);
        // Match the system light / dark scheme. Mirrors the editor.rs
        // hook so the SQL preview's syntax colours track the user's
        // theme choice instead of staying frozen on the boot scheme.
        apply_sql_scheme(&sql_buffer);
        let buffer_for_theme = sql_buffer.clone();
        adw::StyleManager::default().connect_dark_notify(move |_| {
            apply_sql_scheme(&buffer_for_theme);
        });
        let sql_scroll = gtk::ScrolledWindow::builder().child(&sql_view).vexpand(true).build();
        // Copy SQL toolbar — saves the user from clicking into the
        // sourceview, Ctrl+A, Ctrl+C every time they want to paste
        // the generated DDL into a different tool.
        let copy_sql_btn = gtk::Button::builder()
            .icon_name("edit-copy-symbolic")
            .tooltip_text(crate::tr!("Copy SQL to clipboard"))
            .valign(gtk::Align::Center)
            .build();
        copy_sql_btn.add_css_class("flat");
        let buffer_for_copy = sql_buffer.clone();
        copy_sql_btn.connect_clicked(move |btn| {
            let text = buffer_for_copy.text(&buffer_for_copy.start_iter(), &buffer_for_copy.end_iter(), false);
            btn.clipboard().set_text(text.as_str());
        });
        // CenterBox is the native idiom for "leading / centred /
        // trailing" toolbar layouts. The earlier hexpand label-spacer
        // worked but was a CSS-flexbox-era pattern that fights GTK's
        // layout system.
        let sql_toolbar = gtk::CenterBox::builder()
            .margin_top(6)
            .margin_start(6)
            .margin_end(6)
            .build();
        sql_toolbar.set_end_widget(Some(&copy_sql_btn));
        let sql_page_box = gtk::Box::builder().orientation(gtk::Orientation::Vertical).build();
        sql_page_box.append(&sql_toolbar);
        sql_page_box.append(&sql_scroll);
        let sql_page = view_stack.add_titled_with_icon(
            &sql_page_box,
            Some("sql"),
            &crate::tr!("SQL Preview"),
            "text-x-generic-symbolic",
        );
        let _ = sql_page;

        // Inline switcher centred above the form. We can't add a
        // second AdwHeaderBar to the tab — the wrapper's "Data /
        // Structure" header already takes that role. A centred
        // ViewSwitcher with margins reads as a section navigation
        // without spawning a second toolbar strip.
        let view_switcher = adw::ViewSwitcher::builder()
            .stack(&view_stack)
            .policy(adw::ViewSwitcherPolicy::Wide)
            .halign(gtk::Align::Center)
            .margin_top(6)
            .margin_bottom(6)
            .build();

        // Inner stack swaps between "loading" / "editor" / "error" so
        // Edit-mode tabs show a spinner until fetch_structure_data
        // resolves.
        let inner_stack = gtk::Stack::new();
        inner_stack.set_transition_type(gtk::StackTransitionType::Crossfade);

        // AdwSpinner (libadwaita 1.6+) is the native animated spinner
        // — pulses while the introspection round-trip is in flight.
        // The earlier `emblem-synchronizing-symbolic` rendered as a
        // static sync icon that read as "this could be idle". A
        // centred vertical box with spinner + title + dim subtitle
        // is the same pattern GNOME Software / Console use for
        // in-flight load states.
        let loading_spinner = adw::Spinner::builder().width_request(48).height_request(48).build();
        let loading_title = gtk::Label::builder().label(crate::tr!("Loading structure…")).build();
        loading_title.add_css_class("title-2");
        let loading_subtitle = gtk::Label::builder()
            .label(crate::tr!("Reading columns, indexes, and foreign keys…"))
            .build();
        loading_subtitle.add_css_class("dim-label");
        let loading_box = gtk::Box::builder()
            .orientation(gtk::Orientation::Vertical)
            .spacing(12)
            .halign(gtk::Align::Center)
            .valign(gtk::Align::Center)
            .vexpand(true)
            .build();
        loading_box.append(&loading_spinner);
        loading_box.append(&loading_title);
        loading_box.append(&loading_subtitle);
        inner_stack.add_named(&loading_box, Some("loading"));

        let editor_box = gtk::Box::builder()
            .orientation(gtk::Orientation::Vertical)
            .spacing(0)
            .build();
        // New-mode only: name row at the top of the editor. Edit mode
        // hides this — the tab title already shows the name and rename
        // is a separate (sidebar context-menu) action that we don't
        // want users triggering accidentally by clicking a floating
        // text field. The name_entry widget itself is still built and
        // stored in the model so update()'s SaveCompleted path can
        // `set_text` it when New mode promotes to Edit.
        //
        // Native pattern: a single AdwEntryRow with title "Name". The
        // title floats large when empty (acts as the placeholder) and
        // shrinks to a small label above the typed value — matching
        // GNOME Settings's text input pattern. The PreferencesGroup
        // around it carries only the helper description; no redundant
        // "New table" title since the tab title already says so.
        let name_entry = adw::EntryRow::builder().title(crate::tr!("Name")).build();
        name_entry.set_text(&init.table);
        let name_row = adw::PreferencesGroup::builder()
            .description(crate::tr!("Add a name and at least one column to save."))
            .margin_top(12)
            .margin_bottom(6)
            .margin_start(12)
            .margin_end(12)
            .build();
        name_row.add(&name_entry);
        name_row.set_visible(matches!(init.mode, StructureMode::New));
        editor_box.append(&name_row);
        editor_box.append(&view_switcher);
        editor_box.append(&view_stack);
        // Constrain content width on wide windows so forms don't
        // stretch to ridiculous proportions (without this a single
        // "Add Column" row spans the entire monitor on a wide screen).
        // AdwClamp matches the GNOME Settings / Builder pattern;
        // 900sp gives room for the column-row attributes (Name, Type,
        // Default…) without overflowing on small screens. No outer
        // ScrolledWindow because each view in `view_stack` already has
        // its own scroller — wrapping again would double-scroll.
        let editor_clamp = adw::Clamp::builder()
            .maximum_size(900)
            .tightening_threshold(700)
            .child(&editor_box)
            .build();
        inner_stack.add_named(&editor_clamp, Some("editor"));

        let error_status = adw::StatusPage::builder()
            .icon_name("dialog-error-symbolic")
            .title(crate::tr!("Couldn't load structure"))
            .build();
        // "Try again" — fires another FetchStructure round-trip via
        // the existing output channel. Without this, a transient
        // network blip on a remote DB forces the user to close and
        // reopen the tab. Suggested-action + pill styling matches
        // GNOME Software's "Try Again" affordance on its own
        // load-failure page.
        let retry_button = gtk::Button::builder()
            .label(crate::tr!("Try Again"))
            .halign(gtk::Align::Center)
            .build();
        retry_button.add_css_class("suggested-action");
        retry_button.add_css_class("pill");
        let sender_for_retry = sender.clone();
        let inner_stack_for_retry = inner_stack.clone();
        retry_button.connect_clicked(move |_| {
            // Flip back to the loading page so the user sees we're
            // trying — otherwise the click looks like a no-op until
            // StructureLoaded arrives.
            inner_stack_for_retry.set_visible_child_name("loading");
            let _ = sender_for_retry.output(StructureTabOutput::FetchStructure);
        });
        error_status.set_child(Some(&retry_button));
        inner_stack.add_named(&error_status, Some("error"));

        inner_stack.set_visible_child_name(match init.mode {
            StructureMode::New => "editor",
            StructureMode::Edit => "loading",
        });

        // Bottom action bar.
        let action_bar = gtk::ActionBar::new();
        let pending_label = gtk::Label::builder().build();
        pending_label.add_css_class("dim-label");
        pending_label.set_visible(false);
        action_bar.pack_start(&pending_label);

        let discard_button = gtk::Button::builder()
            .label(crate::tr!("Discard"))
            .sensitive(false)
            .build();
        let save_button = gtk::Button::builder()
            .label(crate::tr!("Save"))
            .sensitive(false)
            .build();
        save_button.add_css_class("suggested-action");
        let drop_button = gtk::Button::builder()
            .label(crate::tr!("Drop Table…"))
            .visible(matches!(init.mode, StructureMode::Edit))
            .build();
        drop_button.add_css_class("destructive-action");
        // Drop sits at the start of the action bar, spatially
        // separated from the Discard / Save pair on the end. Mixing
        // a destructive action with the primary action invites
        // misclicks; HIG groups them by intent.
        action_bar.pack_start(&drop_button);
        action_bar.pack_end(&save_button);
        action_bar.pack_end(&discard_button);

        let sender_for_save = sender.clone();
        save_button.connect_clicked(move |_| sender_for_save.input(StructureTabInput::Save));
        let sender_for_discard = sender.clone();
        discard_button.connect_clicked(move |_| sender_for_discard.input(StructureTabInput::Discard));
        let sender_for_drop = sender.clone();
        drop_button.connect_clicked(move |_| sender_for_drop.input(StructureTabInput::DropTableRequested));

        // Content + bottom bar. The Data/Structure outer header
        // already supplies the toolbar strip — Structure's own
        // sub-navigation lives inline inside `editor_box`.
        root.set_content(Some(&inner_stack));
        root.add_bottom_bar(&action_bar);

        // Wire the table-name entry to push RenameTable / propagate to
        // the model.
        let suppress_emit = Rc::new(Cell::new(false));
        let sender_for_name = sender.clone();
        let suppress_for_name = suppress_emit.clone();
        name_entry.connect_changed(move |e| {
            if suppress_for_name.get() {
                return;
            }
            sender_for_name.input(StructureTabInput::TableNameEdited(e.text().to_string()));
        });

        // No tracker subscription — dirty state is computed from the
        // diff between snapshot + current model on every mutation.

        // Edit mode: kick the App for fetch_structure_data — unless
        // the parent (Table tab in Data mode) explicitly deferred us
        // to avoid an N-tabs-N-bursts startup stampede.
        if matches!(init.mode, StructureMode::Edit) && !init.defer_initial_fetch {
            let _ = sender.output(StructureTabOutput::FetchStructure);
        }

        let model = StructureTab {
            tab_id: init.tab_id,
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
            inner_stack,
            error_status: error_status.clone(),
            name_entry,
            name_row,
            columns_box,
            indexes_box,
            fks_box,
            sql_buffer,
            pending_label,
            save_button,
            discard_button,
            drop_button,
            last_dirty: Rc::new(RefCell::new(false)),
            suppress_emit,
            next_column_seq: Rc::new(RefCell::new(1)),
            column_popovers: Rc::new(RefCell::new(Vec::new())),
            refetching: Rc::new(Cell::new(false)),
        };

        // Initial render so New-mode tabs aren't blank.
        sender.input(StructureTabInput::Refresh);

        ComponentParts { model, widgets: () }
    }

    fn update(&mut self, msg: Self::Input, sender: ComponentSender<Self>) {
        match msg {
            StructureTabInput::StructureLoaded { columns, indexes, fks } => {
                // App coalesces the three fetches into one message.
                // Snapshot all three lists into `original_*` slots so
                // Discard restores the canonical loaded state without
                // a refetch — including columns the user later removed
                // (whose `DraftColumn.original` would otherwise vanish
                // when the row is dropped from `self.columns`).
                *self.original_columns.borrow_mut() = columns.clone();
                *self.columns.borrow_mut() = columns.into_iter().map(DraftColumn::from_info).collect();
                *self.indexes.borrow_mut() = indexes.clone();
                *self.original_indexes.borrow_mut() = indexes;
                *self.foreign_keys.borrow_mut() = fks.clone();
                *self.original_fks.borrow_mut() = fks;
                self.inner_stack.set_visible_child_name("editor");
                // End of refetch window: snapshots are now authoritative,
                // so resume diff-based dirty tracking. The recompute call
                // sees live model == snapshots and clears the tracker /
                // emits DirtyChanged(false), which discards any phantom
                // ops the user could have provoked during the window.
                self.refetching.set(false);
                self.recompute_dirty_state(&sender);
                sender.input(StructureTabInput::Refresh);
            }
            StructureTabInput::LoadFailed(message) => {
                // Surface the driver error inline on the StatusPage —
                // a modal AdwAlertDialog would duplicate the same
                // text and force the user to dismiss it before they
                // can see the page.
                self.error_status.set_description(Some(&message));
                self.inner_stack.set_visible_child_name("error");
                // Bail out of the refetch window even on failure so
                // recompute_dirty_state doesn't stay frozen if the user
                // later retries via the error page's reload action.
                self.refetching.set(false);
            }
            StructureTabInput::Refresh => {
                self.rebuild_columns_view(sender.clone());
                self.rebuild_indexes_view(sender.clone());
                self.rebuild_fks_view(sender.clone());
                self.regenerate_sql_preview_from(&self.current_diff_ops());
            }
            StructureTabInput::TableNameEdited(text) => {
                let prev = self.table_name.borrow().clone();
                if prev == text {
                    return;
                }
                *self.table_name.borrow_mut() = text;
                self.recompute_dirty_state(&sender);
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
                        // Auto-increment requires PK in every supported
                        // driver (MySQL rejects, Postgres SERIAL implies
                        // PK). When PK toggles off, the bound `sensitive`
                        // greys out the Auto checkbox visually but its
                        // `active` stays true — the model would then
                        // emit AUTO_INCREMENT in an invalid context.
                        // Coerce off here so model + tracker stay in
                        // sync with what the driver will accept.
                        if !b {
                            col.auto_increment = false;
                        }
                    }
                    ColumnField::AutoIncrement(b) => col.auto_increment = b,
                    ColumnField::Default(s) => col.default_value = s,
                }
                let new_col = col.clone();
                drop(cols);
                // Echo guard — connect_changed / connect_toggled fire
                // on programmatic widget set during rebuild, with the
                // value already matching the model. Skipping the
                // recompute saves a no-op diff pass.
                if prev == new_col {
                    return;
                }
                self.recompute_dirty_state(&sender);
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
                };
                self.columns.borrow_mut().push(new_col);
                self.recompute_dirty_state(&sender);
                sender.input(StructureTabInput::Refresh);
            }
            StructureTabInput::RemoveColumn(index) => {
                {
                    let mut cols = self.columns.borrow_mut();
                    if index >= cols.len() {
                        return;
                    }
                    cols.remove(index);
                }
                self.recompute_dirty_state(&sender);
                sender.input(StructureTabInput::Refresh);
            }
            StructureTabInput::AddIndex(index) => {
                self.indexes.borrow_mut().push(index);
                self.recompute_dirty_state(&sender);
                sender.input(StructureTabInput::Refresh);
            }
            StructureTabInput::RemoveIndex(idx_pos) => {
                {
                    let mut idxs = self.indexes.borrow_mut();
                    if idx_pos >= idxs.len() {
                        return;
                    }
                    idxs.remove(idx_pos);
                }
                self.recompute_dirty_state(&sender);
                sender.input(StructureTabInput::Refresh);
            }
            StructureTabInput::AddForeignKey(fk) => {
                self.foreign_keys.borrow_mut().push(fk);
                self.recompute_dirty_state(&sender);
                sender.input(StructureTabInput::Refresh);
            }
            StructureTabInput::RemoveForeignKey(idx_pos) => {
                {
                    let mut fks = self.foreign_keys.borrow_mut();
                    if idx_pos >= fks.len() {
                        return;
                    }
                    fks.remove(idx_pos);
                }
                self.recompute_dirty_state(&sender);
                sender.input(StructureTabInput::Refresh);
            }
            StructureTabInput::Save => {
                let table = self.table_name.borrow().clone();
                let mode = *self.mode.borrow();
                let columns = self.columns.borrow().clone();
                if let Err(message) = validate_save(&table, &columns, mode) {
                    let _ = sender.output(StructureTabOutput::ShowToast(message));
                    return;
                }
                let ops = self.current_diff_ops();
                match materialize_ops(&ops, &self.driver_id) {
                    Ok(statements) if !statements.is_empty() => {
                        self.save_button.set_sensitive(false);
                        self.discard_button.set_sensitive(false);
                        let _ = sender.output(StructureTabOutput::ExecuteTransaction { statements });
                    }
                    Ok(_) => {
                        let _ = sender.output(StructureTabOutput::ShowToast(crate::tr!("Nothing to save.")));
                    }
                    Err(BuildDdlError::SqliteNotSupported(detail)) => {
                        let _ = sender.output(StructureTabOutput::ShowAlert {
                            title: crate::tr!("Cannot save"),
                            body: crate::tr!("SQLite doesn't support: {detail}").replace("{detail}", detail),
                        });
                    }
                    Err(e) => {
                        let _ = sender.output(StructureTabOutput::ShowAlert {
                            title: crate::tr!("Cannot save"),
                            body: format!("{e}"),
                        });
                    }
                }
            }
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
                        .map(DraftColumn::from_info)
                        .collect();
                    *self.indexes.borrow_mut() = self.original_indexes.borrow().clone();
                    *self.foreign_keys.borrow_mut() = self.original_fks.borrow().clone();
                }
                self.recompute_dirty_state(&sender);
                sender.input(StructureTabInput::Refresh);
            }
            StructureTabInput::DropTableRequested => {
                let _ = sender.output(StructureTabOutput::DropTableRequested {
                    schema: self.schema.clone(),
                    table: self.table_name.borrow().clone(),
                });
            }
            StructureTabInput::SaveCompleted { new_table_name } => {
                if let Some(name) = new_table_name {
                    *self.mode.borrow_mut() = StructureMode::Edit;
                    *self.table_name.borrow_mut() = name.clone();
                    *self.original_table_name.borrow_mut() = name.clone();
                    self.name_entry.set_text(&name);
                    self.drop_button.set_visible(true);
                    self.name_row.set_visible(false);
                }
                if matches!(*self.mode.borrow(), StructureMode::Edit) {
                    // Eagerly zero the dirty state before the async refetch
                    // round-trip. Without this, recompute_dirty_state would
                    // diff the live model against the pre-save snapshot for
                    // the entire FetchStructure window, producing phantom
                    // pending ops for changes that were just committed —
                    // and the close-with-pending dialog would surface them
                    // if the user closed the tab during the refetch. The
                    // SQL preview is also reset to "no pending changes" so
                    // a New→Edit promotion doesn't leave a stale CREATE
                    // TABLE statement visible in the preview pane until
                    // StructureLoaded arrives.
                    structure_tracker::with_tab(self.tab_id, |t| t.clear());
                    self.refresh_buttons(0);
                    self.regenerate_sql_preview_from(&[]);
                    let mut last = self.last_dirty.borrow_mut();
                    if *last {
                        *last = false;
                        let _ = sender.output(StructureTabOutput::DirtyChanged(false));
                    }
                    drop(last);
                    self.refetching.set(true);
                    let _ = sender.output(StructureTabOutput::FetchStructure);
                }
            }
            StructureTabInput::SaveFailed(message) => {
                self.recompute_dirty_state(&sender);
                let _ = sender.output(StructureTabOutput::ShowAlert {
                    title: crate::tr!("Save failed"),
                    body: message,
                });
            }
        }
    }
}

/// Pick the sourceview5 style scheme matching the active Adwaita
/// light / dark mode. Called on init and on `connect_dark_notify`
/// so the SQL preview tracks system theme switches.
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
