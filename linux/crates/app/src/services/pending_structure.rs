use tablepro_core::ddl::{
    BuildDdlError, DdlDialect, DdlOperation, DdlPlan, DraftProblem, TableChanges, TableDefinition, TableDraft,
};
use tablepro_core::meta::TableRef;

/// What a Structure tab would save: the table as it was read, the
/// user's draft of it and the changes between the two. A new table has
/// no original.
#[derive(Debug, Clone, PartialEq)]
pub struct PendingStructure {
    pub original: Option<TableDefinition>,
    pub draft: TableDraft,
    pub changes: TableChanges,
    /// Columns whose typed default the engine's parser refused. The
    /// draft still holds the default from before, so saving it would
    /// drop what the user typed without a word.
    pub unparsed_defaults: Vec<String>,
}

/// Why a structure cannot be saved as it stands.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SaveBlocker {
    Draft(DraftProblem),
    UnparsedDefault(String),
}

impl PendingStructure {
    /// Every save goes through this, the close prompts' included, which
    /// never pass the tab's own Save button.
    pub fn check(&self) -> Result<(), SaveBlocker> {
        self.draft.validate().map_err(SaveBlocker::Draft)?;
        match self.unparsed_defaults.first() {
            Some(column) => Err(SaveBlocker::UnparsedDefault(column.clone())),
            None => Ok(()),
        }
    }

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
            Some(original) => {
                self.draft.validate()?;
                ddl.plan_alter_table(original, &self.changes)
            }
            None => ddl.plan_create_table(&self.draft),
        }
    }

    /// What a connection without structure editing refuses.
    pub fn operation(&self) -> DdlOperation {
        match self.original {
            Some(_) => DdlOperation::AlterTable,
            None => DdlOperation::CreateTable,
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
    use tablepro_core::column::{ColumnDefault, ColumnInfo};
    use tablepro_core::ddl::{ColumnAttributes, ColumnDefinition, DraftColumn, DraftType, diff_table};
    use tablepro_core::dialect::SqlDialect;

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
            unparsed_defaults: Vec::new(),
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

    fn orders() -> TableDefinition {
        let dialect = drivers_postgres::PgDialect::new(&ServerInfo::new("PostgreSQL", "18.0", 18, 0, 0));
        let column = |name: &str, primary_key: bool| {
            ColumnDefinition::new(
                ColumnInfo {
                    name: name.to_owned(),
                    column_type: dialect.parse_type("integer").expect("a PostgreSQL type"),
                    nullable: !primary_key,
                    primary_key,
                    is_auto_increment: false,
                    is_generated: false,
                    default: ColumnDefault::None,
                    comment: None,
                },
                ColumnAttributes::default(),
            )
        };
        TableDefinition {
            table: TableRef::new(Some("app".to_owned()), "orders"),
            columns: vec![column("id", true), column("total", false)],
            primary_key: None,
            indexes: Vec::new(),
            foreign_keys: Vec::new(),
            inbound_foreign_keys: Vec::new(),
            source: None,
        }
    }

    fn edited(edit: impl FnOnce(&mut TableDraft)) -> PendingStructure {
        let original = orders();
        let mut draft = TableDraft::from_definition(&original);
        edit(&mut draft);
        PendingStructure {
            changes: diff_table(&original, &draft),
            original: Some(original),
            draft,
            unparsed_defaults: Vec::new(),
        }
    }

    #[test]
    fn a_save_waits_for_a_valid_draft_and_every_typed_default() {
        let postgres = drivers_postgres::PgDialect::new(&ServerInfo::new("PostgreSQL", "18.0", 18, 0, 0));
        let mut typed_default = edited(|draft| draft.columns[1].nullable = false);
        typed_default.unparsed_defaults = vec!["total".to_owned()];
        let unnamed = edited(|draft| draft.columns[1].name = String::new());

        assert_eq!(
            typed_default.check(),
            Err(SaveBlocker::UnparsedDefault("total".to_owned()))
        );
        assert_eq!(unnamed.check(), Err(SaveBlocker::Draft(DraftProblem::EmptyColumnName)));
        assert_eq!(
            unnamed.plan(&postgres),
            Err(BuildDdlError::Draft(DraftProblem::EmptyColumnName))
        );
        assert_eq!(edited(|draft| draft.columns[1].nullable = false).check(), Ok(()));
        assert_eq!(unnamed.operation(), DdlOperation::AlterTable);
        assert_eq!(created().operation(), DdlOperation::CreateTable);
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
            unparsed_defaults: Vec::new(),
        };
        let unchanged = PendingStructure {
            changes: TableChanges::default(),
            draft: TableDraft::from_definition(&original),
            original: Some(original),
            unparsed_defaults: Vec::new(),
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
