use gtk4::prelude::*;
use gtk4::{gio, glib};
use tablepro_storage::ConnectionColor;
use uuid::Uuid;

pub(super) const PICKER: &str = "picker";
pub(super) const CONNECT: &str = "connect";
pub(super) const DELETE: &str = "delete";
pub(super) const DUPLICATE: &str = "duplicate";
pub(super) const NEW_GROUP: &str = "new-group";
pub(super) const SET_COLOR: &str = "set-color";
pub(super) const SET_GROUP: &str = "set-group";

/// The row's own actions: its menu, and the colour and group radios,
/// whose state is that row's connection.
pub(super) const ROW: &str = "picker-row";
pub(super) const ROW_MENU: &str = "menu";
pub(super) const ROW_COLOR: &str = "color";
pub(super) const ROW_GROUP: &str = "group";

/// The radio state standing for "no colour" or "no group". An empty
/// string rather than a missing state, because the action's parameter
/// type is a string and a radio group needs every entry to carry one.
pub(super) const NONE: &str = "";

/// One connection's menu. Every item names the connection by id, so the
/// menu acts on the row it opened on whatever the list does meanwhile.
/// Delete sits in its own section so a destructive action is never the
/// neighbour of an ordinary one.
pub(crate) fn connection_menu(id: Uuid, groups: &[String]) -> gio::Menu {
    let target = id.to_string().to_variant();
    let menu = gio::Menu::new();
    let open = gio::Menu::new();
    open.append_item(&item(&crate::i18n::gettext("Connect"), PICKER, CONNECT, &target));
    open.append_item(&item(&crate::i18n::gettext("Duplicate"), PICKER, DUPLICATE, &target));
    open.append_submenu(Some(&crate::i18n::gettext("Colour")), &color_menu());
    open.append_submenu(Some(&crate::i18n::gettext("Group")), &group_menu(&target, groups));
    menu.append_section(None, &open);
    let danger = gio::Menu::new();
    // Named as the dialog it opens names it.
    danger.append_item(&item(&crate::i18n::gettext("Delete…"), PICKER, DELETE, &target));
    menu.append_section(None, &danger);
    menu
}

fn item(label: &str, group: &str, action: &str, target: &glib::Variant) -> gio::MenuItem {
    let item = gio::MenuItem::new(Some(label), None);
    item.set_action_and_target_value(Some(&format!("{group}.{action}")), Some(target));
    item
}

/// The colour choices, as a radio group. "No Colour" leads because it
/// is the state every connection starts in.
fn color_menu() -> gio::Menu {
    let menu = gio::Menu::new();
    menu.append_item(&item(
        &crate::i18n::gettext("No Colour"),
        ROW,
        ROW_COLOR,
        &NONE.to_variant(),
    ));
    let colors = gio::Menu::new();
    for color in ConnectionColor::ALL {
        colors.append_item(&item(&color_name(color), ROW, ROW_COLOR, &color.id().to_variant()));
    }
    menu.append_section(None, &colors);
    menu
}

/// The groups already in the list, as a radio group, with a way to
/// start a new one at the end.
fn group_menu(target: &glib::Variant, groups: &[String]) -> gio::Menu {
    let menu = gio::Menu::new();
    menu.append_item(&item(
        &crate::i18n::gettext("No Group"),
        ROW,
        ROW_GROUP,
        &NONE.to_variant(),
    ));
    if !groups.is_empty() {
        let existing = gio::Menu::new();
        for group in groups {
            existing.append_item(&item(group, ROW, ROW_GROUP, &group.to_variant()));
        }
        menu.append_section(None, &existing);
    }
    let new = gio::Menu::new();
    new.append_item(&item(&crate::i18n::gettext("New Group…"), PICKER, NEW_GROUP, target));
    menu.append_section(None, &new);
    menu
}

pub(super) fn color_name(color: ConnectionColor) -> String {
    match color {
        ConnectionColor::Blue => crate::i18n::gettext("Blue"),
        ConnectionColor::Teal => crate::i18n::gettext("Teal"),
        ConnectionColor::Green => crate::i18n::gettext("Green"),
        ConnectionColor::Yellow => crate::i18n::gettext("Yellow"),
        ConnectionColor::Orange => crate::i18n::gettext("Orange"),
        ConnectionColor::Red => crate::i18n::gettext("Red"),
        ConnectionColor::Pink => crate::i18n::gettext("Pink"),
        ConnectionColor::Purple => crate::i18n::gettext("Purple"),
        ConnectionColor::Slate => crate::i18n::gettext("Slate"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Each item's label, action and target, in order, sections and
    /// submenus flattened.
    fn items(menu: &gio::MenuModel) -> Vec<(String, Option<String>, Option<glib::Variant>)> {
        let mut found = Vec::new();
        for index in 0..menu.n_items() {
            if let Some(label) = menu
                .item_attribute_value(index, "label", None)
                .and_then(|value| value.get::<String>())
            {
                let action = menu
                    .item_attribute_value(index, "action", None)
                    .and_then(|value| value.get::<String>());
                found.push((label, action, menu.item_attribute_value(index, "target", None)));
            }
            for link in ["section", "submenu"] {
                if let Some(linked) = menu.item_link(index, link) {
                    found.extend(items(&linked));
                }
            }
        }
        found
    }

    fn labels(menu: &gio::Menu) -> Vec<String> {
        items(menu.upcast_ref()).into_iter().map(|(label, ..)| label).collect()
    }

    #[test]
    fn connect_leads_and_delete_closes_the_menu() {
        let id = Uuid::new_v4();

        let found = items(connection_menu(id, &[]).upcast_ref());

        let first = found.first().expect("an item");
        assert_eq!(first.0, "Connect");
        assert_eq!(first.1.as_deref(), Some("picker.connect"));
        let last = found.last().expect("an item");
        assert_eq!(last.0, "Delete…");
        assert_eq!(last.1.as_deref(), Some("picker.delete"));
        for (label, action, target) in &found {
            if action.as_deref().is_some_and(|action| action.starts_with("picker.")) {
                assert_eq!(
                    target.as_ref().and_then(|target| target.get::<String>()),
                    Some(id.to_string()),
                    "{label} does not name the row's connection"
                );
            }
        }
    }

    #[test]
    fn the_group_menu_offers_every_group_the_list_already_has() {
        let labels = labels(&connection_menu(
            Uuid::new_v4(),
            &["Archive".to_owned(), "Work".to_owned()],
        ));

        assert!(labels.contains(&"Archive".to_owned()), "{labels:?}");
        assert!(labels.contains(&"Work".to_owned()), "{labels:?}");
        assert!(labels.contains(&"No Group".to_owned()), "{labels:?}");
        assert!(labels.contains(&"New Group…".to_owned()), "{labels:?}");
    }

    #[test]
    fn the_radio_target_tells_no_colour_apart_from_a_colour() {
        let found = items(color_menu().upcast_ref());

        let targets: Vec<String> = found
            .iter()
            .filter_map(|(_, _, target)| target.as_ref().and_then(|target| target.get::<String>()))
            .collect();
        assert_eq!(targets.first().map(String::as_str), Some(NONE));
        assert_eq!(targets.len(), ConnectionColor::ALL.len() + 1);
        assert!(targets.iter().skip(1).all(|id| ConnectionColor::from_id(id).is_some()));
    }
}
