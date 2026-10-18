use tablepro_core::column::ColumnType;
use tablepro_core::ddl::ddl_sql::default_sql;
use tablepro_core::ddl::{
    BuildDdlError, ColumnCapabilities, ColumnDefinition, DdlCapabilities, DdlDialect, DdlPlan, DraftColumn, Permission,
    RefusalReason, TableChanges, TableDefinition, TableDraft,
};
use tablepro_core::dialect::SqlDialect;
use tablepro_core::value::Value;

use crate::dialect::ClickHouseDialect;

static CAPABILITIES: DdlCapabilities = DdlCapabilities {
    // A table needs an engine and a sorting key the draft has no place
    // for, so tables are created in the editor.
    create_table: false,
    rename_table: true,
    add_column: true,
    drop_column: true,
    rename_column: true,
    alter_column_type: true,
    // Nullability is part of the type, so it changes by rewriting the
    // column as Nullable(T) or T.
    alter_column_nullability: true,
    alter_column_default: true,
    alter_primary_key: false,
    alter_auto_increment: false,
    auto_increment_outside_primary_key: false,
    // A data-skipping index needs a TYPE and a GRANULARITY the index
    // dialog does not ask for.
    create_index: false,
    drop_index: true,
    expression_index_keys: true,
    partial_indexes: false,
    add_foreign_key: false,
    drop_foreign_key: false,
    column_comments: true,
    drop_table_cascade: false,
};

const TYPE_SUGGESTIONS: &[&str] = &[
    "String",
    "Int32",
    "Int64",
    "UInt32",
    "UInt64",
    "Float64",
    "Decimal(18, 2)",
    "Bool",
    "Date",
    "DateTime",
    "DateTime64(3)",
    "UUID",
    "LowCardinality(String)",
    "Array(String)",
];

/// ClickHouse changes a table one ALTER at a time, and keeps no
/// transaction around them.
impl DdlDialect for ClickHouseDialect {
    fn capabilities(&self) -> &DdlCapabilities {
        &CAPABILITIES
    }

    fn sql_dialect(&self) -> &dyn SqlDialect {
        self
    }

    /// A sorting or partition key column cannot be renamed, retyped or
    /// dropped without rebuilding the table, and a retype needs the
    /// declaration the catalogue gave.
    fn column_capabilities(&self, table: &TableDefinition, column: &ColumnDefinition) -> ColumnCapabilities {
        let mut permissions = ColumnCapabilities::standard(&CAPABILITIES, table, column);
        let roles = column.attributes.key_roles;
        if roles.sorting_key || roles.partition_key {
            let key = || Permission::Refused(RefusalReason::KeyColumn);
            permissions.rename = permissions.rename.and(key);
            permissions.drop = permissions.drop.and(key);
            permissions.alter_type = permissions.alter_type.and(key);
            permissions.alter_nullability = permissions.alter_nullability.and(key);
        }
        if column.info.column_type.catalog.is_none() {
            let unreadable = || Permission::Refused(RefusalReason::UnreadableDefinition);
            permissions.alter_nullability = permissions.alter_nullability.and(unreadable);
        }
        permissions
    }

    fn type_suggestions(&self) -> &'static [&'static str] {
        TYPE_SUGGESTIONS
    }

    fn default_column_type(&self) -> &'static str {
        "String"
    }

    fn plan_create_table(&self, draft: &TableDraft) -> Result<DdlPlan, BuildDdlError> {
        draft.check_create(self)?;
        Err(BuildDdlError::Unsupported(
            tablepro_core::ddl::DdlOperation::CreateTable,
        ))
    }

    fn plan_alter_table(&self, original: &TableDefinition, changes: &TableChanges) -> Result<DdlPlan, BuildDdlError> {
        changes.check(self, original)?;
        let mut statements = Vec::new();
        let table = changes.target(&original.table);
        // ClickHouse has no ALTER TABLE ... RENAME TO. The new name keeps
        // the database, or the table would move to the session's.
        if changes.renamed_table.is_some() {
            statements.push(format!(
                "RENAME TABLE {} TO {}",
                self.qualify(&original.table),
                self.qualify(&table)
            ));
        }
        let qualified = self.qualify(&table);
        let alter = |action: String| format!("ALTER TABLE {qualified} {action}");
        for index in &changes.dropped_indexes {
            statements.push(alter(format!("DROP INDEX {}", self.quote_identifier(&index.name))));
        }
        for column in &changes.dropped_columns {
            statements.push(alter(format!("DROP COLUMN {}", self.quote_identifier(column.name()))));
        }
        for rename in changes.ordered_renames(original) {
            statements.push(alter(format!(
                "RENAME COLUMN {} TO {}",
                self.quote_identifier(&rename.from),
                self.quote_identifier(&rename.to)
            )));
        }
        for alteration in &changes.altered_columns {
            let draft = &alteration.draft;
            let name = self.quote_identifier(&draft.name);
            let changed = alteration.changed;
            if changed.column_type || changed.nullability {
                let resolved = draft.column_type.resolve(self, &draft.name)?;
                statements.push(alter(format!(
                    "MODIFY COLUMN {name} {}",
                    with_nullability(&resolved.sql, draft.nullable)
                )));
            }
            if changed.default {
                let column_type = draft.column_type.column_type(self, &draft.name)?;
                statements.push(alter(
                    match default_sql(self, &draft.name, &draft.default, &column_type)? {
                        Some(default) => format!("MODIFY COLUMN {name} DEFAULT {default}"),
                        None => format!("MODIFY COLUMN {name} REMOVE DEFAULT"),
                    },
                ));
            }
            if changed.comment {
                statements.push(alter(format!(
                    "COMMENT COLUMN {name} {}",
                    self.comment(draft.comment_text())
                )));
            }
        }
        for column in &changes.added_columns {
            statements.push(alter(format!("ADD COLUMN {}", self.column_definition(column)?)));
        }
        DdlPlan::for_changes(changes, statements)
    }

    /// SHOW CREATE TABLE, which carries the engine, the keys and the
    /// settings the definition does not model.
    fn create_table_script(&self, definition: &TableDefinition) -> Result<DdlPlan, BuildDdlError> {
        definition
            .source
            .as_ref()
            .map(|source| DdlPlan::from_sql([source.create_statement.clone()]))
            .ok_or(BuildDdlError::NoTableSource)
    }
}

impl ClickHouseDialect {
    fn column_definition(&self, column: &DraftColumn) -> Result<String, BuildDdlError> {
        let resolved = column.column_type.resolve(self, &column.name)?;
        let mut parts = vec![
            self.quote_identifier(&column.name),
            with_nullability(&resolved.sql, column.nullable),
        ];
        if let Some(default) = default_sql(self, &column.name, &column.default, &resolved.column_type)? {
            parts.push(format!("DEFAULT {default}"));
        }
        if let Some(comment) = column.comment_text() {
            parts.push(format!("COMMENT {}", self.comment(Some(comment))));
        }
        Ok(parts.join(" "))
    }

    fn comment(&self, text: Option<&str>) -> String {
        let value = Value::Text(text.unwrap_or_default().to_owned());
        SqlDialect::literal(self, &value, &ColumnType::untyped_text("String")).unwrap_or_else(|_| "''".to_owned())
    }
}

/// `declaration` as Nullable or not. LowCardinality has to stay
/// outermost, so the Nullable goes inside it.
fn with_nullability(declaration: &str, nullable: bool) -> String {
    let declaration = declaration.trim();
    if let Some(inner) = wrapped(declaration, "LowCardinality") {
        return format!("LowCardinality({})", with_nullability(inner, nullable));
    }
    match (wrapped(declaration, "Nullable"), nullable) {
        (Some(_), true) | (None, false) => declaration.to_owned(),
        (Some(inner), false) => inner.trim().to_owned(),
        (None, true) => format!("Nullable({declaration})"),
    }
}

fn wrapped<'a>(declaration: &'a str, wrapper: &str) -> Option<&'a str> {
    let rest = declaration.get(wrapper.len()..)?;
    let head = declaration.get(..wrapper.len())?;
    (head.eq_ignore_ascii_case(wrapper) && rest.starts_with('(') && rest.ends_with(')'))
        .then(|| rest.get(1..rest.len() - 1))
        .flatten()
}

#[cfg(test)]
mod tests {
    use tablepro_core::ServerInfo;
    use tablepro_core::column::{ColumnDefault, ColumnInfo};
    use tablepro_core::ddl::{
        ColumnAttributes, ColumnKeyRoles, DdlOperation, DraftType, DropTableOptions, TableSource, diff_table,
    };
    use tablepro_core::meta::TableRef;

    use super::*;

    fn dialect() -> ClickHouseDialect {
        ClickHouseDialect::new(&ServerInfo::new("ClickHouse", "25.3", 25, 3, 0))
    }

    fn column(name: &str, declaration: &str, sorting_key: bool) -> ColumnDefinition {
        let column_type = dialect().parse_type(declaration).expect("a ClickHouse type");
        ColumnDefinition::new(
            ColumnInfo {
                name: name.to_owned(),
                nullable: declaration.starts_with("Nullable"),
                column_type,
                primary_key: sorting_key,
                is_auto_increment: false,
                is_generated: false,
                default: ColumnDefault::None,
                comment: None,
            },
            ColumnAttributes {
                key_roles: ColumnKeyRoles {
                    sorting_key,
                    partition_key: false,
                },
                ..ColumnAttributes::default()
            },
        )
    }

    fn events() -> TableDefinition {
        TableDefinition {
            table: TableRef::new(Some("analytics".to_owned()), "events"),
            columns: vec![
                column("id", "UInt64", true),
                column("label", "String", false),
                column("note", "Nullable(String)", false),
            ],
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

    fn sql(plan: Result<DdlPlan, BuildDdlError>) -> Vec<String> {
        plan.expect("the change plans")
            .sql()
            .into_iter()
            .map(str::to_owned)
            .collect()
    }

    #[test]
    fn clickhouse_capabilities_refuse_key_columns() {
        let table = events();

        let key = dialect().column_capabilities(&table, &table.columns[0]);
        let plain = dialect().column_capabilities(&table, &table.columns[1]);

        for permission in [&key.rename, &key.drop, &key.alter_type, &key.alter_nullability] {
            assert_eq!(*permission, Permission::Refused(RefusalReason::KeyColumn));
        }
        assert_eq!(key.alter_default, Permission::Allowed);
        assert_eq!(plain.rename, Permission::Allowed);
        assert_eq!(plain.alter_type, Permission::Allowed);
        assert!(!DdlDialect::capabilities(&dialect()).create_table);
        assert!(matches!(
            alter(&table, |draft| draft.columns[0].name = "event_id".to_owned()),
            Err(BuildDdlError::Refused {
                reason: RefusalReason::KeyColumn,
                ..
            })
        ));
    }

    /// ClickHouse has no foreign keys, so a reference can only come from
    /// a definition built elsewhere; the rule still holds.
    fn referenced(table: &mut TableDefinition, column: &str) {
        table.inbound_foreign_keys = vec![tablepro_core::ddl::InboundForeignKey {
            name: "visits_event_fk".to_owned(),
            table: TableRef::new(Some("analytics".to_owned()), "visits"),
            columns: vec!["event_id".to_owned()],
            referenced_columns: vec![column.to_owned()],
        }];
    }

    #[test]
    fn primary_key_referenced_by_foreign_key_is_refused() {
        let mut table = events();
        table.primary_key = Some(tablepro_core::ddl::PrimaryKeyConstraint {
            name: None,
            columns: vec!["id".to_owned()],
        });
        referenced(&mut table, "id");

        let permissions = dialect().column_capabilities(&table, &table.columns[1]);

        assert_eq!(
            permissions.alter_primary_key,
            Permission::Refused(RefusalReason::ReferencedByForeignKeys(vec![
                "visits_event_fk".to_owned()
            ]))
        );
    }

    #[test]
    fn drop_of_referenced_column_is_refused() {
        let mut table = events();
        referenced(&mut table, "label");

        let plan = alter(&table, |draft| draft.columns.retain(|column| column.name != "label"));

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
    fn a_table_is_never_created_from_a_draft() {
        let mut draft = TableDraft::new(TableRef::unqualified("t"));
        draft
            .columns
            .push(DraftColumn::new("id", DraftType::Typed("UInt64".to_owned())));

        assert_eq!(
            dialect().plan_create_table(&draft),
            Err(BuildDdlError::Unsupported(DdlOperation::CreateTable))
        );
    }

    #[test]
    fn clickhouse_rename_uses_rename_table_in_the_same_database() {
        let plan = alter(&events(), |draft| draft.table.name = "visits".to_owned());

        assert_eq!(sql(plan), ["RENAME TABLE `analytics`.`events` TO `analytics`.`visits`"]);
    }

    #[test]
    fn plan_alter_table_nullability_type_and_default() {
        let plan = alter(&events(), |draft| {
            let label = &mut draft.columns[1];
            label.nullable = true;
            label.default = ColumnDefault::Literal(Value::Text("it's".to_owned()));
            draft.columns[2].column_type = DraftType::Typed("LowCardinality(String)".to_owned());
            draft.columns[2].comment = Some("free text".to_owned());
        });

        assert_eq!(
            sql(plan),
            [
                "ALTER TABLE `analytics`.`events` MODIFY COLUMN `label` Nullable(String)",
                "ALTER TABLE `analytics`.`events` MODIFY COLUMN `label` DEFAULT 'it\\'s'",
                "ALTER TABLE `analytics`.`events` MODIFY COLUMN `note` LowCardinality(Nullable(String))",
                "ALTER TABLE `analytics`.`events` COMMENT COLUMN `note` 'free text'",
            ]
        );
    }

    #[test]
    fn a_removed_default_and_a_rename_and_an_added_column() {
        let mut table = events();
        table.columns[1].info.default = ColumnDefault::Literal(Value::Text("x".to_owned()));

        let plan = alter(&table, |draft| {
            draft.columns[1].default = ColumnDefault::None;
            draft.columns[2].name = "remark".to_owned();
            draft.columns[2].nullable = false;
            draft
                .columns
                .push(DraftColumn::new("tag", DraftType::Typed("String".to_owned())));
        });

        assert_eq!(
            sql(plan),
            [
                "ALTER TABLE `analytics`.`events` RENAME COLUMN `note` TO `remark`",
                "ALTER TABLE `analytics`.`events` MODIFY COLUMN `label` REMOVE DEFAULT",
                "ALTER TABLE `analytics`.`events` MODIFY COLUMN `remark` String",
                "ALTER TABLE `analytics`.`events` ADD COLUMN `tag` Nullable(String)",
            ]
        );
    }

    #[test]
    fn a_swap_steps_aside_through_a_temporary_name() {
        let plan = alter(&events(), |draft| {
            draft.columns[1].name = "note".to_owned();
            draft.columns[2].name = "label".to_owned();
        });

        assert_eq!(
            sql(plan),
            [
                "ALTER TABLE `analytics`.`events` RENAME COLUMN `label` TO `__tablepro_rename_1`",
                "ALTER TABLE `analytics`.`events` RENAME COLUMN `note` TO `label`",
                "ALTER TABLE `analytics`.`events` RENAME COLUMN `__tablepro_rename_1` TO `note`",
            ]
        );
    }

    #[test]
    fn the_script_is_the_servers_own_text() {
        let mut table = events();

        assert_eq!(dialect().create_table_script(&table), Err(BuildDdlError::NoTableSource));
        table.source = Some(TableSource {
            create_statement: "CREATE TABLE analytics.events (`id` UInt64) ENGINE = MergeTree ORDER BY id".to_owned(),
            dependents: Vec::new(),
        });
        assert_eq!(
            sql(dialect().create_table_script(&table)),
            ["CREATE TABLE analytics.events (`id` UInt64) ENGINE = MergeTree ORDER BY id"]
        );
        assert_eq!(
            sql(dialect().plan_drop_table(&table.table, DropTableOptions::default())),
            ["DROP TABLE `analytics`.`events`"]
        );
    }

    #[test]
    fn nullability_wraps_inside_low_cardinality() {
        assert_eq!(with_nullability("String", true), "Nullable(String)");
        assert_eq!(with_nullability("Nullable(String)", false), "String");
        assert_eq!(with_nullability("nullable(Int64)", true), "nullable(Int64)");
        assert_eq!(
            with_nullability("LowCardinality(Nullable(String))", false),
            "LowCardinality(String)"
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
