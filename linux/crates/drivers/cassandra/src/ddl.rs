use tablepro_core::ddl::{
    BuildDdlError, ColumnCapabilities, ColumnDefinition, DdlCapabilities, DdlDialect, DdlPlan, DraftColumn,
    DraftProblem, Permission, ReferentialAction, RefusalReason, TableChanges, TableDefinition, TableDraft,
};
use tablepro_core::dialect::SqlDialect;

use crate::dialect::CqlDialect;

static CAPABILITIES: DdlCapabilities = DdlCapabilities {
    create_table: true,
    rename_table: false,
    add_column: true,
    drop_column: true,
    // Only a primary key column, which `column_capabilities` says.
    rename_column: true,
    alter_column_type: false,
    alter_column_nullability: false,
    alter_column_default: false,
    alter_primary_key: false,
    alter_auto_increment: false,
    auto_increment_outside_primary_key: false,
    // A secondary index names one column with no direction, and the
    // index dialog asks for more; one is created in the editor.
    create_index: false,
    drop_index: true,
    expression_index_keys: false,
    descending_index_keys: false,
    partial_indexes: false,
    add_foreign_key: false,
    drop_foreign_key: false,
    column_comments: false,
    drop_table_cascade: false,
    column_defaults: false,
    required_columns: false,
    declared_column_order: false,
};

const TYPE_SUGGESTIONS: &[&str] = &[
    "text",
    "int",
    "bigint",
    "uuid",
    "timeuuid",
    "timestamp",
    "date",
    "boolean",
    "double",
    "decimal",
    "varint",
    "blob",
    "list<text>",
    "set<text>",
    "map<text, text>",
];

/// CQL changes a table one ALTER at a time, with no transaction around
/// them, and a key is fixed once the table exists.
impl DdlDialect for CqlDialect {
    fn capabilities(&self) -> &DdlCapabilities {
        &CAPABILITIES
    }

    fn sql_dialect(&self) -> &dyn SqlDialect {
        self
    }

    /// A key column cannot be dropped, and CQL renames only key columns.
    fn column_capabilities(&self, table: &TableDefinition, column: &ColumnDefinition) -> ColumnCapabilities {
        let mut permissions = ColumnCapabilities::standard(&CAPABILITIES, table, column);
        let roles = column.attributes.key_roles;
        if roles.partition_key || roles.sorting_key {
            permissions.drop = permissions.drop.and(|| Permission::Refused(RefusalReason::KeyColumn));
        } else {
            permissions.rename = permissions
                .rename
                .and(|| Permission::Refused(RefusalReason::EngineUnsupported));
        }
        permissions
    }

    fn type_suggestions(&self) -> &'static [&'static str] {
        TYPE_SUGGESTIONS
    }

    fn default_column_type(&self) -> &'static str {
        "text"
    }

    fn referential_actions(&self) -> &'static [ReferentialAction] {
        &[]
    }

    /// The first key column is the partition key and the rest cluster
    /// within it, as `PRIMARY KEY (a, b)` reads.
    fn plan_create_table(&self, draft: &TableDraft) -> Result<DdlPlan, BuildDdlError> {
        draft.check_create(self)?;
        let key: Vec<String> = draft
            .columns
            .iter()
            .filter(|column| column.primary_key)
            .map(|column| self.quote_identifier(&column.name))
            .collect();
        if key.is_empty() {
            return Err(BuildDdlError::Draft(DraftProblem::NoPrimaryKey));
        }
        let mut parts = draft
            .columns
            .iter()
            .map(|column| self.column_definition(column))
            .collect::<Result<Vec<_>, _>>()?;
        parts.push(format!("PRIMARY KEY ({})", key.join(", ")));
        Ok(DdlPlan::from_sql([format!(
            "CREATE TABLE {} ({})",
            self.qualify(&draft.table),
            parts.join(", ")
        )]))
    }

    fn plan_alter_table(&self, original: &TableDefinition, changes: &TableChanges) -> Result<DdlPlan, BuildDdlError> {
        changes.check(self, original)?;
        let qualified = self.qualify(&original.table);
        let alter = |action: String| format!("ALTER TABLE {qualified} {action}");
        let mut statements = Vec::new();
        for index in &changes.dropped_indexes {
            let qualified_index = match original.table.schema.as_deref().filter(|schema| !schema.is_empty()) {
                Some(schema) => format!(
                    "{}.{}",
                    self.quote_identifier(schema),
                    self.quote_identifier(&index.name)
                ),
                None => self.quote_identifier(&index.name),
            };
            statements.push(format!("DROP INDEX {qualified_index}"));
        }
        for column in &changes.dropped_columns {
            statements.push(alter(format!("DROP {}", self.quote_identifier(column.name()))));
        }
        for rename in changes.ordered_renames(original) {
            statements.push(alter(format!(
                "RENAME {} TO {}",
                self.quote_identifier(&rename.from),
                self.quote_identifier(&rename.to)
            )));
        }
        for column in &changes.added_columns {
            statements.push(alter(format!("ADD {}", self.column_definition(column)?)));
        }
        DdlPlan::for_changes(changes, statements)
    }

    /// The CREATE statement the driver wrote from the server's schema
    /// tables, then each secondary index.
    fn create_table_script(&self, definition: &TableDefinition) -> Result<DdlPlan, BuildDdlError> {
        let source = definition.source.as_ref().ok_or(BuildDdlError::NoTableSource)?;
        let dependents = source.dependents.iter().map(|dependent| dependent.sql.clone());
        Ok(DdlPlan::from_sql(
            std::iter::once(source.create_statement.clone()).chain(dependents),
        ))
    }
}

impl CqlDialect {
    fn column_definition(&self, column: &DraftColumn) -> Result<String, BuildDdlError> {
        let resolved = column.column_type.resolve(self, &column.name)?;
        Ok(format!("{} {}", self.quote_identifier(&column.name), resolved.sql))
    }
}

#[cfg(test)]
mod tests {
    use tablepro_core::ServerInfo;
    use tablepro_core::column::{ColumnDefault, ColumnInfo};
    use tablepro_core::ddl::{ColumnAttributes, ColumnKeyRoles, DdlOperation, DraftType, TableSource, diff_table};
    use tablepro_core::meta::TableRef;
    use tablepro_core::value::Value;

    use super::*;
    use crate::cql_type::CqlType;

    fn dialect() -> CqlDialect {
        CqlDialect::new(&ServerInfo::new("Cassandra", "5.0.9", 5, 0, 9))
    }

    fn column(name: &str, declaration: &str, partition_key: bool) -> ColumnDefinition {
        ColumnDefinition::new(
            ColumnInfo {
                name: name.to_owned(),
                column_type: CqlType::parse(declaration).unwrap().column_type(Some(declaration)),
                nullable: !partition_key,
                primary_key: partition_key,
                is_auto_increment: false,
                is_generated: false,
                partition_scoped: false,
                default: ColumnDefault::None,
                comment: None,
            },
            ColumnAttributes {
                key_roles: ColumnKeyRoles {
                    sorting_key: false,
                    partition_key,
                },
                ..ColumnAttributes::default()
            },
        )
    }

    fn users() -> TableDefinition {
        TableDefinition {
            table: TableRef::new(Some("shop".to_owned()), "users"),
            columns: vec![column("id", "uuid", true), column("name", "text", false)],
            primary_key: None,
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

    #[test]
    fn a_table_is_created_with_its_key_and_nothing_cql_lacks() {
        let mut draft = TableDraft::new(TableRef::new(Some("shop".to_owned()), "orders"));
        let mut id = DraftColumn::new("id", DraftType::Typed("uuid".to_owned()));
        id.primary_key = true;
        id.nullable = false;
        let mut day = DraftColumn::new("day", DraftType::Typed("date".to_owned()));
        day.primary_key = true;
        day.nullable = false;
        draft.columns = vec![
            id,
            day,
            DraftColumn::new("Total", DraftType::Typed("decimal".to_owned())),
        ];

        let plan = dialect().plan_create_table(&draft).unwrap();
        assert_eq!(
            plan.sql(),
            [
                "CREATE TABLE \"shop\".\"orders\" (\"id\" uuid, \"day\" date, \"Total\" decimal, PRIMARY KEY (\"id\", \"day\"))"
            ]
        );

        let mut defaulted = draft.clone();
        defaulted.columns[2].default = ColumnDefault::Literal(Value::Int(0));
        assert_eq!(
            dialect().plan_create_table(&defaulted).unwrap_err(),
            BuildDdlError::Unsupported(DdlOperation::ColumnDefault)
        );
        let mut required = draft.clone();
        required.columns[2].nullable = false;
        assert_eq!(
            dialect().plan_create_table(&required).unwrap_err(),
            BuildDdlError::Unsupported(DdlOperation::RequiredColumn)
        );
        let mut keyless = draft;
        for column in &mut keyless.columns {
            column.primary_key = false;
            column.nullable = true;
        }
        assert_eq!(
            dialect().plan_create_table(&keyless).unwrap_err(),
            BuildDdlError::Draft(DraftProblem::NoPrimaryKey)
        );
    }

    #[test]
    fn columns_are_added_dropped_and_key_columns_renamed() {
        let table = users();

        let added = alter(&table, |draft| {
            draft
                .columns
                .push(DraftColumn::new("tags", DraftType::Typed("set<text>".to_owned())));
        })
        .unwrap();
        assert_eq!(added.sql(), ["ALTER TABLE \"shop\".\"users\" ADD \"tags\" set<text>"]);

        let dropped = alter(&table, |draft| draft.columns.retain(|column| column.name != "name")).unwrap();
        assert_eq!(dropped.sql(), ["ALTER TABLE \"shop\".\"users\" DROP \"name\""]);

        let renamed = alter(&table, |draft| draft.columns[0].name = "user_id".to_owned()).unwrap();
        assert_eq!(
            renamed.sql(),
            ["ALTER TABLE \"shop\".\"users\" RENAME \"id\" TO \"user_id\""]
        );
    }

    #[test]
    fn what_cql_cannot_change_is_refused_with_a_reason() {
        let table = users();
        let key = dialect().column_capabilities(&table, &table.columns[0]);
        let plain = dialect().column_capabilities(&table, &table.columns[1]);

        assert_eq!(key.drop, Permission::Refused(RefusalReason::KeyColumn));
        assert_eq!(key.rename, Permission::Allowed);
        assert_eq!(plain.rename, Permission::Refused(RefusalReason::EngineUnsupported));
        assert!(matches!(
            alter(&table, |draft| draft.columns[1].name = "full_name".to_owned()),
            Err(BuildDdlError::Refused {
                reason: RefusalReason::EngineUnsupported,
                ..
            })
        ));
        assert!(alter(&table, |draft| draft.columns[1].nullable = false).is_err());
        assert!(alter(&table, |draft| draft.table.name = "people".to_owned()).is_err());
    }

    #[test]
    fn the_script_is_the_servers_table_then_its_indexes() {
        let mut table = users();
        assert_eq!(
            dialect().create_table_script(&table).unwrap_err(),
            BuildDdlError::NoTableSource
        );
        table.source = Some(TableSource {
            create_statement: "CREATE TABLE shop.users (id uuid PRIMARY KEY, name text)".to_owned(),
            dependents: vec![tablepro_core::ddl::SchemaObjectSource {
                kind: tablepro_core::ddl::SchemaObjectKind::Index,
                name: "users_name".to_owned(),
                table: "users".to_owned(),
                sql: "CREATE INDEX users_name ON shop.users (name)".to_owned(),
            }],
        });

        assert_eq!(
            dialect().create_table_script(&table).unwrap().sql(),
            [
                "CREATE TABLE shop.users (id uuid PRIMARY KEY, name text)",
                "CREATE INDEX users_name ON shop.users (name)"
            ]
        );
    }
}
