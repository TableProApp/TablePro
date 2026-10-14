//! The foreign key rows of the Structure tab's Foreign Keys page.

use gtk4 as gtk;
use libadwaita as adw;
use libadwaita::prelude::*;

use tablepro_core::ddl::Permission;

use super::columns::gate;
use super::foreign_key_object::ForeignKeyObject;
use super::referential_action_label::action_text;
use super::{StructureTabInput, StructureTabSender};

/// The subtitle reads the whole relationship at a glance:
/// `col_a, col_b → other_table (ref_a, ref_b)`. `drafted` is a key the
/// user added in this tab rather than one read from the table.
pub(super) fn build_fk_row(
    object: &ForeignKeyObject,
    removable: &Permission,
    drafted: bool,
    sender: &StructureTabSender,
) -> adw::ActionRow {
    let fk = object.info();
    let qualified_ref = match &fk.ref_schema {
        Some(s) if !s.is_empty() => format!("{s}.{}", fk.ref_table),
        _ => fk.ref_table.clone(),
    };
    let mut subtitle = format!(
        "{} → {qualified_ref} ({})",
        fk.columns.join(", "),
        fk.ref_columns.join(", "),
    );
    if fk.on_delete.is_some() || fk.on_update.is_some() {
        subtitle.push_str(&format!(
            " · ON DELETE {} · ON UPDATE {}",
            action_text(fk.on_delete, drafted),
            action_text(fk.on_update, drafted),
        ));
    }

    let row = adw::ActionRow::builder()
        .use_markup(false)
        .title(fk.name.as_str())
        .subtitle(subtitle)
        .build();

    let remove_button = gtk::Button::builder()
        .icon_name(crate::ui::icons::USER_TRASH)
        .valign(gtk::Align::Center)
        .build();
    remove_button.add_css_class("flat");
    crate::ui::a11y::describe_icon_button(&remove_button, &crate::i18n::gettext("Remove Foreign Key"), None);
    remove_button.set_widget_name("fk-remove");
    gate(&remove_button, removable);
    let key_for_remove = object.downgrade();
    let sender_for_remove = sender.clone();
    remove_button.connect_clicked(move |_| {
        if let Some(key) = key_for_remove.upgrade() {
            sender_for_remove.input(StructureTabInput::RemoveForeignKey(key));
        }
    });
    row.add_suffix(&remove_button);

    row
}
