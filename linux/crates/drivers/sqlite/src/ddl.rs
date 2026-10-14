//! How SQLite plans structure changes: its own ALTER TABLE where that
//! can make the change, and a rebuild of the table where it cannot.

mod column_constraint_segment;
mod create_table_source;
mod declared_shape;
mod native_change_rules;
mod rebuild_plan;
mod source_element;
mod source_read_error;

use tablepro_core::ForeignKeyInfo;
use tablepro_core::column::ColumnDefault;
use tablepro_core::ddl::ddl_sql::{column_list, default_sql, index_keys_sql, parenthesized};
use tablepro_core::ddl::{
    BuildDdlError, ColumnCapabilities, ColumnDefinition, DdlCapabilities, DdlDialect, DdlPlan, DraftColumn,
    GeneratedStorage, Permission, RefusalReason, SchemaObjectKind, TableChanges, TableDefinition, TableDraft,
};
use tablepro_core::dialect::SqlDialect;
use tablepro_core::meta::{IndexInfo, TableRef};

use self::create_table_source::CreateTableSource;
pub(crate) use self::create_table_source::declared_foreign_key_names;
use self::declared_shape::readable;
use crate::dialect::SqliteDialect;

/// A change ALTER TABLE cannot make rebuilds the table, so every change
/// is offered. The rebuild needs the table's stored CREATE TABLE, and
/// `table_capabilities` and `column_capabilities` refuse the changes
/// only a rebuild makes when that text cannot be read.
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
    alter_auto_increment: true,
    // AUTOINCREMENT belongs to the INTEGER PRIMARY KEY.
    auto_increment_outside_primary_key: false,
    create_index: true,
    drop_index: true,
    expression_index_keys: true,
    partial_indexes: true,
    add_foreign_key: true,
    drop_foreign_key: true,
    column_comments: false,
    drop_table_cascade: false,
};

const TYPE_SUGGESTIONS: &[&str] = &[
    "INTEGER", "TEXT", "REAL", "BLOB", "NUMERIC", "BOOLEAN", "DATETIME", "DATE",
];

impl DdlDialect for SqliteDialect {
    fn capabilities(&self) -> &DdlCapabilities {
        &CAPABILITIES
    }

    fn sql_dialect(&self) -> &dyn SqlDialect {
        self
    }

    /// Without a readable CREATE TABLE no rebuild runs, so no foreign key
    /// is added or dropped and the key stays where it is.
    fn table_capabilities(&self, table: &TableDefinition) -> DdlCapabilities {
        match readable(table) {
            true => CAPABILITIES,
            false => DdlCapabilities {
                alter_primary_key: false,
                add_foreign_key: false,
                drop_foreign_key: false,
                ..CAPABILITIES
            },
        }
    }

    /// The rebuild writes a new type or nullability beside a generated
    /// column's expression rather than restating the column, so neither
    /// loses the expression.
    fn column_capabilities(&self, table: &TableDefinition, column: &ColumnDefinition) -> ColumnCapabilities {
        let mut permissions = ColumnCapabilities::standard(&CAPABILITIES, table, column);
        let rebuildable = Permission::unless(readable(table), RefusalReason::UnreadableDefinition);
        let rebuild = || rebuildable.clone();
        permissions.alter_type = rebuild();
        permissions.alter_nullability = rebuild();
        permissions.alter_default = permissions.alter_default.and(rebuild);
        permissions.alter_primary_key = permissions.alter_primary_key.and(rebuild);
        permissions.alter_auto_increment = permissions.alter_auto_increment.and(rebuild);
        permissions
    }

    fn type_suggestions(&self) -> &'static [&'static str] {
        TYPE_SUGGESTIONS
    }

    fn default_column_type(&self) -> &'static str {
        "TEXT"
    }

    /// Foreign keys are declared inside CREATE TABLE, and the
    /// connection's `foreign_keys` setting enforces them.
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
        definitions.extend(
            draft
                .foreign_keys
                .iter()
                .map(|key| foreign_key_constraint(self, key, &key.columns)),
        );
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

    /// Native statements when ALTER TABLE makes every change, otherwise
    /// a rebuild that also runs the native ones.
    fn plan_alter_table(&self, original: &TableDefinition, changes: &TableChanges) -> Result<DdlPlan, BuildDdlError> {
        changes.check(self, original)?;
        let source = CreateTableSource::of(original);
        let Some(change) = native_change_rules::first_rebuild_change(original, source.as_ref().ok(), changes) else {
            return self.native_plan(original, changes);
        };
        let source = source.map_err(|error| {
            tracing::debug!(%error, table = %original.table.name, "the stored CREATE TABLE could not be read");
            BuildDdlError::Refused {
                column: change.column,
                operation: change.operation,
                reason: RefusalReason::UnreadableDefinition,
            }
        })?;
        rebuild_plan::plan(self, original, &source, changes)
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
    /// One native ALTER TABLE per change, inside the write's
    /// transaction.
    fn native_plan(&self, original: &TableDefinition, changes: &TableChanges) -> Result<DdlPlan, BuildDdlError> {
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
        // SQLite rewrites the table's indexes, triggers and views to the
        // new name as each rename runs.
        for rename in changes.ordered_renames(original) {
            statements.push(format!(
                "ALTER TABLE {qualified} RENAME COLUMN {} TO {}",
                self.quote_identifier(&rename.from),
                self.quote_identifier(&rename.to)
            ));
        }
        for column in &changes.added_columns {
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
        DdlPlan::for_changes(changes, statements)
    }

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

/// A foreign key as a table constraint over `columns`. The parent is
/// named bare, since SQLite looks for it in the child's own schema and
/// refuses a qualified name, and a key with no parent columns points at
/// the parent's primary key.
fn foreign_key_constraint(dialect: &SqliteDialect, key: &ForeignKeyInfo, columns: &[String]) -> String {
    let mut sql = format!(
        "CONSTRAINT {} FOREIGN KEY ({}) REFERENCES {}",
        dialect.quote_identifier(&key.name),
        column_list(dialect, columns),
        dialect.quote_identifier(&key.ref_table)
    );
    if !key.ref_columns.is_empty() {
        sql.push_str(&format!(" ({})", column_list(dialect, &key.ref_columns)));
    }
    for (clause, action) in [("ON DELETE", key.on_delete), ("ON UPDATE", key.on_update)] {
        if let Some(action) = action.filter(|action| !action.is_default()) {
            sql.push_str(&format!(" {clause} {}", action.as_sql()));
        }
    }
    sql
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
mod tests;
