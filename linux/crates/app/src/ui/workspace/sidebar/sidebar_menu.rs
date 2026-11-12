use gtk4::gio;
use gtk4::prelude::*;
use tablepro_core::ddl::DatabaseNoun;
use tablepro_core::meta::ObjectKind;

use super::object_key::ObjectKey;
use super::object_target::ObjectTarget;
use super::sidebar_affordances::SidebarAffordances;
use super::sidebar_view::Holds;

pub(super) const OPEN_IN_NEW_TAB: &str = "open-in-new-tab";
pub(super) const EDIT_STRUCTURE: &str = "edit-structure";
pub(super) const SHOW_CREATE_TABLE: &str = "show-create-table";
pub(super) const IMPORT_CSV: &str = "import-csv";
pub(super) const TRUNCATE_TABLE: &str = "truncate-table";
pub(super) const DROP_TABLE: &str = "drop-table";
pub(super) const NEW_TABLE: &str = "new-table";
pub(super) const NEW_SCHEMA: &str = "new-schema";
/// A schema's drop, whose target is the schema's name and never none.
pub(super) const DROP_SCHEMA: &str = "drop-schema";
/// The drop of a database the engine lists as a schema, whose target is
/// its name.
pub(super) const DROP_DATABASE: &str = "drop-database";
pub(super) const SHOW_DIAGRAM: &str = "show-diagram";
/// A schema's diagram, whose target is the schema, as New Table's is.
pub(super) const SHOW_SCHEMA_DIAGRAM: &str = "show-schema-diagram";
pub(super) const SHOW_DEFINITION: &str = "show-definition";
pub(super) const GROUP: &str = "sidebar";

/// The menu of one object. Every item carries the object's key, so the
/// one popover serves every row and acts on the object it opened for,
/// even after the list changes under it. What writes sits in sections of
/// its own, and a read-only connection is not offered it. A view's shape
/// comes from its query, so only a table offers to change, empty or drop
/// it, and a routine, a sequence or a trigger is changed in the editor.
pub(crate) fn object_menu(
    key: &ObjectKey,
    kind: ObjectKind,
    affordances: SidebarAffordances,
    holds: Holds,
) -> gio::Menu {
    let menu = gio::Menu::new();
    let open = gio::Menu::new();
    if let ObjectTarget::Definition(_) = key.0 {
        open.append_item(&item(&crate::i18n::gettext("_Show Definition"), SHOW_DEFINITION, key));
        menu.append_section(None, &open);
        return menu;
    }
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
    let danger = gio::Menu::new();
    if affordances.catalog.truncate_table {
        // A collection is emptied by deleting its documents, which is
        // what the dialog asks before.
        let label = match holds {
            Holds::Collections => crate::i18n::gettext("Delete All _Documents…"),
            Holds::Tables | Holds::Keys => crate::i18n::gettext("Tr_uncate Table…"),
        };
        danger.append_item(&item(&label, TRUNCATE_TABLE, key));
    }
    if affordances.can_edit_structure {
        danger.append_item(&item(&crate::i18n::gettext("Drop _Table…"), DROP_TABLE, key));
    }
    if danger.n_items() > 0 {
        menu.append_section(None, &danger);
    }
    menu
}

/// A schema's menu: New Table where the connection creates tables, New
/// Schema where it creates schemas, the schema's diagram where it holds
/// tables in SQL, and the schema's drop, or its database's, when the list
/// offers to drop it. ClickHouse creates no table: one there needs an
/// engine and a sorting key the structure tab has no place for. Keys
/// have none of them. New Table and the diagram carry the schema, or
/// nothing for the objects an engine lists with none; a drop carries the
/// schema's name and is never offered without one.
pub(crate) fn schema_menu(
    schema: Option<&str>,
    droppable: bool,
    affordances: SidebarAffordances,
    holds: Holds,
) -> Option<gio::Menu> {
    if holds == Holds::Keys {
        return None;
    }
    let menu = gio::Menu::new();
    let target = schema.map(str::to_owned).to_variant();
    let create = gio::Menu::new();
    if affordances.offers_new_table() {
        let item = gio::MenuItem::new(Some(&crate::i18n::gettext("_New Table…")), None);
        item.set_action_and_target_value(Some(&format!("{GROUP}.{NEW_TABLE}")), Some(&target));
        create.append_item(&item);
    }
    if affordances.offers_new_schema() {
        create.append(
            Some(&crate::i18n::gettext("New _Schema…")),
            Some(&format!("{GROUP}.{NEW_SCHEMA}")),
        );
    }
    append_filled(&menu, &create);
    let show = gio::Menu::new();
    if affordances.speaks_sql {
        let item = gio::MenuItem::new(Some(&crate::i18n::gettext("Show ER _Diagram")), None);
        item.set_action_and_target_value(Some(&format!("{GROUP}.{SHOW_SCHEMA_DIAGRAM}")), Some(&target));
        show.append_item(&item);
    }
    append_filled(&menu, &show);
    if let (Some(schema), true, Some(action)) = (schema, droppable, schema_drop(affordances)) {
        let danger = gio::Menu::new();
        let item = gio::MenuItem::new(Some(&drop_label(action, affordances.catalog.database_noun)), None);
        item.set_action_and_target_value(Some(&format!("{GROUP}.{action}")), Some(&schema.to_variant()));
        danger.append_item(&item);
        menu.append_section(None, &danger);
    }
    (menu.n_items() > 0).then_some(menu)
}

/// What a schema's row drops when the list offers to drop the schema:
/// the schema, or the database it is where the engine's databases are
/// its schemas. A read-only connection drops nothing.
pub(super) fn schema_drop(affordances: SidebarAffordances) -> Option<&'static str> {
    if affordances.read_only {
        return None;
    }
    if affordances.lists_databases {
        affordances.catalog.drop_database.then_some(DROP_DATABASE)
    } else {
        affordances.catalog.drop_schema.then_some(DROP_SCHEMA)
    }
}

// The schema menu's other items hold S and D, which "Drop Schema" and "Drop Database" would take.
fn drop_label(action: &str, noun: DatabaseNoun) -> String {
    match (action, noun) {
        (DROP_SCHEMA, _) => crate::i18n::gettext("Drop Sc_hema…"),
        (_, DatabaseNoun::Keyspace) => crate::i18n::gettext("Drop _Keyspace…"),
        (_, DatabaseNoun::Database) => crate::i18n::gettext("Drop Data_base…"),
    }
}

fn append_filled(menu: &gio::Menu, section: &gio::Menu) {
    if section.n_items() > 0 {
        menu.append_section(None, section);
    }
}

/// Whether `action` is offered for a `kind` on a connection with
/// `affordances`, as `object_menu` offers it.
pub(super) fn offers(action: &str, kind: ObjectKind, affordances: SidebarAffordances) -> bool {
    let table = kind.is_structure_editable();
    if kind.has_definition() {
        return action == SHOW_DEFINITION;
    }
    match action {
        OPEN_IN_NEW_TAB => true,
        SHOW_CREATE_TABLE | SHOW_DIAGRAM => kind.is_browsable() && affordances.speaks_sql,
        EDIT_STRUCTURE => table && affordances.can_edit_structure,
        IMPORT_CSV => table && !affordances.read_only,
        TRUNCATE_TABLE => table && !affordances.read_only && affordances.catalog.truncate_table,
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
    use tablepro_core::ddl::CatalogCapabilities;
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

    /// Each item's label, in menu order, sections flattened.
    fn labels(menu: &gio::MenuModel) -> Vec<String> {
        let mut found = Vec::new();
        for index in 0..menu.n_items() {
            if let Some(label) = menu
                .item_attribute_value(index, "label", None)
                .and_then(|value| value.get::<String>())
            {
                found.push(label);
            }
            if let Some(section) = menu.item_link(index, "section") {
                found.extend(labels(&section));
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
            opens_databases: true,
            ..SidebarAffordances::default()
        }
    }

    /// `all`, on an engine that also empties tables and makes and drops
    /// schemas and databases.
    fn everything() -> SidebarAffordances {
        SidebarAffordances {
            catalog: CatalogCapabilities {
                truncate_table: true,
                create_schema: true,
                drop_schema: true,
                create_database: true,
                drop_database: true,
                ..CatalogCapabilities::default()
            },
            own_database_droppable: true,
            ..all()
        }
    }

    /// `everything`, where the schemas are the server's databases.
    fn databases(noun: DatabaseNoun) -> SidebarAffordances {
        let mut affordances = everything();
        affordances.opens_databases = false;
        affordances.lists_databases = true;
        affordances.catalog.database_noun = noun;
        affordances
    }

    fn orders() -> ObjectKey {
        ObjectKey::rows(TableRef::new(Some("sales".to_owned()), "orders"))
    }

    #[test]
    fn every_item_carries_the_object_key() {
        let key = orders();

        let menu = object_menu(&key, ObjectKind::Table, everything(), Holds::Tables);

        let found = items(menu.upcast_ref());
        assert_eq!(found.len(), 7);
        for (action, target) in found {
            let target = target.unwrap_or_else(|| panic!("{action} has no target"));
            assert_eq!(ObjectKey::from_variant(&target).as_ref(), Some(&key), "{action}");
        }
    }

    #[test]
    fn every_item_has_an_access_key_of_its_own() {
        let key = orders();

        assert_access_keys(&object_menu(&key, ObjectKind::Table, all(), Holds::Tables));
        assert_access_keys(&object_menu(&key, ObjectKind::Table, everything(), Holds::Tables));
        let mongo = SidebarAffordances::of(false, Some(&tablepro_driver_mongodb::MongoDialect), Some("shop"));
        assert_access_keys(&object_menu(&key, ObjectKind::Table, mongo, Holds::Collections));
        assert_access_keys(&schema_menu(Some("sales"), false, all(), Holds::Tables).expect("a menu"));
        for affordances in [
            everything(),
            databases(DatabaseNoun::Database),
            databases(DatabaseNoun::Keyspace),
        ] {
            let menu = schema_menu(Some("sales"), true, affordances, Holds::Tables).expect("a menu");
            assert_access_keys(&menu);
        }
    }

    #[test]
    fn a_definition_offers_only_to_show_it_and_carries_its_trigger_table() {
        let key = ObjectKey(ObjectTarget::Definition(tablepro_core::meta::ObjectInfo::trigger(
            Some("sales".to_owned()),
            "audit",
            "orders",
        )));

        let menu = object_menu(&key, ObjectKind::Trigger, everything(), Holds::Tables);

        let found = items(menu.upcast_ref());
        assert_eq!(found.len(), 1);
        let (action, target) = &found[0];
        assert_eq!(action, "sidebar.show-definition");
        assert_eq!(target.as_ref().and_then(ObjectKey::from_variant).as_ref(), Some(&key));
        assert_access_keys(&menu);
        for action in [
            OPEN_IN_NEW_TAB,
            SHOW_CREATE_TABLE,
            SHOW_DIAGRAM,
            EDIT_STRUCTURE,
            IMPORT_CSV,
            TRUNCATE_TABLE,
            DROP_TABLE,
        ] {
            assert!(!offers(action, ObjectKind::Trigger, everything()), "{action}");
        }
        assert!(offers(SHOW_DEFINITION, ObjectKind::Function, all()));
        assert!(!offers(SHOW_DEFINITION, ObjectKind::Table, all()));
    }

    #[test]
    fn a_read_only_connection_is_offered_nothing_that_writes() {
        let key = ObjectKey::rows(TableRef::unqualified("orders"));
        let read_only = SidebarAffordances {
            read_only: true,
            ..everything()
        };

        assert_eq!(
            actions(&object_menu(&key, ObjectKind::Table, read_only, Holds::Tables)),
            [
                "sidebar.open-in-new-tab",
                "sidebar.show-diagram",
                "sidebar.edit-structure",
                "sidebar.show-create-table"
            ]
        );
        assert!(!offers(TRUNCATE_TABLE, ObjectKind::Table, read_only));
    }

    #[test]
    fn edit_structure_follows_the_dialect() {
        let key = ObjectKey::rows(TableRef::unqualified("orders"));
        let without = SidebarAffordances {
            can_edit_structure: false,
            ..all()
        };

        assert!(
            !actions(&object_menu(&key, ObjectKind::Table, without, Holds::Tables))
                .contains(&"sidebar.edit-structure".to_owned())
        );
        assert!(
            actions(&object_menu(&key, ObjectKind::Table, all(), Holds::Tables))
                .contains(&"sidebar.drop-table".to_owned())
        );
    }

    #[test]
    fn a_key_offers_only_to_open_it() {
        let key = ObjectKey::rows(TableRef::unqualified("user:1"));
        let kind = ObjectKind::Key(tablepro_core::meta::KeyKind::Hash);

        assert_eq!(
            actions(&object_menu(&key, kind, everything(), Holds::Keys)),
            ["sidebar.open-in-new-tab"]
        );
        for action in [
            SHOW_CREATE_TABLE,
            SHOW_DIAGRAM,
            EDIT_STRUCTURE,
            IMPORT_CSV,
            TRUNCATE_TABLE,
            DROP_TABLE,
        ] {
            assert!(!offers(action, kind, everything()), "{action}");
        }
    }

    #[test]
    fn a_collection_offers_neither_sql_nor_a_drop_the_dialect_cannot_plan() {
        let key = ObjectKey::rows(TableRef::new(Some("shop".to_owned()), "orders"));
        let documents = SidebarAffordances::default();

        assert_eq!(
            actions(&object_menu(&key, ObjectKind::Table, documents, Holds::Collections)),
            ["sidebar.open-in-new-tab", "sidebar.import-csv"]
        );
        assert!(!offers(DROP_TABLE, ObjectKind::Table, documents));
        assert!(!offers(SHOW_CREATE_TABLE, ObjectKind::Table, documents));
    }

    #[test]
    fn a_table_or_a_collection_is_emptied_beside_its_drop() {
        let table = object_menu(&orders(), ObjectKind::Table, everything(), Holds::Tables);
        let mongo = SidebarAffordances::of(false, Some(&tablepro_driver_mongodb::MongoDialect), Some("shop"));
        let collection = object_menu(&orders(), ObjectKind::Table, mongo, Holds::Collections);

        let offered = actions(&table);
        assert_eq!(
            offered[offered.len() - 2..],
            ["sidebar.truncate-table", "sidebar.drop-table"]
        );
        assert!(labels(table.upcast_ref()).contains(&"Tr_uncate Table…".to_owned()));
        assert_eq!(
            actions(&collection),
            [
                "sidebar.open-in-new-tab",
                "sidebar.import-csv",
                "sidebar.truncate-table"
            ]
        );
        assert!(labels(collection.upcast_ref()).contains(&"Delete All _Documents…".to_owned()));
        assert!(offers(TRUNCATE_TABLE, ObjectKind::PartitionedTable, everything()));
    }

    #[test]
    fn a_view_or_an_engine_that_cannot_empty_a_table_offers_no_truncate() {
        let view = object_menu(&orders(), ObjectKind::View, everything(), Holds::Tables);
        let without = SidebarAffordances {
            catalog: CatalogCapabilities {
                truncate_table: false,
                ..everything().catalog
            },
            ..everything()
        };

        assert!(!actions(&view).contains(&"sidebar.truncate-table".to_owned()));
        assert!(!offers(TRUNCATE_TABLE, ObjectKind::View, everything()));
        assert!(
            !actions(&object_menu(&orders(), ObjectKind::Table, without, Holds::Tables))
                .contains(&"sidebar.truncate-table".to_owned())
        );
        assert!(!offers(TRUNCATE_TABLE, ObjectKind::Table, without));
    }

    #[test]
    fn a_schema_menu_offers_new_table_and_its_diagram_with_the_schema() {
        let menu = schema_menu(Some("sales"), false, all(), Holds::Tables).expect("a menu");

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
    fn a_droppable_schema_offers_a_new_schema_and_its_drop_by_name() {
        let menu = schema_menu(Some("sales"), true, everything(), Holds::Tables).expect("a menu");

        let found = items(menu.upcast_ref());
        let actions: Vec<&str> = found.iter().map(|(action, _)| action.as_str()).collect();
        assert_eq!(
            actions,
            [
                "sidebar.new-table",
                "sidebar.new-schema",
                "sidebar.show-schema-diagram",
                "sidebar.drop-schema"
            ]
        );
        let target = |wanted: &str| {
            found
                .iter()
                .find(|(action, _)| action == wanted)
                .and_then(|(_, target)| target.clone())
        };
        assert_eq!(target("sidebar.new-schema"), None, "a new schema is the connection's");
        assert_eq!(
            target("sidebar.drop-schema").and_then(|target| target.get::<String>()),
            Some("sales".to_owned())
        );
        assert!(labels(menu.upcast_ref()).contains(&"Drop Sc_hema…".to_owned()));
    }

    #[test]
    fn a_schema_that_is_a_database_drops_the_database_in_the_engines_words() {
        for (noun, label) in [
            (DatabaseNoun::Database, "Drop Data_base…"),
            (DatabaseNoun::Keyspace, "Drop _Keyspace…"),
        ] {
            let menu = schema_menu(Some("shop"), true, databases(noun), Holds::Tables).expect("a menu");

            let found = items(menu.upcast_ref());
            let actions: Vec<&str> = found.iter().map(|(action, _)| action.as_str()).collect();
            assert_eq!(
                actions,
                [
                    "sidebar.new-table",
                    "sidebar.show-schema-diagram",
                    "sidebar.drop-database"
                ],
                "{label}"
            );
            assert_eq!(
                found
                    .last()
                    .and_then(|(_, target)| target.as_ref())
                    .and_then(|target| target.get::<String>()),
                Some("shop".to_owned())
            );
            assert!(labels(menu.upcast_ref()).contains(&label.to_owned()), "{label}");
        }
    }

    #[test]
    fn a_schema_the_list_withholds_or_cannot_name_offers_no_drop() {
        let actions = |menu: Option<gio::Menu>| menu.map(|menu| actions(&menu)).unwrap_or_default();
        let read_only = SidebarAffordances {
            read_only: true,
            ..everything()
        };

        for offered in [
            actions(schema_menu(Some("public"), false, everything(), Holds::Tables)),
            actions(schema_menu(None, true, everything(), Holds::Tables)),
            actions(schema_menu(Some("sales"), true, read_only, Holds::Tables)),
        ] {
            assert!(!offered.contains(&"sidebar.drop-schema".to_owned()), "{offered:?}");
        }
        assert_eq!(
            actions(schema_menu(Some("sales"), true, read_only, Holds::Tables)),
            ["sidebar.show-schema-diagram"]
        );
        assert_eq!(schema_drop(read_only), None);
        assert_eq!(schema_drop(everything()), Some(DROP_SCHEMA));
        assert_eq!(schema_drop(databases(DatabaseNoun::Database)), Some(DROP_DATABASE));
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
            actions(schema_menu(None, false, read_only, Holds::Tables)),
            ["sidebar.show-schema-diagram"]
        );
        assert!(schema_menu(Some("shop"), true, documents, Holds::Collections).is_none());
        assert!(
            schema_menu(None, false, everything(), Holds::Keys).is_none(),
            "keys have no diagram"
        );
    }

    #[test]
    fn a_view_offers_no_structure_change() {
        let key = ObjectKey::rows(TableRef::unqualified("active_users"));

        let offered = actions(&object_menu(&key, ObjectKind::View, all(), Holds::Tables));

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
