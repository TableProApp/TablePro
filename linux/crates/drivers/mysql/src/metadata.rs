//! The catalogue reads behind the sidebar, the grid and the structure
//! tab. Every one is a bound query over information_schema, so a table
//! name never becomes SQL.

use futures_util::TryStreamExt;
use sqlx::mysql::MySqlConnection;
use sqlx::{AssertSqlSafe, Executor as _, Row as _};
use tablepro_core::column::ColumnInfo;
use tablepro_core::ddl::{
    InboundForeignKey, PrimaryKeyConstraint, ReferentialAction, TableDefinition, TableSource, UnmodeledAttribute,
};
use tablepro_core::dialect::SqlDialect;
use tablepro_core::meta::{
    IndexInfo, IndexKey, ObjectInfo, ObjectKind, ObjectScope, RowCountEstimate, RowIdentity, SchemaInfo, TableEstimate,
    TableRef,
};
use tablepro_core::{DriverError, ForeignKeyInfo};

use crate::catalog::{
    COLUMN_ENGINE_ATTRIBUTES_SQL, CatalogCells, INBOUND_FOREIGN_KEYS_SQL, MySqlColumnRow, column_definition,
    column_info, columns_sql, inbound_foreign_keys,
};
use crate::decode::decode_row;
use crate::dialect::MySqlDialect;
use crate::errors::map_error;
use crate::flavour::MySqlFlavour;
use crate::mysql_timestamp_mode::MySqlTimestampMode;
use crate::mysql_wire_format::MySqlWireFormat;
use crate::table_engine;

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

/// Tables, views and sequences, then routines. Two reads rather than a
/// UNION, because the two catalogue tables collate their names
/// differently and a UNION of them can refuse to sort.
pub(crate) async fn list_objects(
    connection: &mut MySqlConnection,
    flavour: MySqlFlavour,
    scope: &ObjectScope,
) -> Result<Vec<ObjectInfo>, DriverError> {
    let (tables_sql, routines_sql, binds): (_, _, Vec<Option<&str>>) = match scope {
        ObjectScope::DefaultSchema => (TABLES_IN_SCHEMA_SQL, ROUTINES_IN_SCHEMA_SQL, vec![None]),
        ObjectScope::Schema(name) => (TABLES_IN_SCHEMA_SQL, ROUTINES_IN_SCHEMA_SQL, vec![Some(name.as_str())]),
        ObjectScope::AllSchemas => (ALL_TABLES_SQL, ALL_ROUTINES_SQL, Vec::new()),
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
            objects.push(ObjectInfo {
                schema: row.text(0)?,
                name: row.required_text(1)?,
                kind,
            });
        }
    }
    Ok(objects)
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

/// MySQL 8 names a functional key part in EXPRESSION; MariaDB has no
/// such column, and no functional key parts.
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
    let sql = match (flavour, dialect.version()) {
        (MySqlFlavour::MySql, (major, _)) if major >= 8 => MYSQL_INDEXES_SQL,
        _ => MARIADB_INDEXES_SQL,
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
    let rows = column_rows(connection, flavour, table).await?;
    let engine = table_engine::lookup(connection, flavour, table).await?;
    let attributes = engine_attributes(connection, dialect, table).await;
    let columns = rows
        .iter()
        .map(|row| {
            let mut unmodeled: Vec<UnmodeledAttribute> = attributes
                .iter()
                .filter(|(column, _)| *column == row.name)
                .map(|(_, attribute)| UnmodeledAttribute::new(attribute.clone()))
                .collect();
            if engine.is_ndb() {
                unmodeled.push(UnmodeledAttribute::new("ENGINE=ndbcluster"));
            }
            column_definition(row, flavour, unmodeled)
        })
        .collect();
    let indexes = fetch_indexes(connection, dialect, table).await?;
    let primary_key = indexes
        .iter()
        .find(|index| index.primary)
        .map(|index| PrimaryKeyConstraint {
            name: Some(index.name.clone()),
            columns: index.key_columns(),
        });
    let foreign_keys = fetch_foreign_keys(connection, flavour, table).await?;
    let inbound = catalog_rows(
        connection,
        flavour,
        INBOUND_FOREIGN_KEYS_SQL,
        "KEY_COLUMN_USAGE",
        &table_binds(table),
    )
    .await?;
    let inbound_foreign_keys: Vec<InboundForeignKey> = inbound_foreign_keys(&inbound)?;
    let create_statement = show_create(connection, dialect, table).await?;
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
    })
}

/// Engine attributes on columns, from MySQL 8.0.21 on. An older server
/// has no such table, which is the same as having no attributes.
async fn engine_attributes(
    connection: &mut MySqlConnection,
    dialect: &MySqlDialect,
    table: &TableRef,
) -> Vec<(String, String)> {
    let flavour = dialect.flavour();
    if flavour != MySqlFlavour::MySql || dialect.version().0 < 8 {
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

    fn column(name: &str, nullable: bool) -> ColumnInfo {
        ColumnInfo {
            name: name.to_owned(),
            column_type: ColumnType::unknown(),
            nullable,
            primary_key: false,
            is_auto_increment: false,
            is_generated: false,
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
