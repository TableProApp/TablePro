use tablepro_core::column::{ColumnKind, ColumnType, IntegerKind, IntegerWidth};
use tablepro_core::ddl::ddl_sql::{column_list, create_index_sql, default_sql, foreign_key_sql};
use tablepro_core::ddl::{
    BuildDdlError, CollationName, DdlCapabilities, DdlDialect, DdlPlan, DraftColumn, GeneratedStorage, IdentityStyle,
    TableChanges, TableDefinition, TableDraft,
};
use tablepro_core::dialect::SqlDialect;
use tablepro_core::meta::TableRef;
use tablepro_core::value::Value;

use crate::dialect::PgDialect;

static CAPABILITIES: DdlCapabilities = DdlCapabilities {
    create_table: true,
    rename_table: true,
    add_column: true,
    drop_column: true,
    rename_column: true,
    alter_column_type: true,
    alter_column_nullability: true,
    alter_column_default: true,
    alter_primary_key: true,
    // An identity added to a column with rows has to start past them,
    // which needs a setval this plan does not write yet.
    alter_auto_increment: false,
    create_index: true,
    drop_index: true,
    expression_index_keys: true,
    partial_indexes: true,
    add_foreign_key: true,
    drop_foreign_key: true,
    column_comments: true,
    drop_table_cascade: true,
};

const TYPE_SUGGESTIONS: &[&str] = &[
    "integer",
    "bigint",
    "smallint",
    "text",
    "varchar(255)",
    "boolean",
    "timestamp",
    "timestamp with time zone",
    "date",
    "time",
    "numeric(10, 2)",
    "real",
    "double precision",
    "uuid",
    "jsonb",
    "json",
    "bytea",
];

/// PostgreSQL changes a table in one ALTER TABLE: it orders the
/// subcommands itself, drops before adds, so one statement carries
/// every column change and the whole change commits or none of it does.
/// Renames cannot share it, and indexes and comments are statements of
/// their own.
impl DdlDialect for PgDialect {
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
        "text"
    }

    fn plan_create_table(&self, draft: &TableDraft) -> Result<DdlPlan, BuildDdlError> {
        draft.check_create(self)?;
        let table = TableRef::new(draft.table.schema.clone(), draft.table.name.trim());
        let mut definitions = draft
            .columns
            .iter()
            .map(|column| self.column_definition(column))
            .collect::<Result<Vec<_>, _>>()?;
        let key: Vec<String> = draft.primary_key().into_iter().map(str::to_owned).collect();
        if !key.is_empty() {
            definitions.push(format!("PRIMARY KEY ({})", column_list(self, &key)));
        }
        definitions.extend(draft.foreign_keys.iter().map(|key| foreign_key_sql(self, &table, key)));
        let mut statements = vec![format!(
            "CREATE TABLE {} (\n  {}\n)",
            self.qualify(&table),
            definitions.join(",\n  ")
        )];
        for column in &draft.columns {
            if let Some(comment) = column.comment_text() {
                statements.push(self.comment_on(&table, &column.name, Some(comment)));
            }
        }
        statements.extend(
            draft
                .indexes
                .iter()
                .filter(|index| !index.primary)
                .map(|index| create_index_sql(self, &table, index)),
        );
        Ok(DdlPlan::from_sql(statements))
    }

    fn plan_alter_table(&self, original: &TableDefinition, changes: &TableChanges) -> Result<DdlPlan, BuildDdlError> {
        changes.check(self, original)?;
        let mut statements = Vec::new();
        if let Some(name) = &changes.renamed_table {
            statements.push(format!(
                "ALTER TABLE {} RENAME TO {}",
                self.qualify(&original.table),
                self.quote_identifier(name)
            ));
        }
        let table = changes.target(&original.table);
        let qualified = self.qualify(&table);
        for rename in &changes.renamed_columns {
            statements.push(format!(
                "ALTER TABLE {qualified} RENAME COLUMN {} TO {}",
                self.quote_identifier(&rename.from),
                self.quote_identifier(&rename.to)
            ));
        }
        // A column drop takes its indexes with it, so the explicit drops
        // go first.
        for index in &changes.dropped_indexes {
            let index = TableRef::new(table.schema.clone(), index.name.clone());
            statements.push(format!("DROP INDEX {}", self.qualify(&index)));
        }

        let mut actions = Vec::new();
        for key in &changes.dropped_foreign_keys {
            actions.push(format!("DROP CONSTRAINT {}", self.quote_identifier(&key.name)));
        }
        let old_key = changes
            .primary_key
            .as_ref()
            .and_then(|change| change.from.as_ref())
            .and_then(|key| key.name.as_ref());
        if let Some(name) = old_key {
            actions.push(format!("DROP CONSTRAINT {}", self.quote_identifier(name)));
        }
        for column in &changes.dropped_columns {
            actions.push(format!("DROP COLUMN {}", self.quote_identifier(column.name())));
        }
        for alteration in &changes.altered_columns {
            let draft = &alteration.draft;
            let name = self.quote_identifier(&draft.name);
            let changed = alteration.changed;
            if changed.column_type {
                let resolved = draft.column_type.resolve(self, &draft.name)?;
                actions.push(format!(
                    "ALTER COLUMN {name} TYPE {} USING {name}::{}",
                    resolved.sql, resolved.sql
                ));
            }
            if changed.nullability {
                let action = if draft.nullable {
                    "DROP NOT NULL"
                } else {
                    "SET NOT NULL"
                };
                actions.push(format!("ALTER COLUMN {name} {action}"));
            }
            if changed.default {
                let column_type = draft.column_type.column_type(self, &draft.name)?;
                actions.push(match default_sql(self, &draft.name, &draft.default, &column_type)? {
                    Some(default) => format!("ALTER COLUMN {name} SET DEFAULT {default}"),
                    None => format!("ALTER COLUMN {name} DROP DEFAULT"),
                });
            }
        }
        for column in &changes.added_columns {
            actions.push(format!("ADD COLUMN {}", self.column_definition(column)?));
        }
        if let Some(change) = changes.primary_key.as_ref().filter(|change| !change.to.is_empty()) {
            actions.push(format!("ADD PRIMARY KEY ({})", column_list(self, &change.to)));
        }
        for key in &changes.added_foreign_keys {
            actions.push(format!("ADD {}", foreign_key_sql(self, &table, key)));
        }
        if !actions.is_empty() {
            statements.push(format!("ALTER TABLE {qualified} {}", actions.join(", ")));
        }

        let altered_comments = changes
            .altered_columns
            .iter()
            .filter(|alteration| alteration.changed.comment)
            .map(|alteration| &alteration.draft);
        let added_comments = changes
            .added_columns
            .iter()
            .filter(|column| column.comment_text().is_some());
        for column in altered_comments.chain(added_comments) {
            statements.push(self.comment_on(&table, &column.name, column.comment_text()));
        }
        statements.extend(
            changes
                .added_indexes
                .iter()
                .map(|index| create_index_sql(self, &table, index)),
        );
        Ok(DdlPlan::from_sql(statements))
    }
}

impl PgDialect {
    /// A column as CREATE TABLE and ADD COLUMN declare it. A column read
    /// from the catalogue keeps its collation, its identity style and its
    /// generation expression.
    fn column_definition(&self, column: &DraftColumn) -> Result<String, BuildDdlError> {
        let resolved = column.column_type.resolve(self, &column.name)?;
        let attributes = column.original.as_ref().map(|original| &original.attributes);
        // A serial column numbers itself through a sequence default, and
        // only its pseudo-type makes one again: an identity clause would
        // be another kind of column.
        let serial = attributes
            .filter(|attributes| column.auto_increment && attributes.identity == IdentityStyle::SequenceDefault)
            .and_then(|_| serial_type(&resolved.column_type));
        let declaration = serial.map_or_else(|| resolved.sql.clone(), str::to_owned);
        let mut parts = vec![self.quote_identifier(&column.name), declaration];
        if let Some(collation) = attributes.and_then(|attributes| attributes.collation.as_ref()) {
            parts.push(format!("COLLATE {}", self.collation(collation)));
        }
        if let Some(generated) = attributes.and_then(|attributes| attributes.generated.as_ref()) {
            let storage = match generated.storage {
                GeneratedStorage::Stored => "STORED",
                GeneratedStorage::Virtual => "VIRTUAL",
            };
            parts.push(format!("GENERATED ALWAYS AS ({}) {storage}", generated.expression));
        } else if column.auto_increment && serial.is_none() {
            let always = attributes.is_some_and(|attributes| attributes.identity == IdentityStyle::GeneratedAlways);
            parts.push(match always {
                true => "GENERATED ALWAYS AS IDENTITY".to_owned(),
                false => "GENERATED BY DEFAULT AS IDENTITY".to_owned(),
            });
        } else if serial.is_none()
            && let Some(default) = default_sql(self, &column.name, &column.default, &resolved.column_type)?
        {
            parts.push(format!("DEFAULT {default}"));
        }
        if !column.nullable {
            parts.push("NOT NULL".to_owned());
        }
        Ok(parts.join(" "))
    }

    fn collation(&self, collation: &CollationName) -> String {
        match &collation.schema {
            Some(schema) => format!(
                "{}.{}",
                self.quote_identifier(schema),
                self.quote_identifier(&collation.name)
            ),
            None => self.quote_identifier(&collation.name),
        }
    }

    fn comment_on(&self, table: &TableRef, column: &str, comment: Option<&str>) -> String {
        let target = format!("{}.{}", self.qualify(table), self.quote_identifier(column));
        let text = comment.map(|text| Value::Text(text.to_owned()));
        match text.and_then(|text| SqlDialect::literal(self, &text, &ColumnType::untyped_text("text")).ok()) {
            Some(literal) => format!("COMMENT ON COLUMN {target} IS {literal}"),
            None => format!("COMMENT ON COLUMN {target} IS NULL"),
        }
    }
}

fn serial_type(column_type: &ColumnType) -> Option<&'static str> {
    match &column_type.kind {
        ColumnKind::Integer(IntegerKind {
            width: IntegerWidth::W16,
            ..
        }) => Some("smallserial"),
        ColumnKind::Integer(IntegerKind {
            width: IntegerWidth::W32,
            ..
        }) => Some("serial"),
        ColumnKind::Integer(IntegerKind {
            width: IntegerWidth::W64,
            ..
        }) => Some("bigserial"),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use tablepro_core::ForeignKeyInfo;
    use tablepro_core::ServerInfo;
    use tablepro_core::column::{ColumnDefault, ColumnInfo, SqlExpression};
    use tablepro_core::ddl::{
        ColumnAttributes, ColumnDefinition, DdlOperation, DraftType, DropTableOptions, InboundForeignKey, Permission,
        PrimaryKeyConstraint, ReferentialAction, RefusalReason, diff_table,
    };
    use tablepro_core::meta::{IndexInfo, IndexKey};

    use super::*;

    fn dialect() -> PgDialect {
        PgDialect::new(&ServerInfo::new("PostgreSQL", "18.0", 18, 0, 0))
    }

    fn column(name: &str, declaration: &str, primary_key: bool) -> ColumnDefinition {
        let parsed = dialect()
            .parse_type(declaration)
            .expect("a type the test dialect parses");
        ColumnDefinition::new(
            ColumnInfo {
                name: name.to_owned(),
                column_type: parsed,
                nullable: !primary_key,
                primary_key,
                is_auto_increment: false,
                is_generated: false,
                default: ColumnDefault::None,
                comment: None,
            },
            ColumnAttributes::default(),
        )
    }

    fn users() -> TableDefinition {
        TableDefinition {
            table: TableRef::new(Some("app".to_owned()), "users"),
            columns: vec![
                column("id", "integer", true),
                column("email", "text", false),
                column("status", "integer", false),
            ],
            primary_key: Some(PrimaryKeyConstraint {
                name: Some("users_pkey".to_owned()),
                columns: vec!["id".to_owned()],
            }),
            indexes: Vec::new(),
            foreign_keys: Vec::new(),
            inbound_foreign_keys: Vec::new(),
            source: None,
        }
    }

    fn typed(name: &str, declaration: &str) -> DraftColumn {
        DraftColumn::new(name, DraftType::Typed(declaration.to_owned()))
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
        let mut draft = TableDraft::new(TableRef::new(Some("app".to_owned()), "notes"));
        let mut id = typed("id", "bigint");
        id.primary_key = true;
        id.nullable = false;
        id.auto_increment = true;
        let mut body = typed("body", "text");
        body.nullable = false;
        body.default = ColumnDefault::Literal(Value::Text("it's".to_owned()));
        body.comment = Some("the note".to_owned());
        let mut created = typed("created_at", "timestamp with time zone");
        created.default = ColumnDefault::Expression(SqlExpression::from_catalog_text("now()"));
        draft.columns = vec![id, body, created];

        assert_eq!(
            sql(dialect().plan_create_table(&draft)),
            [
                "CREATE TABLE \"app\".\"notes\" (\n  \"id\" bigint GENERATED BY DEFAULT AS IDENTITY NOT NULL,\n  \
                 \"body\" text DEFAULT 'it''s' NOT NULL,\n  \"created_at\" timestamp with time zone DEFAULT now(),\n  \
                 PRIMARY KEY (\"id\")\n)",
                "COMMENT ON COLUMN \"app\".\"notes\".\"body\" IS 'the note'",
            ]
        );
    }

    #[test]
    fn the_script_keeps_serial_and_identity_columns_apart() {
        let mut table = users();
        let numbered = |column: &mut ColumnDefinition, identity: IdentityStyle| {
            column.info.is_auto_increment = true;
            column.attributes.identity = identity;
        };
        numbered(&mut table.columns[0], IdentityStyle::SequenceDefault);
        let mut ticket = column("ticket", "bigint", false);
        numbered(&mut ticket, IdentityStyle::GeneratedAlways);
        table.columns.push(ticket);

        assert_eq!(
            sql(dialect().create_table_script(&table)),
            [
                "CREATE TABLE \"app\".\"users\" (\n  \"id\" serial NOT NULL,\n  \"email\" text,\n  \"status\" \
                 integer,\n  \"ticket\" bigint GENERATED ALWAYS AS IDENTITY,\n  PRIMARY KEY (\"id\")\n)"
            ]
        );
    }

    #[test]
    fn plan_create_table_composite_key_index_and_foreign_key() {
        let mut draft = TableDraft::new(TableRef::unqualified("lines"));
        let mut order = typed("order_id", "integer");
        order.primary_key = true;
        order.nullable = false;
        let mut line = typed("line", "integer");
        line.primary_key = true;
        line.nullable = false;
        draft.columns = vec![order, line, typed("sku", "text")];
        draft.indexes = vec![IndexInfo {
            name: "lines_by_sku".to_owned(),
            keys: vec![IndexKey::Column {
                name: "sku".to_owned(),
                descending: true,
            }],
            unique: true,
            primary: false,
            predicate: None,
        }];
        draft.foreign_keys = vec![ForeignKeyInfo {
            name: "lines_order_fk".to_owned(),
            columns: vec!["order_id".to_owned()],
            ref_schema: None,
            ref_table: "orders".to_owned(),
            ref_columns: vec!["id".to_owned()],
            on_delete: Some(ReferentialAction::Cascade),
            on_update: Some(ReferentialAction::NoAction),
        }];

        assert_eq!(
            sql(dialect().plan_create_table(&draft)),
            [
                "CREATE TABLE \"lines\" (\n  \"order_id\" integer NOT NULL,\n  \"line\" integer NOT NULL,\n  \
                 \"sku\" text,\n  PRIMARY KEY (\"order_id\", \"line\"),\n  CONSTRAINT \"lines_order_fk\" FOREIGN KEY \
                 (\"order_id\") REFERENCES \"orders\" (\"id\") ON DELETE CASCADE\n)",
                "CREATE UNIQUE INDEX \"lines_by_sku\" ON \"lines\" (\"sku\" DESC)",
            ]
        );
    }

    #[test]
    fn plan_alter_table_nullability_type_and_default_in_one_statement() {
        let plan = alter(&users(), |draft| {
            let status = &mut draft.columns[2];
            status.column_type = DraftType::Typed("bigint".to_owned());
            status.nullable = false;
            status.default = ColumnDefault::Literal(Value::Int(0));
            draft.columns[1].default = ColumnDefault::Expression(SqlExpression::from_catalog_text("'x'"));
        });

        assert_eq!(
            sql(plan),
            [
                "ALTER TABLE \"app\".\"users\" ALTER COLUMN \"email\" SET DEFAULT 'x', ALTER COLUMN \"status\" TYPE \
              bigint USING \"status\"::bigint, ALTER COLUMN \"status\" SET NOT NULL, ALTER COLUMN \"status\" SET \
              DEFAULT 0"
            ]
        );
    }

    #[test]
    fn renames_run_first_and_the_rest_names_the_new_table() {
        let plan = alter(&users(), |draft| {
            draft.table.name = "members".to_owned();
            draft.columns[1].name = "mail".to_owned();
            draft.columns[1].nullable = false;
        });

        assert_eq!(
            sql(plan),
            [
                "ALTER TABLE \"app\".\"users\" RENAME TO \"members\"",
                "ALTER TABLE \"app\".\"members\" RENAME COLUMN \"email\" TO \"mail\"",
                "ALTER TABLE \"app\".\"members\" ALTER COLUMN \"mail\" SET NOT NULL",
            ]
        );
    }

    #[test]
    fn a_cleared_default_and_comment_are_dropped() {
        let mut original = users();
        original.columns[2].info.default = ColumnDefault::Literal(Value::Int(1));
        original.columns[2].info.comment = Some("state".to_owned());

        let plan = alter(&original, |draft| {
            draft.columns[2].default = ColumnDefault::None;
            draft.columns[2].comment = None;
        });

        assert_eq!(
            sql(plan),
            [
                "ALTER TABLE \"app\".\"users\" ALTER COLUMN \"status\" DROP DEFAULT",
                "COMMENT ON COLUMN \"app\".\"users\".\"status\" IS NULL",
            ]
        );
    }

    #[test]
    fn a_primary_key_change_drops_the_named_constraint_and_adds_the_key() {
        let plan = alter(&users(), |draft| {
            draft.columns[1].primary_key = true;
            draft.columns[1].nullable = false;
        });

        assert_eq!(
            sql(plan),
            [
                "ALTER TABLE \"app\".\"users\" DROP CONSTRAINT \"users_pkey\", ALTER COLUMN \"email\" SET NOT NULL, \
              ADD PRIMARY KEY (\"id\", \"email\")"
            ]
        );
    }

    #[test]
    fn dropped_indexes_go_before_the_combined_alter_and_new_ones_after() {
        let mut original = users();
        original.indexes = vec![IndexInfo {
            name: "by_email".to_owned(),
            keys: vec![IndexKey::Column {
                name: "email".to_owned(),
                descending: false,
            }],
            unique: false,
            primary: false,
            predicate: None,
        }];

        let plan = alter(&original, |draft| {
            draft.indexes.clear();
            draft.columns.retain(|column| column.name != "email");
            draft.columns.push(typed("nickname", "text"));
            draft.indexes.push(IndexInfo {
                name: "by_lower_nickname".to_owned(),
                keys: vec![IndexKey::Expression {
                    sql: "lower(nickname)".to_owned(),
                    descending: false,
                }],
                unique: false,
                primary: false,
                predicate: Some("nickname IS NOT NULL".to_owned()),
            });
        });

        assert_eq!(
            sql(plan),
            [
                "DROP INDEX \"app\".\"by_email\"",
                "ALTER TABLE \"app\".\"users\" DROP COLUMN \"email\", ADD COLUMN \"nickname\" text",
                "CREATE INDEX \"by_lower_nickname\" ON \"app\".\"users\" ((lower(nickname))) WHERE nickname IS NOT \
                 NULL",
            ]
        );
    }

    fn referenced(table: &mut TableDefinition, column: &str) {
        table.inbound_foreign_keys = vec![InboundForeignKey {
            name: "orders_user_fk".to_owned(),
            table: TableRef::new(Some("app".to_owned()), "orders"),
            columns: vec!["user_id".to_owned()],
            referenced_columns: vec![column.to_owned()],
        }];
    }

    #[test]
    fn primary_key_referenced_by_foreign_key_is_refused() {
        let mut table = users();
        referenced(&mut table, "id");

        let permissions = dialect().column_capabilities(&table, &table.columns[1]);
        let plan = alter(&table, |draft| {
            draft.columns[1].primary_key = true;
            draft.columns[1].nullable = false;
        });

        assert_eq!(
            permissions.alter_primary_key,
            Permission::Refused(RefusalReason::ReferencedByForeignKeys(vec![
                "orders_user_fk".to_owned()
            ]))
        );
        assert!(
            matches!(
                plan,
                Err(BuildDdlError::Refused {
                    operation: DdlOperation::AlterPrimaryKey,
                    reason: RefusalReason::ReferencedByForeignKeys(_),
                    ..
                })
            ),
            "{plan:?}"
        );
    }

    #[test]
    fn drop_of_referenced_column_is_refused() {
        let mut table = users();
        referenced(&mut table, "email");

        let plan = alter(&table, |draft| draft.columns.retain(|column| column.name != "email"));

        assert!(
            matches!(
                &plan,
                Err(BuildDdlError::Refused {
                    column,
                    operation: DdlOperation::DropColumn,
                    reason: RefusalReason::ReferencedByForeignKeys(keys),
                }) if column == "email" && keys == &["orders_user_fk".to_owned()]
            ),
            "{plan:?}"
        );
    }

    #[test]
    fn an_identity_change_waits_for_its_plan() {
        let plan = alter(&users(), |draft| draft.columns[2].auto_increment = true);

        assert!(
            matches!(
                plan,
                Err(BuildDdlError::Refused {
                    operation: DdlOperation::AlterAutoIncrement,
                    reason: RefusalReason::EngineUnsupported,
                    ..
                })
            ),
            "{plan:?}"
        );
    }

    #[test]
    fn a_typed_type_is_refused_before_it_reaches_the_server() {
        let plan = alter(&users(), |draft| {
            draft.columns[2].column_type = DraftType::Typed("int; DROP TABLE users".to_owned());
        });

        assert!(matches!(plan, Err(BuildDdlError::InvalidType { .. })), "{plan:?}");
    }

    #[test]
    fn a_rename_stays_in_its_schema_and_a_drop_can_cascade() {
        let drop = dialect().plan_drop_table(
            &TableRef::new(Some("app".to_owned()), "users"),
            DropTableOptions {
                if_exists: true,
                cascade: true,
            },
        );

        assert_eq!(sql(drop), ["DROP TABLE IF EXISTS \"app\".\"users\" CASCADE"]);
    }

    #[test]
    fn the_script_restates_identity_collation_and_generated_columns() {
        let mut table = users();
        table.columns[0].info.is_auto_increment = true;
        table.columns[0].attributes.identity = IdentityStyle::GeneratedAlways;
        table.columns[1].attributes.collation = Some(CollationName::new(Some("pg_catalog".to_owned()), "C"));
        let mut total = column("total", "integer", false);
        total.info.is_generated = true;
        total.attributes.generated = Some(tablepro_core::ddl::GeneratedColumn {
            expression: SqlExpression::from_catalog_text("(status * 2)"),
            storage: GeneratedStorage::Stored,
        });
        table.columns.push(total);

        let script = sql(dialect().create_table_script(&table));

        assert_eq!(
            script,
            [
                "CREATE TABLE \"app\".\"users\" (\n  \"id\" integer GENERATED ALWAYS AS IDENTITY NOT NULL,\n  \"email\" \
              text COLLATE \"pg_catalog\".\"C\",\n  \"status\" integer,\n  \"total\" integer GENERATED ALWAYS AS \
              ((status * 2)) STORED,\n  PRIMARY KEY (\"id\")\n)"
            ]
        );
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
