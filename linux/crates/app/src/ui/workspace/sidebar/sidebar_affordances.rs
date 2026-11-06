use tablepro_core::ddl::{CatalogCapabilities, catalog_capabilities, protects_database};
use tablepro_core::dialect::{DatabaseLayout, SqlDialect};
use tablepro_session::Session;

/// What the sidebar offers for the connection: the structure tab's
/// actions follow its DDL dialect, the way the structure tab does, a
/// table's CREATE statement and an ER diagram of its keys are shown only
/// where the engine speaks SQL, and a read-only connection is offered
/// nothing that writes.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub(crate) struct SidebarAffordances {
    pub read_only: bool,
    pub can_create_table: bool,
    pub can_edit_structure: bool,
    pub speaks_sql: bool,
    /// Another of the server's databases opens beside the connection,
    /// where a connection's catalog describes only its own (0030).
    pub opens_databases: bool,
    /// The schemas the catalog lists are the server's databases, so a
    /// schema's row drops a database.
    pub lists_databases: bool,
    /// What the engine does to whole tables, schemas and databases
    /// (core 0013).
    pub catalog: CatalogCapabilities,
    /// Whether the database the session opened may be dropped from its
    /// row beside the connection: never one the engine keeps for itself.
    pub own_database_droppable: bool,
}

impl SidebarAffordances {
    pub(crate) fn of(read_only: bool, dialect: Option<&dyn SqlDialect>, database: Option<&str>) -> Self {
        let ddl = dialect.and_then(|dialect| dialect.ddl());
        let layout = dialect.map(|dialect| dialect.database_layout());
        Self {
            read_only,
            can_create_table: ddl.is_some_and(|ddl| ddl.capabilities().create_table),
            can_edit_structure: ddl.is_some(),
            speaks_sql: dialect.is_some_and(|dialect| dialect.grammar().is_sql()),
            opens_databases: layout == Some(DatabaseLayout::WithSchemas),
            lists_databases: layout == Some(DatabaseLayout::AsSchemas),
            catalog: dialect.map(catalog_capabilities).unwrap_or_default(),
            own_database_droppable: dialect
                .zip(database)
                .is_some_and(|(dialect, database)| !protects_database(dialect, database)),
        }
    }

    /// Read again after each reconnect, which can reach another server
    /// version.
    pub(crate) fn for_session(session: &Session) -> Self {
        Self::of(
            session.read_only(),
            session.current_dialect().as_deref(),
            session.database(),
        )
    }

    /// Whether a section header has its New Table button.
    pub(crate) fn offers_new_table(self) -> bool {
        self.can_create_table && !self.read_only
    }

    /// Whether a schema's row offers to make another schema. Where the
    /// schemas are the server's databases, a new one is New Database…
    /// on the connection's row.
    pub(crate) fn offers_new_schema(self) -> bool {
        self.catalog.create_schema && !self.read_only && !self.lists_databases
    }

    pub(crate) fn offers_new_database(self) -> bool {
        self.catalog.create_database && !self.read_only
    }

    pub(crate) fn offers_drop_database(self) -> bool {
        self.catalog.drop_database && !self.read_only
    }
}

#[cfg(test)]
mod tests {
    use tablepro_core::ServerInfo;
    use tablepro_core::ddl::DatabaseNoun;
    use tablepro_test_support::FakeDialect;

    use super::*;

    #[test]
    fn affordances_from_ddl_capabilities() {
        let postgres = tablepro_driver_postgres::PgDialect::new(&ServerInfo::new("PostgreSQL", "18.0", 18, 0, 0));
        let clickhouse =
            tablepro_driver_clickhouse::ClickHouseDialect::new(&ServerInfo::new("ClickHouse", "25.8", 25, 8, 0));

        let none = SidebarAffordances::of(false, Some(&FakeDialect), None);
        let creates = SidebarAffordances::of(false, Some(&postgres), Some("app"));
        let edits_only = SidebarAffordances::of(false, Some(&clickhouse), Some("default"));
        let gone = SidebarAffordances::of(false, None, Some("app"));

        assert!(!none.can_edit_structure && !none.offers_new_table());
        assert!(creates.speaks_sql);
        assert!(creates.opens_databases, "PostgreSQL lists one database's schemas");
        assert!(!creates.lists_databases);
        assert!(!edits_only.opens_databases, "ClickHouse lists every database already");
        assert!(edits_only.lists_databases);
        let mongo = SidebarAffordances::of(false, Some(&tablepro_driver_mongodb::MongoDialect), Some("shop"));
        assert!(
            !mongo.can_edit_structure && !mongo.speaks_sql,
            "a collection has no SQL to show"
        );
        assert!(creates.can_edit_structure && creates.offers_new_table());
        assert!(edits_only.can_edit_structure);
        assert!(
            !edits_only.offers_new_table(),
            "ClickHouse tables are created in the editor"
        );
        assert_eq!(gone, SidebarAffordances::default());
    }

    #[test]
    fn affordances_hide_drop_when_read_only() {
        let postgres = tablepro_driver_postgres::PgDialect::new(&ServerInfo::new("PostgreSQL", "18.0", 18, 0, 0));
        let writable = SidebarAffordances {
            catalog: CatalogCapabilities {
                create_schema: true,
                create_database: true,
                drop_database: true,
                ..CatalogCapabilities::default()
            },
            ..SidebarAffordances::default()
        };

        let read_only = SidebarAffordances::of(true, Some(&postgres), Some("app"));

        assert!(read_only.read_only);
        assert!(read_only.can_create_table, "the dialect still creates tables");
        assert!(!read_only.offers_new_table());
        assert!(writable.offers_new_schema() && writable.offers_new_database() && writable.offers_drop_database());
        let locked = SidebarAffordances {
            read_only: true,
            ..writable
        };
        assert!(!locked.offers_new_schema() && !locked.offers_new_database() && !locked.offers_drop_database());
    }

    #[test]
    fn a_server_whose_databases_are_its_schemas_makes_no_schema_of_its_own() {
        let databases = SidebarAffordances {
            lists_databases: true,
            catalog: CatalogCapabilities {
                create_schema: true,
                create_database: true,
                ..CatalogCapabilities::default()
            },
            ..SidebarAffordances::default()
        };

        assert!(!databases.offers_new_schema());
        assert!(databases.offers_new_database());
    }

    /// MongoDB's catalog comes from the core, which writes its shell.
    #[test]
    fn mongodb_empties_collections_and_makes_and_drops_databases() {
        let mongo = SidebarAffordances::of(false, Some(&tablepro_driver_mongodb::MongoDialect), Some("shop"));

        assert!(mongo.lists_databases);
        assert!(mongo.catalog.truncate_table);
        assert!(mongo.offers_new_database() && mongo.offers_drop_database());
        assert_eq!(mongo.catalog.database_noun, DatabaseNoun::Database);
        assert!(mongo.own_database_droppable);
        assert!(
            !SidebarAffordances::of(false, Some(&tablepro_driver_mongodb::MongoDialect), Some("admin"))
                .own_database_droppable,
            "the server keeps admin for itself"
        );
        assert!(
            !SidebarAffordances::of(false, Some(&tablepro_driver_mongodb::MongoDialect), None).own_database_droppable,
            "a session that opened no database has none to drop"
        );
    }
}
