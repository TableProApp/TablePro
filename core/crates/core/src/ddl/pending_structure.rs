use crate::meta::TableRef;

use super::{
    BuildDdlError, ChangeReview, DdlDialect, DdlOperation, DdlPlan, DraftProblem, TableChanges, TableDefinition,
    TableDraft,
};

/// What a Structure tab would save: the table as it was read, the user's
/// draft of it and the changes between the two. A new table has no
/// original.
#[derive(Debug, Clone, PartialEq)]
pub struct PendingStructure {
    pub original: Option<TableDefinition>,
    pub draft: TableDraft,
    pub changes: TableChanges,
    /// Columns whose typed default the engine's parser refused. The draft
    /// still holds the default from before, so saving it would drop what
    /// the user typed without a word.
    pub unparsed_defaults: Vec<String>,
    /// The Next Auto Increment the user typed is no value the numbered
    /// column takes, so the draft holds the table's own.
    pub invalid_auto_increment: bool,
}

/// Why a structure cannot be saved as it stands.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SaveBlocker {
    Draft(DraftProblem),
    UnparsedDefault(String),
    InvalidAutoIncrement,
}

impl PendingStructure {
    /// Every save goes through this, the close prompts' included, which
    /// never pass the tab's own Save button.
    pub fn check(&self) -> Result<(), SaveBlocker> {
        self.draft.validate().map_err(SaveBlocker::Draft)?;
        if let Some(column) = self.unparsed_defaults.first() {
            return Err(SaveBlocker::UnparsedDefault(column.clone()));
        }
        match self.invalid_auto_increment {
            true => Err(SaveBlocker::InvalidAutoIncrement),
            false => Ok(()),
        }
    }

    /// Whether the draft holds every value the user typed.
    pub fn typed_values_hold(&self) -> bool {
        self.unparsed_defaults.is_empty() && !self.invalid_auto_increment
    }

    /// A value the draft cannot hold is still the user's edit, so without
    /// counting it here a close would drop it without asking.
    pub fn has_changes(&self) -> bool {
        let drafted = match self.original {
            Some(_) => !self.changes.is_empty(),
            None => !self.draft.columns.is_empty(),
        };
        drafted || !self.typed_values_hold()
    }

    /// The edits the action bar counts. A new table is one.
    pub fn change_count(&self) -> usize {
        let unheld = self.unparsed_defaults.len() + usize::from(self.invalid_auto_increment);
        match self.original {
            Some(_) => self.changes.change_count() + unheld,
            None => usize::from(!self.draft.columns.is_empty() || unheld > 0),
        }
    }

    /// Planned with the dialect of the connection that will run it, so the
    /// SQL is spelled for that server.
    pub fn plan(&self, ddl: &dyn DdlDialect) -> Result<DdlPlan, BuildDdlError> {
        match &self.original {
            Some(original) => {
                self.draft.validate()?;
                ddl.plan_alter_table(original, &self.changes)
            }
            None => ddl.plan_create_table(&self.draft),
        }
    }

    /// What the save would run and lose, planned as `plan` plans it.
    pub fn review(&self, ddl: &dyn DdlDialect) -> Result<ChangeReview, BuildDdlError> {
        let plan = self.plan(ddl)?;
        Ok(match self.original {
            Some(_) => ChangeReview::review(&self.changes, &plan),
            None => ChangeReview::create(&plan),
        })
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

    /// The name the tab follows once the save lands, when that is not the
    /// one it already shows: the table a draft created, or the new name of
    /// a renamed one.
    pub fn saved_table_name(&self) -> Option<String> {
        match &self.original {
            Some(_) => self.changes.renamed_table.clone(),
            None => Some(self.draft.table.name.trim().to_owned()),
        }
    }
}

#[cfg(test)]
mod tests {
    use crate::column::{
        CatalogType, ColumnDefault, ColumnInfo, ColumnKind, ColumnType, IntegerKind, IntegerWidth, ReadForm,
        SqlTypeExpr,
    };
    use crate::ddl::{
        ColumnAttributes, ColumnDefinition, DdlCapabilities, DraftColumn, DraftType, PrimaryKeyConstraint,
        ReferentialAction, diff_table,
    };
    use crate::dialect::{SqlDialect, TestDialect};

    use super::*;

    /// A dialect whose plans only check the draft or changes and report an
    /// empty plan, enough for the PendingStructure contract without a
    /// driver.
    #[derive(Debug)]
    struct TestDdl {
        capabilities: DdlCapabilities,
        sql: TestDialect,
    }

    impl TestDdl {
        fn new() -> Self {
            Self {
                capabilities: every_change(),
                sql: TestDialect::exact(),
            }
        }
    }

    impl DdlDialect for TestDdl {
        fn capabilities(&self) -> &DdlCapabilities {
            &self.capabilities
        }

        fn sql_dialect(&self) -> &dyn SqlDialect {
            &self.sql
        }

        fn type_suggestions(&self) -> &'static [&'static str] {
            &["integer"]
        }

        fn default_column_type(&self) -> &'static str {
            "integer"
        }

        fn referential_actions(&self) -> &'static [ReferentialAction] {
            &[ReferentialAction::NoAction, ReferentialAction::SetNull]
        }

        fn plan_create_table(&self, draft: &TableDraft) -> Result<DdlPlan, BuildDdlError> {
            draft.check_create(self)?;
            Ok(DdlPlan::from_sql(["CREATE TABLE t (id integer)".to_owned()]))
        }

        fn plan_alter_table(
            &self,
            original: &TableDefinition,
            changes: &TableChanges,
        ) -> Result<DdlPlan, BuildDdlError> {
            changes.check(self, original)?;
            Ok(DdlPlan::from_sql(["ALTER TABLE t ADD COLUMN c integer".to_owned()]))
        }
    }

    fn every_change() -> DdlCapabilities {
        DdlCapabilities {
            create_table: true,
            rename_table: true,
            add_column: true,
            drop_column: true,
            rename_column: true,
            alter_column_type: true,
            alter_column_nullability: true,
            alter_column_default: true,
            alter_primary_key: true,
            alter_auto_increment: true,
            auto_increment_outside_primary_key: true,
            create_index: true,
            drop_index: true,
            expression_index_keys: true,
            descending_index_keys: true,
            partial_indexes: true,
            add_foreign_key: true,
            drop_foreign_key: true,
            column_comments: true,
            drop_table_cascade: true,
            column_defaults: true,
            required_columns: true,
            declared_column_order: true,
            column_collations: true,
            table_options: true,
        }
    }

    fn integer() -> ColumnType {
        ColumnType {
            name: "integer".to_owned(),
            kind: ColumnKind::Integer(IntegerKind {
                width: IntegerWidth::W32,
                signed: true,
            }),
            catalog: Some(CatalogType {
                declaration: SqlTypeExpr::from_catalog_text("integer"),
                cast_target: SqlTypeExpr::from_catalog_text("integer"),
            }),
            dynamic_storage: false,
            read_form: ReadForm::Native,
        }
    }

    fn column(name: &str, primary_key: bool) -> ColumnDefinition {
        ColumnDefinition::new(
            ColumnInfo {
                name: name.to_owned(),
                column_type: integer(),
                nullable: !primary_key,
                primary_key,
                is_auto_increment: false,
                is_generated: false,
                partition_scoped: false,
                default: ColumnDefault::None,
                comment: None,
            },
            ColumnAttributes::default(),
        )
    }

    fn orders() -> TableDefinition {
        TableDefinition {
            table: TableRef::new(Some("app".to_owned()), "orders"),
            columns: vec![column("id", true), column("total", false)],
            primary_key: Some(PrimaryKeyConstraint {
                name: None,
                columns: vec!["id".to_owned()],
            }),
            indexes: Vec::new(),
            foreign_keys: Vec::new(),
            inbound_foreign_keys: Vec::new(),
            source: None,
            options: None,
        }
    }

    fn created() -> PendingStructure {
        let mut draft = TableDraft::new(TableRef::new(Some("app".to_owned()), " orders "));
        let mut id = DraftColumn::new("id", DraftType::Typed("integer".to_owned()));
        id.primary_key = true;
        id.nullable = false;
        draft.columns.push(id);
        PendingStructure {
            original: None,
            draft,
            changes: TableChanges::default(),
            unparsed_defaults: Vec::new(),
            invalid_auto_increment: false,
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
            invalid_auto_increment: false,
        }
    }

    #[test]
    fn a_new_table_plans_create_and_names_its_table_as_typed() {
        let pending = created();
        let ddl = TestDdl::new();

        assert!(pending.plan(&ddl).expect("the draft plans").sql()[0].starts_with("CREATE TABLE"));
        assert_eq!(pending.operation(), DdlOperation::CreateTable);
        assert_eq!(pending.table(), TableRef::new(Some("app".to_owned()), "orders"));
        assert_eq!(pending.saved_table_name().as_deref(), Some("orders"));
    }

    #[test]
    fn a_save_waits_for_a_valid_draft_and_every_typed_default() {
        let ddl = TestDdl::new();
        let mut typed_default = edited(|draft| draft.columns[1].nullable = false);
        typed_default.unparsed_defaults = vec!["total".to_owned()];
        let unnamed = edited(|draft| draft.columns[1].name = String::new());

        assert_eq!(
            typed_default.check(),
            Err(SaveBlocker::UnparsedDefault("total".to_owned()))
        );
        assert_eq!(unnamed.check(), Err(SaveBlocker::Draft(DraftProblem::EmptyColumnName)));
        assert_eq!(
            unnamed.plan(&ddl),
            Err(BuildDdlError::Draft(DraftProblem::EmptyColumnName))
        );
        assert_eq!(edited(|draft| draft.columns[1].nullable = false).check(), Ok(()));
        assert_eq!(unnamed.operation(), DdlOperation::AlterTable);
    }

    #[test]
    fn a_default_the_parser_refused_is_a_pending_change() {
        let mut typed_default = edited(|_| {});
        typed_default.unparsed_defaults = vec!["total".to_owned()];

        assert!(!edited(|_| {}).has_changes());
        assert!(typed_default.has_changes());
        assert_eq!(typed_default.change_count(), 1);
        assert!(!typed_default.typed_values_hold());
    }

    #[test]
    fn an_invalid_next_auto_increment_is_a_pending_change_that_holds_the_save() {
        let mut typed_counter = edited(|_| {});
        typed_counter.invalid_auto_increment = true;

        assert!(typed_counter.has_changes());
        assert_eq!(typed_counter.change_count(), 1);
        assert!(!typed_counter.typed_values_hold());
        assert_eq!(typed_counter.check(), Err(SaveBlocker::InvalidAutoIncrement));
    }

    #[test]
    fn an_edit_counts_its_changes_and_follows_a_rename() {
        let original = orders();
        let mut renamed = TableDraft::from_definition(&original);
        renamed.table.name = "purchases".to_owned();
        let pending = PendingStructure {
            changes: diff_table(&original, &renamed),
            original: Some(original.clone()),
            draft: renamed,
            unparsed_defaults: Vec::new(),
            invalid_auto_increment: false,
        };
        let unchanged = PendingStructure {
            changes: TableChanges::default(),
            draft: TableDraft::from_definition(&original),
            original: Some(original),
            unparsed_defaults: Vec::new(),
            invalid_auto_increment: false,
        };

        assert!(pending.has_changes());
        assert_eq!(pending.change_count(), 1);
        assert_eq!(pending.saved_table_name().as_deref(), Some("purchases"));
        assert_eq!(pending.table().name, "orders");
        assert!(!unchanged.has_changes());
        assert!(unchanged.review(&TestDdl::new()).is_ok());
    }
}
