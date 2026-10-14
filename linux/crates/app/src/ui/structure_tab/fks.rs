//! The foreign key rows of the Structure tab's Foreign Keys page.

use gtk4 as gtk;
use libadwaita as adw;
use libadwaita::prelude::*;

use tablepro_core::ddl::{Permission, ReferentialAction};

use super::columns::gate;
use super::foreign_key_object::ForeignKeyObject;
use super::{StructureTabInput, StructureTabSender};

/// The subtitle reads the whole relationship at a glance:
/// `col_a, col_b → other_table (ref_a, ref_b)`.
pub(super) fn build_fk_row(
    object: &ForeignKeyObject,
    removable: &Permission,
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
    // `None` is an action this build does not know, so it says so rather
    // than claiming the default it may not be.
    if fk.on_delete.is_some() || fk.on_update.is_some() {
        subtitle.push_str(&format!(
            " · ON DELETE {} · ON UPDATE {}",
            action_text(fk.on_delete),
            action_text(fk.on_update),
        ));
    }

    let row = adw::ActionRow::builder()
        .use_markup(false)
        .title(fk.name.as_str())
        .subtitle(subtitle)
        .build();

    let remove_button = gtk::Button::builder()
        .icon_name(crate::ui::icons::USER_TRASH)
        .tooltip_text(crate::i18n::gettext("Remove foreign key"))
        .valign(gtk::Align::Center)
        .build();
    remove_button.add_css_class("flat");
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

fn action_text(action: Option<ReferentialAction>) -> String {
    action.map_or_else(
        || crate::i18n::gettext("not reported"),
        |action| action.as_sql().to_owned(),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_unknown_action_says_it_was_not_reported() {
        assert_eq!(action_text(Some(ReferentialAction::SetNull)), "SET NULL");
        assert_eq!(action_text(None), "not reported");
    }
}
