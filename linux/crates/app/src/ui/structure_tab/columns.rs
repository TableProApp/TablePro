//! The column rows of the Structure tab's Columns page.

use std::cell::{Cell, RefCell};
use std::rc::Rc;
use std::sync::Arc;

use gtk4 as gtk;
use gtk4::gio;
use libadwaita as adw;
use libadwaita::prelude::*;
use tablepro_core::ddl::{ColumnCapabilities, DraftColumn, DraftType, Permission};
use tablepro_core::dialect::SqlDialect;

use super::ddl_text::refusal_text;
use super::{ColumnField, StructureTabInput, StructureTabSender};

/// What a column row needs beyond the column: which changes the engine
/// allows on it, and the dialect that checks what the user types.
pub(super) struct ColumnRowContext {
    pub permissions: ColumnCapabilities,
    pub type_suggestions: &'static [&'static str],
    pub dialect: Option<Arc<dyn SqlDialect>>,
    /// The default as SQL the user could type back in, or the text they
    /// typed that did not parse.
    pub default_text: String,
    pub default_error: Option<String>,
}

/// The collapsed row's summary, such as `varchar(255) · NOT NULL ·
/// Primary key`.
fn format_column_subtitle(col: &DraftColumn) -> String {
    let mut parts: Vec<String> = Vec::new();
    let type_text = col.column_type.text();
    if !type_text.is_empty() {
        parts.push(type_text.to_owned());
    }
    parts.push(if col.nullable {
        crate::i18n::gettext("nullable")
    } else {
        crate::i18n::gettext("NOT NULL")
    });
    if col.primary_key {
        parts.push(crate::i18n::gettext("Primary key"));
    }
    if col.auto_increment {
        parts.push(crate::i18n::gettext("auto-increment"));
    }
    parts.join(" · ")
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

/// Whether the engine's parser takes `text` as one type. A catalogue
/// declaration left as it was is never parsed again.
fn type_error(dialect: Option<&dyn SqlDialect>, column: &DraftColumn, text: &str) -> Option<String> {
    let unchanged = matches!(&column.column_type, DraftType::Catalog(_)) && column.column_type.text() == text;
    if unchanged {
        return None;
    }
    let dialect = dialect?;
    dialect.parse_type(text).err().map(|error| error.to_string())
}

/// While `suppress_emit` is set, the signals GTK fires as the initial
/// values go in are not taken for edits.
pub(super) fn build_column_expander_row(
    index: usize,
    col: &DraftColumn,
    context: ColumnRowContext,
    sender: StructureTabSender,
    suppress_emit: Rc<Cell<bool>>,
    popover_registry: Rc<RefCell<Vec<gtk::Popover>>>,
) -> adw::ExpanderRow {
    let permissions = &context.permissions;
    let row = adw::ExpanderRow::builder()
        .title(glib::markup_escape_text(&col.name))
        .subtitle(glib::markup_escape_text(&format_column_subtitle(col)))
        .build();
    row.set_widget_name(&format!("col-row-{index}"));

    // On the header, so it shows whether or not the row is expanded.
    let remove_button = gtk::Button::builder()
        .icon_name(crate::ui::icons::USER_TRASH)
        .tooltip_text(crate::i18n::gettext("Remove column"))
        .valign(gtk::Align::Center)
        .build();
    remove_button.add_css_class("flat");
    remove_button.set_widget_name(&format!("col-remove-{index}"));
    gate(&remove_button, &permissions.drop);
    let sender_for_remove = sender.clone();
    remove_button.connect_clicked(move |_| sender_for_remove.input(StructureTabInput::RemoveColumn(index)));
    row.add_suffix(&remove_button);

    // The expander's title mirrors this entry live, so the collapsed
    // header always shows what the user typed.
    let name_row = adw::EntryRow::builder().title(crate::i18n::gettext("Name")).build();
    name_row.set_text(&col.name);
    name_row.set_widget_name(&format!("col-name-{index}"));
    gate(&name_row, &permissions.rename);
    let sender_for_name = sender.clone();
    let suppress_for_name = suppress_emit.clone();
    // The row owns this entry, so the entry holds the row weakly.
    let row_for_name = row.downgrade();
    name_row.connect_changed(move |e| {
        if suppress_for_name.get() {
            return;
        }
        let text = e.text().to_string();
        if let Some(row) = row_for_name.upgrade() {
            row.set_title(&glib::markup_escape_text(&text));
        }
        sender_for_name.input(StructureTabInput::ColumnEdited {
            index,
            field: ColumnField::Name(text),
        });
    });
    row.add_row(&name_row);

    // Free text, so `decimal(10,2)` or an enum type need no list; the
    // menu only suggests.
    let type_row = adw::EntryRow::builder().title(crate::i18n::gettext("Type")).build();
    type_row.set_text(col.column_type.text());
    type_row.set_widget_name(&format!("col-type-{index}"));
    gate(&type_row, &permissions.alter_type);
    mark_invalid(
        &type_row,
        type_error(context.dialect.as_deref(), col, col.column_type.text()).as_deref(),
    );
    let sender_for_type = sender.clone();
    let suppress_for_type = suppress_emit.clone();
    let dialect_for_type = context.dialect.clone();
    let column_for_type = col.clone();
    type_row.connect_changed(move |e| {
        if suppress_for_type.get() {
            return;
        }
        let text = e.text().to_string();
        mark_invalid(
            e,
            type_error(dialect_for_type.as_deref(), &column_for_type, &text).as_deref(),
        );
        sender_for_type.input(StructureTabInput::ColumnEdited {
            index,
            field: ColumnField::Type(text),
        });
    });
    if type_row.is_sensitive() {
        let (suggestions_button, suggestions_popover) =
            build_type_suggestions_button(context.type_suggestions, &type_row);
        type_row.add_suffix(&suggestions_button);
        popover_registry.borrow_mut().push(suggestions_popover);
    }
    row.add_row(&type_row);

    let nullable_row = adw::SwitchRow::builder()
        .title(crate::i18n::gettext("Nullable"))
        .active(col.nullable)
        .build();
    nullable_row.set_widget_name(&format!("col-nullable-{index}"));
    gate(&nullable_row, &permissions.alter_nullability);
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

    // SQL, as the engine's parser reads it: a quoted literal or an
    // expression. Empty means no DEFAULT clause.
    let default_row = adw::EntryRow::builder()
        .title(crate::i18n::gettext("Default value"))
        .build();
    default_row.set_text(&context.default_text);
    default_row.set_widget_name(&format!("col-default-{index}"));
    gate(&default_row, &permissions.alter_default);
    mark_invalid(&default_row, context.default_error.as_deref());
    let sender_for_default = sender.clone();
    let suppress_for_default = suppress_emit.clone();
    default_row.connect_changed(move |e| {
        if suppress_for_default.get() {
            return;
        }
        sender_for_default.input(StructureTabInput::ColumnEdited {
            index,
            field: ColumnField::Default(e.text().to_string()),
        });
    });
    row.add_row(&default_row);

    let pk_row = adw::SwitchRow::builder()
        .title(crate::i18n::gettext("Primary key"))
        .active(col.primary_key)
        .build();
    pk_row.set_widget_name(&format!("col-pk-{index}"));
    gate(&pk_row, &permissions.alter_primary_key);
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

    // A numbered column has to be a key on every engine, so the switch
    // follows the primary key's where the engine allows the change.
    let auto_row = adw::SwitchRow::builder()
        .title(crate::i18n::gettext("Auto increment"))
        .active(col.auto_increment)
        .build();
    auto_row.set_widget_name(&format!("col-auto-{index}"));
    match &permissions.alter_auto_increment {
        Permission::Allowed => {
            auto_row.set_sensitive(col.primary_key);
            pk_row
                .bind_property("active", &auto_row, "sensitive")
                .sync_create()
                .build();
        }
        refused => gate(&auto_row, refused),
    }
    let sender_for_auto = sender.clone();
    let suppress_for_auto = suppress_emit.clone();
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

    // Empty means the column carries no description; clearing one the
    // server had drops it.
    let comment_row = adw::EntryRow::builder().title(crate::i18n::gettext("Comment")).build();
    comment_row.set_text(col.comment.as_deref().unwrap_or(""));
    comment_row.set_widget_name(&format!("col-comment-{index}"));
    gate(&comment_row, &permissions.alter_comment);
    let sender_for_comment = sender;
    let suppress_for_comment = suppress_emit;
    comment_row.connect_changed(move |e| {
        if suppress_for_comment.get() {
            return;
        }
        let text = e.text().to_string();
        let value = if text.is_empty() { None } else { Some(text) };
        sender_for_comment.input(StructureTabInput::ColumnEdited {
            index,
            field: ColumnField::Comment(value),
        });
    });
    row.add_row(&comment_row);

    row
}

/// A picked type is written into `target`, whose `changed` handler
/// takes it like typed text. Each button has its own action group, so
/// two columns' menus never share the `types.apply` action.
///
/// The popover comes back too, to be popped down before its row goes.
fn build_type_suggestions_button(
    suggestions: &'static [&'static str],
    target: &adw::EntryRow,
) -> (gtk::MenuButton, gtk::Popover) {
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
        .build();
    button.add_css_class("flat");
    button.insert_action_group("types", Some(&action_group));
    let popover = gtk::PopoverMenu::from_model(Some(&menu));
    button.set_popover(Some(&popover));
    (button, popover.upcast())
}
