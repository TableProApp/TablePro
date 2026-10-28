use gtk4::prelude::*;
use gtk4::{gio, glib};
use tablepro_storage::{ConnectionColor, ConnectionGroupName, ConnectionTag};
use uuid::Uuid;

use crate::ui::connection_appearance::color_name;
use crate::ui::menu_label;

pub(super) const PICKER: &str = "picker";
pub(super) const CONNECT: &str = "connect";
pub(super) const EDIT: &str = "edit";
pub(super) const DELETE: &str = "delete";
pub(super) const DUPLICATE: &str = "duplicate";
pub(super) const NEW_GROUP: &str = "new-group";
pub(super) const SET_COLOR: &str = "set-color";
pub(super) const MOVE_TO_GROUP: &str = "move-to-group";
pub(super) const NEW_TAG: &str = "new-tag";
pub(super) const SET_TAG: &str = "set-tag";
/// The window's, since the picker's primary menu offers it too.
pub(crate) const MANAGE_TAGS: &str = "win.manage-tags";

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

/// The row's check action for one tag.
pub(super) fn tag_action(tag: Uuid) -> String {
    format!("tag-{tag}")
}

/// The action that connects to the saved connection `id`, and its target.
pub(crate) fn connect_action(id: Uuid) -> (String, glib::Variant) {
    (format!("{PICKER}.{CONNECT}"), id.to_string().to_variant())
}

/// The Connect item of the connection `id`'s menu.
pub(crate) fn connect_item(id: Uuid) -> gio::MenuItem {
    item(
        &crate::i18n::gettext("Connect"),
        PICKER,
        CONNECT,
        &id.to_string().to_variant(),
    )
}

/// One connection's menu. Every item names the connection by id, so the
/// menu acts on the row it opened on whatever the list does meanwhile.
/// Delete sits in its own section so a destructive action is never the
/// neighbour of an ordinary one.
pub(crate) fn connection_menu(id: Uuid, groups: &[ConnectionGroupName], tags: &[ConnectionTag]) -> gio::Menu {
    let open = gio::Menu::new();
    open.append_item(&connect_item(id));
    connection_menu_with(&open, id, groups, tags)
}

/// `connection_menu` with `lead` in place of its Connect section, as the
/// window's tree leads with what a connection open or connecting there
/// offers.
pub(crate) fn connection_menu_with(
    lead: &gio::Menu,
    id: Uuid,
    groups: &[ConnectionGroupName],
    tags: &[ConnectionTag],
) -> gio::Menu {
    let target = id.to_string().to_variant();
    let menu = gio::Menu::new();
    menu.append_section(None, lead);
    let change = gio::Menu::new();
    change.append_item(&item(&crate::i18n::gettext("Edit…"), PICKER, EDIT, &target));
    change.append_item(&item(&crate::i18n::gettext("Duplicate"), PICKER, DUPLICATE, &target));
    menu.append_section(None, &change);
    let file = gio::Menu::new();
    file.append_submenu(Some(&crate::i18n::gettext("Colour")), &color_menu());
    file.append_submenu(Some(&crate::i18n::gettext("Tags")), &tag_menu(&target, tags));
    file.append_submenu(
        Some(&crate::i18n::gettext("Move to Group")),
        &group_menu(&target, groups),
    );
    menu.append_section(None, &file);
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

/// The groups already in the list, as a radio group ticked at the one
/// the connection is in, with a way to start a new one at the end.
fn group_menu(target: &glib::Variant, groups: &[ConnectionGroupName]) -> gio::Menu {
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
            existing.append_item(&item(
                &menu_label(group.as_str()),
                ROW,
                ROW_GROUP,
                &group.as_str().to_variant(),
            ));
        }
        menu.append_section(None, &existing);
    }
    let new = gio::Menu::new();
    new.append_item(&item(&crate::i18n::gettext("New Group…"), PICKER, NEW_GROUP, target));
    menu.append_section(None, &new);
    menu
}

/// Every tag as a check item ticked at the ones the connection has,
/// then a way to make one and to change them all.
fn tag_menu(target: &glib::Variant, tags: &[ConnectionTag]) -> gio::Menu {
    let menu = gio::Menu::new();
    if !tags.is_empty() {
        let existing = gio::Menu::new();
        for tag in tags {
            existing.append_item(&gio::MenuItem::new(
                Some(&menu_label(tag.name.as_str())),
                Some(&format!("{ROW}.{}", tag_action(tag.id))),
            ));
        }
        menu.append_section(None, &existing);
    }
    let change = gio::Menu::new();
    change.append_item(&item(&crate::i18n::gettext("New Tag…"), PICKER, NEW_TAG, target));
    change.append_item(&gio::MenuItem::new(
        Some(&crate::i18n::gettext("Manage Tags…")),
        Some(MANAGE_TAGS),
    ));
    menu.append_section(None, &change);
    menu
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

        let found = items(connection_menu(id, &[], &[]).upcast_ref());

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

    fn group(name: &str) -> ConnectionGroupName {
        ConnectionGroupName::new(name).expect("a group name")
    }

    #[test]
    fn the_menu_reads_connect_edit_duplicate_colour_tags_group_delete() {
        let labels = labels(&connection_menu(Uuid::new_v4(), &[], &[]));
        let shown = |label: &str| {
            labels
                .iter()
                .position(|candidate| candidate == label)
                .unwrap_or_else(|| panic!("{label} is missing: {labels:?}"))
        };

        let order = [
            shown("Connect"),
            shown("Edit…"),
            shown("Duplicate"),
            shown("Colour"),
            shown("Tags"),
            shown("Move to Group"),
            shown("Delete…"),
        ];

        assert!(order.windows(2).all(|pair| pair[0] < pair[1]), "{labels:?}");
    }

    #[test]
    fn a_lead_section_takes_the_place_of_connect() {
        let id = Uuid::new_v4();
        let lead = gio::Menu::new();
        lead.append(Some("Disconnect"), Some("win.disconnect-session"));

        let labels = labels(&connection_menu_with(&lead, id, &[], &[]));

        assert_eq!(labels.first().map(String::as_str), Some("Disconnect"));
        assert!(!labels.contains(&"Connect".to_owned()), "{labels:?}");
        assert_eq!(labels.last().map(String::as_str), Some("Delete…"));
        let (action, target) = connect_action(id);
        assert_eq!(action, "picker.connect");
        assert_eq!(target.get::<String>(), Some(id.to_string()));
    }

    #[test]
    fn the_group_menu_offers_every_group_the_list_already_has() {
        let labels = labels(&connection_menu(
            Uuid::new_v4(),
            &[group("Archive"), group("Work")],
            &[],
        ));

        assert!(labels.contains(&"Archive".to_owned()), "{labels:?}");
        assert!(labels.contains(&"Work".to_owned()), "{labels:?}");
        assert!(labels.contains(&"No Group".to_owned()), "{labels:?}");
        assert!(labels.contains(&"New Group…".to_owned()), "{labels:?}");
    }

    #[test]
    fn a_group_name_keeps_its_underscores_in_the_menu() {
        let found = items(connection_menu(Uuid::new_v4(), &[group("dev_db")], &[]).upcast_ref());

        let group = found
            .iter()
            .find(|(_, _, target)| {
                target.as_ref().and_then(|target| target.get::<String>()).as_deref() == Some("dev_db")
            })
            .expect("the group's item");
        assert_eq!(group.0, "dev__db");
    }

    #[test]
    fn the_tags_menu_offers_each_tag_then_new_and_manage() {
        let id = Uuid::new_v4();
        let tag = ConnectionTag::new(
            tablepro_storage::ConnectionTagName::new("dev_prod").expect("a tag name"),
            ConnectionColor::Red,
        );

        let found = items(connection_menu(id, &[], std::slice::from_ref(&tag)).upcast_ref());

        let check = found
            .iter()
            .find(|(label, ..)| label == "dev__prod")
            .expect("the tag's item");
        assert_eq!(check.1.as_deref(), Some(format!("picker-row.tag-{}", tag.id).as_str()));
        assert_eq!(check.2, None, "a check item carries no target");
        let new = found.iter().find(|(label, ..)| label == "New Tag…").expect("New Tag…");
        assert_eq!(new.1.as_deref(), Some("picker.new-tag"));
        let manage = found
            .iter()
            .find(|(label, ..)| label == "Manage Tags…")
            .expect("Manage Tags…");
        assert_eq!(manage.1.as_deref(), Some(MANAGE_TAGS));
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
