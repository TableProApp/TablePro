//! Structure changes on DuckDB.
//!
//! DuckDB takes one action per ALTER TABLE, and a table something else
//! depends on, an index made with CREATE INDEX or another table's
//! foreign key, takes only ADD COLUMN and a column's default: every
//! other change refuses with a dependency error. A column refuses a new
//! type while a key, a CHECK, an index or a generated column uses it.
//! The plans offer only what DuckDB 1.5 takes, measured against it in
//! the driver's DDL tests.

use tablepro_core::column::{ColumnKind, ColumnType};
use tablepro_core::ddl::ddl_sql::{column_list, create_index_sql, default_sql, foreign_key_sql};
use tablepro_core::ddl::{
    BuildDdlError, ColumnAttributes, ColumnCapabilities, ColumnDefinition, DdlCapabilities, DdlDialect, DdlOperation,
    DdlPlan, DraftColumn, Permission, ReferentialAction, RefusalReason, TableChanges, TableDefinition, TableDraft,
};
use tablepro_core::dialect::SqlDialect;
use tablepro_core::meta::{IndexInfo, TableRef};
use tablepro_core::value::Value;

use crate::dialect::DuckDbDialect;

static CAPABILITIES: DdlCapabilities = DdlCapabilities {
    create_table: true,
    rename_table: true,
    add_column: true,
    drop_column: true,
    rename_column: true,
    alter_column_type: true,
    alter_column_nullability: true,
    alter_column_default: true,
    // A key can be added to a table that has none; DuckDB drops or
    // moves none.
    alter_primary_key: true,
    alter_auto_increment: false,
    auto_increment_outside_primary_key: false,
    create_index: true,
    drop_index: true,
    expression_index_keys: true,
    // DuckDB takes DESC in CREATE INDEX and keeps the key ascending.
    descending_index_keys: false,
    partial_indexes: false,
    add_foreign_key: false,
    drop_foreign_key: false,
    column_comments: true,
    // CASCADE drops no table whose key another table references.
    drop_table_cascade: false,
    column_defaults: true,
    required_columns: true,
    declared_column_order: true,
    column_collations: false,
    table_options: false,
};

const TYPE_SUGGESTIONS: &[&str] = &[
    "VARCHAR",
    "INTEGER",
    "BIGINT",
    "DOUBLE",
    "DECIMAL(18,3)",
    "BOOLEAN",
    "DATE",
    "TIMESTAMP",
    "TIMESTAMPTZ",
    "TIME",
    "INTERVAL",
    "UUID",
    "BLOB",
    "JSON",
    "HUGEINT",
];

/// What holds the table in place: the indexes made on it and the keys
/// of other tables that reference it.
fn dependents(table: &TableDefinition) -> Vec<String> {
    let created_indexes = table.indexes.iter().filter(|index| {
        let constraint = table
            .primary_key
            .as_ref()
            .is_some_and(|key| key.name.as_deref() == Some(index.name.as_str()))
            || index.primary;
        let created = table
            .source
            .as_ref()
            .is_some_and(|source| source.dependents.iter().any(|dependent| dependent.name == index.name));
        created && !constraint
    });
    created_indexes
        .map(|index| index.name.clone())
        .chain(table.inbound_foreign_keys.iter().map(|key| key.name.clone()))
        .collect()
}

/// What uses one column so that DuckDB will not change its type: a key
/// or index over it, a foreign key from it, a generated column on it.
fn type_users(table: &TableDefinition, column: &ColumnDefinition) -> Vec<String> {
    let name = column.name();
    let indexes = table
        .indexes
        .iter()
        .filter(|index| index.keys.iter().any(|key| key.column_name() == Some(name)))
        .map(|index| index.name.clone());
    let keys = table
        .foreign_keys
        .iter()
        .filter(|key| key.columns.iter().any(|column| column == name))
        .map(|key| key.name.clone());
    let generated = table
        .columns
        .iter()
        .filter(|other| {
            other
                .attributes
                .generated
                .as_ref()
                .is_some_and(|generated| mentions(generated.expression.as_sql(), name))
        })
        .map(|other| other.name().to_owned());
    indexes.chain(keys).chain(generated).collect()
}

/// Whether an expression names the column, as a word or quoted.
fn mentions(expression: &str, column: &str) -> bool {
    let quoted = format!("\"{}\"", column.replace('"', "\"\""));
    expression.contains(&quoted)
        || expression
            .split(|c: char| !(c.is_alphanumeric() || c == '_'))
            .any(|word| word.eq_ignore_ascii_case(column))
}

impl DdlDialect for DuckDbDialect {
    fn capabilities(&self) -> &DdlCapabilities {
        &CAPABILITIES
    }

    fn sql_dialect(&self) -> &dyn SqlDialect {
        self
    }

    /// A table something depends on can be neither renamed nor given a
    /// key, and a key goes only on a table with none.
    fn table_capabilities(&self, table: &TableDefinition) -> DdlCapabilities {
        let free = dependents(table).is_empty();
        DdlCapabilities {
            rename_table: free,
            alter_primary_key: free && table.primary_key.is_none(),
            ..CAPABILITIES
        }
    }

    fn column_capabilities(&self, table: &TableDefinition, column: &ColumnDefinition) -> ColumnCapabilities {
        let mut permissions = ColumnCapabilities::standard(&self.table_capabilities(table), table, column);
        let held = dependents(table);
        if !held.is_empty() {
            let in_use = || Permission::Refused(RefusalReason::ColumnInUse(held.clone()));
            permissions.rename = permissions.rename.and(in_use);
            permissions.drop = permissions.drop.and(in_use);
            permissions.alter_type = permissions.alter_type.and(in_use);
            permissions.alter_nullability = permissions.alter_nullability.and(in_use);
        }
        let users = type_users(table, column);
        if !users.is_empty() {
            let in_use = || Permission::Refused(RefusalReason::ColumnInUse(users.clone()));
            permissions.alter_type = permissions.alter_type.and(in_use);
            permissions.drop = permissions.drop.and(in_use);
        }
        if let Some(check) = &column.attributes.check {
            let checked = || Permission::Refused(RefusalReason::ConflictingAttribute("CHECK constraint".to_owned()));
            permissions.alter_type = permissions.alter_type.and(checked);
            // DuckDB drops a CHECK on the column alone with it, and
            // refuses to drop a column a CHECK shares with another.
            let shared = table
                .columns
                .iter()
                .any(|other| other.name() != column.name() && mentions(check.as_sql(), other.name()));
            if shared {
                permissions.drop = permissions.drop.and(checked);
            }
        }
        let referencing: Vec<String> = table
            .foreign_keys
            .iter()
            .filter(|key| key.columns.iter().any(|name| name == column.name()))
            .map(|key| key.name.clone())
            .collect();
        if !referencing.is_empty() {
            let in_use = || Permission::Refused(RefusalReason::ColumnInUse(referencing.clone()));
            permissions.rename = permissions.rename.and(in_use);
        }
        permissions
    }

    /// DuckDB drops an index made with CREATE INDEX, and no constraint:
    /// a UNIQUE key's index goes only with its table.
    fn index_removal(&self, table: &TableDefinition, index: &IndexInfo) -> Permission {
        let created = table
            .source
            .as_ref()
            .is_some_and(|source| source.dependents.iter().any(|dependent| dependent.name == index.name));
        Permission::unless(created, RefusalReason::EngineUnsupported)
    }

    fn type_suggestions(&self) -> &'static [&'static str] {
        TYPE_SUGGESTIONS
    }

    fn default_column_type(&self) -> &'static str {
        "VARCHAR"
    }

    fn referential_actions(&self) -> &'static [ReferentialAction] {
        &[ReferentialAction::NoAction]
    }

    /// DuckDB keeps a foreign key's table by name alone, in the schema
    /// of the table that holds the key.
    fn references_other_schemas(&self) -> bool {
        false
    }

    fn plan_create_table(&self, draft: &TableDraft) -> Result<DdlPlan, BuildDdlError> {
        draft.check_create(self)?;
        let table = TableRef::new(draft.table.schema.clone(), draft.table.name.trim());
        let mut definitions = draft
            .columns
            .iter()
            .map(|column| self.column_definition(column, true))
            .collect::<Result<Vec<_>, _>>()?;
        let key: Vec<String> = draft.primary_key().into_iter().map(str::to_owned).collect();
        if !key.is_empty() {
            definitions.push(format!("PRIMARY KEY ({})", column_list(self, &key)));
        }
        definitions.extend(draft.foreign_keys.iter().map(|key| foreign_key_sql(self, &table, key)));
        let qualified = self.qualify(&table);
        let mut statements = vec![format!(
            "CREATE TABLE {qualified} (\n  {}\n)",
            definitions.join(",\n  ")
        )];
        for column in &draft.columns {
            if let Some(comment) = column.comment_text() {
                statements.push(self.comment_on(&qualified, &column.name, Some(comment)));
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
        let narrowed = self.table_capabilities(original);
        if changes.renamed_table.is_some() && !narrowed.rename_table {
            return Err(refused("", DdlOperation::RenameTable, dependents(original)));
        }
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
        let alter = |action: String| format!("ALTER TABLE {qualified} {action}");
        for index in &changes.dropped_indexes {
            let index = TableRef::new(table.schema.clone(), index.name.clone());
            statements.push(format!("DROP INDEX {}", self.qualify(&index)));
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
            if changed.column_type {
                let resolved = draft.column_type.resolve(self, &draft.name)?;
                // DuckDB drops a column's collation with its old type
                // unless the new one names it again.
                let collation = collation_clause(Some(&alteration.original.attributes), &resolved.column_type);
                statements.push(alter(format!("ALTER COLUMN {name} TYPE {}{collation}", resolved.sql)));
            }
            if changed.nullability {
                let action = if draft.nullable {
                    "DROP NOT NULL"
                } else {
                    "SET NOT NULL"
                };
                statements.push(alter(format!("ALTER COLUMN {name} {action}")));
            }
            if changed.default {
                let column_type = draft.column_type.column_type(self, &draft.name)?;
                statements.push(alter(
                    match default_sql(self, &draft.name, &draft.default, &column_type)? {
                        Some(default) => format!("ALTER COLUMN {name} SET DEFAULT {default}"),
                        None => format!("ALTER COLUMN {name} DROP DEFAULT"),
                    },
                ));
            }
            if changed.comment {
                statements.push(self.comment_on(&qualified, &draft.name, draft.comment_text()));
            }
        }
        let held = dependents(original);
        for column in &changes.added_columns {
            // DuckDB adds no column with a constraint, so NOT NULL is set
            // once it is there, which a table with dependents refuses.
            if !column.nullable && !held.is_empty() {
                return Err(refused(&column.name, DdlOperation::AddColumn, held));
            }
            statements.push(alter(format!("ADD COLUMN {}", self.column_definition(column, false)?)));
            if !column.nullable {
                statements.push(alter(format!(
                    "ALTER COLUMN {} SET NOT NULL",
                    self.quote_identifier(&column.name)
                )));
            }
            if let Some(comment) = column.comment_text() {
                statements.push(self.comment_on(&qualified, &column.name, Some(comment)));
            }
        }
        if let Some(change) = &changes.primary_key {
            if change.from.is_some() || !narrowed.alter_primary_key {
                let column = change.to.first().map_or("", String::as_str);
                return Err(refused(column, DdlOperation::AlterPrimaryKey, held));
            }
            if !change.to.is_empty() {
                statements.push(alter(format!("ADD PRIMARY KEY ({})", column_list(self, &change.to))));
            }
        }
        statements.extend(
            changes
                .added_indexes
                .iter()
                .map(|index| create_index_sql(self, &table, index)),
        );
        DdlPlan::for_changes(changes, statements)
    }

    /// DuckDB's own CREATE TABLE text, which keeps its CHECK and UNIQUE
    /// constraints and its generated columns, then the indexes made on
    /// the table and the column comments, which that text leaves out.
    fn create_table_script(&self, definition: &TableDefinition) -> Result<DdlPlan, BuildDdlError> {
        let source = definition.source.as_ref().ok_or(BuildDdlError::NoTableSource)?;
        let mut statements = vec![source.create_statement.trim().trim_end_matches(';').to_owned()];
        statements.extend(
            source
                .dependents
                .iter()
                .map(|dependent| dependent.sql.trim().trim_end_matches(';').to_owned()),
        );
        for column in &definition.columns {
            if let Some(comment) = column.info.comment.as_deref().filter(|text| !text.is_empty()) {
                statements.push(self.comment_on(&self.portable_name(&definition.table), column.name(), Some(comment)));
            }
        }
        Ok(DdlPlan::from_sql(statements))
    }
}

/// ` COLLATE <name>` for a text column the catalogue read with one, as
/// DuckDB's own text spelled it.
fn collation_clause(attributes: Option<&ColumnAttributes>, column_type: &ColumnType) -> String {
    attributes
        .and_then(|attributes| attributes.collation.as_ref())
        .filter(|_| matches!(column_type.kind, ColumnKind::Text { .. }))
        .map(|collation| format!(" COLLATE {}", collation.name))
        .unwrap_or_default()
}

fn refused(column: &str, operation: DdlOperation, users: Vec<String>) -> BuildDdlError {
    BuildDdlError::Refused {
        column: column.to_owned(),
        operation,
        reason: match users.is_empty() {
            true => RefusalReason::EngineUnsupported,
            false => RefusalReason::ColumnInUse(users),
        },
    }
}

impl DuckDbDialect {
    /// A column as CREATE TABLE declares it, or as ADD COLUMN does when
    /// `constraints` is off. A column read from the catalogue keeps its
    /// generation expression and its CHECK.
    fn column_definition(&self, column: &DraftColumn, constraints: bool) -> Result<String, BuildDdlError> {
        let resolved = column.column_type.resolve(self, &column.name)?;
        let attributes = column.original.as_ref().map(|original| &original.attributes);
        let mut parts = vec![
            self.quote_identifier(&column.name),
            format!(
                "{}{}",
                resolved.sql,
                collation_clause(attributes, &resolved.column_type)
            ),
        ];
        if let Some(generated) = attributes.and_then(|attributes| attributes.generated.as_ref()) {
            parts.push(format!(
                "GENERATED ALWAYS AS ({}) VIRTUAL",
                generated.expression.as_sql()
            ));
        } else if let Some(default) = default_sql(self, &column.name, &column.default, &resolved.column_type)? {
            parts.push(format!("DEFAULT {default}"));
        }
        if constraints {
            if !column.nullable {
                parts.push("NOT NULL".to_owned());
            }
            if let Some(check) = attributes.and_then(|attributes| attributes.check.as_ref()) {
                parts.push(format!("CHECK ({})", check.as_sql()));
            }
        }
        Ok(parts.join(" "))
    }

    /// `table` as the statement names it: qualified for a change, portable
    /// in a script the user copies to replay elsewhere.
    fn comment_on(&self, table: &str, column: &str, comment: Option<&str>) -> String {
        let target = format!("{table}.{}", self.quote_identifier(column));
        let text = comment.map(|text| Value::Text(text.to_owned()));
        match text.and_then(|text| SqlDialect::literal(self, &text, &ColumnType::untyped_text("VARCHAR")).ok()) {
            Some(literal) => format!("COMMENT ON COLUMN {target} IS {literal}"),
            None => format!("COMMENT ON COLUMN {target} IS NULL"),
        }
    }
}
