use std::collections::HashSet;

use tablepro_core::ddl::{
    BuildDdlError, CatalogCapabilities, CatalogOption, ColumnCapabilities, ColumnDefinition, DatabaseDraft,
    DatabaseFields, DatabaseNoun, DdlCapabilities, DdlDialect, DdlPlan, DraftColumn, DraftProblem, DropDatabaseOptions,
    KeyspaceReplication, NameLimit, Permission, ReferentialAction, RefusalReason, TableChanges, TableDefinition,
    TableDraft, bare_word, catalog_name, check_database_draft, named, refuse_drop_options,
};
use tablepro_core::dialect::SqlDialect;

use crate::catalog::is_system_keyspace;
use crate::decode::quoted;
use crate::dialect::CqlDialect;

/// The replication map's own keys, which no data centre can share.
const REPLICATION_KEYS: [&str; 2] = ["class", "replication_factor"];

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
    column_collations: false,
    table_options: false,
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

    /// A keyspace is the database, and TRUNCATE needs every node of the
    /// cluster up.
    fn catalog_capabilities(&self) -> CatalogCapabilities {
        CatalogCapabilities {
            truncate_table: true,
            create_database: true,
            drop_database: true,
            database_fields: DatabaseFields {
                replication: true,
                tablets: self.is_scylla(),
                ..DatabaseFields::default()
            },
            database_noun: DatabaseNoun::Keyspace,
            name_limit: Some(NameLimit::Chars(48)),
            ..CatalogCapabilities::default()
        }
    }

    fn protects_database(&self, name: &str) -> bool {
        is_system_keyspace(name)
    }

    /// The server takes a keyspace name of letters, digits and
    /// underscores, quoted or not, so nothing else is written.
    fn plan_create_database(&self, draft: &DatabaseDraft) -> Result<DdlPlan, BuildDdlError> {
        let capabilities = self.catalog_capabilities();
        check_database_draft(&capabilities, draft)?;
        let name = named(
            &capabilities,
            CatalogOption::Name,
            bare_word(CatalogOption::Name, &draft.name)?,
        )?;
        let replication = draft.replication.as_ref().ok_or_else(|| BuildDdlError::InvalidOption {
            option: CatalogOption::ReplicationFactor,
            value: String::new(),
        })?;
        let mut sql = format!(
            "CREATE KEYSPACE {} WITH replication = {}",
            self.quote_identifier(name),
            replication_map(replication)?
        );
        if !draft.durable_writes {
            sql.push_str(" AND durable_writes = false");
        }
        // Only turning tablets off is written; otherwise the server's own default holds.
        if draft.tablets == Some(false) {
            sql.push_str(" AND tablets = {'enabled': false}");
        }
        Ok(DdlPlan::for_databases([sql]))
    }

    fn plan_drop_database(&self, database: &str, options: &DropDatabaseOptions) -> Result<DdlPlan, BuildDdlError> {
        refuse_drop_options(&self.catalog_capabilities(), options)?;
        Ok(DdlPlan::for_databases([format!(
            "DROP KEYSPACE {}",
            self.quote_identifier(catalog_name(CatalogOption::Name, database)?)
        )]))
    }
}

/// The replication map of a new keyspace, each data centre named as a
/// CQL string.
fn replication_map(replication: &KeyspaceReplication) -> Result<String, BuildDdlError> {
    let factors = match replication {
        KeyspaceReplication::Simple { factor } => {
            return Ok(format!(
                "{{'class': 'SimpleStrategy', 'replication_factor': {}}}",
                replicas(*factor)?
            ));
        }
        KeyspaceReplication::NetworkTopology { factors } => factors,
    };
    if factors.is_empty() {
        return Err(BuildDdlError::InvalidOption {
            option: CatalogOption::DataCenter,
            value: String::new(),
        });
    }
    let mut seen = HashSet::new();
    let mut entries = vec!["'class': 'NetworkTopologyStrategy'".to_owned()];
    for (centre, factor) in factors {
        let centre = catalog_name(CatalogOption::DataCenter, centre)?;
        if REPLICATION_KEYS.contains(&centre) || !seen.insert(centre) {
            return Err(BuildDdlError::InvalidOption {
                option: CatalogOption::DataCenter,
                value: centre.to_owned(),
            });
        }
        entries.push(format!("{}: {}", quoted(centre), replicas(*factor)?));
    }
    Ok(format!("{{{}}}", entries.join(", ")))
}

/// A keyspace with no replicas could hold nothing.
fn replicas(factor: u32) -> Result<u32, BuildDdlError> {
    match factor {
        0 => Err(BuildDdlError::InvalidOption {
            option: CatalogOption::ReplicationFactor,
            value: factor.to_string(),
        }),
        factor => Ok(factor),
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
    use tablepro_core::column::{ColumnDefault, ColumnInfo};
    use tablepro_core::ddl::{
        self as catalog, ColumnAttributes, ColumnKeyRoles, DdlOperation, DraftType, DropSchemaOptions, SchemaDraft,
        TableSource, TruncateTableOptions, diff_table,
    };
    use tablepro_core::meta::TableRef;
    use tablepro_core::value::Value;
    use tablepro_core::{ServerInfo, WriteKind};

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
            options: None,
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

    fn scylla() -> CqlDialect {
        CqlDialect::new(&ServerInfo::new("ScyllaDB", "2026.1.0", 2026, 1, 0))
    }

    fn keyspace(replication: KeyspaceReplication) -> DatabaseDraft {
        DatabaseDraft {
            replication: Some(replication),
            ..DatabaseDraft::named("shop")
        }
    }

    fn invalid(plan: Result<DdlPlan, BuildDdlError>) -> Option<CatalogOption> {
        match plan {
            Err(BuildDdlError::InvalidOption { option, .. }) => Some(option),
            _ => None,
        }
    }

    #[test]
    fn a_truncate_names_the_keyspace_and_takes_no_option() {
        let table = TableRef::new(Some("shop".to_owned()), "us\"ers");

        let plan = dialect()
            .plan_truncate_table(&table, &TruncateTableOptions::default())
            .unwrap();

        assert_eq!(plan.sql(), ["TRUNCATE TABLE \"shop\".\"us\"\"ers\""]);
        let restart = TruncateTableOptions {
            restart_identity: true,
            ..TruncateTableOptions::default()
        };
        assert_eq!(
            dialect().plan_truncate_table(&table, &restart),
            Err(BuildDdlError::Unsupported(DdlOperation::TruncateRestartIdentity))
        );
    }

    #[test]
    fn a_keyspace_places_its_replicas_per_data_centre_or_across_the_cluster() {
        let topology = keyspace(KeyspaceReplication::NetworkTopology {
            factors: vec![("dc1".to_owned(), 3), ("it's".to_owned(), 2)],
        });
        let mut simple = keyspace(KeyspaceReplication::Simple { factor: 1 });
        simple.durable_writes = false;

        let planned = dialect().plan_create_database(&topology).unwrap();

        assert_eq!(
            planned.sql(),
            ["CREATE KEYSPACE \"shop\" WITH replication = \
              {'class': 'NetworkTopologyStrategy', 'dc1': 3, 'it''s': 2}"]
        );
        assert_eq!(planned.kind, WriteKind::DatabaseChanges);
        assert_eq!(
            dialect().plan_create_database(&simple).unwrap().sql(),
            ["CREATE KEYSPACE \"shop\" WITH replication = \
              {'class': 'SimpleStrategy', 'replication_factor': 1} AND durable_writes = false"]
        );
        let dropped = dialect()
            .plan_drop_database("Shop", &DropDatabaseOptions::default())
            .unwrap();
        assert_eq!(dropped.sql(), ["DROP KEYSPACE \"Shop\""]);
        assert_eq!(dropped.kind, WriteKind::DatabaseChanges);
        let forced = DropDatabaseOptions {
            force: true,
            cluster: None,
        };
        assert_eq!(
            dialect().plan_drop_database("shop", &forced),
            Err(BuildDdlError::Unsupported(DdlOperation::DropDatabaseForce))
        );
    }

    #[test]
    fn only_scylladb_turns_tablets_off() {
        let mut draft = keyspace(KeyspaceReplication::NetworkTopology {
            factors: vec![("dc1".to_owned(), 1)],
        });
        draft.tablets = Some(false);

        assert_eq!(
            scylla().plan_create_database(&draft).unwrap().sql(),
            ["CREATE KEYSPACE \"shop\" WITH replication = \
              {'class': 'NetworkTopologyStrategy', 'dc1': 1} AND tablets = {'enabled': false}"]
        );
        assert_eq!(
            invalid(dialect().plan_create_database(&draft)),
            Some(CatalogOption::ReplicationFactor)
        );
        draft.tablets = Some(true);
        assert_eq!(
            scylla().plan_create_database(&draft).unwrap().sql(),
            ["CREATE KEYSPACE \"shop\" WITH replication = {'class': 'NetworkTopologyStrategy', 'dc1': 1}"]
        );
        assert!(scylla().catalog_capabilities().database_fields.tablets);
        assert!(!dialect().catalog_capabilities().database_fields.tablets);
    }

    #[test]
    fn a_keyspace_the_server_would_refuse_is_not_planned() {
        let dialect = dialect();
        let topology = |factors: Vec<(&str, u32)>| {
            keyspace(KeyspaceReplication::NetworkTopology {
                factors: factors
                    .into_iter()
                    .map(|(centre, factor)| (centre.to_owned(), factor))
                    .collect(),
            })
        };
        let renamed = |name: String| DatabaseDraft {
            name,
            ..topology(vec![("dc1", 1)])
        };

        assert_eq!(
            invalid(dialect.plan_create_database(&DatabaseDraft::named("shop"))),
            Some(CatalogOption::ReplicationFactor)
        );
        assert_eq!(
            invalid(dialect.plan_create_database(&keyspace(KeyspaceReplication::Simple { factor: 0 }))),
            Some(CatalogOption::ReplicationFactor)
        );
        assert_eq!(
            invalid(dialect.plan_create_database(&topology(vec![("dc1", 0)]))),
            Some(CatalogOption::ReplicationFactor)
        );
        for centres in [vec![], vec![("", 1)], vec![("class", 1)], vec![("dc1", 1), ("dc1", 2)]] {
            assert_eq!(
                invalid(dialect.plan_create_database(&topology(centres.clone()))),
                Some(CatalogOption::DataCenter),
                "{centres:?}"
            );
        }
        for name in ["sh-op".to_owned(), "sh\"op".to_owned(), "k".repeat(49), String::new()] {
            assert_eq!(
                invalid(dialect.plan_create_database(&renamed(name.clone()))),
                Some(CatalogOption::Name),
                "{name:?}"
            );
        }
        assert!(dialect.plan_create_database(&renamed("k".repeat(48))).is_ok());
        assert!(dialect.plan_create_database(&renamed("1st_Shop".to_owned())).is_ok());
        let mut collated = topology(vec![("dc1", 1)]);
        collated.collation = Some("utf8".to_owned());
        assert_eq!(
            invalid(dialect.plan_create_database(&collated)),
            Some(CatalogOption::Collation)
        );
    }

    #[test]
    fn the_system_keyspaces_are_protected() {
        for name in ["system", "system_auth", "system_schema", "system_views"] {
            assert!(dialect().protects_database(name), "{name}");
        }
        assert!(!dialect().protects_database("shop"));
        assert!(!dialect().protects_database("systems"));
    }

    /// The sidebar offers what the capabilities say, so each one has to
    /// plan, with every option it offers, and nothing else may.
    #[test]
    fn every_offered_catalog_operation_plans_and_no_other() {
        for dialect in [dialect(), scylla()] {
            let offered = catalog::catalog_capabilities(&dialect);
            let table = TableRef::new(Some("shop".to_owned()), "users");
            let truncate = TruncateTableOptions {
                cascade: offered.truncate_cascade,
                restart_identity: offered.truncate_restart_identity,
                cluster: None,
            };
            let mut draft = keyspace(KeyspaceReplication::NetworkTopology {
                factors: vec![("dc1".to_owned(), 1)],
            });
            draft.durable_writes = false;
            draft.tablets = offered.database_fields.tablets.then_some(false);
            let drop_options = DropDatabaseOptions {
                force: offered.drop_database_force,
                cluster: None,
            };

            assert!(offered.truncate_table && offered.create_database && offered.drop_database);
            assert!(offered.database_fields.replication);
            assert_eq!(offered.database_noun, DatabaseNoun::Keyspace);
            assert_eq!(offered.name_limit, Some(NameLimit::Chars(48)));
            assert!(catalog::plan_truncate_table(&dialect, &table, &truncate).is_ok());
            assert!(catalog::plan_create_database(&dialect, &draft).is_ok());
            assert!(catalog::plan_drop_database(&dialect, "shop", &drop_options).is_ok());
            assert!(!offered.create_schema && !offered.drop_schema);
            assert_eq!(
                catalog::plan_create_schema(&dialect, &SchemaDraft::default()),
                Err(BuildDdlError::Unsupported(DdlOperation::CreateSchema))
            );
            assert_eq!(
                catalog::plan_drop_schema(&dialect, "shop", DropSchemaOptions::default()),
                Err(BuildDdlError::Unsupported(DdlOperation::DropSchema))
            );
        }
    }
}
