//! The column rows of the Structure tab's Columns page.

use std::cell::{Cell, RefCell};

use gtk4 as gtk;
use gtk4::gio;
use libadwaita as adw;
use libadwaita::prelude::*;
use tablepro_core::ddl::{DraftColumn, DraftType, Permission};
use tablepro_core::dialect::SqlDialect;

use super::context::StructureContext;
use super::draft_column_object::DraftColumnObject;
use super::{ColumnField, StructureTabInput, StructureTabSender};
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
            self.sender.input(StructureTabInput::ColumnEdited { column, field });
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
fn mark_invalid(row: &adw::EntryRow, error: Option<&str>) {
    match error {
        Some(message) => {
            row.add_css_class("error");
            row.set_tooltip_text(Some(message));
            row.upcast_ref::<gtk::Widget>()
                .update_property(&[gtk::accessible::Property::Description(message)]);
        }
        None => {
            row.remove_css_class("error");
            row.set_tooltip_text(None);
            row.upcast_ref::<gtk::Widget>()
                .reset_property(gtk::AccessibleProperty::Description);
        }
    }
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
    dialect.parse_type(text).err().map(|error| error.to_string())
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
    let remove_button = gtk::Button::builder()
        .icon_name(crate::ui::icons::USER_TRASH)
        .tooltip_text(crate::i18n::gettext("Remove column"))
        .valign(gtk::Align::Center)
        .build();
    remove_button.add_css_class("flat");
    remove_button.set_widget_name("col-remove");
    gate(&remove_button, &permissions.drop);
    let column_for_remove = column.downgrade();
    let sender_for_remove = sender.clone();
    remove_button.connect_clicked(move |_| {
        if let Some(column) = column_for_remove.upgrade() {
            sender_for_remove.input(StructureTabInput::RemoveColumn(column));
        }
    });
    row.add_suffix(&remove_button);

    let name_row = adw::EntryRow::builder().title(crate::i18n::gettext("Name")).build();
    name_row.set_text(&draft.name);
    name_row.set_widget_name("col-name");
    gate(&name_row, &permissions.rename);
    let edits_for_name = edits.clone();
    name_row.connect_changed(move |entry| edits_for_name.send(ColumnField::Name(entry.text().to_string())));
    row.add_row(&name_row);

    // Free text, so `decimal(10,2)` or an enum type need no list; the
    // menu only suggests.
    let type_row = adw::EntryRow::builder().title(crate::i18n::gettext("Type")).build();
    type_row.set_text(draft.column_type.text());
    type_row.set_widget_name("col-type");
    // Before the gate, whose reason the tooltip has to keep.
    mark_invalid(
        &type_row,
        type_error(context.dialect.as_deref(), &draft, draft.column_type.text()).as_deref(),
    );
    gate(&type_row, &permissions.alter_type);
    let edits_for_type = edits.clone();
    let dialect_for_type = context.dialect.clone();
    type_row.connect_changed(move |entry| {
        let text = entry.text().to_string();
        let error = edits_for_type
            .column
            .upgrade()
            .and_then(|column| type_error(dialect_for_type.as_deref(), &column.column(), &text));
        mark_invalid(entry, error.as_deref());
        edits_for_type.send(ColumnField::Type(text));
    });
    if type_row.is_sensitive() {
        type_row.add_suffix(&build_type_suggestions_button(context.type_suggestions(), &type_row));
    }
    row.add_row(&type_row);

    let nullable_row = adw::SwitchRow::builder()
        .title(crate::i18n::gettext("Nullable"))
        .active(draft.nullable)
        .build();
    nullable_row.set_widget_name("col-nullable");
    gate(&nullable_row, &permissions.alter_nullability);
    let edits_for_null = edits.clone();
    nullable_row.connect_active_notify(move |switch| edits_for_null.send(ColumnField::Nullable(switch.is_active())));
    row.add_row(&nullable_row);

    // SQL, as the engine's parser reads it: a quoted literal or an
    // expression. Empty means no DEFAULT clause. Text the parser refused
    // stays as the user typed it.
    let default_row = adw::EntryRow::builder()
        .title(crate::i18n::gettext("Default value"))
        .build();
    let default_text = column
        .unparsed_default()
        .map_or_else(|| context.default_text(&draft), |unparsed| unparsed.text);
    default_row.set_text(&default_text);
    default_row.set_widget_name("col-default");
    follow_default_error(column, &default_row);
    gate(&default_row, &permissions.alter_default);
    let edits_for_default = edits.clone();
    default_row.connect_changed(move |entry| edits_for_default.send(ColumnField::Default(entry.text().to_string())));
    row.add_row(&default_row);

    let pk_row = adw::SwitchRow::builder()
        .title(crate::i18n::gettext("Primary key"))
        .active(draft.primary_key)
        .build();
    pk_row.set_widget_name("col-pk");
    gate(&pk_row, &permissions.alter_primary_key);

    let auto_row = adw::SwitchRow::builder()
        .title(crate::i18n::gettext("Auto increment"))
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
        hold_not_null(&nullable_row, draft.primary_key);
    }
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
        }
        if !key
            && follows_key
            && let Some(auto) = auto_for_pk.upgrade()
        {
            auto.set_active(false);
        }
    });
    row.add_row(&pk_row);

    let edits_for_auto = edits.clone();
    auto_row.connect_active_notify(move |switch| edits_for_auto.send(ColumnField::AutoIncrement(switch.is_active())));
    row.add_row(&auto_row);

    // Empty means the column carries no description; clearing one the
    // server had drops it.
    let comment_row = adw::EntryRow::builder().title(crate::i18n::gettext("Comment")).build();
    comment_row.set_text(draft.comment.as_deref().unwrap_or(""));
    comment_row.set_widget_name("col-comment");
    gate(&comment_row, &permissions.alter_comment);
    comment_row.connect_changed(move |entry| {
        let text = entry.text().to_string();
        let value = if text.is_empty() { None } else { Some(text) };
        edits.send(ColumnField::Comment(value));
    });
    row.add_row(&comment_row);

    row
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
        .tooltip_text(crate::i18n::gettext("Suggested types"))
        .valign(gtk::Align::Center)
        .menu_model(&menu)
        .build();
    button.add_css_class("flat");
    button.insert_action_group("types", Some(&action_group));
    button
}
