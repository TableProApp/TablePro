use super::database_service::{ConnectionIdentity, DatabaseService};
use std::sync::Arc;
use tablepro_core::{Connection, TableInfo};
use uuid::Uuid;

pub type Catalog = (Vec<TableInfo>, Vec<TableInfo>);

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CatalogOrigin {
    pub id: Uuid,
    pub identity: ConnectionIdentity,
}

#[derive(Default)]
pub struct CatalogChanges {
    transaction: bool,
    pending: bool,
}

impl CatalogChanges {
    pub fn succeeded(&mut self, sql: &str, driver: &str) -> bool {
        use tablepro_policy::{CatalogEffect, catalog_effect};
        match catalog_effect(sql, driver) {
            CatalogEffect::Begin => {
                self.transaction = true;
                false
            }
            CatalogEffect::Rollback { chain } => {
                self.transaction = chain;
                self.pending = false;
                false
            }
            CatalogEffect::Commit { chain } => {
                self.transaction = chain;
                std::mem::take(&mut self.pending)
            }
            CatalogEffect::Ddl if self.transaction && !matches!(driver, "mysql" | "clickhouse") => {
                self.pending = true;
                false
            }
            CatalogEffect::Ddl => {
                self.transaction = false;
                self.pending = false;
                true
            }
            CatalogEffect::None => false,
        }
    }
}

impl CatalogOrigin {
    pub fn capture(id: Option<Uuid>, database: &DatabaseService) -> Option<Self> {
        let id = id?;
        Some(Self {
            id,
            identity: database.identity(id)?,
        })
    }
    pub fn owns_window(&self, id: Option<Uuid>, database: &DatabaseService) -> bool {
        self.matches(id, database.identity(self.id).as_ref())
    }
    pub(crate) fn matches(&self, id: Option<Uuid>, identity: Option<&ConnectionIdentity>) -> bool {
        id == Some(self.id) && identity == Some(&self.identity)
    }
    pub fn connection(&self, database: &DatabaseService) -> Option<Arc<dyn Connection>> {
        let (connection, identity) = database.get_with_identity(self.id)?;
        (identity == self.identity).then_some(connection)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn committed_ddl_refreshes_but_rollback_and_savepoint_do_not_publish() {
        let mut changes = CatalogChanges::default();
        assert!(!changes.succeeded("/* start */ BEGIN", "postgres"));
        assert!(!changes.succeeded("CREATE VIEW v AS SELECT 1", "postgres"));
        assert!(!changes.succeeded("ROLLBACK TO SAVEPOINT s", "postgres"));
        assert!(changes.succeeded("COMMIT AND CHAIN", "postgres"));
        assert!(!changes.succeeded("DROP VIEW v", "postgres"));
        assert!(!changes.succeeded("ROLLBACK", "postgres"));
        assert!(!changes.succeeded("COMMIT", "postgres"));
        assert!(changes.succeeded("CREATE VIEW v AS SELECT 1", "postgres"));
        assert!(!changes.succeeded("SELECT 'CREATE TABLE x'", "postgres"));
    }
}
