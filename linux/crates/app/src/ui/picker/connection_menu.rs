use gtk4::prelude::*;
use gtk4::{gio, glib};
use tablepro_storage::{ConnectionColor, ConnectionTag};
use uuid::Uuid;

use crate::services::library_outline::{LibraryOutline, LibrarySection};
use crate::ui::connection_appearance::color_menu_label;
use crate::ui::menu_label;

pub(super) const PICKER: &str = "picker";
pub(super) const CONNECT: &str = "connect";
pub(super) const EDIT: &str = "edit";
pub(super) const DELETE: &str = "delete";
pub(super) const DUPLICATE: &str = "duplicate";
pub(super) const NEW_GROUP: &str = "new-group";
pub(super) const NEW_GROUP_FOR: &str = "new-group-for";
pub(super) const RENAME_GROUP: &str = "rename-group";
pub(super) const DELETE_GROUP: &str = "delete-group";
pub(super) const CHANGE_LIBRARY: &str = "change-library";
pub(super) const SET_FAVOURITE: &str = "set-favourite";
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
pub(super) const ROW_MOVE_UP: &str = "move-up";
pub(super) const ROW_MOVE_DOWN: &str = "move-down";
pub(super) const ROW_PARENT: &str = "parent";

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
        &crate::i18n::gettext("_Connect"),
        PICKER,
        CONNECT,
        &id.to_string().to_variant(),
    )
}

// Every item names the connection by id, so the menu acts on the row it opened on whatever the list does meanwhile.
pub(crate) fn connection_menu(
    id: Uuid,
    section: LibrarySection,
    outline: &LibraryOutline,
    tags: &[ConnectionTag],
) -> gio::Menu {
    let open = gio::Menu::new();
    open.append_item(&connect_item(id));
    connection_menu_with(&open, id, section, outline, tags)
}

pub(crate) fn connection_menu_with(
    lead: &gio::Menu,
    id: Uuid,
    section: LibrarySection,
    outline: &LibraryOutline,
    tags: &[ConnectionTag],
) -> gio::Menu {
    let target = id.to_string().to_variant();
    let menu = gio::Menu::new();
    menu.append_section(None, lead);
    let change = gio::Menu::new();
    change.append_item(&item(&crate::i18n::gettext("_Edit…"), PICKER, EDIT, &target));
    change.append_item(&item(&crate::i18n::gettext("D_uplicate"), PICKER, DUPLICATE, &target));
    menu.append_section(None, &change);
    let file = gio::Menu::new();
    file.append_item(&favourite_item(id, outline.favourites().contains(&id)));
    file.append_submenu(Some(&crate::i18n::gettext("Colou_r")), &color_menu());
    file.append_submenu(Some(&crate::i18n::gettext("Tag_s")), &tag_menu(&target, tags));
    file.append_submenu(
        Some(&crate::i18n::gettext("_Move to Group")),
        &move_to_group_menu(&target, outline),
    );
    menu.append_section(None, &file);
    // Recent is ordered by the last connect, which a move cannot change.
    if section != LibrarySection::Recent {
        menu.append_section(None, &order_section());
    }
    let danger = gio::Menu::new();
    // Named as the dialog it opens names it.
    danger.append_item(&item(&crate::i18n::gettext("Dele_te…"), PICKER, DELETE, &target));
    menu.append_section(None, &danger);
    menu
}

pub(super) fn item(label: &str, group: &str, action: &str, target: &glib::Variant) -> gio::MenuItem {
    let item = gio::MenuItem::new(Some(label), None);
    item.set_action_and_target_value(Some(&format!("{group}.{action}")), Some(target));
    item
}

// One item whose label says what it will do, as a check item would not.
fn favourite_item(id: Uuid, favourite: bool) -> gio::MenuItem {
    let label = if favourite {
        crate::i18n::gettext("Remove from F_avourites")
    } else {
        crate::i18n::gettext("_Add to Favourites")
    };
    item(
        &label,
        PICKER,
        SET_FAVOURITE,
        &(id.to_string(), !favourite).to_variant(),
    )
}

pub(super) fn order_section() -> gio::Menu {
    let order = gio::Menu::new();
    order.append(
        Some(&crate::i18n::gettext("Move U_p")),
        Some(&format!("{ROW}.{ROW_MOVE_UP}")),
    );
    order.append(
        Some(&crate::i18n::gettext("Move Do_wn")),
        Some(&format!("{ROW}.{ROW_MOVE_DOWN}")),
    );
    order
}

/// The colour choices, as a radio group. "No Colour" leads because it
/// is the state every connection starts in.
fn color_menu() -> gio::Menu {
    let menu = gio::Menu::new();
    menu.append_item(&item(
        &crate::i18n::gettext("_No Colour"),
        ROW,
        ROW_COLOR,
        &NONE.to_variant(),
    ));
    let colors = gio::Menu::new();
    for color in ConnectionColor::ALL {
        colors.append_item(&item(
            &color_menu_label(color),
            ROW,
            ROW_COLOR,
            &color.id().to_variant(),
        ));
    }
    menu.append_section(None, &colors);
    menu
}

// Each group by its path, so two groups of one name in different places read apart.
fn move_to_group_menu(target: &glib::Variant, outline: &LibraryOutline) -> gio::Menu {
    let menu = gio::Menu::new();
    menu.append_item(&item(
        &crate::i18n::gettext("_No Group"),
        ROW,
        ROW_GROUP,
        &NONE.to_variant(),
    ));
    let groups = outline.groups();
    if !groups.is_empty() {
        let existing = gio::Menu::new();
        for (id, label, _) in groups {
            existing.append_item(&item(&menu_label(&label), ROW, ROW_GROUP, &id.to_string().to_variant()));
        }
        menu.append_section(None, &existing);
    }
    let new = gio::Menu::new();
    new.append_item(&item(
        &crate::i18n::gettext("New _Group…"),
        PICKER,
        NEW_GROUP_FOR,
        target,
    ));
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
    change.append_item(&item(&crate::i18n::gettext("_New Tag…"), PICKER, NEW_TAG, target));
    change.append_item(&gio::MenuItem::new(
        Some(&crate::i18n::gettext("_Manage Tags…")),
        Some(MANAGE_TAGS),
    ));
    menu.append_section(None, &change);
    menu
}

#[cfg(test)]
pub(super) mod tests {
    use tablepro_storage::{ConnectionGroup, ConnectionGroupName, ConnectionList, SavedConnection};

    use super::*;
    use crate::test_support::assert_access_keys;

    /// Each item's label, action and target, in order, sections and
    /// submenus flattened.
    pub(in crate::ui::picker) fn items(menu: &gio::MenuModel) -> Vec<(String, Option<String>, Option<glib::Variant>)> {
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

    pub(in crate::ui::picker) fn labels(menu: &gio::Menu) -> Vec<String> {
        items(menu.upcast_ref()).into_iter().map(|(label, ..)| label).collect()
    }

    pub(in crate::ui::picker) fn saved(group: Option<Uuid>) -> SavedConnection {
        SavedConnection {
            group_id: group,
            ..crate::ui::session_window::tests::saved_connection(std::path::Path::new("app.db"))
        }
    }

    pub(in crate::ui::picker) fn group(name: &str, parent: Option<Uuid>) -> ConnectionGroup {
        ConnectionGroup::new(ConnectionGroupName::new(name).expect("a group name"), parent)
    }

    pub(in crate::ui::picker) fn outline(
        connections: Vec<SavedConnection>,
        groups: Vec<ConnectionGroup>,
        favourites: Vec<Uuid>,
    ) -> LibraryOutline {
        LibraryOutline::new(
            &ConnectionList::new(connections, Vec::<ConnectionTag>::new())
                .with_groups(groups)
                .with_favorites(favourites),
        )
    }

    fn empty() -> LibraryOutline {
        outline(Vec::new(), Vec::new(), Vec::new())
    }

    fn target_string(target: Option<&glib::Variant>) -> Option<String> {
        target.and_then(|target| target.get::<String>())
    }

    #[test]
    fn connect_leads_and_delete_closes_the_menu() {
        let id = Uuid::new_v4();

        let found = items(connection_menu(id, LibrarySection::Tree, &empty(), &[]).upcast_ref());

        let first = found.first().expect("an item");
        assert_eq!(first.0, "_Connect");
        assert_eq!(first.1.as_deref(), Some("picker.connect"));
        let last = found.last().expect("an item");
        assert_eq!(last.0, "Dele_te…");
        assert_eq!(last.1.as_deref(), Some("picker.delete"));
        for (label, action, target) in &found {
            if action.as_deref().is_some_and(|action| action.starts_with("picker.")) {
                // Set Favourite carries the state it sets beside the id.
                let named = target_string(target.as_ref()).or_else(|| {
                    target
                        .as_ref()
                        .and_then(|target| target.get::<(String, bool)>())
                        .map(|(id, _)| id)
                });
                assert_eq!(
                    named,
                    Some(id.to_string()),
                    "{label} does not name the row's connection"
                );
            }
        }
    }

    #[test]
    fn every_item_has_an_access_key_of_its_own() {
        let saved = saved(None);
        let favourite = outline(vec![saved.clone()], Vec::new(), vec![saved.id]);
        let plain = outline(vec![saved.clone()], Vec::new(), Vec::new());

        for (section, outline) in [
            (LibrarySection::Tree, &plain),
            (LibrarySection::Tree, &favourite),
            (LibrarySection::Favourites, &favourite),
            (LibrarySection::Recent, &plain),
        ] {
            assert_access_keys(&connection_menu(saved.id, section, outline, &[]));
        }
    }

    #[test]
    fn the_menu_reads_connect_edit_duplicate_favourite_colour_tags_group_order_delete() {
        let labels = labels(&connection_menu(Uuid::new_v4(), LibrarySection::Tree, &empty(), &[]));
        let shown = |label: &str| {
            labels
                .iter()
                .position(|candidate| candidate == label)
                .unwrap_or_else(|| panic!("{label} is missing: {labels:?}"))
        };

        let order = [
            shown("_Connect"),
            shown("_Edit…"),
            shown("D_uplicate"),
            shown("_Add to Favourites"),
            shown("Colou_r"),
            shown("Tag_s"),
            shown("_Move to Group"),
            shown("Move U_p"),
            shown("Move Do_wn"),
            shown("Dele_te…"),
        ];

        assert!(order.windows(2).all(|pair| pair[0] < pair[1]), "{labels:?}");
    }

    #[test]
    fn a_lead_section_takes_the_place_of_connect() {
        let id = Uuid::new_v4();
        let lead = gio::Menu::new();
        lead.append(Some("Disconnect"), Some("win.disconnect-session"));

        let labels = labels(&connection_menu_with(&lead, id, LibrarySection::Tree, &empty(), &[]));

        assert_eq!(labels.first().map(String::as_str), Some("Disconnect"));
        assert!(!labels.contains(&"_Connect".to_owned()), "{labels:?}");
        assert_eq!(labels.last().map(String::as_str), Some("Dele_te…"));
        let (action, target) = connect_action(id);
        assert_eq!(action, "picker.connect");
        assert_eq!(target.get::<String>(), Some(id.to_string()));
    }

    #[test]
    fn move_to_group_offers_every_group_by_its_path_in_walk_order() {
        let archive = group("Archive", None);
        let work = group("Work", None);
        let staging = group("Staging", Some(work.id));
        let empty = group("Empty", None);
        let saved = saved(Some(staging.id));
        let outline = outline(
            vec![saved.clone()],
            vec![archive.clone(), work.clone(), staging.clone(), empty.clone()],
            Vec::new(),
        );

        let found = items(connection_menu(saved.id, LibrarySection::Tree, &outline, &[]).upcast_ref());

        let picks: Vec<(String, Option<String>)> = found
            .iter()
            .filter(|(_, action, _)| action.as_deref() == Some("picker-row.group"))
            .map(|(label, _, target)| (label.clone(), target_string(target.as_ref())))
            .collect();
        let mut expected = vec![("_No Group".to_owned(), Some(NONE.to_owned()))];
        expected.extend(
            outline
                .groups()
                .into_iter()
                .map(|(id, label, _)| (label, Some(id.to_string()))),
        );
        assert_eq!(picks, expected);
        for shown in [&archive, &work, &staging, &empty] {
            assert!(
                picks.iter().any(|(_, target)| *target == Some(shown.id.to_string())),
                "{} is missing: {picks:?}",
                shown.name.as_str()
            );
        }
        assert!(picks.iter().any(|(label, _)| label == "Work / Staging"), "{picks:?}");
        let new = found
            .iter()
            .find(|(label, ..)| label == "New _Group…")
            .expect("New Group…");
        assert_eq!(new.1.as_deref(), Some("picker.new-group-for"));
        assert_eq!(target_string(new.2.as_ref()), Some(saved.id.to_string()));
    }

    #[test]
    fn two_groups_with_one_path_stay_two_items() {
        let work = group("Work", None);
        let staging = group("Staging", Some(work.id));
        let lookalike = group("Work / Staging", None);
        let outline = outline(Vec::new(), vec![work, staging.clone(), lookalike.clone()], Vec::new());

        let found = items(connection_menu(Uuid::new_v4(), LibrarySection::Tree, &outline, &[]).upcast_ref());

        let targets: Vec<Option<String>> = found
            .iter()
            .filter(|(label, action, _)| label == "Work / Staging" && action.as_deref() == Some("picker-row.group"))
            .map(|(_, _, target)| target_string(target.as_ref()))
            .collect();
        assert_eq!(targets.len(), 2, "{found:?}");
        assert!(targets.contains(&Some(staging.id.to_string())));
        assert!(targets.contains(&Some(lookalike.id.to_string())));
    }

    #[test]
    fn a_group_name_keeps_its_underscores_in_the_menu() {
        let dev = group("dev_db", None);
        let outline = outline(Vec::new(), vec![dev.clone()], Vec::new());

        let found = items(connection_menu(Uuid::new_v4(), LibrarySection::Tree, &outline, &[]).upcast_ref());

        let item = found
            .iter()
            .find(|(_, _, target)| target_string(target.as_ref()) == Some(dev.id.to_string()))
            .expect("the group's item");
        assert_eq!(item.0, "dev__db");
    }

    #[test]
    fn the_favourite_item_says_what_it_will_do() {
        let saved = saved(None);
        let favourite = |outline: &LibraryOutline| {
            items(connection_menu(saved.id, LibrarySection::Tree, outline, &[]).upcast_ref())
                .into_iter()
                .filter(|(_, action, _)| action.as_deref() == Some("picker.set-favourite"))
                .map(|(label, _, target)| (label, target.and_then(|target| target.get::<(String, bool)>())))
                .collect::<Vec<_>>()
        };

        assert_eq!(
            favourite(&outline(vec![saved.clone()], Vec::new(), Vec::new())),
            [("_Add to Favourites".to_owned(), Some((saved.id.to_string(), true)))]
        );
        assert_eq!(
            favourite(&outline(vec![saved.clone()], Vec::new(), vec![saved.id])),
            [(
                "Remove from F_avourites".to_owned(),
                Some((saved.id.to_string(), false))
            )]
        );
    }

    #[test]
    fn a_recent_row_has_no_move_up_or_down() {
        let moves = |section: LibrarySection| {
            items(connection_menu(Uuid::new_v4(), section, &empty(), &[]).upcast_ref())
                .into_iter()
                .filter_map(|(_, action, _)| action)
                .filter(|action| action == "picker-row.move-up" || action == "picker-row.move-down")
                .collect::<Vec<_>>()
        };

        for section in [LibrarySection::Tree, LibrarySection::Favourites] {
            assert_eq!(
                moves(section),
                ["picker-row.move-up", "picker-row.move-down"],
                "{section:?}"
            );
        }
        assert!(moves(LibrarySection::Recent).is_empty());
    }

    #[test]
    fn the_tags_menu_offers_each_tag_then_new_and_manage() {
        let id = Uuid::new_v4();
        let tag = ConnectionTag::new(
            tablepro_storage::ConnectionTagName::new("dev_prod").expect("a tag name"),
            ConnectionColor::Red,
        );

        let found = items(connection_menu(id, LibrarySection::Tree, &empty(), std::slice::from_ref(&tag)).upcast_ref());

        let check = found
            .iter()
            .find(|(label, ..)| label == "dev__prod")
            .expect("the tag's item");
        assert_eq!(check.1.as_deref(), Some(format!("picker-row.tag-{}", tag.id).as_str()));
        assert_eq!(check.2, None, "a check item carries no target");
        let new = found.iter().find(|(label, ..)| label == "_New Tag…").expect("New Tag…");
        assert_eq!(new.1.as_deref(), Some("picker.new-tag"));
        let manage = found
            .iter()
            .find(|(label, ..)| label == "_Manage Tags…")
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
