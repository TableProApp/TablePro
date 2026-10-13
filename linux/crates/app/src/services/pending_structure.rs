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

    /// A default the parser refused is still the user's edit: the draft
    /// cannot hold it, so without counting it here a close would drop it
    /// without asking.
    pub fn has_changes(&self) -> bool {
        let drafted = match self.original {
            Some(_) => !self.changes.is_empty(),
            None => !self.draft.columns.is_empty(),
        };
        drafted || !self.unparsed_defaults.is_empty()
    }

    /// The edits the action bar counts. A new table is one.
    pub fn change_count(&self) -> usize {
        match self.original {
            Some(_) => self.changes.change_count() + self.unparsed_defaults.len(),
            None => usize::from(!self.draft.columns.is_empty() || !self.unparsed_defaults.is_empty()),
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
    use proptest::prelude::*;
    use tablepro_core::ServerInfo;
    use tablepro_core::column::{ColumnDefault, ColumnInfo};
    use tablepro_core::ddl::{
        ColumnAttributes, ColumnDefinition, DraftColumn, DraftType, PrimaryKeyConstraint, diff_table,
    };
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
    fn a_default_the_parser_refused_is_a_pending_change() {
        let mut typed_default = edited(|_| {});
        typed_default.unparsed_defaults = vec!["total".to_owned()];

        assert!(!edited(|_| {}).has_changes());
        assert!(typed_default.has_changes());
        assert_eq!(typed_default.change_count(), 1);
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

    /// One engine's dialect with the integer and text types its catalogue
    /// would report, and the name it gives a primary key.
    struct Engine {
        name: &'static str,
        dialect: Box<dyn SqlDialect>,
        integer: &'static str,
        text: &'static str,
        key_name: Option<&'static str>,
    }

    fn engines() -> Vec<Engine> {
        let server = |name, major| ServerInfo::new(name, format!("{major}.0"), major, 0, 0);
        let engine = |name, dialect: Box<dyn SqlDialect>, integer, text, key_name| Engine {
            name,
            dialect,
            integer,
            text,
            key_name,
        };
        vec![
            engine(
                "PostgreSQL",
                Box::new(drivers_postgres::PgDialect::new(&server("PostgreSQL", 18))),
                "integer",
                "text",
                Some("t_pkey"),
            ),
            engine(
                "MySQL",
                Box::new(drivers_mysql::MySqlDialect::new(
                    drivers_mysql::MySqlFlavour::MySql,
                    &ServerInfo::new("MySQL", "8.4.3", 8, 4, 3),
                )),
                "int",
                "varchar(40)",
                Some("PRIMARY"),
            ),
            engine(
                "MariaDB",
                Box::new(drivers_mysql::MySqlDialect::new(
                    drivers_mysql::MySqlFlavour::MariaDb,
                    &ServerInfo::new("MariaDB", "11.4.5", 11, 4, 5),
                )),
                "int",
                "varchar(40)",
                Some("PRIMARY"),
            ),
            engine(
                "SQL Server",
                Box::new(drivers_mssql::MssqlDialect::new(16)),
                "int",
                "nvarchar(40)",
                Some("PK_t"),
            ),
            engine(
                "SQLite",
                Box::new(drivers_sqlite::SqliteDialect::new(drivers_sqlite::SqliteVersion::new(
                    3, 46, 0,
                ))),
                "INTEGER",
                "TEXT",
                None,
            ),
            engine(
                "ClickHouse",
                Box::new(drivers_clickhouse::ClickHouseDialect::new(&server("ClickHouse", 25))),
                "Int32",
                "String",
                None,
            ),
        ]
    }

    /// `id` keyed, `name`, `score` with a default and `note` with a
    /// comment, as the engine's catalogue reads them.
    fn table(engine: &Engine) -> TableDefinition {
        let column = |name: &str, declaration: &str| {
            let column_type = engine.dialect.parse_type(declaration).expect("the engine's own type");
            ColumnDefinition::new(
                ColumnInfo {
                    name: name.to_owned(),
                    column_type,
                    nullable: name != "id",
                    primary_key: name == "id",
                    is_auto_increment: false,
                    is_generated: false,
                    default: ColumnDefault::None,
                    comment: None,
                },
                ColumnAttributes::default(),
            )
        };
        let mut score = column("score", engine.integer);
        score.info.default = ColumnDefault::Literal(tablepro_core::Value::Int(0));
        score.attributes.default_constraint_name = Some("DF_t_score".to_owned());
        let mut note = column("note", engine.text);
        note.info.comment = Some("kept".to_owned());
        TableDefinition {
            table: TableRef::new(Some("app".to_owned()), "t"),
            columns: vec![column("id", engine.integer), column("name", engine.text), score, note],
            primary_key: engine.key_name.map(|name| PrimaryKeyConstraint {
                name: Some(name.to_owned()),
                columns: vec!["id".to_owned()],
            }),
            indexes: Vec::new(),
            foreign_keys: Vec::new(),
            inbound_foreign_keys: Vec::new(),
            source: None,
        }
    }

    /// One edit the Structure tab can make, aimed at a column by
    /// position so every edit lands on some column.
    #[derive(Debug, Clone)]
    enum Edit {
        RenameTable,
        Rename(usize, usize),
        Nullable(usize),
        PrimaryKey(usize),
        AutoIncrement(usize),
        Default(usize, Option<i64>),
        Retype(usize, bool),
        Comment(usize),
        Drop(usize),
        Add(usize),
    }

    const NAMES: [&str; 6] = ["id", "name", "score", "note", "fresh", "Score"];

    fn edit() -> impl Strategy<Value = Edit> {
        let column = 0usize..8;
        let name = 0..NAMES.len();
        prop_oneof![
            Just(Edit::RenameTable),
            (column.clone(), name.clone()).prop_map(|(column, name)| Edit::Rename(column, name)),
            column.clone().prop_map(Edit::Nullable),
            column.clone().prop_map(Edit::PrimaryKey),
            column.clone().prop_map(Edit::AutoIncrement),
            (column.clone(), proptest::option::of(-2i64..3)).prop_map(|(column, value)| Edit::Default(column, value)),
            (column.clone(), any::<bool>()).prop_map(|(column, integer)| Edit::Retype(column, integer)),
            column.clone().prop_map(Edit::Comment),
            column.prop_map(Edit::Drop),
            name.prop_map(Edit::Add),
        ]
    }

    fn column(draft: &mut TableDraft, index: usize) -> Option<&mut DraftColumn> {
        let count = draft.columns.len();
        draft.columns.get_mut(index.checked_rem(count)?)
    }

    fn apply(draft: &mut TableDraft, edit: &Edit, engine: &Engine) {
        match *edit {
            Edit::RenameTable => draft.table.name = "renamed".to_owned(),
            Edit::Add(name) => draft
                .columns
                .push(DraftColumn::new(NAMES[name], DraftType::Typed(engine.text.to_owned()))),
            Edit::Drop(index) => {
                if let Some(index) = index.checked_rem(draft.columns.len()) {
                    draft.columns.remove(index);
                }
            }
            Edit::Rename(index, name) => {
                if let Some(column) = column(draft, index) {
                    column.name = NAMES[name].to_owned();
                }
            }
            Edit::Nullable(index) => {
                if let Some(column) = column(draft, index) {
                    column.nullable = !column.nullable;
                }
            }
            Edit::PrimaryKey(index) => {
                if let Some(column) = column(draft, index) {
                    column.primary_key = !column.primary_key;
                    column.nullable &= !column.primary_key;
                }
            }
            Edit::AutoIncrement(index) => {
                if let Some(column) = column(draft, index) {
                    column.auto_increment = !column.auto_increment;
                }
            }
            Edit::Default(index, value) => {
                if let Some(column) = column(draft, index) {
                    column.default = value.map_or(ColumnDefault::None, |value| {
                        ColumnDefault::Literal(tablepro_core::Value::Int(value))
                    });
                }
            }
            Edit::Retype(index, integer) => {
                if let Some(column) = column(draft, index) {
                    let declaration = if integer { engine.integer } else { engine.text };
                    column.column_type = DraftType::Typed(declaration.to_owned());
                }
            }
            Edit::Comment(index) => {
                if let Some(column) = column(draft, index) {
                    column.comment = match column.comment {
                        Some(_) => None,
                        None => Some("new".to_owned()),
                    };
                }
            }
        }
    }

    proptest! {
        /// A save that changes something either writes a statement or is
        /// refused: it never succeeds with the table left as it was.
        #[test]
        fn non_empty_changes_never_plan_empty(edits in proptest::collection::vec(edit(), 1..6)) {
            for engine in engines() {
                let original = table(&engine);
                let mut draft = TableDraft::from_definition(&original);
                for edit in &edits {
                    apply(&mut draft, edit, &engine);
                }
                let changes = diff_table(&original, &draft);
                if changes.is_empty() {
                    continue;
                }
                let ddl = engine.dialect.ddl().expect("every engine plans its DDL");
                let plan = ddl.plan_alter_table(&original, &changes);
                prop_assert!(
                    !matches!(&plan, Ok(plan) if plan.is_empty()),
                    "{} planned nothing for {changes:?}",
                    engine.name
                );
            }
        }
    }
}
