//! The index rows of the Structure tab's Indexes page.

use gtk4 as gtk;
use gtk4::gio;
use libadwaita as adw;
use libadwaita::prelude::*;

use tablepro_core::IndexInfo;
use tablepro_core::ddl::Permission;
use tablepro_core::meta::IndexKey;

use super::columns::gate;
use super::index_object::IndexObject;
use super::{IndexesInput, StructureTabSender};

fn index_badge(label: &str, accent_class: &str) -> gtk::Label {
    let badge = gtk::Label::builder().label(label).valign(gtk::Align::Center).build();
    badge.add_css_class("caption");
    badge.add_css_class(accent_class);
    badge
}

pub(super) fn build_index_row(
    object: &IndexObject,
    removable: &Permission,
    sender: &StructureTabSender,
) -> adw::ActionRow {
    let idx = object.info();
    let row = adw::ActionRow::builder()
        .use_markup(false)
        .title(idx.name.as_str())
        .subtitle(index_key_summary(idx))
        .build();

    if idx.unique {
        row.add_suffix(&index_badge(&crate::i18n::gettext("UNIQUE"), "dim-label"));
    }
    if idx.primary {
        row.add_suffix(&index_badge(&crate::i18n::gettext("PRIMARY"), "accent"));
    }

    let remove_button = gtk::Button::builder()
        .icon_name(crate::ui::icons::USER_TRASH)
        .valign(gtk::Align::Center)
        .build();
    remove_button.add_css_class("flat");
    crate::ui::a11y::describe_icon_button(&remove_button, &crate::i18n::gettext("Remove Index"), None);
    remove_button.set_widget_name("index-remove");
    // The primary key's constraint owns its index.
    if idx.primary {
        remove_button.set_sensitive(false);
        remove_button.set_tooltip_text(Some(&crate::i18n::gettext(
            "Primary-key index can't be dropped here; clear the PK on the column.",
        )));
    } else {
        gate(&remove_button, removable);
    }
    let index_for_remove = object.downgrade();
    let sender_for_remove = sender.clone();
    remove_button.connect_clicked(move |_| {
        if let Some(index) = index_for_remove.upgrade() {
            sender_for_remove.input(IndexesInput::RemoveIndex(index));
        }
    });
    row.add_suffix(&remove_button);

    if idx.definition.is_some() {
        row.add_suffix(&statement_menu(object, sender));
    }

    row
}

/// Show and copy the statement that creates the index, which only an
/// index the table already has carries.
fn statement_menu(object: &IndexObject, sender: &StructureTabSender) -> gtk::MenuButton {
    let menu = gio::Menu::new();
    menu.append(
        Some(&crate::i18n::gettext("Show _CREATE INDEX")),
        Some("index.show-create"),
    );
    menu.append(
        Some(&crate::i18n::gettext("_Copy CREATE INDEX")),
        Some("index.copy-create"),
    );
    let actions = gio::SimpleActionGroup::new();
    let entry = |name: &str, message: fn(IndexObject) -> IndexesInput| {
        let (index, sender) = (object.downgrade(), sender.clone());
        gio::ActionEntry::<gio::SimpleActionGroup>::builder(name)
            .activate(move |_, _, _| {
                if let Some(index) = index.upgrade() {
                    sender.input(message(index));
                }
            })
            .build()
    };
    actions.add_action_entries([
        entry("show-create", IndexesInput::ShowStatement),
        entry("copy-create", IndexesInput::CopyStatement),
    ]);
    let button = gtk::MenuButton::builder()
        .icon_name(crate::ui::icons::VIEW_MORE)
        .valign(gtk::Align::Center)
        .menu_model(&menu)
        .build();
    button.add_css_class("flat");
    crate::ui::a11y::describe_icon_button(&button, &crate::i18n::gettext("Index Options"), None);
    button.set_widget_name("index-statement");
    button.insert_action_group("index", Some(&actions));
    button
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
            definition: None,
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
