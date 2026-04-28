//! Structure workspace tab — full schema-management UI for CREATE /
//! DROP / ALTER TABLE, indexes, and foreign keys.
//!
//! Layout (adw::ToolbarView):
//!
//!   ┌─ HeaderBar { Entry(table name), DropDown(schema) } ──────┐
//!   ├─ ViewSwitcher: Columns | Indexes | FKs | SQL Preview ────┤
//!   │ ┌─ ViewStack ─────────────────────────────────────────┐  │
//!   │ │ Columns: ColumnView (Name, Type, Null, Default,     │  │
//!   │ │   PK, Auto, ✕) + "Add Column" button                │  │
//!   │ │ Indexes: ColumnView (Name, Cols, Unique, ✕)         │  │
//!   │ │ FKs: ColumnView (Name, Cols, Refs, RefCols, ✕)      │  │
//!   │ │ SQL Preview: SourceView5 (read-only, sql highlight) │  │
//!   │ └─────────────────────────────────────────────────────┘  │
//!   ├─ ActionBar { pending count | Discard | Save | Drop } ────┤
//!   └──────────────────────────────────────────────────────────┘
//!
//! Editing flow: every cell mutation pushes a `StructureOp` into the
//! per-tab `StructureChangeTracker`. The tracker's `OpsChanged` event
//! triggers `regenerate_sql_preview`, which calls `materialize` and
//! sets the SourceView buffer text. The Save button reads
//! `materialize` again and dispatches `ExecuteTransaction` to App.

use std::cell::RefCell;
use std::rc::Rc;

use relm4::adw::prelude::*;
use relm4::{ComponentParts, ComponentSender, SimpleComponent, adw, gtk};

use tablepro_core::sql_ddl::{BuildDdlError, DraftColumn};
use tablepro_core::{ColumnInfo, ForeignKeyInfo, IndexInfo};
use uuid::Uuid;

use crate::services::structure_tracker::{self, StructureOp, StructureTrackerEvent};

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
}

/// Curated type lists per driver. Free-text input still allowed via
/// the combo box's editable entry; this list seeds the dropdown so
/// common types are one click away. Order matters — most-common at
/// the top.
fn driver_types(driver_id: &str) -> &'static [&'static str] {
    match driver_id {
        "postgres" => &[
            "integer",
            "bigint",
            "smallint",
            "text",
            "varchar(255)",
            "boolean",
            "timestamp",
            "timestamp with time zone",
            "date",
            "time",
            "numeric(10, 2)",
            "real",
            "double precision",
            "uuid",
            "jsonb",
            "json",
            "bytea",
            "serial",
            "bigserial",
        ],
        "mysql" => &[
            "INT",
            "BIGINT",
            "SMALLINT",
            "TINYINT",
            "VARCHAR(255)",
            "TEXT",
            "BOOLEAN",
            "DATETIME",
            "TIMESTAMP",
            "DATE",
            "TIME",
            "DECIMAL(10, 2)",
            "FLOAT",
            "DOUBLE",
            "JSON",
            "BLOB",
            "CHAR(36)",
        ],
        "sqlite" => &[
            "INTEGER", "TEXT", "REAL", "BLOB", "NUMERIC", "BOOLEAN", "DATETIME", "DATE",
        ],
        _ => &["TEXT"],
    }
}

/// Whether the driver supports this kind of column-level alter on an
/// existing column. SQLite has the most restrictions; the UI uses
/// these to grey out non-supported cells with explanatory tooltips.
fn driver_can_alter_column_type(driver_id: &str) -> bool {
    !matches!(driver_id, "sqlite")
}

fn driver_can_alter_column_nullable(driver_id: &str) -> bool {
    !matches!(driver_id, "sqlite")
}

fn driver_can_alter_column_default(driver_id: &str) -> bool {
    !matches!(driver_id, "sqlite")
}

fn driver_can_drop_column(driver_id: &str) -> bool {
    // SQLite ≥ 3.35 supports DROP COLUMN; the builder doesn't probe
    // the runtime version. Always enable; the driver surfaces the
    // error if running against an older SQLite.
    let _ = driver_id;
    true
}

fn driver_can_drop_foreign_key(driver_id: &str) -> bool {
    !matches!(driver_id, "sqlite")
}

// MySQL drag-reorder support is wired in a follow-up commit; the
// helper stays here so the v1 UI can detect support without circular
// imports later.
#[allow(dead_code)]
fn driver_supports_reorder(driver_id: &str) -> bool {
    matches!(driver_id, "mysql")
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

    // Widget refs we touch from `update`.
    inner_stack: gtk::Stack,
    name_entry: gtk::Entry,
    columns_box: gtk::Box,
    indexes_box: gtk::Box,
    fks_box: gtk::Box,
    sql_buffer: sourceview5::Buffer,
    pending_label: gtk::Label,
    save_button: gtk::Button,
    discard_button: gtk::Button,
    drop_button: gtk::Button,

    last_dirty: Rc<RefCell<bool>>,
    /// Suppress reentrant rebuilds: setting Entry text triggers
    /// changed-signal echoes that would push duplicate RenameTable
    /// ops onto the tracker.
    suppress_emit: Rc<RefCell<bool>>,
    /// Monotonic counter for the "Add Column" placeholder name. Using
    /// `vec.len() + 1` produced duplicate `column_1` after the user
    /// removed a column; a forever-incrementing counter avoids the
    /// collision (validate_save rejects duplicates anyway, but the
    /// confusing UX is worse than the no-op rename the user has to
    /// do afterwards).
    next_column_seq: Rc<RefCell<usize>>,
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
    PendingCountChanged(usize),
    Cleared,
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

#[allow(dead_code)]
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
    fn refresh_buttons(&self, pending_count: usize) {
        let has_pending = pending_count > 0;
        self.save_button.set_sensitive(has_pending);
        self.discard_button.set_sensitive(has_pending);
        if has_pending {
            self.pending_label
                .set_label(&crate::tr!("{n} pending changes").replace("{n}", &pending_count.to_string()));
            self.pending_label.set_visible(true);
        } else {
            self.pending_label.set_visible(false);
        }
    }

    fn regenerate_sql_preview(&self) {
        let text = match structure_tracker::with_tab_ref(self.tab_id, |t| t.materialize(&self.driver_id)) {
            Some(Ok(stmts)) if !stmts.is_empty() => stmts.join(";\n\n") + ";",
            Some(Ok(_)) => crate::tr!("-- No pending changes."),
            Some(Err(e)) => format!("-- {e}"),
            None => crate::tr!("-- Tracker unavailable."),
        };
        self.sql_buffer.set_text(&text);
    }

    fn rebuild_columns_view(&self, sender: ComponentSender<Self>) {
        // Tear down + rebuild. Editing happens infrequently enough
        // that rebuilding the whole list per change is cheap. The
        // outer columns_box holds (ListBox + Add button) so the rows
        // get the standard `.boxed-list` styling: rounded corners,
        // separators between rows, hover highlight.
        clear_box(&self.columns_box);
        let driver_id = self.driver_id.clone();
        let list = boxed_list();
        for (i, col) in self.columns.borrow().iter().enumerate() {
            let row = wrap_in_list_row(build_column_row(i, col, &driver_id, sender.clone()));
            list.append(&row);
        }
        self.columns_box.append(&list);
        let add_button = gtk::Button::builder()
            .label(crate::tr!("Add Column"))
            .icon_name("list-add-symbolic")
            .build();
        add_button.add_css_class("flat");
        let sender_for_add = sender.clone();
        add_button.connect_clicked(move |_| sender_for_add.input(StructureTabInput::AddColumn));
        self.columns_box.append(&wrap_button_in_row(add_button));
    }

    fn rebuild_indexes_view(&self, sender: ComponentSender<Self>) {
        clear_box(&self.indexes_box);
        let list = boxed_list();
        for (i, idx) in self.indexes.borrow().iter().enumerate() {
            let row = wrap_in_list_row(build_index_row(i, idx, sender.clone()));
            list.append(&row);
        }
        self.indexes_box.append(&list);
        let add_button = gtk::Button::builder()
            .label(crate::tr!("Add Index…"))
            .icon_name("list-add-symbolic")
            .build();
        add_button.add_css_class("flat");
        let columns_for_dialog = self.columns.clone();
        let sender_for_add = sender.clone();
        let parent_box = self.indexes_box.clone();
        add_button.connect_clicked(move |_| {
            present_index_dialog(&parent_box, &columns_for_dialog.borrow(), sender_for_add.clone());
        });
        self.indexes_box.append(&wrap_button_in_row(add_button));
    }

    fn rebuild_fks_view(&self, sender: ComponentSender<Self>) {
        clear_box(&self.fks_box);
        let driver_id = self.driver_id.clone();
        let list = boxed_list();
        for (i, fk) in self.foreign_keys.borrow().iter().enumerate() {
            let row = wrap_in_list_row(build_fk_row(i, fk, &driver_id, sender.clone()));
            list.append(&row);
        }
        self.fks_box.append(&list);
        let add_button = gtk::Button::builder()
            .label(crate::tr!("Add Foreign Key…"))
            .icon_name("list-add-symbolic")
            .build();
        add_button.add_css_class("flat");
        let columns_for_dialog = self.columns.clone();
        let sender_for_add = sender.clone();
        let parent_box = self.fks_box.clone();
        add_button.connect_clicked(move |_| {
            present_fk_dialog(&parent_box, &columns_for_dialog.borrow(), sender_for_add.clone());
        });
        self.fks_box.append(&wrap_button_in_row(add_button));
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

/// Wrap a content widget in a non-activatable `gtk::ListBoxRow` so it
/// participates in the boxed-list styling without GTK trying to treat
/// it as an action target.
fn wrap_in_list_row(content: gtk::Widget) -> gtk::ListBoxRow {
    let row = gtk::ListBoxRow::builder().activatable(false).selectable(false).build();
    row.set_child(Some(&content));
    row
}

fn wrap_button_in_row(button: gtk::Button) -> gtk::Box {
    let row = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .margin_top(6)
        .margin_bottom(12)
        .margin_start(12)
        .margin_end(12)
        .build();
    row.append(&button);
    row
}

fn clear_box(b: &gtk::Box) {
    while let Some(child) = b.first_child() {
        b.remove(&child);
    }
}

/// Build one row for the Columns view. SQLite-restricted fields render
/// as set_sensitive(false) with explanatory tooltips so the user
/// understands why they can't edit. Non-original (newly added) columns
/// always allow full editing — those become AddColumn ops which SQLite
/// accepts at execution time.
fn build_column_row(
    index: usize,
    col: &DraftColumn,
    driver_id: &str,
    sender: ComponentSender<StructureTab>,
) -> gtk::Widget {
    let row = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(6)
        .margin_top(2)
        .margin_bottom(2)
        .margin_start(12)
        .margin_end(12)
        .build();

    let is_existing = col.original.is_some();
    let limit_for_existing = is_existing && driver_id == "sqlite";

    // Name
    let name_entry = gtk::Entry::builder()
        .text(&col.name)
        .placeholder_text(crate::tr!("column_name"))
        .hexpand(true)
        .build();
    name_entry.set_widget_name(&format!("col-name-{index}"));
    let sender_for_name = sender.clone();
    name_entry.connect_changed(move |e| {
        sender_for_name.input(StructureTabInput::ColumnEdited {
            index,
            field: ColumnField::Name(e.text().to_string()),
        });
    });
    row.append(&name_entry);

    // Type combo. ComboBoxText was soft-deprecated in GTK 4.10 in
    // favour of gtk::DropDown — but DropDown doesn't natively support
    // dropdown-with-free-text without a custom factory + entry. The
    // narrow allow covers ONLY the construction + property access on
    // ComboBoxText so a future deprecation elsewhere in the file
    // still surfaces a warning.
    let type_combo = build_type_combo(driver_id);
    if let Some(entry) = combo_entry(&type_combo) {
        entry.set_text(&col.data_type);
        let sender_for_type = sender.clone();
        entry.connect_changed(move |e| {
            sender_for_type.input(StructureTabInput::ColumnEdited {
                index,
                field: ColumnField::Type(e.text().to_string()),
            });
        });
    }
    if limit_for_existing && !driver_can_alter_column_type(driver_id) {
        type_combo.set_sensitive(false);
        type_combo.set_tooltip_text(Some(&crate::tr!("Type changes aren't supported by SQLite.")));
    }
    type_combo.set_size_request(180, -1);
    row.append(&type_combo);

    // Nullable
    let nullable_check = gtk::CheckButton::builder()
        .label(crate::tr!("Nullable"))
        .active(col.nullable)
        .build();
    if limit_for_existing && !driver_can_alter_column_nullable(driver_id) {
        nullable_check.set_sensitive(false);
        nullable_check.set_tooltip_text(Some(&crate::tr!("Nullability changes aren't supported by SQLite.")));
    }
    let sender_for_null = sender.clone();
    nullable_check.connect_toggled(move |c| {
        sender_for_null.input(StructureTabInput::ColumnEdited {
            index,
            field: ColumnField::Nullable(c.is_active()),
        });
    });
    row.append(&nullable_check);

    // Default
    let default_entry = gtk::Entry::builder()
        .text(col.default_value.as_deref().unwrap_or(""))
        .placeholder_text(crate::tr!("DEFAULT"))
        .build();
    default_entry.set_size_request(120, -1);
    if limit_for_existing && !driver_can_alter_column_default(driver_id) {
        default_entry.set_sensitive(false);
        default_entry.set_tooltip_text(Some(&crate::tr!("Default changes aren't supported by SQLite.")));
    }
    let sender_for_default = sender.clone();
    default_entry.connect_changed(move |e| {
        let text = e.text().to_string();
        let value = if text.is_empty() { None } else { Some(text) };
        sender_for_default.input(StructureTabInput::ColumnEdited {
            index,
            field: ColumnField::Default(value),
        });
    });
    row.append(&default_entry);

    // PK
    let pk_check = gtk::CheckButton::builder()
        .label(crate::tr!("PK"))
        .active(col.primary_key)
        .tooltip_text(crate::tr!("Primary key"))
        .build();
    let sender_for_pk = sender.clone();
    pk_check.connect_toggled(move |c| {
        sender_for_pk.input(StructureTabInput::ColumnEdited {
            index,
            field: ColumnField::PrimaryKey(c.is_active()),
        });
    });
    row.append(&pk_check);

    // Auto-increment
    let auto_check = gtk::CheckButton::builder()
        .label(crate::tr!("Auto"))
        .active(col.auto_increment)
        .tooltip_text(crate::tr!("Auto-increment / SERIAL"))
        .build();
    let sender_for_auto = sender.clone();
    auto_check.connect_toggled(move |c| {
        sender_for_auto.input(StructureTabInput::ColumnEdited {
            index,
            field: ColumnField::AutoIncrement(c.is_active()),
        });
    });
    row.append(&auto_check);

    // Remove (trash) button
    let remove_button = gtk::Button::builder()
        .icon_name("user-trash-symbolic")
        .tooltip_text(crate::tr!("Remove column"))
        .build();
    remove_button.add_css_class("flat");
    remove_button.add_css_class("destructive-action");
    if is_existing && !driver_can_drop_column(driver_id) {
        remove_button.set_sensitive(false);
    }
    let sender_for_remove = sender.clone();
    remove_button.connect_clicked(move |_| sender_for_remove.input(StructureTabInput::RemoveColumn(index)));
    row.append(&remove_button);

    row.upcast()
}

fn build_index_row(index: usize, idx: &IndexInfo, sender: ComponentSender<StructureTab>) -> gtk::Widget {
    let row = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(6)
        .margin_top(2)
        .margin_bottom(2)
        .margin_start(12)
        .margin_end(12)
        .build();

    let name_label = gtk::Label::builder()
        .label(&idx.name)
        .xalign(0.0)
        .hexpand(true)
        .ellipsize(gtk::pango::EllipsizeMode::End)
        .build();
    if idx.primary {
        name_label.add_css_class("dim-label");
    }
    row.append(&name_label);

    let cols_label = gtk::Label::builder()
        .label(idx.columns.join(", "))
        .xalign(0.0)
        .hexpand(true)
        .build();
    cols_label.add_css_class("dim-label");
    row.append(&cols_label);

    if idx.unique {
        let badge = gtk::Label::builder().label(crate::tr!("UNIQUE")).build();
        badge.add_css_class("caption");
        badge.add_css_class("dim-label");
        row.append(&badge);
    }
    if idx.primary {
        let badge = gtk::Label::builder().label(crate::tr!("PRIMARY")).build();
        badge.add_css_class("caption");
        badge.add_css_class("accent");
        row.append(&badge);
    }

    let remove_button = gtk::Button::builder()
        .icon_name("user-trash-symbolic")
        .tooltip_text(crate::tr!("Remove index"))
        .build();
    remove_button.add_css_class("flat");
    remove_button.add_css_class("destructive-action");
    // Primary index isn't user-droppable — it's owned by the PK
    // column constraint and removing it breaks the table.
    if idx.primary {
        remove_button.set_sensitive(false);
        remove_button.set_tooltip_text(Some(&crate::tr!(
            "Primary-key index can't be dropped here; clear the PK on the column."
        )));
    }
    let sender_for_remove = sender.clone();
    remove_button.connect_clicked(move |_| sender_for_remove.input(StructureTabInput::RemoveIndex(index)));
    row.append(&remove_button);

    row.upcast()
}

fn build_fk_row(
    index: usize,
    fk: &ForeignKeyInfo,
    driver_id: &str,
    sender: ComponentSender<StructureTab>,
) -> gtk::Widget {
    let row = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(6)
        .margin_top(2)
        .margin_bottom(2)
        .margin_start(12)
        .margin_end(12)
        .build();

    let name_label = gtk::Label::builder()
        .label(&fk.name)
        .xalign(0.0)
        .hexpand(true)
        .ellipsize(gtk::pango::EllipsizeMode::End)
        .build();
    row.append(&name_label);

    let cols_label = gtk::Label::builder()
        .label(fk.columns.join(", "))
        .xalign(0.0)
        .hexpand(true)
        .build();
    cols_label.add_css_class("dim-label");
    row.append(&cols_label);

    let ref_text = match &fk.ref_schema {
        Some(s) if !s.is_empty() => format!("→ {s}.{} ({})", fk.ref_table, fk.ref_columns.join(", ")),
        _ => format!("→ {} ({})", fk.ref_table, fk.ref_columns.join(", ")),
    };
    let ref_label = gtk::Label::builder().label(&ref_text).xalign(0.0).hexpand(true).build();
    ref_label.add_css_class("dim-label");
    row.append(&ref_label);

    let remove_button = gtk::Button::builder()
        .icon_name("user-trash-symbolic")
        .tooltip_text(crate::tr!("Remove foreign key"))
        .build();
    remove_button.add_css_class("flat");
    remove_button.add_css_class("destructive-action");
    if !driver_can_drop_foreign_key(driver_id) {
        remove_button.set_sensitive(false);
        remove_button.set_tooltip_text(Some(&crate::tr!("Dropping a foreign key isn't supported by SQLite.")));
    }
    let sender_for_remove = sender.clone();
    remove_button.connect_clicked(move |_| sender_for_remove.input(StructureTabInput::RemoveForeignKey(index)));
    row.append(&remove_button);

    row.upcast()
}

/// Show the "Add Index" form dialog. The dialog wraps an
/// AdwAlertDialog around a body Box with name entry + column
/// multi-select + unique toggle.
fn present_index_dialog(parent: &gtk::Box, columns: &[DraftColumn], sender: ComponentSender<StructureTab>) {
    let dialog = adw::AlertDialog::new(Some(&crate::tr!("Add Index")), None);
    let body = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(8)
        .margin_top(6)
        .margin_bottom(6)
        .build();

    let name_entry = gtk::Entry::builder().placeholder_text(crate::tr!("index_name")).build();
    body.append(&gtk::Label::builder().label(crate::tr!("Name")).xalign(0.0).build());
    body.append(&name_entry);

    body.append(
        &gtk::Label::builder()
            .label(crate::tr!("Columns"))
            .xalign(0.0)
            .margin_top(6)
            .build(),
    );
    let columns_list = gtk::ListBox::builder().selection_mode(gtk::SelectionMode::None).build();
    columns_list.add_css_class("boxed-list");
    let column_checks: Rc<RefCell<Vec<(String, gtk::CheckButton)>>> = Rc::new(RefCell::new(Vec::new()));
    for col in columns {
        let row = adw::ActionRow::builder().title(&col.name).build();
        let check = gtk::CheckButton::new();
        check.set_valign(gtk::Align::Center);
        row.add_suffix(&check);
        row.set_activatable_widget(Some(&check));
        columns_list.append(&row);
        column_checks.borrow_mut().push((col.name.clone(), check));
    }
    body.append(&columns_list);

    let unique_check = gtk::CheckButton::builder().label(crate::tr!("Unique")).build();
    unique_check.set_margin_top(6);
    body.append(&unique_check);

    dialog.set_extra_child(Some(&body));
    dialog.add_response("cancel", &crate::tr!("Cancel"));
    dialog.add_response("add", &crate::tr!("Add"));
    dialog.set_response_appearance("add", adw::ResponseAppearance::Suggested);
    dialog.set_default_response(Some("add"));
    dialog.set_close_response("cancel");

    let column_checks_for_resp = column_checks.clone();
    let sender_for_resp = sender.clone();
    dialog.connect_response(None, move |dlg, response| {
        dlg.close();
        if response != "add" {
            return;
        }
        let name = name_entry.text().to_string();
        if name.trim().is_empty() {
            sender_for_resp.input(StructureTabInput::Refresh);
            return;
        }
        let cols: Vec<String> = column_checks_for_resp
            .borrow()
            .iter()
            .filter_map(|(n, c)| if c.is_active() { Some(n.clone()) } else { None })
            .collect();
        if cols.is_empty() {
            return;
        }
        sender_for_resp.input(StructureTabInput::AddIndex(IndexInfo {
            name,
            columns: cols,
            unique: unique_check.is_active(),
            primary: false,
        }));
    });

    dialog.present(Some(parent));
}

/// Show the "Add Foreign Key" form dialog. The reference table /
/// columns are free-text in v1 (no live drop-down of available
/// tables) — that requires plumbing list_tables through the tab,
/// follow-up commit.
fn present_fk_dialog(parent: &gtk::Box, columns: &[DraftColumn], sender: ComponentSender<StructureTab>) {
    let dialog = adw::AlertDialog::new(Some(&crate::tr!("Add Foreign Key")), None);
    let body = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(8)
        .margin_top(6)
        .margin_bottom(6)
        .build();

    let name_entry = gtk::Entry::builder().placeholder_text(crate::tr!("fk_name")).build();
    body.append(&gtk::Label::builder().label(crate::tr!("Name")).xalign(0.0).build());
    body.append(&name_entry);

    body.append(
        &gtk::Label::builder()
            .label(crate::tr!("Columns"))
            .xalign(0.0)
            .margin_top(6)
            .build(),
    );
    let columns_list = gtk::ListBox::builder().selection_mode(gtk::SelectionMode::None).build();
    columns_list.add_css_class("boxed-list");
    let column_checks: Rc<RefCell<Vec<(String, gtk::CheckButton)>>> = Rc::new(RefCell::new(Vec::new()));
    for col in columns {
        let row = adw::ActionRow::builder().title(&col.name).build();
        let check = gtk::CheckButton::new();
        check.set_valign(gtk::Align::Center);
        row.add_suffix(&check);
        row.set_activatable_widget(Some(&check));
        columns_list.append(&row);
        column_checks.borrow_mut().push((col.name.clone(), check));
    }
    body.append(&columns_list);

    body.append(
        &gtk::Label::builder()
            .label(crate::tr!("References (table)"))
            .xalign(0.0)
            .margin_top(6)
            .build(),
    );
    let ref_table_entry = gtk::Entry::builder()
        .placeholder_text(crate::tr!("schema.referenced_table"))
        .build();
    body.append(&ref_table_entry);

    body.append(
        &gtk::Label::builder()
            .label(crate::tr!("Reference columns"))
            .xalign(0.0)
            .margin_top(6)
            .build(),
    );
    let ref_cols_entry = gtk::Entry::builder().placeholder_text(crate::tr!("col1, col2")).build();
    body.append(&ref_cols_entry);

    let actions = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(8)
        .margin_top(6)
        .build();
    let on_delete = gtk::DropDown::from_strings(&["NO ACTION", "RESTRICT", "CASCADE", "SET NULL", "SET DEFAULT"]);
    let on_update = gtk::DropDown::from_strings(&["NO ACTION", "RESTRICT", "CASCADE", "SET NULL", "SET DEFAULT"]);
    actions.append(
        &gtk::Label::builder()
            .label(crate::tr!("ON DELETE"))
            .valign(gtk::Align::Center)
            .build(),
    );
    actions.append(&on_delete);
    actions.append(
        &gtk::Label::builder()
            .label(crate::tr!("ON UPDATE"))
            .valign(gtk::Align::Center)
            .margin_start(12)
            .build(),
    );
    actions.append(&on_update);
    body.append(&actions);

    dialog.set_extra_child(Some(&body));
    dialog.add_response("cancel", &crate::tr!("Cancel"));
    dialog.add_response("add", &crate::tr!("Add"));
    dialog.set_response_appearance("add", adw::ResponseAppearance::Suggested);
    dialog.set_default_response(Some("add"));
    dialog.set_close_response("cancel");

    let column_checks_for_resp = column_checks.clone();
    let actions_text = ["NO ACTION", "RESTRICT", "CASCADE", "SET NULL", "SET DEFAULT"];
    let sender_for_resp = sender.clone();
    dialog.connect_response(None, move |dlg, response| {
        dlg.close();
        if response != "add" {
            return;
        }
        let name = name_entry.text().to_string();
        let ref_table = ref_table_entry.text().to_string();
        if name.trim().is_empty() || ref_table.trim().is_empty() {
            return;
        }
        let cols: Vec<String> = column_checks_for_resp
            .borrow()
            .iter()
            .filter_map(|(n, c)| if c.is_active() { Some(n.clone()) } else { None })
            .collect();
        if cols.is_empty() {
            return;
        }
        let ref_cols: Vec<String> = ref_cols_entry
            .text()
            .split(',')
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
            .collect();
        if ref_cols.is_empty() {
            return;
        }
        let (ref_schema, ref_table_only) = match ref_table.split_once('.') {
            Some((s, t)) => (Some(s.trim().to_string()), t.trim().to_string()),
            None => (None, ref_table),
        };
        let action_at = |idx: u32| -> Option<String> {
            let s = actions_text.get(idx as usize)?;
            if *s == "NO ACTION" { None } else { Some((*s).into()) }
        };
        sender_for_resp.input(StructureTabInput::AddForeignKey(ForeignKeyInfo {
            name,
            columns: cols,
            ref_schema,
            ref_table: ref_table_only,
            ref_columns: ref_cols,
            on_delete: action_at(on_delete.selected()),
            on_update: action_at(on_update.selected()),
        }));
    });

    dialog.present(Some(parent));
}

/// Validate the model against driver constraints before Save. Returns
/// the first user-visible error string, or None if all checks pass.
fn validate_save(table_name: &str, columns: &[DraftColumn], mode: StructureMode) -> Result<(), String> {
    if matches!(mode, StructureMode::New) && table_name.trim().is_empty() {
        return Err(crate::tr!("Table name is required."));
    }
    if matches!(mode, StructureMode::New) && columns.is_empty() {
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

        // Top header: table-name entry + driver label.
        let header = adw::HeaderBar::builder().show_title(false).build();
        let title_box = gtk::Box::builder()
            .orientation(gtk::Orientation::Horizontal)
            .spacing(8)
            .build();
        let name_entry = gtk::Entry::builder()
            .text(&init.table)
            .placeholder_text(crate::tr!("table_name"))
            .width_chars(20)
            .build();
        title_box.append(&name_entry);
        let driver_label = gtk::Label::builder()
            .label(driver_display_name(&init.driver_id))
            .build();
        driver_label.add_css_class("dim-label");
        driver_label.add_css_class("caption");
        title_box.append(&driver_label);
        header.set_title_widget(Some(&title_box));

        // ViewSwitcher header (under HeaderBar).
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
        let sql_scroll = gtk::ScrolledWindow::builder().child(&sql_view).vexpand(true).build();
        let sql_page = view_stack.add_titled_with_icon(
            &sql_scroll,
            Some("sql"),
            &crate::tr!("SQL Preview"),
            "text-x-generic-symbolic",
        );
        let _ = sql_page;

        let view_switcher = adw::ViewSwitcher::builder()
            .stack(&view_stack)
            .policy(adw::ViewSwitcherPolicy::Wide)
            .build();

        // Inner stack swaps between "loading" / "editor" / "error" so
        // Edit-mode tabs show a spinner until fetch_structure_data
        // resolves.
        let inner_stack = gtk::Stack::new();
        inner_stack.set_transition_type(gtk::StackTransitionType::Crossfade);

        let loading_status = adw::StatusPage::builder()
            .icon_name("emblem-synchronizing-symbolic")
            .title(crate::tr!("Loading structure…"))
            .build();
        inner_stack.add_named(&loading_status, Some("loading"));

        let editor_box = gtk::Box::builder()
            .orientation(gtk::Orientation::Vertical)
            .spacing(0)
            .build();
        editor_box.append(&view_switcher);
        editor_box.append(&view_stack);
        inner_stack.add_named(&editor_box, Some("editor"));

        let error_status = adw::StatusPage::builder()
            .icon_name("dialog-error-symbolic")
            .title(crate::tr!("Couldn't load structure"))
            .build();
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

        // Top header + content + bottom bar.
        root.add_top_bar(&header);
        root.set_content(Some(&inner_stack));
        root.add_bottom_bar(&action_bar);

        // Wire the table-name entry to push RenameTable / propagate to
        // the model.
        let suppress_emit = Rc::new(RefCell::new(false));
        let sender_for_name = sender.clone();
        let suppress_for_name = suppress_emit.clone();
        name_entry.connect_changed(move |e| {
            if *suppress_for_name.borrow() {
                return;
            }
            sender_for_name.input(StructureTabInput::TableNameEdited(e.text().to_string()));
        });

        // Subscribe to the per-tab tracker.
        let (tracker_tx, tracker_rx) = relm4::channel::<StructureTrackerEvent>();
        structure_tracker::with_tab(init.tab_id, |t| t.subscribe(tracker_tx));
        let input_for_tracker = sender.input_sender().clone();
        relm4::spawn_local(tracker_rx.forward(input_for_tracker, |event| match event {
            StructureTrackerEvent::OpsChanged(n) => StructureTabInput::PendingCountChanged(n),
            StructureTrackerEvent::Cleared => StructureTabInput::Cleared,
        }));

        // Edit mode: kick the App for fetch_structure_data.
        if matches!(init.mode, StructureMode::Edit) {
            let _ = sender.output(StructureTabOutput::FetchStructure);
        }

        let model = StructureTab {
            tab_id: init.tab_id,
            schema: init.schema,
            table_name: Rc::new(RefCell::new(init.table)),
            mode: Rc::new(RefCell::new(init.mode)),
            driver_id: init.driver_id,
            columns: Rc::new(RefCell::new(Vec::new())),
            indexes: Rc::new(RefCell::new(Vec::new())),
            foreign_keys: Rc::new(RefCell::new(Vec::new())),
            inner_stack,
            name_entry,
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
        };

        // Initial render so New-mode tabs aren't blank.
        sender.input(StructureTabInput::Refresh);

        ComponentParts { model, widgets: () }
    }

    fn update(&mut self, msg: Self::Input, sender: ComponentSender<Self>) {
        match msg {
            StructureTabInput::StructureLoaded { columns, indexes, fks } => {
                // App now coalesces the three fetches into one
                // message; replace the model wholesale and rebuild
                // the UI once.
                *self.columns.borrow_mut() = columns.into_iter().map(DraftColumn::from_info).collect();
                *self.indexes.borrow_mut() = indexes;
                *self.foreign_keys.borrow_mut() = fks;
                self.inner_stack.set_visible_child_name("editor");
                sender.input(StructureTabInput::Refresh);
            }
            StructureTabInput::LoadFailed(message) => {
                self.inner_stack.set_visible_child_name("error");
                let _ = sender.output(StructureTabOutput::ShowAlert {
                    title: crate::tr!("Couldn't load structure"),
                    body: message,
                });
            }
            StructureTabInput::Refresh => {
                self.rebuild_columns_view(sender.clone());
                self.rebuild_indexes_view(sender.clone());
                self.rebuild_fks_view(sender.clone());
                self.regenerate_sql_preview();
            }
            StructureTabInput::TableNameEdited(text) => {
                let mode = *self.mode.borrow();
                if matches!(mode, StructureMode::New) {
                    *self.table_name.borrow_mut() = text.clone();
                    // For New mode we rebuild the CreateTable op below
                    // in update_create_op_for_new(). For Edit mode the
                    // RenameTable op is the right ledger entry.
                    self.update_create_op_for_new();
                } else {
                    let old_name = self.table_name.borrow().clone();
                    if old_name != text && !text.is_empty() {
                        let schema = self.schema.clone();
                        structure_tracker::with_tab(self.tab_id, |t| {
                            t.push(
                                StructureOp::RenameTable {
                                    schema: schema.clone(),
                                    old_name: old_name.clone(),
                                    new_name: text.clone(),
                                },
                                StructureOp::RenameTable {
                                    schema: schema.clone(),
                                    old_name: text.clone(),
                                    new_name: old_name.clone(),
                                },
                            );
                        });
                        *self.table_name.borrow_mut() = text;
                    }
                }
                self.regenerate_sql_preview();
            }
            StructureTabInput::ColumnEdited { index, field } => {
                let mode = *self.mode.borrow();
                let mut cols = self.columns.borrow_mut();
                let Some(col) = cols.get_mut(index) else {
                    return;
                };
                let prev = col.clone();
                match field {
                    ColumnField::Name(s) => col.name = s,
                    ColumnField::Type(s) => col.data_type = s,
                    ColumnField::Nullable(b) => col.nullable = b,
                    ColumnField::PrimaryKey(b) => col.primary_key = b,
                    ColumnField::AutoIncrement(b) => col.auto_increment = b,
                    ColumnField::Default(s) => col.default_value = s,
                }
                let new_col = col.clone();
                drop(cols);
                if matches!(mode, StructureMode::New) {
                    self.update_create_op_for_new();
                } else if let Some(_orig) = new_col.original.as_ref() {
                    // Existing column: push AlterColumn op (materialize
                    // groups all alter ops per column for MySQL).
                    let table = self.table_name.borrow().clone();
                    let schema = self.schema.clone();
                    structure_tracker::with_tab(self.tab_id, |t| {
                        t.push(
                            StructureOp::AlterColumn {
                                schema: schema.clone(),
                                table: table.clone(),
                                column: new_col.clone(),
                            },
                            StructureOp::AlterColumn {
                                schema: schema.clone(),
                                table: table.clone(),
                                column: prev.clone(),
                            },
                        );
                    });
                } else {
                    // Newly-added column in Edit mode: regenerate the
                    // AddColumn op (or rather, update its in-flight
                    // payload). We do this by rebuilding the pending
                    // ops for added columns each time the user edits.
                    self.update_added_columns_ops();
                }
                self.regenerate_sql_preview();
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
                self.columns.borrow_mut().push(new_col.clone());
                let mode = *self.mode.borrow();
                if matches!(mode, StructureMode::Edit) {
                    let table = self.table_name.borrow().clone();
                    let schema = self.schema.clone();
                    structure_tracker::with_tab(self.tab_id, |t| {
                        t.push(
                            StructureOp::AddColumn {
                                schema: schema.clone(),
                                table: table.clone(),
                                column: new_col.clone(),
                            },
                            StructureOp::DropColumn {
                                schema: schema.clone(),
                                table: table.clone(),
                                column_name: new_col.name.clone(),
                            },
                        );
                    });
                } else {
                    self.update_create_op_for_new();
                }
                sender.input(StructureTabInput::Refresh);
            }
            StructureTabInput::RemoveColumn(index) => {
                let mode = *self.mode.borrow();
                let removed = {
                    let mut cols = self.columns.borrow_mut();
                    if index >= cols.len() {
                        return;
                    }
                    cols.remove(index)
                };
                if matches!(mode, StructureMode::Edit) {
                    if removed.original.is_some() {
                        let table = self.table_name.borrow().clone();
                        let schema = self.schema.clone();
                        let drop_op = StructureOp::DropColumn {
                            schema: schema.clone(),
                            table: table.clone(),
                            column_name: removed.name.clone(),
                        };
                        let restore_op = StructureOp::AddColumn {
                            schema: schema.clone(),
                            table: table.clone(),
                            column: removed.clone(),
                        };
                        structure_tracker::with_tab(self.tab_id, |t| t.push(drop_op, restore_op));
                    } else {
                        self.update_added_columns_ops();
                    }
                } else {
                    self.update_create_op_for_new();
                }
                sender.input(StructureTabInput::Refresh);
            }
            StructureTabInput::AddIndex(index) => {
                self.indexes.borrow_mut().push(index.clone());
                let mode = *self.mode.borrow();
                let table = self.table_name.borrow().clone();
                let schema = self.schema.clone();
                if matches!(mode, StructureMode::Edit) {
                    let inverse_name = index.name.clone();
                    structure_tracker::with_tab(self.tab_id, |t| {
                        t.push(
                            StructureOp::AddIndex {
                                schema: schema.clone(),
                                table: table.clone(),
                                index: index.clone(),
                            },
                            StructureOp::DropIndex {
                                schema: schema.clone(),
                                table: table.clone(),
                                index_name: inverse_name,
                            },
                        );
                    });
                } else {
                    self.update_create_op_for_new();
                }
                sender.input(StructureTabInput::Refresh);
            }
            StructureTabInput::RemoveIndex(idx_pos) => {
                let mode = *self.mode.borrow();
                let removed = {
                    let mut idxs = self.indexes.borrow_mut();
                    if idx_pos >= idxs.len() {
                        return;
                    }
                    idxs.remove(idx_pos)
                };
                if matches!(mode, StructureMode::Edit) {
                    let table = self.table_name.borrow().clone();
                    let schema = self.schema.clone();
                    structure_tracker::with_tab(self.tab_id, |t| {
                        t.push(
                            StructureOp::DropIndex {
                                schema: schema.clone(),
                                table: table.clone(),
                                index_name: removed.name.clone(),
                            },
                            StructureOp::AddIndex {
                                schema: schema.clone(),
                                table: table.clone(),
                                index: removed.clone(),
                            },
                        );
                    });
                } else {
                    self.update_create_op_for_new();
                }
                sender.input(StructureTabInput::Refresh);
            }
            StructureTabInput::AddForeignKey(fk) => {
                self.foreign_keys.borrow_mut().push(fk.clone());
                let mode = *self.mode.borrow();
                let table = self.table_name.borrow().clone();
                let schema = self.schema.clone();
                if matches!(mode, StructureMode::Edit) {
                    let inverse_name = fk.name.clone();
                    structure_tracker::with_tab(self.tab_id, |t| {
                        t.push(
                            StructureOp::AddForeignKey {
                                schema: schema.clone(),
                                table: table.clone(),
                                fk: fk.clone(),
                            },
                            StructureOp::DropForeignKey {
                                schema: schema.clone(),
                                table: table.clone(),
                                fk_name: inverse_name,
                            },
                        );
                    });
                } else {
                    self.update_create_op_for_new();
                }
                sender.input(StructureTabInput::Refresh);
            }
            StructureTabInput::RemoveForeignKey(idx_pos) => {
                let mode = *self.mode.borrow();
                let removed = {
                    let mut fks = self.foreign_keys.borrow_mut();
                    if idx_pos >= fks.len() {
                        return;
                    }
                    fks.remove(idx_pos)
                };
                if matches!(mode, StructureMode::Edit) {
                    let table = self.table_name.borrow().clone();
                    let schema = self.schema.clone();
                    structure_tracker::with_tab(self.tab_id, |t| {
                        t.push(
                            StructureOp::DropForeignKey {
                                schema: schema.clone(),
                                table: table.clone(),
                                fk_name: removed.name.clone(),
                            },
                            StructureOp::AddForeignKey {
                                schema: schema.clone(),
                                table: table.clone(),
                                fk: removed.clone(),
                            },
                        );
                    });
                } else {
                    self.update_create_op_for_new();
                }
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
                let result = structure_tracker::with_tab_ref(self.tab_id, |t| t.materialize(&self.driver_id));
                match result {
                    Some(Ok(statements)) if !statements.is_empty() => {
                        self.save_button.set_sensitive(false);
                        self.discard_button.set_sensitive(false);
                        let _ = sender.output(StructureTabOutput::ExecuteTransaction { statements });
                    }
                    Some(Ok(_)) => {
                        let _ = sender.output(StructureTabOutput::ShowToast(crate::tr!("Nothing to save.")));
                    }
                    Some(Err(BuildDdlError::SqliteNotSupported(detail))) => {
                        let _ = sender.output(StructureTabOutput::ShowAlert {
                            title: crate::tr!("Cannot save"),
                            body: crate::tr!("SQLite doesn't support: {detail}").replace("{detail}", detail),
                        });
                    }
                    Some(Err(e)) => {
                        let _ = sender.output(StructureTabOutput::ShowAlert {
                            title: crate::tr!("Cannot save"),
                            body: format!("{e}"),
                        });
                    }
                    None => {}
                }
            }
            StructureTabInput::Discard => {
                structure_tracker::with_tab(self.tab_id, |t| t.clear());
                // Reset the model to original state. For New mode that's
                // empty; for Edit mode the originals are still in
                // DraftColumn.original, so re-derive them.
                let mode = *self.mode.borrow();
                if matches!(mode, StructureMode::New) {
                    self.columns.borrow_mut().clear();
                    self.indexes.borrow_mut().clear();
                    self.foreign_keys.borrow_mut().clear();
                } else {
                    let originals: Vec<DraftColumn> = self
                        .columns
                        .borrow()
                        .iter()
                        .filter_map(|c| c.original.clone().map(DraftColumn::from_info))
                        .collect();
                    *self.columns.borrow_mut() = originals;
                }
                sender.input(StructureTabInput::Refresh);
            }
            StructureTabInput::DropTableRequested => {
                let _ = sender.output(StructureTabOutput::DropTableRequested {
                    schema: self.schema.clone(),
                    table: self.table_name.borrow().clone(),
                });
            }
            StructureTabInput::PendingCountChanged(n) => {
                self.refresh_buttons(n);
                let dirty = n > 0;
                let mut last = self.last_dirty.borrow_mut();
                if *last != dirty {
                    *last = dirty;
                    let _ = sender.output(StructureTabOutput::DirtyChanged(dirty));
                }
            }
            StructureTabInput::Cleared => {
                self.refresh_buttons(0);
                let mut last = self.last_dirty.borrow_mut();
                if *last {
                    *last = false;
                    let _ = sender.output(StructureTabOutput::DirtyChanged(false));
                }
            }
            StructureTabInput::SaveCompleted { new_table_name } => {
                if let Some(name) = new_table_name {
                    *self.mode.borrow_mut() = StructureMode::Edit;
                    *self.table_name.borrow_mut() = name.clone();
                    *self.suppress_emit.borrow_mut() = true;
                    self.name_entry.set_text(&name);
                    *self.suppress_emit.borrow_mut() = false;
                    self.drop_button.set_visible(true);
                }
                structure_tracker::with_tab(self.tab_id, |t| t.clear());
                if matches!(*self.mode.borrow(), StructureMode::Edit) {
                    let _ = sender.output(StructureTabOutput::FetchStructure);
                }
            }
            StructureTabInput::SaveFailed(message) => {
                let pending = structure_tracker::with_tab_ref(self.tab_id, |t| t.pending_count()).unwrap_or(0);
                self.refresh_buttons(pending);
                let _ = sender.output(StructureTabOutput::ShowAlert {
                    title: crate::tr!("Save failed"),
                    body: message,
                });
            }
        }
    }
}

impl StructureTab {
    /// Rebuild the single CreateTable op for New mode from current
    /// model state. Called whenever any field changes.
    fn update_create_op_for_new(&self) {
        let table = self.table_name.borrow().clone();
        let columns = self.columns.borrow().clone();
        let indexes = self.indexes.borrow().clone();
        let fks = self.foreign_keys.borrow().clone();
        let schema = self.schema.clone();
        structure_tracker::with_tab(self.tab_id, |t| {
            t.clear();
            t.push(
                StructureOp::CreateTable {
                    schema: schema.clone(),
                    table: table.clone(),
                    columns,
                    indexes,
                    fks,
                },
                // Inverse for CreateTable is unsupported (we don't undo
                // a draft create); push a stub for symmetry.
                StructureOp::CreateTable {
                    schema,
                    table,
                    columns: vec![],
                    indexes: vec![],
                    fks: vec![],
                },
            );
        });
    }

    /// In Edit mode, walk the model's newly-added columns (where
    /// `original.is_none()`) and rebuild `AddColumn` ops for them.
    /// Existing columns' `AlterColumn` ops are pushed inline as the
    /// user edits each field; `AddColumn` payloads need this surgical
    /// rewrite because the user can edit the same draft column's
    /// fields multiple times after adding it.
    fn update_added_columns_ops(&self) {
        let table = self.table_name.borrow().clone();
        let schema = self.schema.clone();
        let new_cols: Vec<DraftColumn> = self
            .columns
            .borrow()
            .iter()
            .filter(|c| c.original.is_none())
            .cloned()
            .collect();
        structure_tracker::with_tab(self.tab_id, |t| {
            // Strip every prior AddColumn op on this table so the
            // tracker reflects only the latest column-state.
            let table_for_filter = table.clone();
            t.retain_ops(|op| matches!(op, StructureOp::AddColumn { table: t, .. } if *t == table_for_filter));
            // Re-push current state. Inverse for each is the matching
            // DropColumn so undo restores the prior model.
            for col in new_cols {
                t.push(
                    StructureOp::AddColumn {
                        schema: schema.clone(),
                        table: table.clone(),
                        column: col.clone(),
                    },
                    StructureOp::DropColumn {
                        schema: schema.clone(),
                        table: table.clone(),
                        column_name: col.name.clone(),
                    },
                );
            }
        });
    }
}

/// Build the per-column type combo box with curated suggestions for
/// `driver_id`. ComboBoxText is soft-deprecated since GTK 4.10; the
/// allow attribute is scoped to this builder so the file's other
/// deprecation warnings (if any future API gets soft-removed) stay
/// visible.
#[allow(deprecated)]
fn build_type_combo(driver_id: &str) -> gtk::ComboBoxText {
    let combo = gtk::ComboBoxText::with_entry();
    for ty in driver_types(driver_id) {
        combo.append_text(ty);
    }
    combo
}

/// Pull the inner `gtk::Entry` out of a `gtk::ComboBoxText` so callers
/// can wire change signals on the editable text field.
#[allow(deprecated)]
fn combo_entry(combo: &gtk::ComboBoxText) -> Option<gtk::Entry> {
    combo.child().and_then(|c| c.dynamic_cast::<gtk::Entry>().ok())
}

fn driver_display_name(driver_id: &str) -> &'static str {
    match driver_id {
        "postgres" => "PostgreSQL",
        "mysql" => "MySQL",
        "sqlite" => "SQLite",
        _ => "Database",
    }
}

fn default_type_for(driver_id: &str) -> String {
    match driver_id {
        "postgres" => "text".into(),
        "mysql" => "VARCHAR(255)".into(),
        "sqlite" => "TEXT".into(),
        _ => "TEXT".into(),
    }
}
