//! The column rows of the Structure tab's Columns page.

use std::cell::{Cell, RefCell};

use gtk4 as gtk;
use gtk4::gio;
use libadwaita as adw;
use libadwaita::prelude::*;
use tablepro_core::ddl::{ColumnCapabilities, DraftColumn, DraftType, Permission};
use tablepro_core::dialect::SqlDialect;

use super::character_set_choices::{
    ChoiceRow, character_set_choices, collation_choices, default_collation, follow_catalog, takes_character_set,
};
use super::context::StructureContext;
use super::draft_column_object::DraftColumnObject;
use super::{ColumnField, ColumnsInput, StructureTabSender};
use crate::ui::a11y::describe_icon_button;
use crate::ui::error_text::refusal_text;
use crate::ui::handler_guard::HandlerGuard;

/// Sends a row's edits as edits of its column, while the column lives.
#[derive(Clone)]
struct ColumnEdits {
    column: glib::WeakRef<DraftColumnObject>,
    sender: StructureTabSender,
}

impl ColumnEdits {
    fn send(&self, field: ColumnField) {
        if let Some(column) = self.column.upgrade() {
            self.sender.input(ColumnsInput::ColumnEdited { column, field });
        }
    }
}

/// Turn a control off with the reason, in its tooltip and for screen
/// readers, when the engine refuses the change it makes.
pub(super) fn gate(widget: &impl IsA<gtk::Widget>, permission: &Permission) {
    if let Permission::Refused(reason) = permission {
        let text = refusal_text(reason);
        widget.set_sensitive(false);
        widget.set_tooltip_text(Some(&text));
        widget
            .upcast_ref::<gtk::Widget>()
            .update_property(&[gtk::accessible::Property::Description(&text)]);
    }
}

/// A key column takes no NULL on any engine, so while the column is in
/// the key its Nullable switch is off and stays off.
fn hold_not_null(row: &adw::SwitchRow, key: bool) {
    row.set_sensitive(!key);
    let widget = row.upcast_ref::<gtk::Widget>();
    if key {
        let text = crate::i18n::gettext("A primary key column can't take NULL.");
        row.set_tooltip_text(Some(&text));
        widget.update_property(&[gtk::accessible::Property::Description(&text)]);
    } else {
        row.set_tooltip_text(None);
        widget.reset_property(gtk::AccessibleProperty::Description);
    }
}

/// Mark a field whose text the engine's parser refused, or clear it.
pub(super) fn mark_invalid(row: &adw::EntryRow, error: Option<&str>) {
    match error {
        Some(message) => {
            row.add_css_class("error");
            row.set_tooltip_text(Some(message));
        }
        None => {
            row.remove_css_class("error");
            row.set_tooltip_text(None);
        }
    }
    crate::ui::a11y::show_invalid(row, error);
}

/// Whether the engine's parser takes `text` as one type. The
/// catalogue's own declaration, typed back as it was, is never parsed
/// again.
fn type_error(dialect: Option<&dyn SqlDialect>, column: &DraftColumn, text: &str) -> Option<String> {
    let declared = column
        .original
        .as_ref()
        .is_some_and(|original| DraftType::Catalog(original.info.column_type.clone()).text() == text);
    if declared {
        return None;
    }
    let dialect = dialect?;
    dialect
        .parse_type(text)
        .err()
        .map(|error| crate::ui::error_text::type_syntax_message(&error))
}

/// Mark the Default field with the error the column holds, now and each
/// time it changes. The column outlives its row when the list builds
/// its rows again, so the handler goes with the row.
fn follow_default_error(column: &DraftColumnObject, row: &adw::EntryRow) {
    mark_invalid(row, column.default_error().as_deref());
    let weak_row = row.downgrade();
    let handler = column.connect_default_error_notify(move |column| {
        if let Some(row) = weak_row.upgrade() {
            mark_invalid(&row, column.default_error().as_deref());
        }
    });
    let guard = RefCell::new(Some(HandlerGuard::new(column, handler)));
    row.connect_destroy(move |_| drop(guard.take()));
}

/// The row of one column. Each control takes its value from the column
/// before its handler is connected, so building a row sends no edit.
pub(super) fn build_column_row(
    column: &DraftColumnObject,
    context: &StructureContext,
    sender: &StructureTabSender,
) -> adw::ExpanderRow {
    let draft = column.column();
    let permissions = context.column_permissions(&draft);
    let edits = ColumnEdits {
        column: column.downgrade(),
        sender: sender.clone(),
    };
    let row = adw::ExpanderRow::builder().use_markup(false).build();
    column.bind_property("name", &row, "title").sync_create().build();
    column.bind_property("summary", &row, "subtitle").sync_create().build();

    // On the header, so it shows whether or not the row is expanded.
    row.add_suffix(&remove_button(column, sender, &permissions.drop));
    row.add_row(&name_row(&draft, &permissions.rename, edits.clone()));
    let type_row = type_row(&draft, context, &permissions.alter_type, edits.clone());
    row.add_row(&type_row);
    if context.capabilities().column_collations {
        let (character_set_row, collation_row) =
            character_set_rows(&draft, context, &permissions.alter_collation, &edits);
        show_while_text(&type_row, &draft, context, &edits, [&character_set_row, &collation_row]);
        row.add_row(&character_set_row);
        row.add_row(&collation_row);
    }
    let nullable_row = nullable_row(&draft, &permissions.alter_nullability, edits.clone());
    row.add_row(&nullable_row);
    row.add_row(&default_row(
        column,
        &draft,
        context,
        &permissions.alter_default,
        edits.clone(),
    ));
    let (pk_row, auto_row) = key_rows(&draft, context, &permissions, &nullable_row, &edits);
    row.add_row(&pk_row);
    row.add_row(&auto_row);
    row.add_row(&comment_row(&draft, &permissions.alter_comment, edits));
    row
}

fn remove_button(column: &DraftColumnObject, sender: &StructureTabSender, permission: &Permission) -> gtk::Button {
    let remove_button = gtk::Button::builder()
        .icon_name(crate::ui::icons::USER_TRASH)
        .valign(gtk::Align::Center)
        .build();
    remove_button.add_css_class("flat");
    describe_icon_button(&remove_button, &crate::i18n::gettext("Remove Column"), None);
    remove_button.set_widget_name("col-remove");
    gate(&remove_button, permission);
    let column_for_remove = column.downgrade();
    let sender_for_remove = sender.clone();
    remove_button.connect_clicked(move |_| {
        if let Some(column) = column_for_remove.upgrade() {
            sender_for_remove.input(ColumnsInput::RemoveColumn(column));
        }
    });
    remove_button
}

fn name_row(draft: &DraftColumn, permission: &Permission, edits: ColumnEdits) -> adw::EntryRow {
    let name_row = adw::EntryRow::builder().title(crate::i18n::gettext("Name")).build();
    name_row.set_text(&draft.name);
    name_row.set_widget_name("col-name");
    gate(&name_row, permission);
    name_row.connect_changed(move |entry| edits.send(ColumnField::Name(entry.text().to_string())));
    name_row
}

/// Free text, so `decimal(10,2)` or an enum type need no list; the
/// menu only suggests.
fn type_row(
    draft: &DraftColumn,
    context: &StructureContext,
    permission: &Permission,
    edits: ColumnEdits,
) -> adw::EntryRow {
    let type_row = adw::EntryRow::builder().title(crate::i18n::gettext("Type")).build();
    type_row.set_text(draft.column_type.text());
    type_row.set_widget_name("col-type");
    // Before the gate, whose reason the tooltip has to keep.
    mark_invalid(
        &type_row,
        type_error(context.dialect.as_deref(), draft, draft.column_type.text()).as_deref(),
    );
    gate(&type_row, permission);
    let dialect_for_type = context.dialect.clone();
    type_row.connect_changed(move |entry| {
        let text = entry.text().to_string();
        let error = edits
            .column
            .upgrade()
            .and_then(|column| type_error(dialect_for_type.as_deref(), &column.column(), &text));
        mark_invalid(entry, error.as_deref());
        edits.send(ColumnField::Type(text));
    });
    if type_row.is_sensitive() {
        type_row.add_suffix(&build_type_suggestions_button(context.type_suggestions(), &type_row));
    }
    type_row
}

/// The Character Set and Collation of a column that holds text, from
/// the server's lists. A character set picked takes its default
/// collation, and the Collation row then lists only that set's.
fn character_set_rows(
    draft: &DraftColumn,
    context: &StructureContext,
    permission: &Permission,
    edits: &ColumnEdits,
) -> (adw::ComboRow, adw::ComboRow) {
    let catalog = context.character_set_catalog();
    let character_set_row = adw::ComboRow::builder()
        .title(crate::i18n::gettext("Character Set"))
        .build();
    character_set_row.set_widget_name("col-charset");
    let collation_row = adw::ComboRow::builder()
        .title(crate::i18n::gettext("Collation"))
        .build();
    collation_row.set_widget_name("col-collation");

    let edits_for_collation = edits.clone();
    let collation = ChoiceRow::new(&collation_row, move |picked| {
        edits_for_collation.send(ColumnField::Collation(picked));
    });
    collation.show(
        &collation_choices(&catalog, draft.character_set.as_deref(), draft.collation.as_deref()),
        draft.collation.as_deref(),
    );
    // A column the server gave a character set has one of its own; only
    // one that has none yet can keep following the table's.
    let table_default = draft
        .original
        .as_ref()
        .is_none_or(|original| original.attributes.character_set.is_none());
    let (edits_for_set, catalog_for_set) = (edits.clone(), catalog.clone());
    let character_set = ChoiceRow::new(&character_set_row, move |picked| {
        let default = picked
            .as_deref()
            .and_then(|name| default_collation(&catalog_for_set, name));
        collation.show(
            &collation_choices(&catalog_for_set, picked.as_deref(), default.as_deref()),
            default.as_deref(),
        );
        edits_for_set.send(ColumnField::CharacterSet {
            character_set: picked,
            collation: default,
        });
    });
    character_set.show(
        &character_set_choices(&catalog, draft.character_set.as_deref(), table_default),
        draft.character_set.as_deref(),
    );
    for row in [&character_set_row, &collation_row] {
        follow_catalog(row, &context.character_sets);
        gate(row, permission);
    }
    (character_set_row, collation_row)
}

/// `rows` show while the column's type holds text, and follow the Type
/// field as it is typed. The Type field's own handler has written the
/// type into the column by the time this one reads it.
fn show_while_text(
    type_row: &adw::EntryRow,
    draft: &DraftColumn,
    context: &StructureContext,
    edits: &ColumnEdits,
    rows: [&adw::ComboRow; 2],
) {
    let holds_text = takes_character_set(context.dialect.as_deref(), draft);
    for row in rows {
        row.set_visible(holds_text);
    }
    let (dialect, column) = (context.dialect.clone(), edits.column.clone());
    let rows = rows.map(|row| row.downgrade());
    type_row.connect_changed(move |_| {
        let Some(column) = column.upgrade() else {
            return;
        };
        let holds_text = takes_character_set(dialect.as_deref(), &column.column());
        for row in rows.iter().filter_map(glib::WeakRef::upgrade) {
            row.set_visible(holds_text);
        }
    });
}

fn nullable_row(draft: &DraftColumn, permission: &Permission, edits: ColumnEdits) -> adw::SwitchRow {
    let nullable_row = adw::SwitchRow::builder()
        .title(crate::i18n::gettext("Nullable"))
        .active(draft.nullable)
        .build();
    nullable_row.set_widget_name("col-nullable");
    gate(&nullable_row, permission);
    nullable_row.connect_active_notify(move |switch| edits.send(ColumnField::Nullable(switch.is_active())));
    nullable_row
}

/// SQL, as the engine's parser reads it: a quoted literal or an
/// expression. Empty means no DEFAULT clause. Text the parser refused
/// stays as the user typed it.
fn default_row(
    column: &DraftColumnObject,
    draft: &DraftColumn,
    context: &StructureContext,
    permission: &Permission,
    edits: ColumnEdits,
) -> adw::EntryRow {
    let default_row = adw::EntryRow::builder()
        .title(crate::i18n::gettext("Default value"))
        .build();
    let default_text = column
        .unparsed_default()
        .map_or_else(|| context.default_text(draft), |unparsed| unparsed.text);
    default_row.set_text(&default_text);
    default_row.set_widget_name("col-default");
    follow_default_error(column, &default_row);
    gate(&default_row, permission);
    default_row.connect_changed(move |entry| edits.send(ColumnField::Default(entry.text().to_string())));
    default_row
}

/// The Primary Key and Auto Increment switches. Joining the key turns
/// `nullable_row` off, and leaving it gives back what it showed before.
fn key_rows(
    draft: &DraftColumn,
    context: &StructureContext,
    permissions: &ColumnCapabilities,
    nullable_row: &adw::SwitchRow,
    edits: &ColumnEdits,
) -> (adw::SwitchRow, adw::SwitchRow) {
    let pk_row = adw::SwitchRow::builder()
        .title(crate::i18n::gettext("Primary Key"))
        .active(draft.primary_key)
        .build();
    pk_row.set_widget_name("col-pk");
    gate(&pk_row, &permissions.alter_primary_key);

    let auto_row = adw::SwitchRow::builder()
        .title(crate::i18n::gettext("Auto Increment"))
        .active(draft.auto_increment)
        .build();
    auto_row.set_widget_name("col-auto");
    // Numbering goes off with the key, on an engine that numbers only a
    // key column.
    let follows_key = !context.capabilities().auto_increment_outside_primary_key;
    match &permissions.alter_auto_increment {
        Permission::Allowed if follows_key => {
            pk_row
                .bind_property("active", &auto_row, "sensitive")
                .sync_create()
                .build();
        }
        Permission::Allowed => {}
        refused => gate(&auto_row, refused),
    }

    // A refused nullability change keeps the reason it already shows.
    let hold = permissions.alter_nullability.is_allowed();
    if hold {
        hold_not_null(nullable_row, draft.primary_key);
    }
    // Where only a key column refuses NULL, as in CQL, the switch the
    // user cannot touch follows the key.
    let nullable_follows_key = !context.capabilities().required_columns && draft.original.is_none();
    let edits_for_pk = edits.clone();
    // The row owns both switches, so this holds them weakly.
    let nullable_for_pk = nullable_row.downgrade();
    let auto_for_pk = auto_row.downgrade();
    // Given back when the column leaves the key.
    let nullable_before_key = Cell::new(draft.nullable);
    pk_row.connect_active_notify(move |switch| {
        let key = switch.is_active();
        edits_for_pk.send(ColumnField::PrimaryKey(key));
        // Each switch sends its own edit, so the column holds what the
        // row shows.
        if hold && let Some(nullable) = nullable_for_pk.upgrade() {
            if key {
                nullable_before_key.set(nullable.is_active());
                nullable.set_active(false);
            } else {
                nullable.set_active(nullable_before_key.get());
            }
            hold_not_null(&nullable, key);
        } else if nullable_follows_key && let Some(nullable) = nullable_for_pk.upgrade() {
            nullable.set_active(!key);
        }
        if !key
            && follows_key
            && let Some(auto) = auto_for_pk.upgrade()
        {
            auto.set_active(false);
        }
    });

    let edits_for_auto = edits.clone();
    auto_row.connect_active_notify(move |switch| edits_for_auto.send(ColumnField::AutoIncrement(switch.is_active())));
    (pk_row, auto_row)
}

/// Empty means the column carries no description; clearing one the
/// server had drops it.
fn comment_row(draft: &DraftColumn, permission: &Permission, edits: ColumnEdits) -> adw::EntryRow {
    let comment_row = adw::EntryRow::builder().title(crate::i18n::gettext("Comment")).build();
    comment_row.set_text(draft.comment.as_deref().unwrap_or(""));
    comment_row.set_widget_name("col-comment");
    gate(&comment_row, permission);
    comment_row.connect_changed(move |entry| {
        let text = entry.text().to_string();
        let value = if text.is_empty() { None } else { Some(text) };
        edits.send(ColumnField::Comment(value));
    });
    comment_row
}

/// A picked type is written into `target`, whose `changed` handler
/// takes it like typed text. Each button has its own action group, so
/// two columns' menus never share the `types.apply` action.
fn build_type_suggestions_button(suggestions: &'static [&'static str], target: &adw::EntryRow) -> gtk::MenuButton {
    let action_group = gio::SimpleActionGroup::new();
    let apply_action = gio::SimpleAction::new("apply", Some(&String::static_variant_type()));
    // The entry owns this button and its actions.
    let target_for_action = target.downgrade();
    apply_action.connect_activate(move |_, param| {
        if let (Some(s), Some(target)) = (param.and_then(|v| v.get::<String>()), target_for_action.upgrade()) {
            target.set_text(&s);
        }
    });
    action_group.add_action(&apply_action);

    let menu = gio::Menu::new();
    for ty in suggestions {
        let item = gio::MenuItem::new(Some(ty), None);
        item.set_action_and_target_value(Some("types.apply"), Some(&ty.to_variant()));
        menu.append_item(&item);
    }

    let button = gtk::MenuButton::builder()
        .icon_name(crate::ui::icons::PAN_DOWN)
        .valign(gtk::Align::Center)
        .menu_model(&menu)
        .build();
    button.add_css_class("flat");
    describe_icon_button(&button, &crate::i18n::gettext("Suggested Types"), None);
    button.insert_action_group("types", Some(&action_group));
    button
}
