//! The catalogue reads behind the sidebar, the grid and the structure
//! tab. Every one is a bound query over information_schema, so a table
//! name never becomes SQL.

use std::collections::HashMap;

use futures_util::TryStreamExt;
use sqlx::mysql::MySqlConnection;
use sqlx::{AssertSqlSafe, Executor as _, Row as _};
use tablepro_core::column::{ColumnDefault, ColumnInfo, ColumnKind, SqlExpression, TemporalZone};
use tablepro_core::ddl::{
    CharacterSet, ColumnDefinition, InboundForeignKey, OutboundForeignKey, PrimaryKeyConstraint, ReferentialAction,
    TableDefinition, TableOptions, TableSource, UnmodeledAttribute,
};
use tablepro_core::dialect::SqlDialect;
use tablepro_core::meta::{
    IndexInfo, IndexKey, ObjectInfo, ObjectKind, ObjectScope, RowCountEstimate, RowIdentity, SchemaInfo, TableEstimate,
    TableRef,
};
use tablepro_core::{DriverError, ForeignKeyInfo, UnsupportedFeature, Value};

use crate::catalog::{
    CHARACTER_SETS_SQL, COLLATIONS_SQL, COLUMN_COMPARISONS_SQL, COLUMN_ENGINE_ATTRIBUTES_SQL, CatalogCells,
    ColumnCheck, FULL_COLLATION_NAMES_SQL, FULL_COLLATIONS_SQL, INBOUND_FOREIGN_KEYS_SQL, ListedOptions, ListedSrid,
    MARIADB_COLUMN_CHECKS_SQL, MARIADB_GEOMETRY_SRIDS_SQL, MySqlColumnRow, TableComparisons, character_sets,
    column_checks, column_comparisons, column_definition, column_info, columns_sql, compares_alike, geometry_srids,
    inbound_foreign_keys, place_column_checks, quoted_default, table_options,
};
use crate::decode::decode_row;
use crate::dialect::MySqlDialect;
use crate::errors::map_error;
use crate::flavour::MySqlFlavour;
use crate::mysql_timestamp_mode::MySqlTimestampMode;
use crate::mysql_wire_format::MySqlWireFormat;
use crate::table_engine::{self, TableEngine};

/// Rows of a catalogue query whose parameters are all text or NULL.
pub(crate) async fn catalog_rows(
    connection: &mut MySqlConnection,
    flavour: MySqlFlavour,
    sql: &'static str,
    table: &'static str,
    binds: &[Option<&str>],
) -> Result<Vec<CatalogCells>, DriverError> {
    let mut query = sqlx::query(sql).persistent(false);
    for bind in binds {
        query = query.bind(bind.map(str::to_owned));
    }
    let rows: Vec<_> = query
        .fetch(&mut *connection)
        .try_collect()
        .await
        .map_err(|error| map_error(&error, flavour))?;
    Ok(rows
        .iter()
        .map(|row| {
            CatalogCells::new(
                table,
                decode_row(row, MySqlWireFormat::Binary, MySqlTimestampMode::WorkspaceUtc),
            )
        })
        .collect())
}

fn table_binds(table: &TableRef) -> [Option<&str>; 2] {
    [table.schema.as_deref(), Some(table.name.as_str())]
}

pub(crate) async fn list_schemas(
    connection: &mut MySqlConnection,
    flavour: MySqlFlavour,
) -> Result<Vec<SchemaInfo>, DriverError> {
    let rows = catalog_rows(connection, flavour, "SELECT DATABASE()", "DATABASE", &[]).await?;
    let current = match rows.first() {
        Some(row) => row.text(0)?,
        None => None,
    };
    Ok(current
        .into_iter()
        .map(|name| SchemaInfo {
            name,
            is_default: true,
            is_system: false,
        })
        .collect())
}

/// The databases MySQL and MariaDB keep for themselves.
const SYSTEM_DATABASES: [&str; 4] = ["information_schema", "mysql", "performance_schema", "sys"];

/// Every database the login can see, the connection's own the default.
pub(crate) async fn list_databases(
    connection: &mut MySqlConnection,
    flavour: MySqlFlavour,
) -> Result<Vec<SchemaInfo>, DriverError> {
    let current = list_schemas(connection, flavour)
        .await?
        .into_iter()
        .next()
        .map(|schema| schema.name);
    let rows = catalog_rows(
        connection,
        flavour,
        "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA ORDER BY SCHEMA_NAME",
        "SCHEMATA",
        &[],
    )
    .await?;
    let mut databases = Vec::with_capacity(rows.len());
    for row in rows {
        let Some(name) = row.text(0)? else {
            continue;
        };
        databases.push(SchemaInfo {
            is_default: current.as_deref() == Some(name.as_str()),
            is_system: SYSTEM_DATABASES.contains(&name.as_str()),
            name,
        });
    }
    Ok(databases)
}

const TABLES_IN_SCHEMA_SQL: &str = "\
SELECT TABLE_SCHEMA, TABLE_NAME, TABLE_TYPE FROM information_schema.TABLES
WHERE TABLE_SCHEMA = COALESCE(?, DATABASE()) ORDER BY TABLE_NAME";
const ROUTINES_IN_SCHEMA_SQL: &str = "\
SELECT ROUTINE_SCHEMA, ROUTINE_NAME, ROUTINE_TYPE FROM information_schema.ROUTINES
WHERE ROUTINE_SCHEMA = COALESCE(?, DATABASE()) ORDER BY ROUTINE_NAME";
/// The schemas MySQL keeps for itself stay out of "all schemas".
const ALL_TABLES_SQL: &str = "\
SELECT TABLE_SCHEMA, TABLE_NAME, TABLE_TYPE FROM information_schema.TABLES
WHERE TABLE_SCHEMA NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys')
ORDER BY TABLE_SCHEMA, TABLE_NAME";
const ALL_ROUTINES_SQL: &str = "\
SELECT ROUTINE_SCHEMA, ROUTINE_NAME, ROUTINE_TYPE FROM information_schema.ROUTINES
WHERE ROUTINE_SCHEMA NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys')
ORDER BY ROUTINE_SCHEMA, ROUTINE_NAME";

const TRIGGERS_IN_SCHEMA_SQL: &str = "\
SELECT TRIGGER_SCHEMA, TRIGGER_NAME, EVENT_OBJECT_TABLE FROM information_schema.TRIGGERS
WHERE TRIGGER_SCHEMA = COALESCE(?, DATABASE()) ORDER BY TRIGGER_NAME, EVENT_OBJECT_TABLE";
const ALL_TRIGGERS_SQL: &str = "\
SELECT TRIGGER_SCHEMA, TRIGGER_NAME, EVENT_OBJECT_TABLE FROM information_schema.TRIGGERS
WHERE TRIGGER_SCHEMA NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys')
ORDER BY TRIGGER_SCHEMA, TRIGGER_NAME, EVENT_OBJECT_TABLE";

/// Tables, views and sequences, then routines, then triggers. Separate
/// reads rather than a UNION, because the catalogue tables collate their
/// names differently and a UNION of them can refuse to sort.
pub(crate) async fn list_objects(
    connection: &mut MySqlConnection,
    flavour: MySqlFlavour,
    scope: &ObjectScope,
) -> Result<Vec<ObjectInfo>, DriverError> {
    let (tables_sql, routines_sql, triggers_sql, binds): (_, _, _, Vec<Option<&str>>) = match scope {
        ObjectScope::DefaultSchema => (
            TABLES_IN_SCHEMA_SQL,
            ROUTINES_IN_SCHEMA_SQL,
            TRIGGERS_IN_SCHEMA_SQL,
            vec![None],
        ),
        ObjectScope::Schema(name) => (
            TABLES_IN_SCHEMA_SQL,
            ROUTINES_IN_SCHEMA_SQL,
            TRIGGERS_IN_SCHEMA_SQL,
            vec![Some(name.as_str())],
        ),
        ObjectScope::AllSchemas => (ALL_TABLES_SQL, ALL_ROUTINES_SQL, ALL_TRIGGERS_SQL, Vec::new()),
    };
    let mut objects = Vec::new();
    for (sql, table) in [(tables_sql, "TABLES"), (routines_sql, "ROUTINES")] {
        for row in catalog_rows(connection, flavour, sql, table, &binds).await? {
            let kind = match row.text(2)?.as_deref() {
                Some("BASE TABLE" | "SYSTEM VERSIONED" | "TEMPORARY") => ObjectKind::Table,
                Some("VIEW" | "SYSTEM VIEW") => ObjectKind::View,
                Some("SEQUENCE") => ObjectKind::Sequence,
                Some("FUNCTION") => ObjectKind::Function,
                Some("PROCEDURE") => ObjectKind::Procedure,
                _ => continue,
            };
            objects.push(ObjectInfo::new(row.text(0)?, row.required_text(1)?, kind));
        }
    }
    for row in catalog_rows(connection, flavour, triggers_sql, "TRIGGERS", &binds).await? {
        objects.push(ObjectInfo::trigger(
            row.text(0)?,
            row.required_text(1)?,
            row.required_text(2)?,
        ));
    }
    Ok(objects)
}

const ROUTINE_EXISTS_SQL: &str = "\
SELECT 1 FROM information_schema.ROUTINES
WHERE ROUTINE_SCHEMA = COALESCE(?, DATABASE()) AND ROUTINE_NAME = ? AND ROUTINE_TYPE = ?";
const SEQUENCE_EXISTS_SQL: &str = "\
SELECT 1 FROM information_schema.TABLES
WHERE TABLE_SCHEMA = COALESCE(?, DATABASE()) AND TABLE_NAME = ? AND TABLE_TYPE = 'SEQUENCE'";
const TRIGGER_EXISTS_SQL: &str = "\
SELECT 1 FROM information_schema.TRIGGERS
WHERE TRIGGER_SCHEMA = COALESCE(?, DATABASE()) AND TRIGGER_NAME = ? AND EVENT_OBJECT_TABLE = ?";

/// The server's CREATE text for a function, procedure, sequence or
/// trigger. The name is looked up first as a bound parameter, so a
/// dropped object gives an empty text rather than a server error, and
/// SHOW, which cannot take a parameter, only ever sees a name the
/// catalogue returned, quoted by the dialect.
pub(crate) async fn fetch_object_definition(
    connection: &mut MySqlConnection,
    dialect: &MySqlDialect,
    object: &ObjectInfo,
) -> Result<String, DriverError> {
    let flavour = dialect.flavour();
    let schema = object.schema.as_deref();
    let name = Some(object.name.as_str());
    let (exists_sql, exists_table, extra, show, column) = match object.kind {
        ObjectKind::Function => (
            ROUTINE_EXISTS_SQL,
            "ROUTINES",
            Some("FUNCTION"),
            "FUNCTION",
            "Create Function",
        ),
        ObjectKind::Procedure => (
            ROUTINE_EXISTS_SQL,
            "ROUTINES",
            Some("PROCEDURE"),
            "PROCEDURE",
            "Create Procedure",
        ),
        ObjectKind::Sequence => (SEQUENCE_EXISTS_SQL, "TABLES", None, "SEQUENCE", "Create Table"),
        ObjectKind::Trigger => (
            TRIGGER_EXISTS_SQL,
            "TRIGGERS",
            object.table.as_deref(),
            "TRIGGER",
            "SQL Original Statement",
        ),
        _ => {
            return Err(DriverError::Unsupported {
                feature: UnsupportedFeature::ObjectDefinitions,
            });
        }
    };
    if object.kind == ObjectKind::Trigger && extra.is_none() {
        return Ok(String::new());
    }
    let mut binds = vec![schema, name];
    binds.extend(extra.map(Some));
    if catalog_rows(connection, flavour, exists_sql, exists_table, &binds)
        .await?
        .is_empty()
    {
        return Ok(String::new());
    }
    let sql = format!(
        "SHOW CREATE {show} {}",
        dialect.qualify(&TableRef::new(object.schema.clone(), object.name.clone()))
    );
    let row = connection
        .fetch_one(sqlx::raw_sql(AssertSqlSafe(sql)))
        .await
        .map_err(|error| map_error(&error, flavour))?;
    let text: Option<&[u8]> = row.try_get_unchecked(column).map_err(|error| DriverError::Decode {
        column: column.to_owned(),
        detail: error.to_string(),
    })?;
    match text {
        Some(bytes) => String::from_utf8(bytes.to_vec()).map_err(|error| DriverError::Decode {
            column: column.to_owned(),
            detail: error.to_string(),
        }),
        None => Ok(String::new()),
    }
}

async fn column_rows(
    connection: &mut MySqlConnection,
    flavour: MySqlFlavour,
    table: &TableRef,
) -> Result<Vec<MySqlColumnRow>, DriverError> {
    catalog_rows(
        connection,
        flavour,
        columns_sql(flavour),
        "COLUMNS",
        &table_binds(table),
    )
    .await?
    .iter()
    .map(MySqlColumnRow::from_cells)
    .collect()
}

pub(crate) async fn fetch_columns(
    connection: &mut MySqlConnection,
    flavour: MySqlFlavour,
    table: &TableRef,
) -> Result<Vec<ColumnInfo>, DriverError> {
    Ok(column_rows(connection, flavour, table)
        .await?
        .iter()
        .map(|row| column_info(row, flavour))
        .collect())
}

/// MySQL 8.0.13 and later name a functional key part in EXPRESSION;
/// MariaDB has no such column, and no functional key parts.
const MYSQL_INDEXES_SQL: &str = "\
SELECT INDEX_NAME, NON_UNIQUE, COLUMN_NAME, COLLATION, EXPRESSION
FROM information_schema.STATISTICS
WHERE TABLE_SCHEMA = COALESCE(?, DATABASE()) AND TABLE_NAME = ?
ORDER BY INDEX_NAME = 'PRIMARY' DESC, INDEX_NAME, SEQ_IN_INDEX";
const MARIADB_INDEXES_SQL: &str = "\
SELECT INDEX_NAME, NON_UNIQUE, COLUMN_NAME, COLLATION, NULL AS EXPRESSION
FROM information_schema.STATISTICS
WHERE TABLE_SCHEMA = COALESCE(?, DATABASE()) AND TABLE_NAME = ?
ORDER BY INDEX_NAME = 'PRIMARY' DESC, INDEX_NAME, SEQ_IN_INDEX";

pub(crate) async fn fetch_indexes(
    connection: &mut MySqlConnection,
    dialect: &MySqlDialect,
    table: &TableRef,
) -> Result<Vec<IndexInfo>, DriverError> {
    let flavour = dialect.flavour();
    let sql = match dialect.has_functional_key_parts() {
        true => MYSQL_INDEXES_SQL,
        false => MARIADB_INDEXES_SQL,
    };
    let rows = catalog_rows(connection, flavour, sql, "STATISTICS", &table_binds(table)).await?;
    let mut indexes: Vec<IndexInfo> = Vec::new();
    for row in rows {
        let name = row.required_text(0)?;
        let descending = row.text(3)?.as_deref() == Some("D");
        let key = match (row.text(2)?, row.text(4)?) {
            (Some(column), _) => IndexKey::Column {
                name: column,
                descending,
            },
            (None, Some(expression)) => IndexKey::Expression {
                sql: expression,
                descending,
            },
            (None, None) => continue,
        };
        match indexes.last_mut().filter(|index| index.name == name) {
            Some(index) => index.keys.push(key),
            None => indexes.push(IndexInfo {
                unique: row.number(1)? == Some(0),
                primary: name == "PRIMARY",
                name,
                keys: vec![key],
                predicate: None,
            }),
        }
    }
    Ok(indexes)
}

const FOREIGN_KEYS_SQL: &str = "\
SELECT k.CONSTRAINT_NAME, k.COLUMN_NAME, k.REFERENCED_TABLE_SCHEMA, k.REFERENCED_TABLE_NAME,
       k.REFERENCED_COLUMN_NAME, r.DELETE_RULE, r.UPDATE_RULE
FROM information_schema.KEY_COLUMN_USAGE k
JOIN information_schema.REFERENTIAL_CONSTRAINTS r
  ON r.CONSTRAINT_SCHEMA = k.CONSTRAINT_SCHEMA AND r.CONSTRAINT_NAME = k.CONSTRAINT_NAME
 AND r.TABLE_NAME = k.TABLE_NAME
WHERE k.TABLE_SCHEMA = COALESCE(?, DATABASE()) AND k.TABLE_NAME = ? AND k.REFERENCED_TABLE_NAME IS NOT NULL
ORDER BY k.CONSTRAINT_NAME, k.ORDINAL_POSITION";

pub(crate) async fn fetch_foreign_keys(
    connection: &mut MySqlConnection,
    flavour: MySqlFlavour,
    table: &TableRef,
) -> Result<Vec<ForeignKeyInfo>, DriverError> {
    let rows = catalog_rows(
        connection,
        flavour,
        FOREIGN_KEYS_SQL,
        "KEY_COLUMN_USAGE",
        &table_binds(table),
    )
    .await?;
    let mut keys: Vec<ForeignKeyInfo> = Vec::new();
    for row in rows {
        let name = row.required_text(0)?;
        let column = row.required_text(1)?;
        let referenced = row.required_text(4)?;
        if let Some(key) = keys.last_mut().filter(|key| key.name == name) {
            key.columns.push(column);
            key.ref_columns.push(referenced);
            continue;
        }
        keys.push(ForeignKeyInfo {
            name,
            columns: vec![column],
            ref_schema: row.text(2)?,
            ref_table: row.required_text(3)?,
            ref_columns: vec![referenced],
            on_delete: row.text(5)?.as_deref().and_then(referential_action),
            on_update: row.text(6)?.as_deref().and_then(referential_action),
        });
    }
    Ok(keys)
}

pub(crate) async fn fetch_outbound_foreign_keys(
    connection: &mut MySqlConnection,
    flavour: MySqlFlavour,
    table: &TableRef,
) -> Result<Vec<OutboundForeignKey>, DriverError> {
    let keys = fetch_foreign_keys(connection, flavour, table).await?;
    let mut tables = KeyTables::default();
    let mut outbound = Vec::with_capacity(keys.len());
    for key in keys {
        let parent = TableRef::new(key.ref_schema.clone(), key.ref_table.clone());
        let parent_compares_alike = tables
            .compare(connection, flavour, (table, &key.columns), (&parent, &key.ref_columns))
            .await?;
        outbound.push(OutboundForeignKey {
            key,
            parent_compares_alike,
        });
    }
    Ok(outbound)
}

/// The keys of every database the account can see that point at the
/// table, since a key can cross databases.
pub(crate) async fn fetch_inbound_foreign_keys(
    connection: &mut MySqlConnection,
    flavour: MySqlFlavour,
    table: &TableRef,
) -> Result<Vec<InboundForeignKey>, DriverError> {
    let rows = catalog_rows(
        connection,
        flavour,
        INBOUND_FOREIGN_KEYS_SQL,
        "KEY_COLUMN_USAGE",
        &table_binds(table),
    )
    .await?;
    let mut keys = inbound_foreign_keys(&rows)?;
    let mut tables = KeyTables::default();
    for key in &mut keys {
        key.child_compares_alike = tables
            .compare(
                connection,
                flavour,
                (table, &key.referenced_columns),
                (&key.table, &key.columns),
            )
            .await?;
    }
    Ok(keys)
}

/// The columns of the tables a read's keys join, each read once, by
/// table so information_schema opens only that table.
#[derive(Default)]
struct KeyTables(HashMap<TableRef, TableComparisons>);

impl KeyTables {
    /// Whether a value of each column of `from` finds, as text read
    /// under the paired column of `to`, the rows the key matches.
    async fn compare(
        &mut self,
        connection: &mut MySqlConnection,
        flavour: MySqlFlavour,
        from: (&TableRef, &[String]),
        to: (&TableRef, &[String]),
    ) -> Result<bool, DriverError> {
        for table in [from.0, to.0] {
            if !self.0.contains_key(table) {
                let rows = catalog_rows(
                    connection,
                    flavour,
                    COLUMN_COMPARISONS_SQL,
                    "COLUMNS",
                    &table_binds(table),
                )
                .await?;
                self.0.insert(table.clone(), column_comparisons(&rows)?);
            }
        }
        let empty = TableComparisons::new();
        let side = |table: &TableRef| self.0.get(table).unwrap_or(&empty);
        Ok(compares_alike(side(from.0), from.1, side(to.0), to.1))
    }
}

fn referential_action(rule: &str) -> Option<ReferentialAction> {
    ReferentialAction::ALL
        .into_iter()
        .find(|action| action.as_sql().eq_ignore_ascii_case(rule))
}

/// A primary key, or a unique index over NOT NULL columns, names a row.
/// Anything else leaves the grid read-only.
pub(crate) async fn row_identity(
    connection: &mut MySqlConnection,
    dialect: &MySqlDialect,
    table: &TableRef,
) -> Result<RowIdentity, DriverError> {
    let indexes = fetch_indexes(connection, dialect, table).await?;
    let columns = fetch_columns(connection, dialect.flavour(), table).await?;
    Ok(identity_of(&indexes, &columns))
}

pub(crate) fn identity_of(indexes: &[IndexInfo], columns: &[ColumnInfo]) -> RowIdentity {
    if let Some(primary) = indexes.iter().find(|index| index.primary && index.can_identify_rows()) {
        return RowIdentity::UniqueKey {
            columns: primary.key_columns(),
        };
    }
    let not_null = |name: &str| columns.iter().any(|column| column.name == name && !column.nullable);
    indexes
        .iter()
        .find(|index| index.can_identify_rows() && index.key_columns().iter().all(|name| not_null(name)))
        .map_or(RowIdentity::Unordered, |index| RowIdentity::UniqueKey {
            columns: index.key_columns(),
        })
}

const TABLE_ROWS_SQL: &str = "\
SELECT TABLE_ROWS FROM information_schema.TABLES
WHERE TABLE_SCHEMA = COALESCE(?, DATABASE()) AND TABLE_NAME = ?";

pub(crate) async fn table_estimate(
    connection: &mut MySqlConnection,
    flavour: MySqlFlavour,
    table: &TableRef,
) -> Result<TableEstimate, DriverError> {
    let rows = catalog_rows(connection, flavour, TABLE_ROWS_SQL, "TABLES", &table_binds(table)).await?;
    let estimate = match rows.first() {
        Some(row) => row.number(0)?,
        None => None,
    };
    Ok(TableEstimate {
        rows: estimate.map_or(RowCountEstimate::Unknown, RowCountEstimate::Approximate),
        heap_blocks: None,
    })
}

pub(crate) async fn fetch_table_definition(
    connection: &mut MySqlConnection,
    dialect: &MySqlDialect,
    table: &TableRef,
) -> Result<TableDefinition, DriverError> {
    let flavour = dialect.flavour();
    let mut rows = column_rows(connection, flavour, table).await?;
    let engine = table_engine::lookup(connection, flavour, table).await?;
    let mut attributes = engine_attributes(connection, dialect, table).await;
    let create_statement = show_create(connection, dialect, table).await?;
    let checks = match flavour {
        MySqlFlavour::MariaDb => {
            let binds = table_binds(table);
            let geometry = catalog_rows(
                connection,
                flavour,
                MARIADB_GEOMETRY_SRIDS_SQL,
                "GEOMETRY_COLUMNS",
                &binds,
            )
            .await?;
            for (column, srid) in geometry_srids(&geometry)? {
                match srid {
                    ListedSrid::Exact(srid) => {
                        if let Some(row) = rows.iter_mut().find(|row| row.name == column) {
                            row.srs_id = Some(srid);
                        }
                    }
                    ListedSrid::Saturated => attributes.push((column, "REF_SYSTEM_ID".to_owned())),
                }
            }
            let checks = catalog_rows(
                connection,
                flavour,
                MARIADB_COLUMN_CHECKS_SQL,
                "CHECK_CONSTRAINTS",
                &binds,
            )
            .await?;
            let names: Vec<&str> = rows.iter().map(|row| row.name.as_str()).collect();
            place_column_checks(&create_statement, &names, column_checks(&checks)?)
        }
        MySqlFlavour::MySql => Vec::new(),
    };
    let mut columns: Vec<ColumnDefinition> = rows
        .iter()
        .enumerate()
        .map(|(index, row)| {
            let mut unmodeled: Vec<UnmodeledAttribute> = attributes
                .iter()
                .filter(|(column, _)| *column == row.name)
                .map(|(_, attribute)| UnmodeledAttribute::new(attribute.clone()))
                .collect();
            if engine.is_ndb() {
                unmodeled.push(UnmodeledAttribute::new("ENGINE=ndbcluster"));
            }
            let check = checks.get(index);
            if check == Some(&ColumnCheck::Unplaced) {
                unmodeled.push(UnmodeledAttribute::new("CHECK"));
            }
            let mut definition = column_definition(row, flavour, unmodeled);
            if let Some(ColumnCheck::Clause(clause)) = check {
                definition.attributes.check = Some(SqlExpression::from_catalog_text(clause.as_str()));
            }
            definition
        })
        .collect();
    for definition in &mut columns {
        if let Some(default) = timestamp_default(connection, flavour, &create_statement, definition).await? {
            definition.info.default = default;
        }
    }
    let indexes = fetch_indexes(connection, dialect, table).await?;
    let primary_key = indexes
        .iter()
        .find(|index| index.primary)
        .map(|index| PrimaryKeyConstraint {
            name: Some(index.name.clone()),
            columns: index.key_columns(),
        });
    let foreign_keys = fetch_foreign_keys(connection, flavour, table).await?;
    let inbound_foreign_keys = fetch_inbound_foreign_keys(connection, flavour, table).await?;
    let options = definition_options(&engine, flavour, &create_statement, &columns);
    Ok(TableDefinition {
        table: table.clone(),
        columns,
        primary_key,
        indexes,
        foreign_keys,
        inbound_foreign_keys,
        source: Some(TableSource {
            create_statement,
            dependents: Vec::new(),
        }),
        options,
    })
}

/// NDB's table options were never measured, so none are offered.
fn definition_options(
    engine: &TableEngine,
    flavour: MySqlFlavour,
    create_statement: &str,
    columns: &[ColumnDefinition],
) -> Option<TableOptions> {
    if engine.is_ndb() {
        return None;
    }
    let listed = ListedOptions {
        collation: engine.collation.as_deref(),
        auto_increment: engine.auto_increment,
        create_statement,
        numbered: columns.iter().any(|column| column.info.is_auto_increment),
    };
    table_options(listed, flavour)
}

/// The character sets and collations the server offers. Collations come
/// from where the server spells the names tables carry.
pub(crate) async fn fetch_character_sets(
    connection: &mut MySqlConnection,
    flavour: MySqlFlavour,
) -> Result<Vec<CharacterSet>, DriverError> {
    let sets = catalog_rows(connection, flavour, CHARACTER_SETS_SQL, "CHARACTER_SETS", &[]).await?;
    let full_names = catalog_rows(connection, flavour, FULL_COLLATION_NAMES_SQL, "COLUMNS", &[]).await?;
    let listed_apart = full_names
        .first()
        .map(|row| row.number(0))
        .transpose()?
        .flatten()
        .is_some_and(|count| count > 0);
    let collations = match listed_apart {
        true => {
            catalog_rows(
                connection,
                flavour,
                FULL_COLLATIONS_SQL,
                "COLLATION_CHARACTER_SET_APPLICABILITY",
                &[],
            )
            .await?
        }
        false => catalog_rows(connection, flavour, COLLATIONS_SQL, "COLLATIONS", &[]).await?,
    };
    character_sets(&sets, &collations)
}

/// A TIMESTAMP's constant default as wall time in the server's zone,
/// which is where a schema change runs (`server_zone`), so restating it
/// keeps the instant. This session reads in UTC, so SHOW CREATE TABLE
/// prints it in UTC. A zero default names no instant and stays as is.
async fn timestamp_default(
    connection: &mut MySqlConnection,
    flavour: MySqlFlavour,
    create_statement: &str,
    definition: &ColumnDefinition,
) -> Result<Option<ColumnDefault>, DriverError> {
    let info = &definition.info;
    let is_instant = matches!(
        info.column_type.kind,
        ColumnKind::Timestamp {
            zone: TemporalZone::Offset,
            ..
        }
    );
    if !is_instant || info.default.is_none() {
        return Ok(None);
    }
    let Some(utc) = quoted_default(create_statement, &info.name) else {
        return Ok(None);
    };
    if utc.starts_with("0000-00-00") {
        return Ok(Some(ColumnDefault::Literal(Value::Text(utc))));
    }
    let digits = utc.split_once('.').map_or(0, |(_, fraction)| fraction.len());
    let row = sqlx::query("SELECT CAST(CONVERT_TZ(?, '+00:00', @@GLOBAL.time_zone) AS CHAR)")
        .persistent(false)
        .bind(utc)
        .fetch_one(&mut *connection)
        .await
        .map_err(|error| map_error(&error, flavour))?;
    let wall: Option<&[u8]> = row.try_get_unchecked(0).map_err(|error| DriverError::Decode {
        column: info.name.clone(),
        detail: error.to_string(),
    })?;
    Ok(wall.map(|wall| {
        let wall = String::from_utf8_lossy(wall);
        ColumnDefault::Literal(Value::Text(with_fraction_digits(&wall, digits)))
    }))
}

/// CONVERT_TZ answers with six fractional digits whatever it was given,
/// and the default reads back as the server printed it only with the
/// digits the column declares.
fn with_fraction_digits(text: &str, digits: usize) -> String {
    let (whole, fraction) = text.split_once('.').unwrap_or((text, ""));
    match fraction.get(..digits).filter(|kept| !kept.is_empty()) {
        Some(kept) => format!("{whole}.{kept}"),
        None => whole.to_owned(),
    }
}

/// Engine attributes on columns, from MySQL 8.0.21 on. An older server
/// has no such table, which is the same as having no attributes.
async fn engine_attributes(
    connection: &mut MySqlConnection,
    dialect: &MySqlDialect,
    table: &TableRef,
) -> Vec<(String, String)> {
    let flavour = dialect.flavour();
    if !dialect.mysql_at_least((8, 0, 21)) {
        return Vec::new();
    }
    let rows = match catalog_rows(
        connection,
        flavour,
        COLUMN_ENGINE_ATTRIBUTES_SQL,
        "COLUMNS_EXTENSIONS",
        &table_binds(table),
    )
    .await
    {
        Ok(rows) => rows,
        Err(error) => {
            tracing::debug!(%error, "COLUMNS_EXTENSIONS could not be read");
            return Vec::new();
        }
    };
    let mut attributes = Vec::new();
    for row in rows {
        let Ok(Some(column)) = row.text(0) else {
            continue;
        };
        for (index, name) in [(1, "ENGINE_ATTRIBUTE"), (2, "SECONDARY_ENGINE_ATTRIBUTE")] {
            if row.text(index).ok().flatten().is_some() {
                attributes.push((column.clone(), name.to_owned()));
            }
        }
    }
    attributes
}

/// The table's own DDL as the server prints it. SHOW cannot take a
/// parameter, so the name goes in quoted by the dialect.
async fn show_create(
    connection: &mut MySqlConnection,
    dialect: &MySqlDialect,
    table: &TableRef,
) -> Result<String, DriverError> {
    let sql = format!("SHOW CREATE TABLE {}", dialect.qualify(table));
    let row = connection
        .fetch_one(sqlx::raw_sql(AssertSqlSafe(sql)))
        .await
        .map_err(|error| map_error(&error, dialect.flavour()))?;
    let bytes: &[u8] = row.try_get_unchecked(1).map_err(|error| DriverError::Decode {
        column: "Create Table".to_owned(),
        detail: error.to_string(),
    })?;
    String::from_utf8(bytes.to_vec()).map_err(|error| DriverError::Decode {
        column: "Create Table".to_owned(),
        detail: error.to_string(),
    })
}

#[cfg(test)]
mod tests {
    use tablepro_core::column::{ColumnDefault, ColumnType};

    use super::*;

    #[test]
    fn a_converted_default_keeps_the_digits_the_column_declares() {
        assert_eq!(
            with_fraction_digits("2000-01-01 07:00:00.000000", 0),
            "2000-01-01 07:00:00"
        );
        assert_eq!(
            with_fraction_digits("2000-01-01 07:00:00.250000", 3),
            "2000-01-01 07:00:00.250"
        );
        assert_eq!(with_fraction_digits("2000-01-01 07:00:00", 0), "2000-01-01 07:00:00");
    }

    fn column(name: &str, nullable: bool) -> ColumnInfo {
        ColumnInfo {
            name: name.to_owned(),
            column_type: ColumnType::unknown(),
            nullable,
            primary_key: false,
            is_auto_increment: false,
            is_generated: false,
            partition_scoped: false,
            default: ColumnDefault::None,
            comment: None,
        }
    }

    fn index(name: &str, unique: bool, columns: &[&str]) -> IndexInfo {
        IndexInfo {
            name: name.to_owned(),
            keys: columns
                .iter()
                .map(|column| IndexKey::Column {
                    name: (*column).to_owned(),
                    descending: false,
                })
                .collect(),
            unique,
            primary: name == "PRIMARY",
            predicate: None,
        }
    }

    #[test]
    fn identity_prefers_the_primary_key_then_a_not_null_unique_index() {
        let columns = [column("id", false), column("email", false), column("nick", true)];

        let with_primary = [index("email_unique", true, &["email"]), index("PRIMARY", true, &["id"])];
        assert_eq!(
            identity_of(&with_primary, &columns),
            RowIdentity::UniqueKey {
                columns: vec!["id".to_owned()]
            }
        );

        let unique_only = [
            index("nick_unique", true, &["nick"]),
            index("email_unique", true, &["email"]),
        ];
        assert_eq!(
            identity_of(&unique_only, &columns),
            RowIdentity::UniqueKey {
                columns: vec!["email".to_owned()]
            }
        );

        let nullable_only = [index("nick_unique", true, &["nick"]), index("plain", false, &["id"])];
        assert_eq!(identity_of(&nullable_only, &columns), RowIdentity::Unordered);
    }

    #[test]
    fn referential_rules_map_to_actions() {
        assert_eq!(referential_action("SET NULL"), Some(ReferentialAction::SetNull));
        assert_eq!(referential_action("NO ACTION"), Some(ReferentialAction::NoAction));
        assert_eq!(referential_action("RESTRICT"), Some(ReferentialAction::Restrict));
        assert_eq!(referential_action("SOMETHING NEW"), None);
    }
}
