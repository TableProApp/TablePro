//! A SQL Server database or schema as a SQL dump, in the order SMO
//! scripts one: schemas, alias types, sequences and tables before the
//! rows; indexes, identity positions, checks, foreign keys and comments
//! after them; then views and routines, then triggers.

mod dump_statements;
mod mssql_dump;

use std::collections::HashMap;

use tablepro_core::ddl::ddl_sql::index_keys_sql;
use tablepro_core::dialect::SqlDialect;
use tablepro_core::dump::{
    DumpCatalog, DumpObject, DumpObjectKind, DumpScope, DumpSection, DumpSkip, DumpSkipReason, DumpStatement, DumpTable,
};
use tablepro_core::meta::{IndexInfo, TableRef};
use tablepro_core::sql_syntax::{SqlGrammar, holds_client_directive};
use tablepro_core::{DriverError, ForeignKeyInfo, Value};
use tiberius::ColumnData;

use crate::catalog::Cells;
use crate::ddl::{CreateTableFacts, IdentitySeed, KeyClause};
use crate::dialect::MssqlDialect;
use crate::in_band_request::{Interrupt, Watch};
use crate::metadata::{self, CLR_TYPES, SEQUENCE_COLUMNS, SequenceRow, referential_action, sequence_statement};
use crate::physical::MssqlClient;
use crate::workspace_call::{catalogue_rows, text_param};

use dump_statements::{
    AliasBase, Enforcement, ModuleSettings, SequencePosition, check_constraint, create_alias_type, create_schema,
    disable_trigger, foreign_key, module_statements, next_unused, reseed, unique_constraint,
};
pub(crate) use mssql_dump::MssqlDump;

/// `{scope}` in each query below is the condition on its schema id.
const SCHEMAS_SQL: &str = "SELECT s.name FROM sys.schemas s WHERE s.name <> N'dbo' AND {scope} ORDER BY s.name";

/// Alias types over a system type. Table types and CLR types take syntax
/// this does not write.
const ALIAS_TYPES_SQL: &str = "SELECT SCHEMA_NAME(t.schema_id), t.name, TYPE_NAME(t.system_type_id), \
        CAST(t.max_length AS int), CAST(t.precision AS int), CAST(t.scale AS int), CAST(t.is_nullable AS int) \
    FROM sys.types t \
    WHERE t.is_user_defined = 1 AND t.is_assembly_type = 0 AND t.is_table_type = 0 AND {scope} \
    ORDER BY 1, 2";

const TABLES_SQL: &str = "SELECT SCHEMA_NAME(t.schema_id), t.name FROM sys.tables t \
    WHERE t.is_ms_shipped = 0 AND {scope} ORDER BY 1, 2";

/// Primary keys and UNIQUE constraints, and whether each one's index is
/// the table's clustered one.
const KEYS_SQL: &str = "SELECT SCHEMA_NAME(t.schema_id), t.name, kc.name, RTRIM(kc.type), \
        CAST(CASE WHEN i.type = 1 THEN 1 ELSE 0 END AS int) \
    FROM sys.key_constraints kc \
    JOIN sys.tables t ON t.object_id = kc.parent_object_id \
    JOIN sys.indexes i ON i.object_id = kc.parent_object_id AND i.index_id = kc.unique_index_id \
    WHERE t.is_ms_shipped = 0 AND {scope} \
    ORDER BY 1, 2, 3";

/// `last_value` is NULL until a row takes a number.
const IDENTITIES_SQL: &str = "SELECT SCHEMA_NAME(t.schema_id), t.name, CAST(ic.seed_value AS nvarchar(64)), \
        CAST(ic.increment_value AS nvarchar(64)), CAST(ic.last_value AS nvarchar(64)) \
    FROM sys.identity_columns ic JOIN sys.tables t ON t.object_id = ic.object_id \
    WHERE t.is_ms_shipped = 0 AND {scope} \
    ORDER BY 1, 2";

const CHECKS_SQL: &str = "SELECT SCHEMA_NAME(t.schema_id), t.name, cc.name, cc.definition, \
        CAST(cc.is_not_trusted AS int), CAST(cc.is_disabled AS int) \
    FROM sys.check_constraints cc JOIN sys.tables t ON t.object_id = cc.parent_object_id \
    WHERE t.is_ms_shipped = 0 AND {scope} \
    ORDER BY 1, 2, 3";

const FOREIGN_KEYS_SQL: &str = "SELECT SCHEMA_NAME(t.schema_id), t.name, fk.name, pc.name, \
        SCHEMA_NAME(rt.schema_id), rt.name, rc.name, fk.delete_referential_action_desc, \
        fk.update_referential_action_desc, CAST(fk.is_not_trusted AS int), CAST(fk.is_disabled AS int) \
    FROM sys.foreign_keys fk \
    JOIN sys.tables t ON t.object_id = fk.parent_object_id \
    JOIN sys.foreign_key_columns fkc ON fkc.constraint_object_id = fk.object_id \
    JOIN sys.columns pc ON pc.object_id = fkc.parent_object_id AND pc.column_id = fkc.parent_column_id \
    JOIN sys.objects rt ON rt.object_id = fk.referenced_object_id \
    JOIN sys.columns rc ON rc.object_id = fkc.referenced_object_id AND rc.column_id = fkc.referenced_column_id \
    WHERE t.is_ms_shipped = 0 AND {scope} \
    ORDER BY 1, 2, 3, fkc.constraint_column_id";

/// Views, functions and procedures, with what tells why one has no text
/// and the SET options it was made under. A CLR module has no
/// `sys.sql_modules` row.
const MODULES_SQL: &str = "SELECT SCHEMA_NAME(o.schema_id), o.name, RTRIM(o.type), OBJECT_DEFINITION(o.object_id), \
        CAST(OBJECTPROPERTY(o.object_id, 'IsEncrypted') AS int), \
        CAST(m.uses_ansi_nulls AS int), CAST(m.uses_quoted_identifier AS int) \
    FROM sys.objects o LEFT JOIN sys.sql_modules m ON m.object_id = o.object_id \
    WHERE o.type IN ('V', 'FN', 'IF', 'TF', 'FS', 'FT', 'P', 'PC') AND o.is_ms_shipped = 0 AND {scope} \
    ORDER BY 1, 2";

/// DML triggers of tables and views; `parent_class` 1 leaves out the
/// database's DDL triggers.
const TRIGGERS_SQL: &str = "SELECT SCHEMA_NAME(p.schema_id), tr.name, p.name, RTRIM(tr.type), \
        OBJECT_DEFINITION(tr.object_id), CAST(OBJECTPROPERTY(tr.object_id, 'IsEncrypted') AS int), \
        CAST(m.uses_ansi_nulls AS int), CAST(m.uses_quoted_identifier AS int), CAST(tr.is_disabled AS int) \
    FROM sys.triggers tr JOIN sys.objects p ON p.object_id = tr.parent_id \
    LEFT JOIN sys.sql_modules m ON m.object_id = tr.object_id \
    WHERE tr.parent_class = 1 AND tr.is_ms_shipped = 0 AND {scope} \
    ORDER BY 1, 3, 2";

/// The sequences, with where each stands. `last_used_value`, which says
/// whether one was ever used, came with SQL Server 2017; before it, a
/// sequence still at its start reads as unused.
fn sequences_sql(major_version: u32) -> String {
    let used = match major_version >= 14 {
        true => "CAST(CASE WHEN s.last_used_value IS NULL THEN 0 ELSE 1 END AS int)",
        false => "CAST(CASE WHEN s.current_value = s.start_value THEN 0 ELSE 1 END AS int)",
    };
    format!(
        "SELECT SCHEMA_NAME(s.schema_id), s.name, {SEQUENCE_COLUMNS}, CAST(s.current_value AS nvarchar(64)), {used} \
         FROM sys.sequences s JOIN sys.types t ON t.user_type_id = s.user_type_id \
         WHERE {{scope}} ORDER BY 1, 2"
    )
}

/// The condition that keeps a query to the scope's schemas: every one of
/// the database's but the server's own and the fixed roles' (ids from
/// 16384), or the one named in `@P1`.
fn scope_condition(scope: &DumpScope, schema_id: &str) -> String {
    match scope {
        DumpScope::Database => {
            format!("{schema_id} < 16384 AND SCHEMA_NAME({schema_id}) NOT IN (N'sys', N'INFORMATION_SCHEMA', N'guest')")
        }
        DumpScope::Schema(_) => format!("{schema_id} = SCHEMA_ID(@P1)"),
    }
}

fn scope_params(scope: &DumpScope) -> Vec<ColumnData<'static>> {
    match scope {
        DumpScope::Database => Vec::new(),
        DumpScope::Schema(schema) => vec![text_param(schema)],
    }
}

/// What goes after the rows, kept apart by kind so the file has each
/// kind together in the order a load needs.
#[derive(Default)]
struct AfterData {
    indexes: Vec<DumpObject>,
    positions: Vec<DumpObject>,
    checks: Vec<DumpObject>,
    foreign_keys: Vec<DumpObject>,
    comments: Vec<DumpObject>,
}

impl AfterData {
    fn into_objects(self) -> impl Iterator<Item = DumpObject> {
        self.indexes
            .into_iter()
            .chain(self.positions)
            .chain(self.checks)
            .chain(self.foreign_keys)
            .chain(self.comments)
    }
}

fn after(kind: DumpObjectKind, schema: Option<String>, name: &str, statements: Vec<String>) -> DumpObject {
    DumpObject::new(
        kind,
        DumpSection::AfterData,
        schema,
        name,
        statements.into_iter().map(DumpStatement::new).collect(),
    )
}

pub(crate) async fn read_dump_catalog(
    client: &mut MssqlClient,
    watch: &Watch,
    dialect: &MssqlDialect,
    scope: &DumpScope,
) -> Result<DumpCatalog, Interrupt> {
    let mut read = CatalogRead {
        client,
        watch,
        dialect,
        scope,
        catalog: DumpCatalog::default(),
        after_data: AfterData::default(),
    };
    read.before_data().await?;
    read.tables().await?;
    read.constraints().await?;
    read.modules().await?;
    let CatalogRead {
        mut catalog,
        after_data,
        ..
    } = read;
    catalog.objects.extend(after_data.into_objects());
    Ok(catalog)
}

/// One dump's catalogue read, on one connection.
struct CatalogRead<'a> {
    client: &'a mut MssqlClient,
    watch: &'a Watch,
    dialect: &'a MssqlDialect,
    scope: &'a DumpScope,
    catalog: DumpCatalog,
    after_data: AfterData,
}

impl CatalogRead<'_> {
    /// `sql`'s rows with its `{scope}` the condition on `schema_id`.
    async fn rows(&mut self, sql: &str, schema_id: &str) -> Result<Vec<Vec<Value>>, Interrupt> {
        let sql = sql.replace("{scope}", &scope_condition(self.scope, schema_id));
        catalogue_rows(self.client, self.watch, &sql, &scope_params(self.scope)).await
    }

    async fn before_data(&mut self) -> Result<(), Interrupt> {
        for row in self.rows(SCHEMAS_SQL, "s.schema_id").await? {
            let name = Cells::new(&row, "sys.schemas").required_text(0)?;
            let create = DumpStatement::new(create_schema(&name));
            self.catalog.objects.push(DumpObject::new(
                DumpObjectKind::Schema,
                DumpSection::BeforeData,
                None,
                name,
                vec![create],
            ));
        }
        for row in self.rows(ALIAS_TYPES_SQL, "t.schema_id").await? {
            self.catalog.objects.push(alias_type(self.dialect, &row)?);
        }
        let sequences = sequences_sql(self.dialect.major_version());
        for row in self.rows(&sequences, "s.schema_id").await? {
            self.catalog.objects.push(sequence(self.dialect, &row)?);
        }
        Ok(())
    }

    async fn tables(&mut self) -> Result<(), Interrupt> {
        let keys = key_rows(&self.rows(KEYS_SQL, "t.schema_id").await?)?;
        let identities = identity_rows(&self.rows(IDENTITIES_SQL, "t.schema_id").await?)?;
        for row in self.rows(TABLES_SQL, "t.schema_id").await? {
            let cells = Cells::new(&row, "sys.tables");
            let table = TableRef::new(cells.text(0), cells.required_text(1)?);
            let parts = TableParts {
                keys: keys.get(&table).map(Vec::as_slice).unwrap_or_default(),
                identity: identities.get(&table),
            };
            self.table(&table, &parts).await?;
        }
        Ok(())
    }

    /// The table's CREATE without its foreign keys, which go after every
    /// table's rows, and what follows its rows: indexes, UNIQUE
    /// constraints, the identity's position and column comments.
    async fn table(&mut self, table: &TableRef, parts: &TableParts<'_>) -> Result<(), Interrupt> {
        let dialect = self.dialect;
        let relation = dialect.qualify(table);
        let mut definition =
            metadata::fetch_table_definition(self.client, self.watch, table, &relation, dialect.major_version())
                .await?;
        definition.foreign_keys.clear();
        let unique = |index: &IndexInfo| parts.keys.iter().any(|key| !key.primary && key.name == index.name);
        let (uniques, indexes): (Vec<IndexInfo>, Vec<IndexInfo>) =
            std::mem::take(&mut definition.indexes).into_iter().partition(unique);
        definition.indexes = indexes;
        let facts = CreateTableFacts {
            key: key_clause(dialect, &definition.indexes, parts.keys),
            identity: parts
                .identity
                .and_then(|identity| IdentitySeed::new(&identity.seed, &identity.increment)),
        };
        let script = dialect
            .table_script(&definition, &facts)
            .map_err(|error| DriverError::Decode {
                column: format!("table {relation}"),
                detail: error.to_string(),
            })?;

        self.catalog.objects.push(DumpObject::table(
            table.clone(),
            vec![DumpStatement::new(script.create)],
        ));
        self.catalog.tables.push(DumpTable::new(table.clone()));
        let schema = || table.schema.clone();
        let indexes: Vec<String> = script.indexes.into_iter().chain(script.stated).collect();
        if !indexes.is_empty() {
            self.after_data
                .indexes
                .push(after(DumpObjectKind::Index, schema(), &table.name, indexes));
        }
        for index in &uniques {
            let clustered = parts.keys.iter().any(|key| key.name == index.name && key.clustered);
            let statement = unique_constraint(dialect, &relation, index, clustered);
            self.after_data.indexes.push(after(
                DumpObjectKind::Constraint,
                schema(),
                &index.name,
                vec![statement],
            ));
        }
        let last_value = parts.identity.and_then(|identity| identity.last_value.as_deref());
        if let Some(last_value) = last_value
            && has_rows(self.client, self.watch, &relation).await?
        {
            let statements = reseed(&relation, last_value).into_iter().collect();
            self.after_data
                .positions
                .push(after(DumpObjectKind::SequenceValue, schema(), &table.name, statements));
        }
        if !script.comments.is_empty() {
            self.after_data
                .comments
                .push(after(DumpObjectKind::Comment, schema(), &table.name, script.comments));
        }
        Ok(())
    }

    /// CHECK constraints and foreign keys, which the structure model
    /// either leaves out or puts inside the CREATE.
    async fn constraints(&mut self) -> Result<(), Interrupt> {
        for row in self.rows(CHECKS_SQL, "t.schema_id").await? {
            let cells = Cells::new(&row, "sys.check_constraints");
            let table = TableRef::new(cells.text(0), cells.required_text(1)?);
            let name = cells.required_text(2)?;
            let Some(definition) = cells.text(3) else {
                self.catalog.skipped.push(DumpSkip {
                    kind: DumpObjectKind::Constraint,
                    schema: table.schema.clone(),
                    name,
                    reason: DumpSkipReason::NoDefinition,
                });
                continue;
            };
            let enforcement = Enforcement {
                trusted: !cells.flag(4),
                disabled: cells.flag(5),
            };
            let statements = check_constraint(&self.dialect.qualify(&table), &name, &definition, enforcement);
            self.after_data
                .checks
                .push(after(DumpObjectKind::Constraint, table.schema, &name, statements));
        }
        let rows = self.rows(FOREIGN_KEYS_SQL, "t.schema_id").await?;
        for found in foreign_key_rows(&rows)? {
            let statements = foreign_key(self.dialect, &found.table, &found.key, found.enforcement);
            self.after_data.foreign_keys.push(after(
                DumpObjectKind::ForeignKey,
                found.table.schema,
                &found.key.name,
                statements,
            ));
        }
        Ok(())
    }

    async fn modules(&mut self) -> Result<(), Interrupt> {
        for row in self.rows(MODULES_SQL, "o.schema_id").await? {
            let cells = Cells::new(&row, "sys.sql_modules");
            let module = Module {
                schema: cells.required_text(0)?,
                name: cells.required_text(1)?,
                code: cells.required_text(2)?,
                text: cells.text(3),
                encrypted: cells.flag(4),
                settings: settings(&cells, 5),
            };
            place_module(&mut self.catalog, module, DumpSection::Programs, None);
        }
        for row in self.rows(TRIGGERS_SQL, "p.schema_id").await? {
            let cells = Cells::new(&row, "sys.triggers");
            let schema = cells.required_text(0)?;
            let table = TableRef::new(Some(schema.clone()), cells.required_text(2)?);
            let module = Module {
                schema,
                name: cells.required_text(1)?,
                code: cells.required_text(3)?,
                text: cells.text(4),
                encrypted: cells.flag(5),
                settings: settings(&cells, 6),
            };
            let disabled = cells.flag(8).then(|| self.dialect.qualify(&table));
            place_module(&mut self.catalog, module, DumpSection::Triggers, disabled);
        }
        Ok(())
    }
}

/// The primary key as its constraint and index are, where both are read.
fn key_clause(dialect: &MssqlDialect, indexes: &[IndexInfo], keys: &[KeyRow]) -> Option<KeyClause> {
    let key = keys.iter().find(|key| key.primary)?;
    let index = indexes.iter().find(|index| index.primary && index.name == key.name)?;
    Some(KeyClause {
        name: key.name.clone(),
        clustered: key.clustered,
        keys: index_keys_sql(dialect, index),
    })
}

fn alias_type(dialect: &MssqlDialect, row: &[Value]) -> Result<DumpObject, DriverError> {
    let cells = Cells::new(row, "sys.types");
    let schema = cells.text(0);
    let name = cells.required_text(1)?;
    let system_type = cells.required_text(2)?;
    let base = AliasBase {
        system_type: &system_type,
        max_length: cells.int(3).unwrap_or(0),
        precision: cells.int(4).unwrap_or(0),
        scale: cells.int(5).unwrap_or(0),
        nullable: cells.flag(6),
    };
    let qualified = dialect.qualify(&TableRef::new(schema.clone(), name.clone()));
    let create = DumpStatement::new(create_alias_type(&qualified, &base));
    Ok(DumpObject::new(
        DumpObjectKind::Type,
        DumpSection::BeforeData,
        schema,
        name,
        vec![create],
    ))
}

/// The sequence made again where the old one would hand out its next
/// value, so a load hands out none twice.
fn sequence(dialect: &MssqlDialect, row: &[Value]) -> Result<DumpObject, DriverError> {
    let cells = Cells::new(row, "sys.sequences");
    let schema = cells.text(0);
    let name = cells.required_text(1)?;
    let settings = row.get(2..11).unwrap_or_default();
    let mut sequence = SequenceRow::from_cells(&Cells::new(settings, "sys.sequences"))?;
    let current = cells.required_text(11)?;
    sequence.start = next_unused(&SequencePosition {
        start: &sequence.start,
        current: &current,
        increment: &sequence.increment,
        minimum: &sequence.minimum,
        maximum: &sequence.maximum,
        cycles: sequence.cycles,
        used: cells.flag(12),
    });
    let qualified = dialect.qualify(&TableRef::new(schema.clone(), name.clone()));
    let create = DumpStatement::new(sequence_statement(&qualified, &sequence));
    Ok(DumpObject::new(
        DumpObjectKind::Sequence,
        DumpSection::BeforeData,
        schema,
        name,
        vec![create],
    ))
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct KeyRow {
    name: String,
    primary: bool,
    clustered: bool,
}

fn key_rows(rows: &[Vec<Value>]) -> Result<HashMap<TableRef, Vec<KeyRow>>, DriverError> {
    let mut keys: HashMap<TableRef, Vec<KeyRow>> = HashMap::new();
    for row in rows {
        let cells = Cells::new(row, "sys.key_constraints");
        let table = TableRef::new(cells.text(0), cells.required_text(1)?);
        keys.entry(table).or_default().push(KeyRow {
            name: cells.required_text(2)?,
            primary: cells.text(3).as_deref() == Some("PK"),
            clustered: cells.flag(4),
        });
    }
    Ok(keys)
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct IdentityRow {
    seed: String,
    increment: String,
    last_value: Option<String>,
}

fn identity_rows(rows: &[Vec<Value>]) -> Result<HashMap<TableRef, IdentityRow>, DriverError> {
    let mut identities = HashMap::new();
    for row in rows {
        let cells = Cells::new(row, "sys.identity_columns");
        let table = TableRef::new(cells.text(0), cells.required_text(1)?);
        identities.insert(
            table,
            IdentityRow {
                seed: cells.required_text(2)?,
                increment: cells.required_text(3)?,
                last_value: cells.text(4),
            },
        );
    }
    Ok(identities)
}

/// What the scope-wide reads say about one table.
struct TableParts<'a> {
    keys: &'a [KeyRow],
    identity: Option<&'a IdentityRow>,
}

async fn has_rows(client: &mut MssqlClient, watch: &Watch, relation: &str) -> Result<bool, Interrupt> {
    let sql = format!("SELECT CAST(CASE WHEN EXISTS (SELECT 1 FROM {relation}) THEN 1 ELSE 0 END AS int)");
    let rows = catalogue_rows(client, watch, &sql, &[]).await?;
    Ok(rows.first().is_some_and(|row| Cells::new(row, "EXISTS").flag(0)))
}

struct ForeignKeyRow {
    table: TableRef,
    key: ForeignKeyInfo,
    enforcement: Enforcement,
}

/// One row per column pair, in key order, grouped into keys.
fn foreign_key_rows(rows: &[Vec<Value>]) -> Result<Vec<ForeignKeyRow>, DriverError> {
    let mut keys: Vec<ForeignKeyRow> = Vec::new();
    for row in rows {
        let cells = Cells::new(row, "sys.foreign_keys");
        let table = TableRef::new(cells.text(0), cells.required_text(1)?);
        let name = cells.required_text(2)?;
        let column = cells.required_text(3)?;
        let referenced = cells.required_text(6)?;
        match keys.last_mut() {
            Some(last) if last.table == table && last.key.name == name => {
                last.key.columns.push(column);
                last.key.ref_columns.push(referenced);
            }
            _ => keys.push(ForeignKeyRow {
                table,
                key: ForeignKeyInfo {
                    name,
                    columns: vec![column],
                    ref_schema: cells.text(4),
                    ref_table: cells.required_text(5)?,
                    ref_columns: vec![referenced],
                    on_delete: cells.text(7).as_deref().and_then(referential_action),
                    on_update: cells.text(8).as_deref().and_then(referential_action),
                },
                enforcement: Enforcement {
                    trusted: !cells.flag(9),
                    disabled: cells.flag(10),
                },
            }),
        }
    }
    Ok(keys)
}

/// A view, routine or trigger as the catalogue gives it.
struct Module {
    schema: String,
    name: String,
    code: String,
    text: Option<String>,
    encrypted: bool,
    settings: ModuleSettings,
}

/// A module with no `sys.sql_modules` row reads as made under the
/// defaults.
fn settings(cells: &Cells<'_>, first: usize) -> ModuleSettings {
    let on = |index: usize| cells.int(index).is_none_or(|value| value != 0);
    ModuleSettings {
        ansi_nulls: on(first),
        quoted_identifier: on(first + 1),
    }
}

fn module_kind(code: &str) -> DumpObjectKind {
    match code {
        "V" => DumpObjectKind::View,
        "P" | "PC" => DumpObjectKind::Procedure,
        "TR" | "TA" => DumpObjectKind::Trigger,
        _ => DumpObjectKind::Function,
    }
}

/// The module in `section`, or in the skipped list with why it has no
/// text. `disabled_on` names the table of a trigger that is turned off.
fn place_module(catalog: &mut DumpCatalog, module: Module, section: DumpSection, disabled_on: Option<String>) {
    let kind = module_kind(&module.code);
    let Some(text) = module.text else {
        let reason = if CLR_TYPES.contains(&module.code.as_str()) {
            DumpSkipReason::ClrRoutine
        } else if module.encrypted {
            DumpSkipReason::Encrypted
        } else {
            DumpSkipReason::NoDefinition
        };
        catalog.skipped.push(DumpSkip {
            kind,
            schema: Some(module.schema),
            name: module.name,
            reason,
        });
        return;
    };
    // A line that is only GO inside the text would end the batch there on
    // load, and make a different module.
    if holds_client_directive(&text, SqlGrammar::MsSql) {
        catalog.skipped.push(DumpSkip {
            kind,
            schema: Some(module.schema),
            name: module.name,
            reason: DumpSkipReason::SplitsApart,
        });
        return;
    }
    let mut statements = module_statements(&module.schema, &text, module.settings);
    if let Some(table) = disabled_on {
        statements.push(DumpStatement::new(disable_trigger(
            &module.schema,
            &module.name,
            &table,
        )));
    }
    catalog.objects.push(DumpObject::new(
        kind,
        section,
        Some(module.schema),
        module.name,
        statements,
    ));
}

#[cfg(test)]
mod tests {
    use tablepro_core::ddl::ReferentialAction;

    use super::*;

    fn text(value: &str) -> Value {
        Value::Text(value.to_owned())
    }

    fn module(code: &str, text: Option<&str>, encrypted: bool) -> Module {
        Module {
            schema: "app".to_owned(),
            name: "m".to_owned(),
            code: code.to_owned(),
            text: text.map(str::to_owned),
            encrypted,
            settings: ModuleSettings {
                ansi_nulls: true,
                quoted_identifier: true,
            },
        }
    }

    #[test]
    fn a_scope_is_the_users_schemas_or_the_one_named() {
        assert_eq!(
            scope_condition(&DumpScope::Database, "o.schema_id"),
            "o.schema_id < 16384 AND SCHEMA_NAME(o.schema_id) NOT IN (N'sys', N'INFORMATION_SCHEMA', N'guest')"
        );
        assert_eq!(
            scope_condition(&DumpScope::Schema("app".to_owned()), "t.schema_id"),
            "t.schema_id = SCHEMA_ID(@P1)"
        );
        assert!(scope_params(&DumpScope::Database).is_empty());
        assert_eq!(scope_params(&DumpScope::Schema("app".to_owned())).len(), 1);
    }

    #[test]
    fn every_query_is_ordered_and_scoped() {
        for sql in [
            SCHEMAS_SQL,
            ALIAS_TYPES_SQL,
            TABLES_SQL,
            KEYS_SQL,
            IDENTITIES_SQL,
            CHECKS_SQL,
            FOREIGN_KEYS_SQL,
            MODULES_SQL,
            TRIGGERS_SQL,
            &sequences_sql(16),
            &sequences_sql(13),
        ] {
            assert!(sql.contains("{scope}") && sql.contains(" ORDER BY "), "{sql}");
        }
        assert!(sequences_sql(14).contains("last_used_value"));
        assert!(!sequences_sql(13).contains("last_used_value"));
    }

    #[test]
    fn foreign_key_rows_group_by_table_and_constraint() {
        let row = |table: &str, name: &str, column: &str, referenced: &str, trusted: i64| {
            vec![
                text("app"),
                text(table),
                text(name),
                text(column),
                text("app"),
                text("parent"),
                text(referenced),
                text("CASCADE"),
                text("NO_ACTION"),
                Value::Int(1 - trusted),
                Value::Int(0),
            ]
        };
        let rows = vec![
            row("child", "fk", "tenant", "tenant", 1),
            row("child", "fk", "parent_id", "id", 1),
            row("other", "fk", "parent_id", "id", 0),
        ];

        let keys = foreign_key_rows(&rows).unwrap();

        assert_eq!(keys.len(), 2);
        assert_eq!(keys[0].key.columns, ["tenant", "parent_id"]);
        assert_eq!(keys[0].key.ref_columns, ["tenant", "id"]);
        assert_eq!(keys[0].key.on_delete, Some(ReferentialAction::Cascade));
        assert!(keys[0].enforcement.trusted);
        assert_eq!(keys[1].table, TableRef::new(Some("app".to_owned()), "other"));
        assert!(!keys[1].enforcement.trusted);
    }

    #[test]
    fn key_rows_tell_the_primary_key_from_a_unique_one() {
        let rows = vec![
            vec![text("app"), text("t"), text("pk_t"), text("PK"), Value::Int(1)],
            vec![text("app"), text("t"), text("uq_t"), text("UQ"), Value::Int(0)],
        ];

        let keys = key_rows(&rows).unwrap();

        let table = TableRef::new(Some("app".to_owned()), "t");
        assert_eq!(
            keys.get(&table).map(Vec::as_slice),
            Some(
                &[
                    KeyRow {
                        name: "pk_t".to_owned(),
                        primary: true,
                        clustered: true,
                    },
                    KeyRow {
                        name: "uq_t".to_owned(),
                        primary: false,
                        clustered: false,
                    },
                ][..]
            )
        );
    }

    #[test]
    fn a_sequence_is_made_again_at_its_next_value() {
        let row = vec![
            text("app"),
            text("ticket"),
            text("int"),
            text("100"),
            text("5"),
            text("-2147483648"),
            text("2147483647"),
            Value::Int(0),
            Value::Int(1),
            Value::Null,
            Value::Int(10),
            text("110"),
            Value::Int(1),
        ];

        let object = sequence(&MssqlDialect::new(16), &row).unwrap();

        assert_eq!(object.kind, DumpObjectKind::Sequence);
        assert_eq!(
            object.statements,
            [DumpStatement::new(
                "CREATE SEQUENCE [app].[ticket] AS int START WITH 115 INCREMENT BY 5 MINVALUE -2147483648 \
                 MAXVALUE 2147483647 NO CYCLE CACHE;"
            )]
        );
    }

    #[test]
    fn a_module_without_text_is_skipped_with_why() {
        let mut catalog = DumpCatalog::default();

        place_module(&mut catalog, module("PC", None, false), DumpSection::Programs, None);
        place_module(&mut catalog, module("P", None, true), DumpSection::Programs, None);
        place_module(&mut catalog, module("V", None, false), DumpSection::Programs, None);

        let reasons: Vec<(DumpObjectKind, DumpSkipReason)> =
            catalog.skipped.iter().map(|skip| (skip.kind, skip.reason)).collect();
        assert_eq!(
            reasons,
            [
                (DumpObjectKind::Procedure, DumpSkipReason::ClrRoutine),
                (DumpObjectKind::Procedure, DumpSkipReason::Encrypted),
                (DumpObjectKind::View, DumpSkipReason::NoDefinition),
            ]
        );
        assert!(catalog.objects.is_empty());
    }

    #[test]
    fn a_disabled_trigger_is_made_then_turned_off() {
        let mut catalog = DumpCatalog::default();
        let trigger = module("TR", Some("CREATE TRIGGER tr ON t AFTER INSERT AS SELECT 1"), false);

        place_module(
            &mut catalog,
            trigger,
            DumpSection::Triggers,
            Some("[app].[t]".to_owned()),
        );

        let object = &catalog.objects[0];
        assert_eq!(
            (object.kind, object.section),
            (DumpObjectKind::Trigger, DumpSection::Triggers)
        );
        let sql: Vec<&str> = object
            .statements
            .iter()
            .map(|statement| statement.sql.as_str())
            .collect();
        assert_eq!(
            sql,
            [
                "CREATE TRIGGER [app].tr ON [app].t AFTER INSERT AS SELECT 1",
                "DISABLE TRIGGER [app].[m] ON [app].[t]",
            ]
        );
    }

    #[test]
    fn a_module_that_a_go_line_would_split_is_left_out() {
        let mut catalog = DumpCatalog::default();
        let split = module("P", Some("CREATE PROCEDURE p AS\nSELECT 1\nGO\nSELECT 2"), false);

        place_module(&mut catalog, split, DumpSection::Programs, None);

        assert!(catalog.objects.is_empty() && catalog.skipped.is_empty());
    }
}
