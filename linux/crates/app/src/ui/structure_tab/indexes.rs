//! Index-row builder + tag widgets used by the Indexes page of the
//! Structure tab.

use relm4::adw::prelude::*;
use relm4::{ComponentSender, adw, gtk};

use tablepro_core::IndexInfo;

use super::{StructureTab, StructureTabInput};

/// Tiny inline pill rendered as an AdwActionRow suffix — used by the
/// indexes list to show UNIQUE / PRIMARY tags. `accent_class` is the
/// CSS class controlling the colour (`dim-label`, `accent`, etc.).
fn index_badge(label: &str, accent_class: &str) -> gtk::Label {
    let badge = gtk::Label::builder().label(label).valign(gtk::Align::Center).build();
    badge.add_css_class("caption");
    badge.add_css_class(accent_class);
    badge
}

/// Index row as a native `AdwActionRow` — title is the index name,
/// subtitle is the comma-separated column list. UNIQUE / PRIMARY are
/// small caption suffixes, the trash button is an end-suffix. The row
/// participates in `boxed-list` styling for free; no manual margins.
pub(super) fn build_index_row(index: usize, idx: &IndexInfo, sender: ComponentSender<StructureTab>) -> adw::ActionRow {
    // Empty columns array means the driver returned a malformed index
    // (corrupt catalog or driver bug). Render a dim "—" subtitle so
    // the user sees something rather than an empty cell.
    let subtitle = if idx.columns.is_empty() {
        "—".to_string()
    } else {
        idx.columns.join(", ")
    };
    let row = adw::ActionRow::builder()
        .title(glib::markup_escape_text(&idx.name))
        .subtitle(glib::markup_escape_text(&subtitle))
        .build();

    if idx.unique {
        row.add_suffix(&index_badge(&crate::tr!("UNIQUE"), "dim-label"));
    }
    if idx.primary {
        row.add_suffix(&index_badge(&crate::tr!("PRIMARY"), "accent"));
    }

    let remove_button = gtk::Button::builder()
        .icon_name("user-trash-symbolic")
        .tooltip_text(crate::tr!("Remove index"))
        .valign(gtk::Align::Center)
        .build();
    remove_button.add_css_class("flat");
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
    row.add_suffix(&remove_button);

    row
}
