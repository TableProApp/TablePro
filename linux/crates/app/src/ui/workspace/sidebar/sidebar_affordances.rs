use tablepro_core::dialect::SqlDialect;
use tablepro_session::Session;

/// What the sidebar offers for the connection: the structure tab's
/// actions follow its DDL dialect, the way the structure tab does, a
/// table's CREATE statement is shown only where the engine speaks SQL,
/// and a read-only connection is offered nothing that writes.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub(crate) struct SidebarAffordances {
    pub read_only: bool,
    pub can_create_table: bool,
    pub can_edit_structure: bool,
    pub shows_create_table: bool,
}

impl SidebarAffordances {
    pub(crate) fn of(read_only: bool, dialect: Option<&dyn SqlDialect>) -> Self {
        let ddl = dialect.and_then(|dialect| dialect.ddl());
        Self {
            read_only,
            can_create_table: ddl.is_some_and(|ddl| ddl.capabilities().create_table),
            can_edit_structure: ddl.is_some(),
            shows_create_table: dialect.is_some_and(|dialect| dialect.grammar().is_sql()),
        }
    }

    /// Read again after each reconnect, which can reach another server
    /// version.
    pub(crate) fn for_session(session: &Session) -> Self {
        Self::of(session.read_only(), session.current_dialect().as_deref())
    }

    /// Whether a section header has its New Table button.
    pub(crate) fn offers_new_table(self) -> bool {
        self.can_create_table && !self.read_only
    }
}

#[cfg(test)]
mod tests {
    use tablepro_core::ServerInfo;
    use tablepro_test_support::FakeDialect;

    use super::*;

    #[test]
    fn affordances_from_ddl_capabilities() {
        let postgres = tablepro_driver_postgres::PgDialect::new(&ServerInfo::new("PostgreSQL", "18.0", 18, 0, 0));
        let clickhouse =
            tablepro_driver_clickhouse::ClickHouseDialect::new(&ServerInfo::new("ClickHouse", "25.8", 25, 8, 0));

        let none = SidebarAffordances::of(false, Some(&FakeDialect));
        let creates = SidebarAffordances::of(false, Some(&postgres));
        let edits_only = SidebarAffordances::of(false, Some(&clickhouse));
        let gone = SidebarAffordances::of(false, None);

        assert!(!none.can_edit_structure && !none.offers_new_table());
        assert!(creates.shows_create_table);
        let mongo = SidebarAffordances::of(false, Some(&tablepro_driver_mongodb::MongoDialect));
        assert!(
            !mongo.can_edit_structure && !mongo.shows_create_table,
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

        let read_only = SidebarAffordances::of(true, Some(&postgres));

        assert!(read_only.read_only);
        assert!(read_only.can_create_table, "the dialect still creates tables");
        assert!(!read_only.offers_new_table());
    }
}
