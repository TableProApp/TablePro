//! Column-row builder + per-driver type helpers used by the Columns
//! page of the Structure tab.

use std::cell::{Cell, RefCell};
use std::rc::Rc;

use relm4::adw::prelude::*;
use relm4::gtk::gio;
use relm4::{ComponentSender, adw, gtk};

use tablepro_core::sql_ddl::DraftColumn;

use super::{ColumnField, StructureTab, StructureTabInput};

/// Curated type lists per driver. Free-text input still allowed via
/// the combo box's editable entry; this list seeds the dropdown so
/// common types are one click away. Order matters — most-common at
/// the top.
pub(super) fn driver_types(driver_id: &str) -> &'static [&'static str] {
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

/// Whether the driver supports column-level ALTER on an existing
/// column (type / nullable / default). SQLite blocks all three; the
/// UI uses this to grey out non-supported cells with explanatory
/// tooltips.
fn driver_can_alter_existing_column(driver_id: &str) -> bool {
    !matches!(driver_id, "sqlite")
}

fn driver_can_drop_column(_driver_id: &str) -> bool {
    // SQLite ≥ 3.35 supports DROP COLUMN; the builder doesn't probe
    // the runtime version. Always enable; the driver surfaces the
    // error if running against an older SQLite.
    true
}

pub(super) fn default_type_for(driver_id: &str) -> String {
    match driver_id {
        "postgres" => "text".into(),
        "mysql" => "VARCHAR(255)".into(),
        "sqlite" => "TEXT".into(),
        _ => "TEXT".into(),
    }
}

/// Render a draft column's summary line for the collapsed expander
/// header — `varchar(255) · NOT NULL · Primary key`. Order: type,
/// nullability, primary key, auto-increment. Empty parts are skipped
/// so a freshly-added column with default state shows the minimum
/// useful information.
fn format_column_subtitle(col: &DraftColumn) -> String {
    let mut parts: Vec<String> = Vec::new();
    if !col.data_type.trim().is_empty() {
        parts.push(col.data_type.clone());
    }
    parts.push(if col.nullable {
        crate::tr!("nullable")
    } else {
        crate::tr!("NOT NULL")
    });
    if col.primary_key {
        parts.push(crate::tr!("Primary key"));
    }
    if col.auto_increment {
        parts.push(crate::tr!("auto-increment"));
    }
    parts.join(" · ")
}

/// Build one collapsible column row as `adw::ExpanderRow`. Collapsed
/// state shows the column name (title) + summary subtitle; expanded
/// reveals one `AdwEntryRow` / `AdwSwitchRow` per editable attribute.
/// SQLite-restricted fields render as `set_sensitive(false)` with
/// explanatory tooltips so the user understands why they can't edit.
/// Non-original (newly-added) columns always allow full editing —
/// those become `AddColumn` ops which SQLite accepts at execution.
///
/// `suppress_emit` lets the caller mark a window during which signal
/// callbacks should NOT push edits onto the model. Used during
/// `rebuild_columns_view` to silence the `changed` / `toggled`
/// emissions GTK fires while initial values are stamped onto the
/// freshly-built widgets.
pub(super) fn build_column_expander_row(
    index: usize,
    col: &DraftColumn,
    driver_id: &str,
    sender: ComponentSender<StructureTab>,
    suppress_emit: Rc<Cell<bool>>,
    popover_registry: Rc<RefCell<Vec<gtk::Popover>>>,
) -> adw::ExpanderRow {
    let is_existing = col.original.is_some();
    let limit_for_existing = is_existing && driver_id == "sqlite";

    let row = adw::ExpanderRow::builder()
        .title(glib::markup_escape_text(&col.name))
        .subtitle(glib::markup_escape_text(&format_column_subtitle(col)))
        .build();
    row.set_widget_name(&format!("col-row-{index}"));

    // Trash button as a header-suffix on the expander row itself —
    // remains visible whether the row is expanded or collapsed.
    let remove_button = gtk::Button::builder()
        .icon_name("user-trash-symbolic")
        .tooltip_text(crate::tr!("Remove column"))
        .valign(gtk::Align::Center)
        .build();
    remove_button.add_css_class("flat");
    if is_existing && !driver_can_drop_column(driver_id) {
        remove_button.set_sensitive(false);
    }
    let sender_for_remove = sender.clone();
    remove_button.connect_clicked(move |_| sender_for_remove.input(StructureTabInput::RemoveColumn(index)));
    row.add_suffix(&remove_button);

    // Name (AdwEntryRow). The expander's title mirrors this entry
    // live so the collapsed header always reflects the user's input.
    let name_row = adw::EntryRow::builder().title(crate::tr!("Name")).build();
    name_row.set_text(&col.name);
    name_row.set_widget_name(&format!("col-name-{index}"));
    let sender_for_name = sender.clone();
    let suppress_for_name = suppress_emit.clone();
    let row_for_name = row.clone();
    name_row.connect_changed(move |e| {
        if suppress_for_name.get() {
            return;
        }
        let text = e.text().to_string();
        row_for_name.set_title(&glib::markup_escape_text(&text));
        sender_for_name.input(StructureTabInput::ColumnEdited {
            index,
            field: ColumnField::Name(text),
        });
    });
    row.add_row(&name_row);

    // Type (AdwEntryRow — free text). A suffix MenuButton offers the
    // curated `driver_types()` suggestions; free-text input remains the
    // primary path so custom types like `decimal(10,2)` or Postgres
    // `enum` literals work without enumeration.
    let type_row = adw::EntryRow::builder().title(crate::tr!("Type")).build();
    type_row.set_text(&col.data_type);
    if limit_for_existing && !driver_can_alter_existing_column(driver_id) {
        type_row.set_sensitive(false);
        type_row.set_tooltip_text(Some(&crate::tr!("Type changes aren't supported by SQLite.")));
    }
    let sender_for_type = sender.clone();
    let suppress_for_type = suppress_emit.clone();
    type_row.connect_changed(move |e| {
        if suppress_for_type.get() {
            return;
        }
        sender_for_type.input(StructureTabInput::ColumnEdited {
            index,
            field: ColumnField::Type(e.text().to_string()),
        });
    });
    let (suggestions_button, suggestions_popover) = build_type_suggestions_button(driver_id, &type_row);
    type_row.add_suffix(&suggestions_button);
    popover_registry.borrow_mut().push(suggestions_popover);
    row.add_row(&type_row);

    // Nullable (AdwSwitchRow).
    let nullable_row = adw::SwitchRow::builder()
        .title(crate::tr!("Nullable"))
        .active(col.nullable)
        .build();
    if limit_for_existing && !driver_can_alter_existing_column(driver_id) {
        nullable_row.set_sensitive(false);
        nullable_row.set_tooltip_text(Some(&crate::tr!("Nullability changes aren't supported by SQLite.")));
    }
    let sender_for_null = sender.clone();
    let suppress_for_null = suppress_emit.clone();
    nullable_row.connect_active_notify(move |s| {
        if suppress_for_null.get() {
            return;
        }
        sender_for_null.input(StructureTabInput::ColumnEdited {
            index,
            field: ColumnField::Nullable(s.is_active()),
        });
    });
    row.add_row(&nullable_row);

    // Default value (AdwEntryRow). Empty input means no DEFAULT clause.
    let default_row = adw::EntryRow::builder().title(crate::tr!("Default value")).build();
    default_row.set_text(col.default_value.as_deref().unwrap_or(""));
    if limit_for_existing && !driver_can_alter_existing_column(driver_id) {
        default_row.set_sensitive(false);
        default_row.set_tooltip_text(Some(&crate::tr!("Default changes aren't supported by SQLite.")));
    }
    let sender_for_default = sender.clone();
    let suppress_for_default = suppress_emit.clone();
    default_row.connect_changed(move |e| {
        if suppress_for_default.get() {
            return;
        }
        let text = e.text().to_string();
        let value = if text.is_empty() { None } else { Some(text) };
        sender_for_default.input(StructureTabInput::ColumnEdited {
            index,
            field: ColumnField::Default(value),
        });
    });
    row.add_row(&default_row);

    // Primary key (AdwSwitchRow).
    let pk_row = adw::SwitchRow::builder()
        .title(crate::tr!("Primary key"))
        .active(col.primary_key)
        .build();
    let sender_for_pk = sender.clone();
    let suppress_for_pk = suppress_emit.clone();
    pk_row.connect_active_notify(move |s| {
        if suppress_for_pk.get() {
            return;
        }
        sender_for_pk.input(StructureTabInput::ColumnEdited {
            index,
            field: ColumnField::PrimaryKey(s.is_active()),
        });
    });
    row.add_row(&pk_row);

    // Auto-increment (AdwSwitchRow). Bound `sensitive` to PK's
    // `active` so the affordance reflects the driver-level constraint
    // (MySQL rejects AUTO_INCREMENT on non-PK; Postgres SERIAL
    // implies PK).
    let auto_row = adw::SwitchRow::builder()
        .title(crate::tr!("Auto increment"))
        .subtitle(crate::tr!("MySQL AUTO_INCREMENT / Postgres SERIAL"))
        .active(col.auto_increment)
        .build();
    auto_row.set_sensitive(col.primary_key);
    pk_row
        .bind_property("active", &auto_row, "sensitive")
        .sync_create()
        .build();
    let sender_for_auto = sender.clone();
    let suppress_for_auto = suppress_emit;
    auto_row.connect_active_notify(move |s| {
        if suppress_for_auto.get() {
            return;
        }
        sender_for_auto.input(StructureTabInput::ColumnEdited {
            index,
            field: ColumnField::AutoIncrement(s.is_active()),
        });
    });
    row.add_row(&auto_row);

    row
}

/// Build a suffix MenuButton for the type AdwEntryRow that opens a
/// native `gtk::PopoverMenu` listing curated `driver_types()` for
/// `driver_id`. Selecting an entry rewrites the target row's text
/// (which fires the row's `changed` signal — the existing handler
/// picks up the new value). Free-text input via the entry stays as
/// the primary path.
///
/// Implementation: a `gio::Menu` model + `MenuButton.set_menu_model`
/// causes GTK to render a `gtk::PopoverMenu` automatically. That is
/// the same widget powering app menus, right-click menus, and
/// gnome-menus across the desktop, so the rendering is identical to
/// every other GNOME menu the user has ever seen — proper menu-item
/// padding, hover/active states, separators, focus ring, all native.
///
/// Each type-name menu item activates a single SimpleAction
/// (`types.apply`) parameterised by the type string. The action is
/// stored in a per-button action group so two columns' menus don't
/// collide on the action name.
///
/// Returns the button plus the auto-built PopoverMenu so the caller
/// can register it for popdown on rebuild — otherwise an open menu
/// would keep its captured target alive and dispatch a click into a
/// detached AdwEntryRow.
fn build_type_suggestions_button(driver_id: &str, target: &adw::EntryRow) -> (gtk::MenuButton, gtk::Popover) {
    // Per-button action group: one action `apply` keyed by `String`
    // parameter. Each menu item activates `types.apply::<typename>`.
    let action_group = gio::SimpleActionGroup::new();
    let apply_action = gio::SimpleAction::new("apply", Some(&String::static_variant_type()));
    let target_for_action = target.clone();
    apply_action.connect_activate(move |_, param| {
        if let Some(s) = param.and_then(|v| v.get::<String>()) {
            target_for_action.set_text(&s);
        }
    });
    action_group.add_action(&apply_action);

    // Build the menu model: every type becomes a labeled item that
    // activates the apply action with the type string as parameter.
    // gtk::PopoverMenu renders each gio::MenuItem as a native menu
    // entry (no separator handling needed for a flat list).
    let menu = gio::Menu::new();
    for ty in driver_types(driver_id) {
        let item = gio::MenuItem::new(Some(ty), None);
        item.set_action_and_target_value(Some("types.apply"), Some(&ty.to_variant()));
        menu.append_item(&item);
    }

    let button = gtk::MenuButton::builder()
        .icon_name("pan-down-symbolic")
        .tooltip_text(crate::tr!("Suggested types"))
        .valign(gtk::Align::Center)
        .build();
    button.add_css_class("flat");
    button.insert_action_group("types", Some(&action_group));
    button.set_menu_model(Some(&menu));

    // The PopoverMenu is auto-created by MenuButton from the menu
    // model. Hand it back so the caller can `popdown` it before the
    // owning column row is torn down on Refresh.
    let popover = button
        .popover()
        .expect("MenuButton creates a PopoverMenu when a menu model is set");
    (button, popover)
}
