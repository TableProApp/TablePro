//! Reading the catalogue on a connection.
//!
//! `catalog` owns the SQL and what the rows mean. This runs it.

use std::collections::BTreeMap;
use std::collections::btree_map::Entry;

use sqlx::sqlite::{SqliteConnection as SqlxConnection, SqliteRow};
use sqlx::{AssertSqlSafe, Row};
use tablepro_core::column::ColumnInfo;
use tablepro_core::ddl::{
    ColumnDefinition, GeneratedColumn, PrimaryKeyConstraint, ReferentialAction, SchemaObjectKind, TableDefinition,
    TableSource,
};
use tablepro_core::meta::{
    EngineRowId, IndexInfo, IndexKey, ObjectInfo, ObjectKind, ObjectScope, RowCountEstimate, RowIdentity, SchemaInfo,
    TableEstimate, TableRef,
};
use tablepro_core::{DriverError, ForeignKeyInfo, ServerCode, ServerDiagnostics};

use crate::catalog::{
    self, InboundKeyRow, MAIN_SCHEMA, SchemaRow, SqliteColumnRow, TableFacts, foreign_key_names, generated_expressions,
    inbound_foreign_keys, select_dependents,
};
use crate::ddl::{declared_descending_key, declared_foreign_key_names};
use crate::errors::{SQLITE_ERROR, map_error};
use crate::index_sql::read_index_sql;

/// What `pragma_table_list` and `pragma_table_xinfo` say about one
/// table, read together.
struct TableShape {
    kind: String,
    facts: TableFacts,
    columns: Vec<SqliteColumnRow>,
}

impl TableShape {
    fn visible_columns(&self) -> impl Iterator<Item = &SqliteColumnRow> {
        self.columns.iter().filter(|column| column.is_visible())
    }

    /// The primary key's columns, in key order.
    fn primary_key(&self) -> Vec<String> {
        let mut keyed: Vec<&SqliteColumnRow> = self.columns.iter().filter(|column| column.pk > 0).collect();
        keyed.sort_by_key(|column| column.pk);
        keyed.into_iter().map(|column| column.name.clone()).collect()
    }
}

pub(crate) async fn list_schemas(connection: &mut SqlxConnection) -> Result<Vec<SchemaInfo>, DriverError> {
    Ok(schema_names(connection)
        .await?
        .into_iter()
        .map(|name| SchemaInfo {
            is_default: name == MAIN_SCHEMA,
            is_system: false,
            name,
        })
        .collect())
}

pub(crate) async fn list_objects(
    connection: &mut SqlxConnection,
    scope: &ObjectScope,
) -> Result<Vec<ObjectInfo>, DriverError> {
    let schemas = match scope {
        ObjectScope::DefaultSchema => vec![MAIN_SCHEMA.to_owned()],
        ObjectScope::Schema(schema) => vec![schema.clone()],
        ObjectScope::AllSchemas => schema_names(connection).await?,
    };
    let mut objects = Vec::new();
    for schema in schemas {
        let rows = sqlx::query(AssertSqlSafe(catalog::objects_sql(&quote(&schema))))
            .fetch_all(&mut *connection)
            .await
            .map_err(map_error)?;
        for row in rows {
            let kind = match text(&row, "type")?.as_str() {
                "view" => ObjectKind::View,
                _ => ObjectKind::Table,
            };
            objects.push(ObjectInfo {
                schema: qualifier(&schema),
                name: text(&row, "name")?,
                kind,
            });
        }
    }
    Ok(objects)
}

pub(crate) async fn fetch_columns(
    connection: &mut SqlxConnection,
    table: &TableRef,
) -> Result<Vec<ColumnInfo>, DriverError> {
    let shape = table_shape(connection, table).await?;
    Ok(shape
        .visible_columns()
        .map(|column| column.column_info(&shape.facts))
        .collect())
}

pub(crate) async fn fetch_indexes(
    connection: &mut SqlxConnection,
    table: &TableRef,
) -> Result<Vec<IndexInfo>, DriverError> {
    let shape = table_shape(connection, table).await?;
    indexes(connection, table, &shape).await
}

pub(crate) async fn fetch_foreign_keys(
    connection: &mut SqlxConnection,
    table: &TableRef,
) -> Result<Vec<ForeignKeyInfo>, DriverError> {
    let keys = foreign_key_rows(connection, table).await?;
    let create = match keys.is_empty() {
        true => None,
        false => create_statement(connection, table).await?,
    };
    resolve_foreign_keys(connection, table, keys, create.as_deref()).await
}

/// The table's foreign keys by pragma id, each with whether it points
/// at the parent's primary key without naming its columns.
async fn foreign_key_rows(
    connection: &mut SqlxConnection,
    table: &TableRef,
) -> Result<BTreeMap<i64, (ForeignKeyInfo, bool)>, DriverError> {
    let schema = schema_of(table);
    let rows = sqlx::query(catalog::FOREIGN_KEY_LIST_SQL)
        .bind(table.name.as_str())
        .bind(schema)
        .fetch_all(&mut *connection)
        .await
        .map_err(map_error)?;
    let mut keys: BTreeMap<i64, (ForeignKeyInfo, bool)> = BTreeMap::new();
    for row in rows {
        let id: i64 = row.try_get("id").map_err(map_error)?;
        let to: Option<String> = row.try_get("to").map_err(map_error)?;
        let (key, to_primary) = match keys.entry(id) {
            Entry::Occupied(entry) => entry.into_mut(),
            Entry::Vacant(entry) => entry.insert((
                ForeignKeyInfo {
                    name: String::new(),
                    columns: Vec::new(),
                    ref_schema: table.schema.clone(),
                    ref_table: text(&row, "table")?,
                    ref_columns: Vec::new(),
                    on_delete: referential_action(&text(&row, "on_delete")?),
                    on_update: referential_action(&text(&row, "on_update")?),
                },
                false,
            )),
        };
        key.columns.push(text(&row, "from")?);
        match to {
            Some(to) => key.ref_columns.push(to),
            None => *to_primary = true,
        }
    }
    Ok(keys)
}

/// Name the keys from the table's CREATE TABLE, and give a key that
/// names no parent columns the parent's primary key.
async fn resolve_foreign_keys(
    connection: &mut SqlxConnection,
    table: &TableRef,
    keys: BTreeMap<i64, (ForeignKeyInfo, bool)>,
    create_statement: Option<&str>,
) -> Result<Vec<ForeignKeyInfo>, DriverError> {
    let declared = create_statement.and_then(declared_foreign_key_names);
    let mut names = foreign_key_names(&table.name, declared, keys.len()).into_iter();
    let mut resolved = Vec::with_capacity(keys.len());
    for (mut key, to_primary) in keys.into_values() {
        key.name = names.next().unwrap_or_default();
        if to_primary {
            let parent = TableRef::new(table.schema.clone(), key.ref_table.clone());
            key.ref_columns = table_shape(connection, &parent).await?.primary_key();
        }
        resolved.push(key);
    }
    Ok(resolved)
}

/// How a row can be named again: the primary key, else a unique index
/// over NOT NULL columns covering every row, else the rowid.
pub(crate) async fn row_identity(
    connection: &mut SqlxConnection,
    table: &TableRef,
) -> Result<RowIdentity, DriverError> {
    let shape = table_shape(connection, table).await?;
    // A view has no rowid and no key, and a virtual table's rowid is
    // whatever its module makes of it.
    if shape.kind != "table" {
        return Ok(RowIdentity::Unordered);
    }
    let primary_key = shape.primary_key();
    if !primary_key.is_empty() {
        return Ok(RowIdentity::UniqueKey { columns: primary_key });
    }
    let not_null: Vec<&str> = shape
        .columns
        .iter()
        .filter(|column| column.not_null)
        .map(|column| column.name.as_str())
        .collect();
    let unique = indexes(connection, table, &shape).await?.into_iter().find(|index| {
        index.can_identify_rows()
            && index
                .key_columns()
                .iter()
                .all(|column| not_null.iter().any(|name| name.eq_ignore_ascii_case(column)))
    });
    if let Some(index) = unique {
        return Ok(RowIdentity::UniqueKey {
            columns: index.key_columns(),
        });
    }
    // A column of that name hides the rowid behind it.
    let shadowed = shape
        .columns
        .iter()
        .any(|column| column.name.eq_ignore_ascii_case("rowid"));
    if shape.facts.without_rowid || shadowed {
        return Ok(RowIdentity::Unordered);
    }
    Ok(RowIdentity::EngineRowId(EngineRowId::SqliteRowid))
}

/// The row count ANALYZE last saw, where it ran.
pub(crate) async fn table_estimate(
    connection: &mut SqlxConnection,
    table: &TableRef,
) -> Result<TableEstimate, DriverError> {
    let schema = quote(schema_of(table));
    let unknown = TableEstimate {
        rows: RowCountEstimate::Unknown,
        heap_blocks: None,
    };
    if !has_table(connection, &schema, "sqlite_stat1").await? {
        return Ok(unknown);
    }
    let stat: Option<String> = sqlx::query_scalar(AssertSqlSafe(catalog::statistics_sql(&schema)))
        .bind(table.name.as_str())
        .fetch_optional(&mut *connection)
        .await
        .map_err(map_error)?
        .flatten();
    let rows = stat
        .as_deref()
        .and_then(|stat| stat.split_whitespace().next())
        .and_then(|first| first.parse::<u64>().ok());
    Ok(match rows {
        Some(rows) => TableEstimate {
            rows: RowCountEstimate::Approximate(rows),
            heap_blocks: None,
        },
        None => unknown,
    })
}

pub(crate) async fn fetch_table_definition(
    connection: &mut SqlxConnection,
    table: &TableRef,
) -> Result<TableDefinition, DriverError> {
    let shape = table_shape(connection, table).await?;
    let schema_sql = quote(schema_of(table));
    let create_statement = create_statement(connection, table).await?;

    let expressions = match (
        &create_statement,
        shape.columns.iter().any(|c| c.generated_storage().is_some()),
    ) {
        (Some(create), true) => generated_expressions(create),
        _ => Default::default(),
    };
    let columns = shape
        .visible_columns()
        .map(|column| {
            let mut attributes = column.attributes(&shape.facts);
            attributes.generated = column
                .generated_storage()
                .zip(expressions.get(&column.name).cloned())
                .map(|(storage, expression)| GeneratedColumn { expression, storage });
            ColumnDefinition::new(column.column_info(&shape.facts), attributes)
        })
        .collect();
    let key_columns = shape.primary_key();
    let primary_key = (!key_columns.is_empty()).then(|| PrimaryKeyConstraint {
        name: None,
        columns: key_columns.clone(),
    });
    let indexes = indexes(connection, table, &shape).await?;
    let foreign_keys = foreign_key_rows(connection, table).await?;
    let foreign_keys = resolve_foreign_keys(connection, table, foreign_keys, create_statement.as_deref()).await?;

    let inbound_rows = sqlx::query(AssertSqlSafe(catalog::inbound_keys_sql(&schema_sql)))
        .bind(table.name.as_str())
        .bind(schema_of(table))
        .fetch_all(&mut *connection)
        .await
        .map_err(map_error)?
        .iter()
        .map(|row| {
            Ok(InboundKeyRow {
                child: text(row, "child")?,
                child_sql: row.try_get("child_sql").map_err(map_error)?,
                child_keys: usize::try_from(row.try_get::<i64, _>("child_keys").map_err(map_error)?).unwrap_or(0),
                id: row.try_get("id").map_err(map_error)?,
                from: text(row, "from")?,
                to: row.try_get("to").map_err(map_error)?,
            })
        })
        .collect::<Result<Vec<_>, DriverError>>()?;
    let inbound = inbound_foreign_keys(table.schema.as_deref(), inbound_rows, &key_columns);

    let source = match create_statement {
        Some(create_statement) => Some(TableSource {
            create_statement,
            dependents: dependents(connection, &schema_sql, &table.name).await?,
        }),
        None => None,
    };

    Ok(TableDefinition {
        table: table.clone(),
        columns,
        primary_key,
        indexes,
        foreign_keys,
        inbound_foreign_keys: inbound,
        source,
    })
}

/// The CREATE statement SQLite stored for the table.
async fn create_statement(connection: &mut SqlxConnection, table: &TableRef) -> Result<Option<String>, DriverError> {
    let schema_sql = quote(schema_of(table));
    Ok(sqlx::query(AssertSqlSafe(catalog::object_sql(&schema_sql)))
        .bind(table.name.as_str())
        .fetch_optional(&mut *connection)
        .await
        .map_err(map_error)?
        .map(|row| row.try_get::<Option<String>, _>("sql"))
        .transpose()
        .map_err(map_error)?
        .flatten())
}

async fn dependents(
    connection: &mut SqlxConnection,
    schema_sql: &str,
    table: &str,
) -> Result<Vec<tablepro_core::ddl::SchemaObjectSource>, DriverError> {
    let rows = sqlx::query(AssertSqlSafe(catalog::dependents_sql(schema_sql)))
        .fetch_all(&mut *connection)
        .await
        .map_err(map_error)?;
    let mut schema_rows = Vec::with_capacity(rows.len());
    for row in rows {
        let kind = match text(&row, "type")?.as_str() {
            "index" => SchemaObjectKind::Index,
            "trigger" => SchemaObjectKind::Trigger,
            _ => SchemaObjectKind::View,
        };
        schema_rows.push(SchemaRow {
            kind,
            name: text(&row, "name")?,
            table: text(&row, "tbl_name")?,
            sql: text(&row, "sql")?,
        });
    }
    Ok(select_dependents(table, schema_rows))
}

async fn indexes(
    connection: &mut SqlxConnection,
    table: &TableRef,
    shape: &TableShape,
) -> Result<Vec<IndexInfo>, DriverError> {
    let schema = schema_of(table);
    let schema_sql = quote(schema);
    let list = sqlx::query(catalog::INDEX_LIST_SQL)
        .bind(table.name.as_str())
        .bind(schema)
        .fetch_all(&mut *connection)
        .await
        .map_err(map_error)?;
    let mut indexes = Vec::with_capacity(list.len() + 1);
    for entry in list {
        let name = text(&entry, "name")?;
        let unique: i64 = entry.try_get("unique").map_err(map_error)?;
        let partial: i64 = entry.try_get("partial").map_err(map_error)?;
        let primary = text(&entry, "origin")? == "pk";
        let stored_sql: Option<String> = sqlx::query_scalar(AssertSqlSafe(catalog::index_sql(&schema_sql)))
            .bind(name.as_str())
            .fetch_optional(&mut *connection)
            .await
            .map_err(map_error)?
            .flatten();
        let parsed = stored_sql.as_deref().and_then(read_index_sql);
        let key_rows = sqlx::query(catalog::INDEX_XINFO_SQL)
            .bind(name.as_str())
            .bind(schema)
            .fetch_all(&mut *connection)
            .await
            .map_err(map_error)?;
        let mut keys = Vec::with_capacity(key_rows.len());
        for (position, key) in key_rows.iter().enumerate() {
            let cid: i64 = key.try_get("cid").map_err(map_error)?;
            let descending = key.try_get::<i64, _>("desc").map_err(map_error)? != 0;
            let column: Option<String> = key.try_get("name").map_err(map_error)?;
            keys.push(match (cid, column) {
                (-2, _) => IndexKey::Expression {
                    sql: parsed
                        .as_ref()
                        .and_then(|parsed| parsed.keys.get(position).cloned())
                        .unwrap_or_default(),
                    descending,
                },
                (-1, _) => IndexKey::Column {
                    name: "rowid".to_owned(),
                    descending,
                },
                (_, column) => IndexKey::Column {
                    name: column.unwrap_or_default(),
                    descending,
                },
            });
        }
        let predicate = match partial {
            0 => None,
            _ => parsed.and_then(|parsed| parsed.predicate),
        };
        indexes.push(IndexInfo {
            name,
            keys,
            unique: unique != 0,
            primary,
            predicate,
        });
    }
    // An INTEGER PRIMARY KEY is the rowid itself and has no index of its
    // own, but the structure tab still shows the key.
    let key_columns = shape.primary_key();
    if !indexes.iter().any(|index| index.primary) && !key_columns.is_empty() {
        indexes.push(IndexInfo {
            name: "PRIMARY".to_owned(),
            keys: key_columns
                .into_iter()
                .map(|name| IndexKey::Column {
                    name,
                    descending: false,
                })
                .collect(),
            unique: true,
            primary: true,
            predicate: None,
        });
    }
    Ok(indexes)
}

async fn table_shape(connection: &mut SqlxConnection, table: &TableRef) -> Result<TableShape, DriverError> {
    let schema = schema_of(table);
    let listed = sqlx::query(catalog::TABLE_LIST_SQL)
        .bind(table.name.as_str())
        .bind(schema)
        .fetch_optional(&mut *connection)
        .await
        .map_err(map_error)?;
    let Some(listed) = listed else {
        return Err(no_such_table(schema, &table.name));
    };
    let kind = text(&listed, "type")?;
    let without_rowid = listed.try_get::<i64, _>("wr").map_err(map_error)? != 0;
    let strict = listed.try_get::<i64, _>("strict").map_err(map_error)? != 0;

    let columns = sqlx::query(catalog::TABLE_XINFO_SQL)
        .bind(table.name.as_str())
        .bind(schema)
        .fetch_all(&mut *connection)
        .await
        .map_err(map_error)?
        .iter()
        .map(SqliteColumnRow::from_row)
        .collect::<Result<Vec<_>, _>>()?;
    let single_column_key = columns.iter().filter(|column| column.pk > 0).count() == 1;
    let mut facts = TableFacts {
        strict,
        without_rowid,
        autoincrement: false,
        single_column_key,
        descending_key: false,
    };
    if let Some(candidate) = columns.iter().find(|column| column.is_rowid_candidate(&facts)) {
        facts.descending_key = create_statement(connection, table)
            .await?
            .is_some_and(|sql| declared_descending_key(&sql, &candidate.name));
        if !facts.descending_key {
            facts.autoincrement = autoincrement(connection, schema, &table.name).await?;
        }
    }
    Ok(TableShape { kind, facts, columns })
}

async fn autoincrement(connection: &mut SqlxConnection, schema: &str, table: &str) -> Result<bool, DriverError> {
    let schema_sql = quote(schema);
    if !has_table(connection, &schema_sql, "sqlite_sequence").await? {
        return Ok(false);
    }
    let rows: i64 = sqlx::query_scalar(AssertSqlSafe(catalog::sequence_sql(&schema_sql)))
        .bind(table)
        .fetch_one(&mut *connection)
        .await
        .map_err(map_error)?;
    Ok(rows > 0)
}

async fn has_table(connection: &mut SqlxConnection, schema_sql: &str, name: &str) -> Result<bool, DriverError> {
    let found: i64 = sqlx::query_scalar(AssertSqlSafe(catalog::has_table_sql(schema_sql)))
        .bind(name)
        .fetch_one(&mut *connection)
        .await
        .map_err(map_error)?;
    Ok(found > 0)
}

async fn schema_names(connection: &mut SqlxConnection) -> Result<Vec<String>, DriverError> {
    sqlx::query_scalar(catalog::DATABASE_LIST_SQL)
        .fetch_all(&mut *connection)
        .await
        .map_err(map_error)
}

fn schema_of(table: &TableRef) -> &str {
    table
        .schema
        .as_deref()
        .filter(|schema| !schema.is_empty())
        .unwrap_or(MAIN_SCHEMA)
}

/// `main` is where an unqualified name already resolves, so its objects
/// carry no schema.
fn qualifier(schema: &str) -> Option<String> {
    (schema != MAIN_SCHEMA).then(|| schema.to_owned())
}

fn quote(name: &str) -> String {
    format!("\"{}\"", name.replace('"', "\"\""))
}

fn text(row: &SqliteRow, column: &str) -> Result<String, DriverError> {
    row.try_get(column).map_err(map_error)
}

fn referential_action(keyword: &str) -> Option<ReferentialAction> {
    ReferentialAction::ALL
        .into_iter()
        .find(|action| action.as_sql().eq_ignore_ascii_case(keyword.trim()))
}

fn no_such_table(schema: &str, name: &str) -> DriverError {
    DriverError::reported(ServerDiagnostics::new(
        Some(ServerCode::Sqlite {
            primary: SQLITE_ERROR,
            extended: SQLITE_ERROR,
        }),
        format!("no such table: {schema}.{name}"),
    ))
}
