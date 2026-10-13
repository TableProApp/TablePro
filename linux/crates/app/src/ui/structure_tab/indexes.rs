//! Index-row builder + tag widgets used by the Indexes page of the
//! Structure tab.

use gtk4 as gtk;
use libadwaita as adw;
use libadwaita::prelude::*;

use tablepro_core::IndexInfo;
use tablepro_core::meta::IndexKey;

use super::{StructureTabInput, StructureTabSender};

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
pub(super) fn build_index_row(index: usize, idx: &IndexInfo, sender: StructureTabSender) -> adw::ActionRow {
    let subtitle = index_key_summary(idx);
    let row = adw::ActionRow::builder()
        .title(glib::markup_escape_text(&idx.name))
        .subtitle(glib::markup_escape_text(&subtitle))
        .build();

    if idx.unique {
        row.add_suffix(&index_badge(&crate::i18n::gettext("UNIQUE"), "dim-label"));
    }
    if idx.primary {
        row.add_suffix(&index_badge(&crate::i18n::gettext("PRIMARY"), "accent"));
    }

    let remove_button = gtk::Button::builder()
        .icon_name(crate::ui::icons::USER_TRASH)
        .tooltip_text(crate::i18n::gettext("Remove index"))
        .valign(gtk::Align::Center)
        .build();
    remove_button.add_css_class("flat");
    // Primary index isn't user-droppable — it's owned by the PK
    // column constraint and removing it breaks the table.
    if idx.primary {
        remove_button.set_sensitive(false);
        remove_button.set_tooltip_text(Some(&crate::i18n::gettext(
            "Primary-key index can't be dropped here; clear the PK on the column.",
        )));
    }
    let sender_for_remove = sender.clone();
    remove_button.connect_clicked(move |_| sender_for_remove.input(StructureTabInput::RemoveIndex(index)));
    row.add_suffix(&remove_button);

    row
}

/// The keys an index covers, as the subtitle reads them: each column or
/// expression in key order, `DESC` where it sorts descending, and the
/// WHERE of a partial index after them.
///
/// No keys at all means the driver returned a malformed index, so the
/// subtitle says so rather than staying empty.
fn index_key_summary(index: &IndexInfo) -> String {
    if index.keys.is_empty() {
        return crate::i18n::gettext("no keys");
    }
    let keys: Vec<String> = index
        .keys
        .iter()
        .map(|key| {
            let text = match key {
                IndexKey::Column { name, .. } => name.as_str(),
                IndexKey::Expression { sql, .. } => sql.as_str(),
            };
            match key.descending() {
                true => format!("{text} DESC"),
                false => text.to_owned(),
            }
        })
        .collect();
    let keys = keys.join(", ");
    match index.predicate.as_deref() {
        Some(predicate) => format!("{keys} WHERE {predicate}"),
        None => keys,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn index(keys: Vec<IndexKey>, predicate: Option<&str>) -> IndexInfo {
        IndexInfo {
            name: "by_email".to_owned(),
            keys,
            unique: false,
            primary: false,
            predicate: predicate.map(str::to_owned),
        }
    }

    #[test]
    fn the_summary_reads_each_key_in_order_with_its_direction() {
        let summary = index_key_summary(&index(
            vec![
                IndexKey::Column {
                    name: "email".to_owned(),
                    descending: false,
                },
                IndexKey::Expression {
                    sql: "lower(name)".to_owned(),
                    descending: true,
                },
            ],
            None,
        ));

        assert_eq!(summary, "email, lower(name) DESC");
    }

    #[test]
    fn a_partial_index_shows_its_predicate() {
        let summary = index_key_summary(&index(
            vec![IndexKey::Column {
                name: "email".to_owned(),
                descending: false,
            }],
            Some("deleted_at IS NULL"),
        ));

        assert_eq!(summary, "email WHERE deleted_at IS NULL");
    }

    #[test]
    fn an_index_without_keys_says_so() {
        assert_eq!(index_key_summary(&index(Vec::new(), None)), "no keys");
    }
}
