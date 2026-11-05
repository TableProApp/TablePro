use tablepro_core::column::ColumnType;
use tablepro_core::ddl::ddl_sql::default_sql;
use tablepro_core::ddl::{
    BuildDdlError, CatalogCapabilities, CatalogOption, ColumnCapabilities, ColumnDefinition, DatabaseDraft,
    DdlCapabilities, DdlDialect, DdlPlan, DraftColumn, DropDatabaseOptions, Permission, RefusalReason, TableChanges,
    TableDefinition, TableDraft, TruncateTableOptions, catalog_name, check_database_draft, named, refuse_drop_options,
    refuse_options,
};
use tablepro_core::dialect::SqlDialect;
use tablepro_core::meta::TableRef;
use tablepro_core::value::Value;

use crate::dialect::ClickHouseDialect;
use crate::metadata::SYSTEM_DATABASES;

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
    descending_index_keys: false,
    partial_indexes: false,
    add_foreign_key: false,
    drop_foreign_key: false,
    column_comments: true,
    drop_table_cascade: false,
    column_defaults: true,
    required_columns: true,
    declared_column_order: true,
    column_collations: false,
    table_options: false,
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
            let mut default_written = false;
            if changed.column_type || changed.nullability {
                let resolved = draft.column_type.resolve(self, &draft.name)?;
                let declaration = with_nullability(&resolved.sql, draft.nullable);
                // From 25.12 the server refuses to make a column non-nullable
                // without a DEFAULT to put in its NULLs. With none in the
                // draft, the type's own default fills them, as older servers
                // did, and is removed again.
                let fills_nulls = alteration.original.info.nullable && !draft.nullable;
                match default_sql(self, &draft.name, &draft.default, &resolved.column_type)? {
                    Some(default) if fills_nulls => {
                        statements.push(alter(format!("MODIFY COLUMN {name} {declaration} DEFAULT {default}")));
                        default_written = true;
                    }
                    None if fills_nulls => {
                        statements.push(alter(format!(
                            "MODIFY COLUMN {name} {declaration} DEFAULT defaultValueOfTypeName({})",
                            self.string_literal(&declaration)
                        )));
                        statements.push(alter(format!("MODIFY COLUMN {name} REMOVE DEFAULT")));
                        default_written = true;
                    }
                    _ => statements.push(alter(format!("MODIFY COLUMN {name} {declaration}"))),
                }
            }
            if changed.default && !default_written {
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

    /// A database is the only namespace, so there are no schemas. The
    /// engine stays the server's default.
    fn catalog_capabilities(&self) -> CatalogCapabilities {
        CatalogCapabilities {
            truncate_table: true,
            create_database: true,
            drop_database: true,
            on_cluster: true,
            ..CatalogCapabilities::default()
        }
    }

    /// The server lets a login drop these, and a drop of `system` stops
    /// half way. `default` is where a login lands when it names none.
    fn protects_database(&self, name: &str) -> bool {
        SYSTEM_DATABASES.contains(&name) || name == "default"
    }

    fn plan_truncate_table(&self, table: &TableRef, options: &TruncateTableOptions) -> Result<DdlPlan, BuildDdlError> {
        refuse_options(&self.catalog_capabilities(), options)?;
        Ok(DdlPlan::from_sql([format!(
            "TRUNCATE TABLE {}{}",
            self.qualify(table),
            self.on_cluster(options.cluster.as_deref())?
        )]))
    }

    fn plan_create_database(&self, draft: &DatabaseDraft) -> Result<DdlPlan, BuildDdlError> {
        let capabilities = self.catalog_capabilities();
        check_database_draft(&capabilities, draft)?;
        Ok(DdlPlan::for_databases([format!(
            "CREATE DATABASE {}{}",
            self.quote_identifier(named(&capabilities, CatalogOption::Name, &draft.name)?),
            self.on_cluster(draft.cluster.as_deref())?
        )]))
    }

    fn plan_drop_database(&self, database: &str, options: &DropDatabaseOptions) -> Result<DdlPlan, BuildDdlError> {
        refuse_drop_options(&self.catalog_capabilities(), options)?;
        Ok(DdlPlan::for_databases([format!(
            "DROP DATABASE {}{}",
            self.quote_identifier(catalog_name(CatalogOption::Name, database)?),
            self.on_cluster(options.cluster.as_deref())?
        )]))
    }
}

impl ClickHouseDialect {
    fn on_cluster(&self, cluster: Option<&str>) -> Result<String, BuildDdlError> {
        match cluster {
            Some(cluster) => Ok(format!(
                " ON CLUSTER {}",
                self.quote_identifier(catalog_name(CatalogOption::Cluster, cluster)?)
            )),
            None => Ok(String::new()),
        }
    }

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
        self.string_literal(text.unwrap_or_default())
    }

    fn string_literal(&self, text: &str) -> String {
        let value = Value::Text(text.to_owned());
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
    use tablepro_core::column::{ColumnDefault, ColumnInfo};
    use tablepro_core::ddl::{
        ColumnAttributes, ColumnKeyRoles, DdlOperation, DraftType, DropSchemaOptions, DropTableOptions, SchemaDraft,
        TableSource, catalog_capabilities, diff_table, plan_create_database, plan_create_schema, plan_drop_database,
        plan_drop_schema, plan_truncate_table, protects_database,
    };
    use tablepro_core::{ServerInfo, WriteKind};

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
                partition_scoped: false,
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
            options: None,
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
            child_compares_alike: true,
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
                "ALTER TABLE `analytics`.`events` MODIFY COLUMN `remark` String DEFAULT defaultValueOfTypeName('String')",
                "ALTER TABLE `analytics`.`events` MODIFY COLUMN `remark` REMOVE DEFAULT",
                "ALTER TABLE `analytics`.`events` ADD COLUMN `tag` Nullable(String)",
            ]
        );
    }

    #[test]
    fn a_column_made_non_nullable_fills_its_nulls_with_the_drafts_default() {
        let plan = alter(&events(), |draft| {
            let note = &mut draft.columns[2];
            note.nullable = false;
            note.default = ColumnDefault::Literal(Value::Text("none".to_owned()));
        });

        assert_eq!(
            sql(plan),
            ["ALTER TABLE `analytics`.`events` MODIFY COLUMN `note` String DEFAULT 'none'"]
        );
    }

    #[test]
    fn a_column_made_nullable_needs_no_default() {
        let plan = alter(&events(), |draft| draft.columns[1].nullable = true);

        assert_eq!(
            sql(plan),
            ["ALTER TABLE `analytics`.`events` MODIFY COLUMN `label` Nullable(String)"]
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

    fn cluster(name: Option<&str>) -> Option<String> {
        name.map(str::to_owned)
    }

    #[test]
    fn a_truncate_runs_here_or_on_the_cluster_named() {
        let table = TableRef::new(Some("analytics".to_owned()), "ev`ents");
        let truncate = |on: Option<&str>| {
            let options = TruncateTableOptions {
                cluster: cluster(on),
                ..TruncateTableOptions::default()
            };
            dialect().plan_truncate_table(&table, &options)
        };

        let here = truncate(None).expect("a plan");
        let everywhere = truncate(Some("main")).expect("a plan");

        assert_eq!(here.sql(), ["TRUNCATE TABLE `analytics`.`ev\\`ents`"]);
        assert_eq!(here.kind, WriteKind::SchemaChanges);
        assert_eq!(
            everywhere.sql(),
            ["TRUNCATE TABLE `analytics`.`ev\\`ents` ON CLUSTER `main`"]
        );
        let cascade = TruncateTableOptions {
            cascade: true,
            ..TruncateTableOptions::default()
        };
        assert_eq!(
            dialect().plan_truncate_table(&table, &cascade),
            Err(BuildDdlError::Unsupported(DdlOperation::TruncateTableCascade))
        );
        assert!(matches!(
            truncate(Some(" ")),
            Err(BuildDdlError::InvalidOption {
                option: CatalogOption::Cluster,
                ..
            })
        ));
    }

    #[test]
    fn a_database_is_created_and_dropped_here_or_on_the_cluster_named() {
        let created = |on: Option<&str>| {
            let draft = DatabaseDraft {
                cluster: cluster(on),
                ..DatabaseDraft::named("sh`op")
            };
            dialect().plan_create_database(&draft).expect("a plan")
        };
        let dropped = |on: Option<&str>| {
            let options = DropDatabaseOptions {
                force: false,
                cluster: cluster(on),
            };
            dialect().plan_drop_database("sh`op", &options).expect("a plan")
        };

        assert_eq!(created(None).sql(), ["CREATE DATABASE `sh\\`op`"]);
        assert_eq!(
            created(Some("main")).sql(),
            ["CREATE DATABASE `sh\\`op` ON CLUSTER `main`"]
        );
        assert_eq!(dropped(None).sql(), ["DROP DATABASE `sh\\`op`"]);
        assert_eq!(
            dropped(Some("main")).sql(),
            ["DROP DATABASE `sh\\`op` ON CLUSTER `main`"]
        );
        for plan in [created(None), created(Some("main")), dropped(None), dropped(Some("main"))] {
            assert_eq!(plan.kind, WriteKind::DatabaseChanges);
        }
    }

    #[test]
    fn a_database_option_clickhouse_has_no_place_for_is_refused() {
        let forced = DropDatabaseOptions {
            force: true,
            cluster: None,
        };
        let collated = DatabaseDraft {
            collation: Some("utf8mb4_bin".to_owned()),
            ..DatabaseDraft::named("shop")
        };

        assert_eq!(
            dialect().plan_drop_database("shop", &forced),
            Err(BuildDdlError::Unsupported(DdlOperation::DropDatabaseForce))
        );
        assert!(matches!(
            dialect().plan_create_database(&collated),
            Err(BuildDdlError::InvalidOption {
                option: CatalogOption::Collation,
                ..
            })
        ));
        assert!(matches!(
            dialect().plan_create_database(&DatabaseDraft::named("")),
            Err(BuildDdlError::InvalidOption {
                option: CatalogOption::Name,
                ..
            })
        ));
    }

    /// Without the capability a cluster is refused before any SQL, so a
    /// caller that skipped the dialog never sends an ON CLUSTER the
    /// server cannot run.
    #[test]
    fn a_cluster_is_refused_where_the_engine_has_none() {
        let without = CatalogCapabilities {
            on_cluster: false,
            ..dialect().catalog_capabilities()
        };
        let options = TruncateTableOptions {
            cluster: cluster(Some("main")),
            ..TruncateTableOptions::default()
        };
        let draft = DatabaseDraft {
            cluster: cluster(Some("main")),
            ..DatabaseDraft::named("shop")
        };
        let dropped = DropDatabaseOptions {
            force: false,
            cluster: cluster(Some("main")),
        };

        assert_eq!(
            refuse_options(&without, &options),
            Err(BuildDdlError::Unsupported(DdlOperation::OnCluster))
        );
        assert_eq!(
            check_database_draft(&without, &draft),
            Err(BuildDdlError::Unsupported(DdlOperation::OnCluster))
        );
        assert_eq!(
            refuse_drop_options(&without, &dropped),
            Err(BuildDdlError::Unsupported(DdlOperation::OnCluster))
        );
        assert!(dialect().catalog_capabilities().on_cluster);
    }

    #[test]
    fn the_servers_own_databases_and_default_are_protected() {
        for name in ["system", "INFORMATION_SCHEMA", "information_schema", "default"] {
            assert!(protects_database(&dialect(), name), "{name}");
        }
        assert!(!protects_database(&dialect(), "analytics"));
        assert!(!protects_database(&dialect(), "Default"));
    }

    /// The sidebar offers what the capabilities say, so each one must
    /// plan, and each one left out must not.
    #[test]
    fn every_catalog_operation_offered_plans_and_no_other_does() {
        let dialect = dialect();
        let offered = catalog_capabilities(&dialect);
        let table = TableRef::new(Some("analytics".to_owned()), "events");
        let schema = SchemaDraft {
            name: "analytics".to_owned(),
            owner: None,
        };
        let on = offered.on_cluster.then(|| "main".to_owned());
        let options = TruncateTableOptions {
            cluster: on.clone(),
            ..TruncateTableOptions::default()
        };
        let draft = DatabaseDraft {
            cluster: on.clone(),
            ..DatabaseDraft::named("shop")
        };
        let dropped = DropDatabaseOptions {
            force: offered.drop_database_force,
            cluster: on,
        };
        let plans = [
            (
                "truncate",
                offered.truncate_table,
                plan_truncate_table(&dialect, &table, &options),
            ),
            (
                "create schema",
                offered.create_schema,
                plan_create_schema(&dialect, &schema),
            ),
            (
                "drop schema",
                offered.drop_schema,
                plan_drop_schema(&dialect, "analytics", DropSchemaOptions::default()),
            ),
            (
                "create database",
                offered.create_database,
                plan_create_database(&dialect, &draft),
            ),
            (
                "drop database",
                offered.drop_database,
                plan_drop_database(&dialect, "shop", &dropped),
            ),
        ];

        for (operation, offered, plan) in plans {
            assert_eq!(offered, plan.is_ok(), "{operation}: {plan:?}");
        }
        assert!(offered.truncate_table && offered.create_database && offered.drop_database);
    }
}
