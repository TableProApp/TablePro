use tablepro_core::ddl::{BuildDdlError, DdlDialect, DdlPlan, TableChanges, TableDefinition, TableDraft};
use tablepro_core::meta::TableRef;

/// What a Structure tab would save: the table as it was read, the
/// user's draft of it and the changes between the two. A new table has
/// no original.
#[derive(Debug, Clone, PartialEq)]
pub struct PendingStructure {
    pub original: Option<TableDefinition>,
    pub draft: TableDraft,
    pub changes: TableChanges,
}

impl PendingStructure {
    pub fn has_changes(&self) -> bool {
        match self.original {
            Some(_) => !self.changes.is_empty(),
            None => !self.draft.columns.is_empty(),
        }
    }

    /// The edits the action bar counts. A new table is one.
    pub fn change_count(&self) -> usize {
        match self.original {
            Some(_) => self.changes.change_count(),
            None => usize::from(!self.draft.columns.is_empty()),
        }
    }

    /// Planned with the dialect of the connection that will run it, so
    /// the SQL is spelled for that server.
    pub fn plan(&self, ddl: &dyn DdlDialect) -> Result<DdlPlan, BuildDdlError> {
        match &self.original {
            Some(original) => ddl.plan_alter_table(original, &self.changes),
            None => ddl.plan_create_table(&self.draft),
        }
    }

    /// The table the write runs against, named as it is before the save.
    pub fn table(&self) -> TableRef {
        match &self.original {
            Some(original) => original.table.clone(),
            None => TableRef::new(self.draft.table.schema.clone(), self.draft.table.name.trim()),
        }
    }

    /// The name the tab follows once the save lands, when that is not
    /// the one it already shows: the table a draft created, or the new
    /// name of a renamed one.
    pub fn saved_table_name(&self) -> Option<String> {
        match &self.original {
            Some(_) => self.changes.renamed_table.clone(),
            None => Some(self.draft.table.name.trim().to_owned()),
        }
    }
}

#[cfg(test)]
mod tests {
    use tablepro_core::ServerInfo;
    use tablepro_core::ddl::{DraftColumn, DraftType, diff_table};

    use super::*;

    fn draft() -> TableDraft {
        let mut draft = TableDraft::new(TableRef::new(Some("app".to_owned()), " orders "));
        let mut id = DraftColumn::new("id", DraftType::Typed("integer".to_owned()));
        id.primary_key = true;
        id.nullable = false;
        draft.columns.push(id);
        draft
    }

    fn created() -> PendingStructure {
        PendingStructure {
            original: None,
            draft: draft(),
            changes: TableChanges::default(),
        }
    }

    #[test]
    fn pending_structure_plans_with_supplied_dialect() {
        let pending = created();
        let postgres = drivers_postgres::PgDialect::new(&ServerInfo::new("PostgreSQL", "18.0", 18, 0, 0));
        let mysql = drivers_mysql::MySqlDialect::new(
            drivers_mysql::MySqlFlavour::MySql,
            &ServerInfo::new("MySQL", "8.4.3", 8, 4, 3),
        );

        let in_postgres = pending.plan(&postgres).expect("the draft plans");
        let in_mysql = pending.plan(&mysql).expect("the draft plans");

        assert!(
            in_postgres.sql()[0].starts_with("CREATE TABLE \"app\".\"orders\""),
            "{:?}",
            in_postgres.sql()
        );
        assert!(
            in_mysql.sql()[0].starts_with("CREATE TABLE `app`.`orders`"),
            "{:?}",
            in_mysql.sql()
        );
        assert_eq!(pending.table(), TableRef::new(Some("app".to_owned()), "orders"));
        assert_eq!(pending.saved_table_name().as_deref(), Some("orders"));
    }

    #[test]
    fn an_edit_counts_its_changes_and_follows_a_rename() {
        let original = TableDefinition {
            table: TableRef::new(Some("app".to_owned()), "orders"),
            columns: Vec::new(),
            primary_key: None,
            indexes: Vec::new(),
            foreign_keys: Vec::new(),
            inbound_foreign_keys: Vec::new(),
            source: None,
        };
        let mut renamed = TableDraft::from_definition(&original);
        renamed.table.name = "purchases".to_owned();
        let pending = PendingStructure {
            changes: diff_table(&original, &renamed),
            original: Some(original.clone()),
            draft: renamed,
        };
        let unchanged = PendingStructure {
            changes: TableChanges::default(),
            draft: TableDraft::from_definition(&original),
            original: Some(original),
        };

        assert!(pending.has_changes());
        assert_eq!(pending.change_count(), 1);
        assert_eq!(pending.saved_table_name().as_deref(), Some("purchases"));
        assert_eq!(pending.table().name, "orders");
        assert!(!unchanged.has_changes());
        assert!(
            !PendingStructure {
                draft: TableDraft::new(TableRef::unqualified("t")),
                ..created()
            }
            .has_changes()
        );
    }
}
