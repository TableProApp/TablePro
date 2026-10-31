use gtk4::gio;
use gtk4::prelude::*;
use tablepro_core::meta::ObjectKind;

use super::object_key::ObjectKey;
use super::sidebar_affordances::SidebarAffordances;
use super::sidebar_view::Holds;

pub(super) const OPEN_IN_NEW_TAB: &str = "open-in-new-tab";
pub(super) const EDIT_STRUCTURE: &str = "edit-structure";
pub(super) const SHOW_CREATE_TABLE: &str = "show-create-table";
pub(super) const IMPORT_CSV: &str = "import-csv";
pub(super) const DROP_TABLE: &str = "drop-table";
pub(super) const NEW_TABLE: &str = "new-table";
pub(super) const SHOW_DIAGRAM: &str = "show-diagram";
/// A schema's diagram, whose target is the schema, as New Table's is.
pub(super) const SHOW_SCHEMA_DIAGRAM: &str = "show-schema-diagram";
pub(super) const GROUP: &str = "sidebar";

/// The menu of one table. Every item carries the table's key, so the one
/// popover serves every row and acts on the table it opened for, even
/// after the list changes under it. What writes sits in sections of its
/// own, and a read-only connection is not offered it. A view's shape
/// comes from its query, so only a table offers to change or drop it.
pub(crate) fn object_menu(key: &ObjectKey, kind: ObjectKind, affordances: SidebarAffordances) -> gio::Menu {
    let menu = gio::Menu::new();
    let open = gio::Menu::new();
    open.append_item(&item(&crate::i18n::gettext("_Open in New Tab"), OPEN_IN_NEW_TAB, key));
    // A key has no SQL to show, no structure to change and no diagram.
    if !kind.is_browsable() {
        menu.append_section(None, &open);
        return menu;
    }
    if affordances.speaks_sql {
        open.append_item(&item(&crate::i18n::gettext("Show ER _Diagram"), SHOW_DIAGRAM, key));
    }
    menu.append_section(None, &open);
    let table = kind.is_structure_editable();
    let structure = gio::Menu::new();
    if table && affordances.can_edit_structure {
        structure.append_item(&item(&crate::i18n::gettext("_Edit Structure"), EDIT_STRUCTURE, key));
    }
    if affordances.speaks_sql {
        structure.append_item(&item(
            &crate::i18n::gettext("Show _CREATE TABLE"),
            SHOW_CREATE_TABLE,
            key,
        ));
    }
    menu.append_section(None, &structure);
    if affordances.read_only || !table {
        return menu;
    }
    let data = gio::Menu::new();
    data.append_item(&item(&crate::i18n::gettext("_Import CSV…"), IMPORT_CSV, key));
    menu.append_section(None, &data);
    if affordances.can_edit_structure {
        let danger = gio::Menu::new();
        danger.append_item(&item(&crate::i18n::gettext("Drop _Table…"), DROP_TABLE, key));
        menu.append_section(None, &danger);
    }
    menu
}

/// A schema's menu: New Table where the connection creates tables, and
/// the schema's diagram where it holds tables in SQL. ClickHouse creates
/// none: a table there needs an engine and a sorting key the structure
/// tab has no place for. Keys have neither. Each item carries the schema,
/// or nothing for the objects an engine lists with none.
pub(crate) fn schema_menu(schema: Option<&str>, affordances: SidebarAffordances, holds: Holds) -> Option<gio::Menu> {
    if holds == Holds::Keys {
        return None;
    }
    let menu = gio::Menu::new();
    let target = schema.map(str::to_owned).to_variant();
    if affordances.offers_new_table() {
        let item = gio::MenuItem::new(Some(&crate::i18n::gettext("_New Table…")), None);
        item.set_action_and_target_value(Some(&format!("{GROUP}.{NEW_TABLE}")), Some(&target));
        menu.append_item(&item);
    }
    if affordances.speaks_sql {
        let item = gio::MenuItem::new(Some(&crate::i18n::gettext("Show ER _Diagram")), None);
        item.set_action_and_target_value(Some(&format!("{GROUP}.{SHOW_SCHEMA_DIAGRAM}")), Some(&target));
        menu.append_item(&item);
    }
    (menu.n_items() > 0).then_some(menu)
}

/// Whether `action` is offered for a `kind` on a connection with
/// `affordances`, as `object_menu` offers it.
pub(super) fn offers(action: &str, kind: ObjectKind, affordances: SidebarAffordances) -> bool {
    let table = kind.is_structure_editable();
    match action {
        OPEN_IN_NEW_TAB => true,
        SHOW_CREATE_TABLE | SHOW_DIAGRAM => kind.is_browsable() && affordances.speaks_sql,
        EDIT_STRUCTURE => table && affordances.can_edit_structure,
        IMPORT_CSV => table && !affordances.read_only,
        // Dropping is planned by the DDL dialect, as structure changes are.
        DROP_TABLE => table && !affordances.read_only && affordances.can_edit_structure,
        _ => false,
    }
}

fn item(label: &str, action: &str, key: &ObjectKey) -> gio::MenuItem {
    let item = gio::MenuItem::new(Some(label), None);
    item.set_action_and_target_value(Some(&format!("{GROUP}.{action}")), Some(&key.to_variant()));
    item
}

#[cfg(test)]
mod tests {
    use gtk4::glib;
    use tablepro_core::meta::TableRef;

    use super::*;
    use crate::test_support::assert_access_keys;

    /// Each item's action and target, in menu order, sections flattened.
    fn items(menu: &gio::MenuModel) -> Vec<(String, Option<glib::Variant>)> {
        let mut found = Vec::new();
        for index in 0..menu.n_items() {
            if let Some(action) = menu
                .item_attribute_value(index, "action", None)
                .and_then(|value| value.get::<String>())
            {
                found.push((action, menu.item_attribute_value(index, "target", None)));
            }
            if let Some(section) = menu.item_link(index, "section") {
                found.extend(items(&section));
            }
        }
        found
    }

    fn actions(menu: &gio::Menu) -> Vec<String> {
        items(menu.upcast_ref()).into_iter().map(|(action, _)| action).collect()
    }

    fn all() -> SidebarAffordances {
        SidebarAffordances {
            read_only: false,
            can_create_table: true,
            can_edit_structure: true,
            speaks_sql: true,
        }
    }

    #[test]
    fn every_item_carries_the_object_key() {
        let key = ObjectKey(TableRef::new(Some("sales".to_owned()), "orders"));

        let menu = object_menu(&key, ObjectKind::Table, all());

        let found = items(menu.upcast_ref());
        assert_eq!(found.len(), 6);
        for (action, target) in found {
            let target = target.unwrap_or_else(|| panic!("{action} has no target"));
            assert_eq!(ObjectKey::from_variant(&target).as_ref(), Some(&key), "{action}");
        }
    }

    #[test]
    fn every_item_has_an_access_key_of_its_own() {
        let key = ObjectKey(TableRef::new(Some("sales".to_owned()), "orders"));

        assert_access_keys(&object_menu(&key, ObjectKind::Table, all()));
        assert_access_keys(&schema_menu(Some("sales"), all(), Holds::Tables).expect("a menu"));
    }

    #[test]
    fn a_read_only_connection_is_offered_nothing_that_writes() {
        let key = ObjectKey(TableRef::unqualified("orders"));
        let read_only = SidebarAffordances {
            read_only: true,
            ..all()
        };

        assert_eq!(
            actions(&object_menu(&key, ObjectKind::Table, read_only)),
            [
                "sidebar.open-in-new-tab",
                "sidebar.show-diagram",
                "sidebar.edit-structure",
                "sidebar.show-create-table"
            ]
        );
    }

    #[test]
    fn edit_structure_follows_the_dialect() {
        let key = ObjectKey(TableRef::unqualified("orders"));
        let without = SidebarAffordances {
            can_edit_structure: false,
            ..all()
        };

        assert!(
            !actions(&object_menu(&key, ObjectKind::Table, without)).contains(&"sidebar.edit-structure".to_owned())
        );
        assert!(actions(&object_menu(&key, ObjectKind::Table, all())).contains(&"sidebar.drop-table".to_owned()));
    }

    #[test]
    fn a_key_offers_only_to_open_it() {
        let key = ObjectKey(TableRef::unqualified("user:1"));
        let kind = ObjectKind::Key(tablepro_core::meta::KeyKind::Hash);

        assert_eq!(actions(&object_menu(&key, kind, all())), ["sidebar.open-in-new-tab"]);
        for action in [SHOW_CREATE_TABLE, SHOW_DIAGRAM, EDIT_STRUCTURE, IMPORT_CSV, DROP_TABLE] {
            assert!(!offers(action, kind, all()), "{action}");
        }
    }

    #[test]
    fn a_collection_offers_neither_sql_nor_a_drop_the_dialect_cannot_plan() {
        let key = ObjectKey(TableRef::new(Some("shop".to_owned()), "orders"));
        let documents = SidebarAffordances {
            read_only: false,
            can_create_table: false,
            can_edit_structure: false,
            speaks_sql: false,
        };

        assert_eq!(
            actions(&object_menu(&key, ObjectKind::Table, documents)),
            ["sidebar.open-in-new-tab", "sidebar.import-csv"]
        );
        assert!(!offers(DROP_TABLE, ObjectKind::Table, documents));
        assert!(!offers(SHOW_CREATE_TABLE, ObjectKind::Table, documents));
    }

    #[test]
    fn a_schema_menu_offers_new_table_and_its_diagram_with_the_schema() {
        let menu = schema_menu(Some("sales"), all(), Holds::Tables).expect("a menu");

        let found = items(menu.upcast_ref());
        let actions: Vec<&str> = found.iter().map(|(action, _)| action.as_str()).collect();
        assert_eq!(actions, ["sidebar.new-table", "sidebar.show-schema-diagram"]);
        for (action, target) in &found {
            assert_eq!(
                target.as_ref().and_then(|target| target.get::<Option<String>>()),
                Some(Some("sales".to_owned())),
                "{action}"
            );
        }
    }

    #[test]
    fn a_schema_menu_follows_the_dialect_and_what_the_session_holds() {
        let read_only = SidebarAffordances {
            read_only: true,
            ..all()
        };
        let documents = SidebarAffordances {
            can_create_table: false,
            can_edit_structure: false,
            speaks_sql: false,
            ..all()
        };

        let actions = |menu: Option<gio::Menu>| menu.map(|menu| actions(&menu)).unwrap_or_default();
        assert_eq!(
            actions(schema_menu(None, read_only, Holds::Tables)),
            ["sidebar.show-schema-diagram"]
        );
        assert!(schema_menu(Some("shop"), documents, Holds::Collections).is_none());
        assert!(schema_menu(None, all(), Holds::Keys).is_none(), "keys have no diagram");
    }

    #[test]
    fn a_view_offers_no_structure_change() {
        let key = ObjectKey(TableRef::unqualified("active_users"));

        let offered = actions(&object_menu(&key, ObjectKind::View, all()));

        assert_eq!(
            offered,
            [
                "sidebar.open-in-new-tab",
                "sidebar.show-diagram",
                "sidebar.show-create-table"
            ]
        );
        for action in [EDIT_STRUCTURE, IMPORT_CSV, DROP_TABLE] {
            assert!(!offers(action, ObjectKind::View, all()), "{action}");
            assert!(offers(action, ObjectKind::PartitionedTable, all()), "{action}");
        }
    }
}
