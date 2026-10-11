//! Foreign-key row builder used by the Foreign Keys page of the
//! Structure tab.

use relm4::adw::prelude::*;
use relm4::{ComponentSender, adw, gtk};

use tablepro_core::ForeignKeyInfo;

use super::{StructureTab, StructureTabInput};

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
    sender: ComponentSender<StructureTab>,
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
    // Show ON DELETE / ON UPDATE inline so the user can read the
    // referential semantics without re-opening the row. Both fields
    // are `Option<String>` — `None` means the driver returned an
    // unrecognised value, render a dash; `Some` is the explicit
    // action chosen at create time (including "NO ACTION").
    if fk.on_delete.is_some() || fk.on_update.is_some() {
        subtitle.push_str(&format!(
            " · ON DELETE {} · ON UPDATE {}",
            fk.on_delete.as_deref().unwrap_or("—"),
            fk.on_update.as_deref().unwrap_or("—"),
        ));
    }

    let row = adw::ActionRow::builder()
        .title(glib::markup_escape_text(&fk.name))
        .subtitle(glib::markup_escape_text(&subtitle))
        .build();

    let remove_button = gtk::Button::builder()
        .icon_name("user-trash-symbolic")
        .tooltip_text(crate::tr!("Remove foreign key"))
        .valign(gtk::Align::Center)
        .build();
    remove_button.add_css_class("flat");
    if !driver_can_drop_foreign_key(driver_id) {
        remove_button.set_sensitive(false);
        remove_button.set_tooltip_text(Some(&crate::tr!("Dropping a foreign key isn't supported by SQLite.")));
    }
    let sender_for_remove = sender.clone();
    remove_button.connect_clicked(move |_| sender_for_remove.input(StructureTabInput::RemoveForeignKey(index)));
    row.add_suffix(&remove_button);

    row
}
