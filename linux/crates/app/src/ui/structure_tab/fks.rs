//! Foreign-key row builder used by the Foreign Keys page of the
//! Structure tab.

use gtk4 as gtk;
use libadwaita as adw;
use libadwaita::prelude::*;

use tablepro_core::ForeignKeyInfo;
use tablepro_core::ddl::ReferentialAction;

use super::{StructureTabInput, StructureTabSender};

fn driver_can_drop_foreign_key(driver_id: &str) -> bool {
    !matches!(driver_id, "sqlite")
}

/// Foreign-key row as a native `AdwActionRow`. Subtitle encodes both
/// local columns and the reference target so users see the full
/// relationship in a glance: `col_a, col_b → other_table (ref_a, ref_b)`.
pub(super) fn build_fk_row(
    index: usize,
    fk: &ForeignKeyInfo,
    driver_id: &str,
    sender: StructureTabSender,
) -> adw::ActionRow {
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
        .title(glib::markup_escape_text(&fk.name))
        .subtitle(glib::markup_escape_text(&subtitle))
        .build();

    let remove_button = gtk::Button::builder()
        .icon_name(crate::ui::icons::USER_TRASH)
        .tooltip_text(crate::i18n::gettext("Remove foreign key"))
        .valign(gtk::Align::Center)
        .build();
    remove_button.add_css_class("flat");
    if !driver_can_drop_foreign_key(driver_id) {
        remove_button.set_sensitive(false);
        remove_button.set_tooltip_text(Some(&crate::i18n::gettext(
            "Dropping a foreign key isn't supported by SQLite.",
        )));
    }
    let sender_for_remove = sender.clone();
    remove_button.connect_clicked(move |_| sender_for_remove.input(StructureTabInput::RemoveForeignKey(index)));
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
