use tablepro_core::ForeignKeyInfo;
use tablepro_core::column::ColumnDefault;
use tablepro_core::ddl::ddl_sql::{column_list, default_sql, foreign_key_sql, index_keys_sql, parenthesized};
use tablepro_core::ddl::{
    BuildDdlError, DdlCapabilities, DdlDialect, DdlOperation, DdlPlan, DraftColumn, GeneratedStorage, SchemaObjectKind,
    TableChanges, TableDefinition, TableDraft,
};
use tablepro_core::dialect::SqlDialect;
use tablepro_core::meta::{IndexInfo, TableRef};

use crate::dialect::SqliteDialect;

/// What SQLite's ALTER TABLE does natively. Everything else needs the
/// table rebuilt, which these plans do not do yet.
static CAPABILITIES: DdlCapabilities = DdlCapabilities {
    create_table: true,
    rename_table: true,
    add_column: true,
    drop_column: true,
    rename_column: true,
    alter_column_type: false,
    alter_column_nullability: false,
    alter_column_default: false,
    alter_primary_key: false,
    alter_auto_increment: false,
    create_index: true,
    drop_index: true,
    expression_index_keys: true,
    partial_indexes: true,
    add_foreign_key: false,
    drop_foreign_key: false,
    column_comments: false,
    drop_table_cascade: false,
};

const TYPE_SUGGESTIONS: &[&str] = &[
    "INTEGER", "TEXT", "REAL", "BLOB", "NUMERIC", "BOOLEAN", "DATETIME", "DATE",
];

/// SQLite runs a schema change inside the write's transaction, one
/// native ALTER TABLE per change.
impl DdlDialect for SqliteDialect {
    fn capabilities(&self) -> &DdlCapabilities {
        &CAPABILITIES
    }

    fn sql_dialect(&self) -> &dyn SqlDialect {
        self
    }

    fn type_suggestions(&self) -> &'static [&'static str] {
        TYPE_SUGGESTIONS
    }

    fn default_column_type(&self) -> &'static str {
        "TEXT"
    }

    /// Foreign keys are declared inside CREATE TABLE, the only place
    /// SQLite takes them.
    fn plan_create_table(&self, draft: &TableDraft) -> Result<DdlPlan, BuildDdlError> {
        draft.check_create(self)?;
        let table = TableRef::new(draft.table.schema.clone(), draft.table.name.trim());
        let key = draft.primary_key();
        // AUTOINCREMENT is only legal on the column's own PRIMARY KEY
        // clause, which also makes it the rowid alias.
        let inline_key = match key.as_slice() {
            [only] => draft
                .column(only)
                .filter(|column| column.auto_increment)
                .map(|column| column.name.as_str()),
            _ => None,
        };
        let mut definitions = draft
            .columns
            .iter()
            .map(|column| self.column_definition(column, inline_key == Some(column.name.as_str())))
            .collect::<Result<Vec<_>, _>>()?;
        if inline_key.is_none() && !key.is_empty() {
            let key: Vec<String> = key.into_iter().map(str::to_owned).collect();
            definitions.push(format!("PRIMARY KEY ({})", column_list(self, &key)));
        }
        // A foreign key names its parent bare: SQLite looks for it in the
        // child's own schema and refuses a qualified name.
        let local = TableRef::unqualified(table.name.clone());
        definitions.extend(draft.foreign_keys.iter().map(|key| {
            let key = ForeignKeyInfo {
                ref_schema: None,
                ..key.clone()
            };
            foreign_key_sql(self, &local, &key)
        }));
        let mut statements = vec![format!(
            "CREATE TABLE {} (\n  {}\n)",
            self.qualify(&table),
            definitions.join(",\n  ")
        )];
        statements.extend(
            draft
                .indexes
                .iter()
                .filter(|index| !index.primary)
                .map(|index| self.create_index(&table, index)),
        );
        Ok(DdlPlan::from_sql(statements))
    }

    fn plan_alter_table(&self, original: &TableDefinition, changes: &TableChanges) -> Result<DdlPlan, BuildDdlError> {
        changes.check(self, original)?;
        let mut statements = Vec::new();
        // SQLite keeps a renamed table in its schema, so the new name is
        // bare.
        if let Some(name) = &changes.renamed_table {
            statements.push(format!(
                "ALTER TABLE {} RENAME TO {}",
                self.qualify(&original.table),
                self.quote_identifier(name)
            ));
        }
        let table = changes.target(&original.table);
        let qualified = self.qualify(&table);
        // SQLite refuses to drop an indexed column, so the index goes
        // first.
        for index in &changes.dropped_indexes {
            let index = TableRef::new(table.schema.clone(), index.name.clone());
            statements.push(format!("DROP INDEX {}", self.qualify(&index)));
        }
        for column in &changes.dropped_columns {
            statements.push(format!(
                "ALTER TABLE {qualified} DROP COLUMN {}",
                self.quote_identifier(column.name())
            ));
        }
        for rename in &changes.renamed_columns {
            statements.push(format!(
                "ALTER TABLE {qualified} RENAME COLUMN {} TO {}",
                self.quote_identifier(&rename.from),
                self.quote_identifier(&rename.to)
            ));
        }
        for column in &changes.added_columns {
            // The rows already there would have nothing to hold.
            if !column.nullable && column.default.is_none() {
                return Err(BuildDdlError::Unsupported(
                    DdlOperation::AddRequiredColumnWithoutDefault,
                ));
            }
            statements.push(format!(
                "ALTER TABLE {qualified} ADD COLUMN {}",
                self.column_definition(column, false)?
            ));
        }
        statements.extend(
            changes
                .added_indexes
                .iter()
                .map(|index| self.create_index(&table, index)),
        );
        Ok(DdlPlan::from_sql(statements))
    }

    /// The CREATE statement SQLite stored, then the stored statements of
    /// the table's own indexes and triggers. Indexes SQLite made for a
    /// constraint have no statement and come back with the table.
    fn create_table_script(&self, definition: &TableDefinition) -> Result<DdlPlan, BuildDdlError> {
        let Some(source) = &definition.source else {
            return self.plan_create_table(&TableDraft::from_definition(definition));
        };
        let own = |table: &str| table.eq_ignore_ascii_case(&definition.table.name);
        let dependents = source
            .dependents
            .iter()
            .filter(|object| matches!(object.kind, SchemaObjectKind::Index | SchemaObjectKind::Trigger))
            .filter(|object| own(&object.table))
            .map(|object| object.sql.clone());
        Ok(DdlPlan::from_sql(
            std::iter::once(source.create_statement.clone()).chain(dependents),
        ))
    }
}

impl SqliteDialect {
    fn column_definition(&self, column: &DraftColumn, inline_key: bool) -> Result<String, BuildDdlError> {
        let resolved = column.column_type.resolve(self, &column.name)?;
        let mut parts = vec![self.quote_identifier(&column.name), resolved.sql.clone()];
        if inline_key {
            parts.push("PRIMARY KEY AUTOINCREMENT".to_owned());
        }
        if !column.nullable {
            parts.push("NOT NULL".to_owned());
        }
        let generated = column
            .original
            .as_ref()
            .and_then(|original| original.attributes.generated.as_ref());
        if let Some(generated) = generated {
            let storage = match generated.storage {
                GeneratedStorage::Stored => "STORED",
                GeneratedStorage::Virtual => "VIRTUAL",
            };
            parts.push(format!(
                "GENERATED ALWAYS AS {} {storage}",
                parenthesized(generated.expression.as_sql())
            ));
        } else if let Some(default) = default_sql(self, &column.name, &column.default, &resolved.column_type)? {
            parts.push(format!("DEFAULT {}", default_clause(&column.default, &default)));
        }
        Ok(parts.join(" "))
    }

    /// The index takes the schema and the table stays bare: SQLite
    /// creates an index in its table's schema and reads `ON` unqualified.
    fn create_index(&self, table: &TableRef, index: &IndexInfo) -> String {
        let unique = if index.unique { "UNIQUE " } else { "" };
        let name = TableRef::new(table.schema.clone(), index.name.clone());
        let mut sql = format!(
            "CREATE {unique}INDEX {} ON {} ({})",
            self.qualify(&name),
            self.quote_identifier(&table.name),
            index_keys_sql(self, index)
        );
        if let Some(predicate) = &index.predicate {
            sql.push_str(&format!(" WHERE {predicate}"));
        }
        sql
    }
}

/// An expression default goes in parentheses, apart from the three
/// CURRENT_ keywords SQLite takes bare.
fn default_clause(default: &ColumnDefault, sql: &str) -> String {
    let keyword = ["CURRENT_TIME", "CURRENT_DATE", "CURRENT_TIMESTAMP"]
        .iter()
        .any(|keyword| sql.trim().eq_ignore_ascii_case(keyword));
    match default {
        ColumnDefault::Expression(_) if !keyword => parenthesized(sql),
        _ => sql.to_owned(),
    }
}

#[cfg(test)]
mod tests {
    use tablepro_core::column::{ColumnInfo, SqlExpression};
    use tablepro_core::ddl::ReferentialAction;
    use tablepro_core::ddl::{
        ColumnAttributes, ColumnDefinition, DraftType, InboundForeignKey, Permission, RefusalReason,
        SchemaObjectSource, TableSource, diff_table,
    };
    use tablepro_core::meta::IndexKey;
    use tablepro_core::value::Value;

    use super::*;
    use crate::catalog::SqliteVersion;

    fn dialect() -> SqliteDialect {
        SqliteDialect::new(SqliteVersion::new(3, 46, 0))
    }

    fn typed(name: &str, declaration: &str) -> DraftColumn {
        DraftColumn::new(name, DraftType::Typed(declaration.to_owned()))
    }

    fn column(name: &str, declaration: &str, primary_key: bool) -> ColumnDefinition {
        ColumnDefinition::new(
            ColumnInfo {
                name: name.to_owned(),
                column_type: dialect().parse_type(declaration).expect("a SQLite type"),
                nullable: !primary_key,
                primary_key,
                is_auto_increment: false,
                is_generated: false,
                default: tablepro_core::column::ColumnDefault::None,
                comment: None,
            },
            ColumnAttributes::default(),
        )
    }

    fn users() -> TableDefinition {
        TableDefinition {
            table: TableRef::unqualified("users"),
            columns: vec![column("id", "INTEGER", true), column("email", "TEXT", false)],
            primary_key: Some(tablepro_core::ddl::PrimaryKeyConstraint {
                name: None,
                columns: vec!["id".to_owned()],
            }),
            indexes: Vec::new(),
            foreign_keys: Vec::new(),
            inbound_foreign_keys: Vec::new(),
            source: None,
        }
    }

    fn alter(original: &TableDefinition, edit: impl FnOnce(&mut TableDraft)) -> Result<DdlPlan, BuildDdlError> {
        let mut draft = TableDraft::from_definition(original);
        edit(&mut draft);
        dialect().plan_alter_table(original, &diff_table(original, &draft))
    }

    fn sql(plan: Result<DdlPlan, BuildDdlError>) -> Vec<String> {
        plan.expect("the change plans")
            .sql()
            .into_iter()
            .map(str::to_owned)
            .collect()
    }

    #[test]
    fn plan_create_table_simple() {
        let mut draft = TableDraft::new(TableRef::unqualified("notes"));
        let mut id = typed("id", "INTEGER");
        id.primary_key = true;
        id.nullable = false;
        id.auto_increment = true;
        let mut body = typed("body", "TEXT");
        body.nullable = false;
        body.default = ColumnDefault::Literal(Value::Text("it's".to_owned()));
        let mut created = typed("created_at", "TEXT");
        created.default = ColumnDefault::Expression(SqlExpression::from_catalog_text("CURRENT_TIMESTAMP"));
        let mut token = typed("token", "TEXT");
        token.default = ColumnDefault::Expression(SqlExpression::from_catalog_text("lower(hex(randomblob(4)))"));
        draft.columns = vec![id, body, created, token];

        assert_eq!(
            sql(dialect().plan_create_table(&draft)),
            [
                "CREATE TABLE \"notes\" (\n  \"id\" INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,\n  \"body\" TEXT NOT \
              NULL DEFAULT 'it''s',\n  \"created_at\" TEXT DEFAULT CURRENT_TIMESTAMP,\n  \"token\" TEXT DEFAULT \
              (lower(hex(randomblob(4))))\n)"
            ]
        );
    }

    #[test]
    fn plan_create_table_composite_key_index_and_foreign_key() {
        let mut draft = TableDraft::new(TableRef::new(Some("main".to_owned()), "lines"));
        let mut order = typed("order_id", "INTEGER");
        order.primary_key = true;
        order.nullable = false;
        let mut line = typed("line", "INTEGER");
        line.primary_key = true;
        line.nullable = false;
        draft.columns = vec![order, line, typed("sku", "TEXT")];
        draft.indexes = vec![IndexInfo {
            name: "by_sku".to_owned(),
            keys: vec![IndexKey::Column {
                name: "sku".to_owned(),
                descending: false,
            }],
            unique: true,
            primary: false,
            predicate: Some("sku IS NOT NULL".to_owned()),
        }];
        draft.foreign_keys = vec![ForeignKeyInfo {
            name: "lines_order_fk".to_owned(),
            columns: vec!["order_id".to_owned()],
            ref_schema: None,
            ref_table: "orders".to_owned(),
            ref_columns: vec!["id".to_owned()],
            on_delete: Some(ReferentialAction::Cascade),
            on_update: None,
        }];

        assert_eq!(
            sql(dialect().plan_create_table(&draft)),
            [
                "CREATE TABLE \"main\".\"lines\" (\n  \"order_id\" INTEGER NOT NULL,\n  \"line\" INTEGER NOT \
                 NULL,\n  \"sku\" TEXT,\n  PRIMARY KEY (\"order_id\", \"line\"),\n  CONSTRAINT \"lines_order_fk\" \
                 FOREIGN KEY (\"order_id\") REFERENCES \"orders\" (\"id\") ON DELETE CASCADE\n)",
                "CREATE UNIQUE INDEX \"main\".\"by_sku\" ON \"lines\" (\"sku\") WHERE sku IS NOT NULL",
            ]
        );
    }

    #[test]
    fn plan_alter_table_takes_the_native_changes_and_refuses_the_rest() {
        let native = alter(&users(), |draft| {
            draft.table.name = "members".to_owned();
            draft.columns[1].name = "mail".to_owned();
            draft.columns.push(typed("nickname", "TEXT"));
        });
        let nullability = alter(&users(), |draft| draft.columns[1].nullable = false);
        let typed_change = alter(&users(), |draft| {
            draft.columns[1].column_type = DraftType::Typed("BLOB".to_owned());
        });
        let default = alter(&users(), |draft| {
            draft.columns[1].default = ColumnDefault::Literal(Value::Text("x".to_owned()));
        });

        assert_eq!(
            sql(native),
            [
                "ALTER TABLE \"users\" RENAME TO \"members\"",
                "ALTER TABLE \"members\" RENAME COLUMN \"email\" TO \"mail\"",
                "ALTER TABLE \"members\" ADD COLUMN \"nickname\" TEXT",
            ]
        );
        for refused in [nullability, typed_change, default] {
            assert!(
                matches!(
                    refused,
                    Err(BuildDdlError::Refused {
                        reason: RefusalReason::EngineUnsupported,
                        ..
                    })
                ),
                "{refused:?}"
            );
        }
    }

    #[test]
    fn a_required_column_without_a_default_cannot_be_added() {
        let plan = alter(&users(), |draft| {
            let mut required = typed("nickname", "TEXT");
            required.nullable = false;
            draft.columns.push(required);
        });

        assert_eq!(
            plan,
            Err(BuildDdlError::Unsupported(
                DdlOperation::AddRequiredColumnWithoutDefault
            ))
        );
    }

    #[test]
    fn an_indexed_column_drop_drops_the_index_first() {
        let mut table = users();
        table.indexes = vec![IndexInfo {
            name: "by_email".to_owned(),
            keys: vec![IndexKey::Column {
                name: "email".to_owned(),
                descending: false,
            }],
            unique: false,
            primary: false,
            predicate: None,
        }];

        let plan = alter(&table, |draft| {
            draft.indexes.clear();
            draft.columns.retain(|column| column.name != "email");
        });

        assert_eq!(
            sql(plan),
            ["DROP INDEX \"by_email\"", "ALTER TABLE \"users\" DROP COLUMN \"email\""]
        );
    }

    #[test]
    fn primary_key_referenced_by_foreign_key_is_refused() {
        let mut table = users();
        // SQLite reports a reference to the primary key with a NULL
        // target, which the catalogue resolves to the key's columns.
        table.inbound_foreign_keys = vec![InboundForeignKey {
            name: "fk_orders_0".to_owned(),
            table: TableRef::unqualified("orders"),
            columns: vec!["user_id".to_owned()],
            referenced_columns: vec!["id".to_owned()],
        }];

        let permissions = dialect().column_capabilities(&table, &table.columns[1]);
        let id = dialect().column_capabilities(&table, &table.columns[0]);

        assert_eq!(
            permissions.alter_primary_key,
            Permission::Refused(RefusalReason::ReferencedByForeignKeys(vec!["fk_orders_0".to_owned()]))
        );
        assert_eq!(
            id.drop,
            Permission::Refused(RefusalReason::ReferencedByForeignKeys(vec!["fk_orders_0".to_owned()]))
        );
    }

    #[test]
    fn drop_of_referenced_column_is_refused() {
        let mut table = users();
        table.inbound_foreign_keys = vec![InboundForeignKey {
            name: "fk_orders_0".to_owned(),
            table: TableRef::unqualified("orders"),
            columns: vec!["user_email".to_owned()],
            referenced_columns: vec!["email".to_owned()],
        }];

        let plan = alter(&table, |draft| draft.columns.retain(|column| column.name != "email"));

        assert!(
            matches!(
                plan,
                Err(BuildDdlError::Refused {
                    operation: DdlOperation::DropColumn,
                    reason: RefusalReason::ReferencedByForeignKeys(_),
                    ..
                })
            ),
            "{plan:?}"
        );
    }

    #[test]
    fn the_script_replays_the_stored_table_and_its_own_dependents() {
        let mut table = users();
        let object = |kind, name: &str, owner: &str, sql: &str| SchemaObjectSource {
            kind,
            name: name.to_owned(),
            table: owner.to_owned(),
            sql: sql.to_owned(),
        };
        table.source = Some(TableSource {
            create_statement: "CREATE TABLE users (id INTEGER PRIMARY KEY, email TEXT)".to_owned(),
            dependents: vec![
                object(
                    SchemaObjectKind::Index,
                    "by_email",
                    "Users",
                    "CREATE INDEX by_email ON users (email)",
                ),
                object(
                    SchemaObjectKind::Index,
                    "by_total",
                    "orders",
                    "CREATE INDEX by_total ON orders (total)",
                ),
                object(
                    SchemaObjectKind::Trigger,
                    "stamp",
                    "users",
                    "CREATE TRIGGER stamp AFTER INSERT ON users BEGIN SELECT 1; END",
                ),
                object(SchemaObjectKind::View, "v", "v", "CREATE VIEW v AS SELECT * FROM users"),
            ],
        });

        assert_eq!(
            sql(dialect().create_table_script(&table)),
            [
                "CREATE TABLE users (id INTEGER PRIMARY KEY, email TEXT)",
                "CREATE INDEX by_email ON users (email)",
                "CREATE TRIGGER stamp AFTER INSERT ON users BEGIN SELECT 1; END",
            ]
        );
    }

    #[test]
    fn foreign_keys_and_comments_wait_for_the_rebuild() {
        let dialect = dialect();
        let capabilities = DdlDialect::capabilities(&dialect);

        assert!(!capabilities.add_foreign_key && !capabilities.drop_foreign_key);
        assert!(!capabilities.column_comments);
        assert!(capabilities.partial_indexes && capabilities.expression_index_keys);
    }

    #[test]
    fn every_type_suggestion_parses() {
        let dialect = dialect();

        for suggestion in dialect.type_suggestions() {
            assert!(dialect.parse_type(suggestion).is_ok(), "{suggestion}");
        }
        assert!(dialect.parse_type(dialect.default_column_type()).is_ok());
    }
}
