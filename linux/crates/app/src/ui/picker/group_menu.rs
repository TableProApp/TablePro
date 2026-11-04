use gtk4::gio;
use gtk4::prelude::*;
use uuid::Uuid;

use super::connection_menu::{
    DELETE_GROUP, NEW_GROUP, NONE, PICKER, RENAME_GROUP, ROW, ROW_PARENT, item, order_section,
};
use crate::services::library_outline::{LibraryItem, LibraryOutline};
use crate::ui::menu_label;

pub(crate) fn group_menu(id: Uuid, outline: &LibraryOutline) -> gio::Menu {
    let target = id.to_string().to_variant();
    let menu = gio::Menu::new();
    let edit = gio::Menu::new();
    // Hidden rather than off at the depth limit, as macOS does.
    if outline.can_create_in(Some(id)) {
        edit.append_item(&item(
            &crate::i18n::gettext("New _Subgroup…"),
            PICKER,
            NEW_GROUP,
            &target,
        ));
    }
    edit.append_item(&item(&crate::i18n::gettext("_Rename…"), PICKER, RENAME_GROUP, &target));
    menu.append_section(None, &edit);
    let order = order_section();
    if let Some(parents) = parent_menu(id, outline) {
        order.append_submenu(Some(&crate::i18n::gettext("Move Group _To")), &parents);
    }
    menu.append_section(None, &order);
    let danger = gio::Menu::new();
    danger.append_item(&item(
        &crate::i18n::gettext("_Delete Group…"),
        PICKER,
        DELETE_GROUP,
        &target,
    ));
    menu.append_section(None, &danger);
    menu
}

pub(crate) fn library_menu() -> gio::Menu {
    let menu = gio::Menu::new();
    menu.append_item(&item(
        &crate::i18n::gettext("New _Group…"),
        PICKER,
        NEW_GROUP,
        &NONE.to_variant(),
    ));
    menu
}

// `None` when the group sits at the top and fits under no other group.
fn parent_menu(id: Uuid, outline: &LibraryOutline) -> Option<gio::Menu> {
    let groups: Vec<Uuid> = outline.group_targets(id).into_iter().flatten().collect();
    let at_top = outline.parent_of(LibraryItem::Group(id)) == Some(None);
    if groups.is_empty() && at_top {
        return None;
    }
    let menu = gio::Menu::new();
    menu.append_item(&item(
        &crate::i18n::gettext("Top _Level"),
        ROW,
        ROW_PARENT,
        &NONE.to_variant(),
    ));
    if !groups.is_empty() {
        let under = gio::Menu::new();
        for parent in groups {
            let Some(label) = outline.label(parent) else {
                continue;
            };
            under.append_item(&item(
                &menu_label(&label),
                ROW,
                ROW_PARENT,
                &parent.to_string().to_variant(),
            ));
        }
        menu.append_section(None, &under);
    }
    Some(menu)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::assert_access_keys;
    use crate::ui::picker::connection_menu::tests::{group, items, labels, outline};

    fn target(target: Option<&gtk4::glib::Variant>) -> Option<String> {
        target.and_then(|target| target.get::<String>())
    }

    #[test]
    fn the_group_menu_reads_subgroup_rename_order_move_delete() {
        let work = group("Work", None);
        let archive = group("Archive", None);
        let outline = outline(Vec::new(), vec![work.clone(), archive], Vec::new());

        let found = items(group_menu(work.id, &outline).upcast_ref());

        let read: Vec<(&str, Option<&str>)> = found
            .iter()
            .filter(|(_, action, _)| action.as_deref() != Some("picker-row.parent"))
            .map(|(label, action, _)| (label.as_str(), action.as_deref()))
            .collect();
        assert_eq!(
            read,
            [
                ("New _Subgroup…", Some("picker.new-group")),
                ("_Rename…", Some("picker.rename-group")),
                ("Move U_p", Some("picker-row.move-up")),
                ("Move Do_wn", Some("picker-row.move-down")),
                ("Move Group _To", None),
                ("_Delete Group…", Some("picker.delete-group")),
            ]
        );
        for (label, action, shown) in &found {
            if action.as_deref().is_some_and(|action| action.starts_with("picker.")) {
                assert_eq!(target(shown.as_ref()), Some(work.id.to_string()), "{label}");
            }
        }
    }

    #[test]
    fn every_group_menu_item_has_an_access_key_of_its_own() {
        let work = group("Work", None);
        let staging = group("Staging", Some(work.id));
        let outline = outline(Vec::new(), vec![work.clone(), staging.clone()], Vec::new());

        assert_access_keys(&group_menu(work.id, &outline));
        assert_access_keys(&library_menu());
        // A group's name is the user's text, so its item has no access key.
        let problems: Vec<String> = crate::test_support::access_key_problems(&crate::test_support::menu_pages(
            &group_menu(staging.id, &outline),
        ))
        .into_iter()
        .filter(|problem| !problem.starts_with("\"Work\""))
        .collect();
        assert!(problems.is_empty(), "{problems:#?}");
    }

    #[test]
    fn a_group_three_deep_offers_no_subgroup() {
        let work = group("Work", None);
        let staging = group("Staging", Some(work.id));
        let deep = group("Deep", Some(staging.id));
        let outline = outline(Vec::new(), vec![work, staging.clone(), deep.clone()], Vec::new());
        let offers_subgroup = |id: Uuid| labels(&group_menu(id, &outline)).contains(&"New _Subgroup…".to_owned());

        assert!(offers_subgroup(staging.id));
        assert!(!offers_subgroup(deep.id));
    }

    #[test]
    fn move_group_to_offers_top_level_and_the_groups_it_fits_under() {
        let work = group("Work", None);
        let staging = group("Staging", Some(work.id));
        let deep = group("Deep", Some(staging.id));
        let archive = group("Archive", None);
        let outline = outline(
            Vec::new(),
            vec![work.clone(), staging.clone(), deep, archive.clone()],
            Vec::new(),
        );

        let picks: Vec<(String, Option<String>)> = items(group_menu(archive.id, &outline).upcast_ref())
            .into_iter()
            .filter(|(_, action, _)| action.as_deref() == Some("picker-row.parent"))
            .map(|(label, _, shown)| (label, target(shown.as_ref())))
            .collect();

        assert_eq!(
            picks,
            [
                ("Top _Level".to_owned(), Some(NONE.to_owned())),
                ("Work".to_owned(), Some(work.id.to_string())),
                ("Work / Staging".to_owned(), Some(staging.id.to_string())),
            ]
        );
    }

    #[test]
    fn a_top_level_group_that_fits_nowhere_else_has_no_move_group_to() {
        let work = group("Work", None);
        let staging = group("Staging", Some(work.id));
        let deep = group("Deep", Some(staging.id));
        let archive = group("Archive", None);
        let outline = outline(
            Vec::new(),
            vec![work.clone(), staging.clone(), deep, archive],
            Vec::new(),
        );

        assert!(!labels(&group_menu(work.id, &outline)).contains(&"Move Group _To".to_owned()));
        assert!(labels(&group_menu(staging.id, &outline)).contains(&"Move Group _To".to_owned()));
    }

    #[test]
    fn the_empty_area_menu_makes_a_top_level_group() {
        let found = items(library_menu().upcast_ref());

        assert_eq!(found.len(), 1, "{found:?}");
        let (label, action, shown) = &found[0];
        assert_eq!(label, "New _Group…");
        assert_eq!(action.as_deref(), Some("picker.new-group"));
        assert_eq!(target(shown.as_ref()), Some(NONE.to_owned()));
    }
}
