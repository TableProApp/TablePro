//! Reading the catalogue on a connection.
//!
//! `catalog` owns the SQL and what the rows mean. This runs it.

use std::collections::btree_map::Entry;
use std::collections::{BTreeMap, HashMap, HashSet, hash_map};

use futures::TryStreamExt;
use sqlx::sqlite::{SqliteConnection as SqlxConnection, SqliteRow};
use sqlx::{AssertSqlSafe, Row};
use tablepro_core::column::ColumnInfo;
use tablepro_core::ddl::{
    ColumnDefinition, GeneratedColumn, InboundForeignKey, OutboundForeignKey, PrimaryKeyConstraint, ReferentialAction,
    SchemaObjectKind, TableDefinition, TableSource,
};
use tablepro_core::meta::{
    EngineRowId, IndexInfo, IndexKey, ObjectDefinition, ObjectInfo, ObjectKind, ObjectScope, RowCountEstimate,
    RowIdentity, SchemaInfo, TableEstimate, TableRef,
};
use tablepro_core::sql_syntax::{SqlGrammar, qualify_created_name, terminated};
use tablepro_core::{
    ByteLimit, CatalogBudget, DriverError, ForeignKeyInfo, ServerCode, ServerDiagnostics, UnsupportedFeature,
};

use crate::catalog::{
    self, InboundKeyColumn, ListedKeyColumn, MAIN_SCHEMA, SchemaRow, SqliteColumnRow, TableFacts, foreign_key_names,
    generated_expressions, inbound_foreign_keys, select_dependents,
};
use crate::ddl::{DeclaredComparisons, declared_descending_key, declared_foreign_key_names, foreign_key_list_bytes};
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
    let mut budget = CatalogBudget::default();
    let mut objects = Vec::new();
    for schema in schemas {
        let mut rows = sqlx::query(AssertSqlSafe(catalog::objects_sql(&quote(&schema)))).fetch(&mut *connection);
        while let Some(row) = rows.try_next().await.map_err(map_error)? {
            let name = budget.keep(text(&row, "name")?)?;
            let schema = budget.keep_optional(qualifier(&schema))?;
            objects.push(match text(&row, "type")?.as_str() {
                "trigger" => ObjectInfo::trigger(schema, name, budget.keep(text(&row, "tbl_name")?)?),
                "view" => ObjectInfo::new(schema, name, ObjectKind::View),
                _ => ObjectInfo::new(schema, name, ObjectKind::Table),
            });
        }
    }
    Ok(objects)
}

/// SQLite keeps a trigger's text as it was written, less the schema
/// before its name. The text gets it back: an attached or temporary
/// trigger needs it to be made where it is, and a main one so a session's
/// temporary table of its table's name cannot take it.
pub(crate) async fn fetch_object_definition(
    connection: &mut SqlxConnection,
    object: &ObjectInfo,
) -> Result<Option<ObjectDefinition>, DriverError> {
    let (ObjectKind::Trigger, Some(table)) = (object.kind, object.parent_table.as_deref()) else {
        return Err(DriverError::Unsupported {
            feature: UnsupportedFeature::ObjectDefinitions,
        });
    };
    let schema = object.schema.as_deref().filter(|schema| !schema.is_empty());
    let sql: Option<Option<String>> = sqlx::query_scalar(AssertSqlSafe(catalog::trigger_sql(&quote(
        schema.unwrap_or(MAIN_SCHEMA),
    ))))
    .bind(object.name.as_str())
    .bind(table)
    .fetch_optional(&mut *connection)
    .await
    .map_err(map_error)?;
    let schema = quote(schema.unwrap_or(MAIN_SCHEMA));
    Ok(sql.flatten().map(|sql| ObjectDefinition {
        sql: terminated(&qualify_created_name(&sql, SqlGrammar::Sqlite, &schema)),
        database: None,
        refusal: None,
    }))
}

pub(crate) async fn fetch_columns(
    connection: &mut SqlxConnection,
    table: &TableRef,
) -> Result<Vec<ColumnInfo>, DriverError> {
    let shape = table_shape(connection, table, &mut CatalogBudget::default()).await?;
    Ok(shape
        .visible_columns()
        .map(|column| column.column_info(&shape.facts))
        .collect())
}

pub(crate) async fn fetch_indexes(
    connection: &mut SqlxConnection,
    table: &TableRef,
) -> Result<Vec<IndexInfo>, DriverError> {
    let mut budget = CatalogBudget::default();
    let shape = table_shape(connection, table, &mut budget).await?;
    indexes(connection, table, &shape, &mut budget).await
}

pub(crate) async fn fetch_foreign_keys(
    connection: &mut SqlxConnection,
    table: &TableRef,
) -> Result<Vec<ForeignKeyInfo>, DriverError> {
    let mut budget = CatalogBudget::default();
    let create = create_statement(connection, table, &mut budget).await?;
    let keys = foreign_key_rows(connection, table, create.as_deref(), &mut budget).await?;
    resolve_foreign_keys(connection, table, keys, create.as_deref(), &mut budget).await
}

pub(crate) async fn fetch_outbound_foreign_keys(
    connection: &mut SqlxConnection,
    table: &TableRef,
) -> Result<Vec<OutboundForeignKey>, DriverError> {
    let mut budget = CatalogBudget::default();
    let create = create_statement(connection, table, &mut budget).await?;
    let keys = foreign_key_rows(connection, table, create.as_deref(), &mut budget).await?;
    if keys.is_empty() {
        return Ok(Vec::new());
    }
    let keys = resolve_foreign_keys(connection, table, keys, create.as_deref(), &mut budget).await?;
    let child = create.as_deref().map(DeclaredComparisons::read);
    release(&mut budget, create);
    let mut parents: HashMap<String, Vec<usize>> = HashMap::new();
    for (index, key) in keys.iter().enumerate() {
        match parents.entry(key.ref_table.to_ascii_lowercase()) {
            hash_map::Entry::Occupied(entry) => entry.into_mut().push(index),
            hash_map::Entry::Vacant(entry) => {
                budget.charge_text(entry.key())?;
                entry.insert(vec![index]);
            }
        }
    }
    let mut alike = vec![true; keys.len()];
    // Each parent's CREATE TABLE is read and parsed once, however many keys point at it.
    for indices in parents.values() {
        let Some(first) = indices.first().and_then(|index| keys.get(*index)) else {
            continue;
        };
        let parent_sql = create_statement(
            connection,
            &TableRef::new(table.schema.clone(), first.ref_table.clone()),
            &mut budget,
        )
        .await?;
        let parent = parent_sql.as_deref().map(DeclaredComparisons::read);
        release(&mut budget, parent_sql);
        for index in indices {
            if let (Some(key), Some(alike)) = (keys.get(*index), alike.get_mut(*index)) {
                *alike = compares_alike(
                    child.as_ref(),
                    parent.as_ref(),
                    key.columns.iter().zip(&key.ref_columns),
                );
            }
        }
    }
    Ok(keys
        .into_iter()
        .zip(alike)
        .map(|(key, parent_compares_alike)| OutboundForeignKey {
            key,
            parent_compares_alike,
        })
        .collect())
}

/// The table's foreign keys by pragma id, each with whether it points
/// at the parent's primary key without naming its columns.
async fn foreign_key_rows(
    connection: &mut SqlxConnection,
    table: &TableRef,
    create_statement: Option<&str>,
    budget: &mut CatalogBudget,
) -> Result<BTreeMap<i64, (ForeignKeyInfo, bool)>, DriverError> {
    budget.fits(create_statement.map_or(0, foreign_key_list_bytes))?;
    let schema = schema_of(table);
    let mut rows = sqlx::query(catalog::FOREIGN_KEY_LIST_SQL)
        .bind(table.name.as_str())
        .bind(schema)
        .fetch(&mut *connection);
    let mut keys: BTreeMap<i64, (ForeignKeyInfo, Vec<ListedKeyColumn>)> = BTreeMap::new();
    while let Some(row) = rows.try_next().await.map_err(map_error)? {
        let id: i64 = row.try_get("id").map_err(map_error)?;
        let (_, columns) = match keys.entry(id) {
            Entry::Occupied(entry) => entry.into_mut(),
            Entry::Vacant(entry) => entry.insert((
                ForeignKeyInfo {
                    name: String::new(),
                    columns: Vec::new(),
                    ref_schema: budget.keep_optional(table.schema.clone())?,
                    ref_table: budget.keep(text(&row, "table")?)?,
                    ref_columns: Vec::new(),
                    on_delete: referential_action(&text(&row, "on_delete")?),
                    on_update: referential_action(&text(&row, "on_update")?),
                },
                Vec::new(),
            )),
        };
        // A column can carry REFERENCES many times over, so its declared name comes back once per key.
        columns.push((
            row.try_get("seq").map_err(map_error)?,
            budget.keep(text(&row, "from")?)?,
            budget.keep_optional(row.try_get("to").map_err(map_error)?)?,
        ));
    }
    Ok(keys
        .into_iter()
        .map(|(id, (mut key, mut columns))| {
            columns.sort_by_key(|(seq, _, _)| *seq);
            let mut to_primary = false;
            for (_, from, to) in columns {
                key.columns.push(from);
                match to {
                    Some(to) => key.ref_columns.push(to),
                    None => to_primary = true,
                }
            }
            (id, (key, to_primary))
        })
        .collect())
}

/// Name the keys from the table's CREATE TABLE, and spell each parent
/// and its columns as the parent declares them: the pragma repeats the
/// REFERENCES clause as written, and every other read here, the grid's
/// filter among them, names them as declared. A key that names no
/// parent columns takes the parent's primary key. A parent that is gone,
/// as one dropped while foreign keys were off, keeps the clause's
/// spelling, and a key of it naming no columns is left with none rather
/// than failing the read of every key of the table.
async fn resolve_foreign_keys(
    connection: &mut SqlxConnection,
    table: &TableRef,
    keys: BTreeMap<i64, (ForeignKeyInfo, bool)>,
    create_statement: Option<&str>,
    budget: &mut CatalogBudget,
) -> Result<Vec<ForeignKeyInfo>, DriverError> {
    let declared = create_statement.and_then(declared_foreign_key_names);
    let names = foreign_key_names(&table.name, declared, keys.len(), budget)?;
    let mut resolved: Vec<(ForeignKeyInfo, bool)> = keys
        .into_values()
        .zip(names)
        .map(|((mut key, to_primary), name)| {
            key.name = name;
            (key, to_primary)
        })
        .collect();
    // SQLite folds ASCII letters alone when it compares names.
    let mut parents: Vec<(String, Vec<usize>)> = Vec::new();
    let mut by_name: HashMap<String, usize> = HashMap::new();
    for (index, (key, _)) in resolved.iter().enumerate() {
        match by_name.entry(key.ref_table.to_ascii_lowercase()) {
            hash_map::Entry::Occupied(entry) => {
                if let Some((_, indices)) = parents.get_mut(*entry.get()) {
                    indices.push(index);
                }
            }
            hash_map::Entry::Vacant(entry) => {
                budget.charge_text(entry.key())?;
                entry.insert(parents.len());
                parents.push((key.ref_table.clone(), vec![index]));
            }
        }
    }
    for (written, indices) in parents {
        let parent = TableRef::new(table.schema.clone(), written);
        let Some(found) = declared_table(connection, &parent, budget).await? else {
            continue;
        };
        let primary_key = found.primary_key();
        for index in indices {
            let Some((key, to_primary)) = resolved.get_mut(index) else {
                continue;
            };
            key.ref_table = budget.keep(found.name.clone())?;
            key.ref_columns = match to_primary {
                // Each key naming no columns holds its own copy of the parent's whole primary key.
                true => {
                    budget.charge_texts(&primary_key)?;
                    primary_key.clone()
                }
                false => key.ref_columns.iter().map(|column| found.spelling(column)).collect(),
            };
        }
        release_columns(budget, &found.columns);
    }
    Ok(resolved.into_iter().map(|(key, _)| key).collect())
}

/// A table's declared name and columns.
struct DeclaredTable {
    name: String,
    columns: Vec<SqliteColumnRow>,
}

impl DeclaredTable {
    fn primary_key(&self) -> Vec<String> {
        let mut keyed: Vec<&SqliteColumnRow> = self.columns.iter().filter(|column| column.pk > 0).collect();
        keyed.sort_by_key(|column| column.pk);
        keyed.into_iter().map(|column| column.name.clone()).collect()
    }

    /// `written` as the table declares it. SQLite folds ASCII letters
    /// alone when it compares names, so this does too.
    fn spelling(&self, written: &str) -> String {
        declared_spelling(written, self.columns.iter().map(|column| column.name.as_str()))
    }
}

fn declared_spelling<'a>(written: &str, mut declared: impl Iterator<Item = &'a str>) -> String {
    declared
        .find(|name| name.eq_ignore_ascii_case(written))
        .unwrap_or(written)
        .to_owned()
}

/// `None` when no table of that name is in the schema.
async fn declared_table(
    connection: &mut SqlxConnection,
    table: &TableRef,
    budget: &mut CatalogBudget,
) -> Result<Option<DeclaredTable>, DriverError> {
    let schema = schema_of(table);
    let name: Option<String> = sqlx::query_scalar(catalog::DECLARED_TABLE_NAME_SQL)
        .bind(table.name.as_str())
        .bind(schema)
        .fetch_optional(&mut *connection)
        .await
        .map_err(map_error)?;
    let Some(name) = name else {
        return Ok(None);
    };
    let columns = column_rows(connection, &name, schema, budget).await?;
    Ok(Some(DeclaredTable { name, columns }))
}

async fn column_rows(
    connection: &mut SqlxConnection,
    table: &str,
    schema: &str,
    budget: &mut CatalogBudget,
) -> Result<Vec<SqliteColumnRow>, DriverError> {
    let mut rows = sqlx::query(catalog::TABLE_XINFO_SQL)
        .bind(table)
        .bind(schema)
        .fetch(&mut *connection);
    let mut columns = Vec::new();
    while let Some(row) = rows.try_next().await.map_err(map_error)? {
        let column = SqliteColumnRow::from_row(&row)?;
        budget.charge_text(&column.name)?;
        budget.charge_text(&column.declared_type)?;
        budget.charge_texts(&column.default)?;
        columns.push(column);
    }
    Ok(columns)
}

fn release_columns(budget: &mut CatalogBudget, columns: &[SqliteColumnRow]) {
    for column in columns {
        budget.release_text(&column.name);
        budget.release_text(&column.declared_type);
        if let Some(default) = &column.default {
            budget.release_text(default);
        }
    }
}

pub(crate) async fn fetch_inbound_foreign_keys(
    connection: &mut SqlxConnection,
    table: &TableRef,
) -> Result<Vec<InboundForeignKey>, DriverError> {
    let mut budget = CatalogBudget::default();
    let shape = table_shape(connection, table, &mut budget).await?;
    inbound_keys(connection, table, &shape, &mut budget).await
}

/// The keys of the schema's other tables that point at `table`, its
/// columns spelled as `shape` declares them, since a child's REFERENCES
/// clause can spell them otherwise. Ordered by child, then key.
async fn inbound_keys(
    connection: &mut SqlxConnection,
    table: &TableRef,
    shape: &TableShape,
    budget: &mut CatalogBudget,
) -> Result<Vec<InboundForeignKey>, DriverError> {
    let parent_sql = create_statement(connection, table, budget).await?;
    let parent = Parent {
        table,
        shape,
        declared: parent_sql.as_deref().map(DeclaredComparisons::read),
        primary_key: shape.primary_key(),
    };
    release(budget, parent_sql);
    let mut keys = small_children_keys(connection, &parent, budget).await?;
    let schema_sql = quote(schema_of(table));
    let mut large = Vec::new();
    {
        let mut rows = sqlx::query_as::<_, (i64, String)>(AssertSqlSafe(catalog::large_children_sql(&schema_sql)))
            .bind(table.name.as_str())
            .bind(schema_of(table))
            .bind(i64::try_from(ByteLimit::CATALOG_DEFAULT.get()).unwrap_or(i64::MAX))
            .fetch(&mut *connection);
        while let Some((rowid, child)) = rows.try_next().await.map_err(map_error)? {
            large.push((rowid, budget.keep(child)?));
        }
    }
    // One child at a time: its CREATE TABLE is let go before the next is read.
    for (rowid, child) in large {
        let row: Option<(String, Option<String>)> = sqlx::query_as(AssertSqlSafe(catalog::schema_row_sql(&schema_sql)))
            .bind(rowid)
            .fetch_optional(&mut *connection)
            .await
            .map_err(map_error)?;
        // A row another connection gave to another table since is not this child's.
        let sql = budget.keep_optional(row.filter(|(name, _)| *name == child).and_then(|(_, sql)| sql))?;
        budget.fits(sql.as_deref().map_or(0, foreign_key_list_bytes))?;
        let (columns, count) = key_columns_into(connection, &child, table, budget).await?;
        match columns.is_empty() {
            true => {
                release(budget, sql);
                budget.release_text(&child);
            }
            false => keys.extend(parent.keys_of(child, columns, sql, count, budget)?),
        }
    }
    keys.sort_by(|left, right| left.table.name.cmp(&right.table.name));
    Ok(keys)
}

/// The keys of the small referring tables, in one read: a child's rows
/// come together, each with its CREATE TABLE, kept from its first row.
async fn small_children_keys(
    connection: &mut SqlxConnection,
    parent: &Parent<'_>,
    budget: &mut CatalogBudget,
) -> Result<Vec<InboundForeignKey>, DriverError> {
    let schema_sql = quote(schema_of(parent.table));
    let mut rows = sqlx::query(AssertSqlSafe(catalog::small_children_keys_sql(&schema_sql)))
        .bind(parent.table.name.as_str())
        .bind(schema_of(parent.table))
        .bind(i64::try_from(ByteLimit::CATALOG_DEFAULT.get()).unwrap_or(i64::MAX))
        .fetch(&mut *connection);
    let mut keys = Vec::new();
    let mut child: Option<(String, Option<String>, usize, Vec<InboundKeyColumn>)> = None;
    while let Some(row) = rows.try_next().await.map_err(map_error)? {
        let name: &str = row.try_get("child").map_err(map_error)?;
        if child.as_ref().is_none_or(|(read, ..)| read != name) {
            if let Some((read, sql, count, columns)) = child.take() {
                keys.extend(parent.keys_of(read, columns, sql, count, budget)?);
            }
            child = Some((
                budget.keep(name.to_owned())?,
                budget.keep_optional(row.try_get("sql").map_err(map_error)?)?,
                usize::try_from(row.try_get::<i64, _>("child_keys").map_err(map_error)?).unwrap_or(0),
                Vec::new(),
            ));
        }
        if let Some((_, _, _, columns)) = &mut child {
            columns.push(InboundKeyColumn {
                id: row.try_get("id").map_err(map_error)?,
                seq: row.try_get("seq").map_err(map_error)?,
                from: budget.keep(text(&row, "from")?)?,
                to: budget.keep_optional(row.try_get("to").map_err(map_error)?)?,
            });
        }
    }
    if let Some((read, sql, count, columns)) = child {
        keys.extend(parent.keys_of(read, columns, sql, count, budget)?);
    }
    Ok(keys)
}

/// The columns of the child's keys that point at `parent`, and how many
/// keys the child has wherever they point, since the ids number them
/// all. SQLite compares a key's parent folding ASCII letters alone.
async fn key_columns_into(
    connection: &mut SqlxConnection,
    child: &str,
    parent: &TableRef,
    budget: &mut CatalogBudget,
) -> Result<(Vec<InboundKeyColumn>, usize), DriverError> {
    let mut rows = sqlx::query(catalog::FOREIGN_KEY_LIST_SQL)
        .bind(child)
        .bind(schema_of(parent))
        .fetch(&mut *connection);
    let mut ids = HashSet::new();
    let mut columns = Vec::new();
    while let Some(row) = rows.try_next().await.map_err(map_error)? {
        let id: i64 = row.try_get("id").map_err(map_error)?;
        ids.insert(id);
        let target: &str = row.try_get("table").map_err(map_error)?;
        if !target.eq_ignore_ascii_case(&parent.name) {
            continue;
        }
        columns.push(InboundKeyColumn {
            id,
            seq: row.try_get("seq").map_err(map_error)?,
            from: budget.keep(text(&row, "from")?)?,
            to: budget.keep_optional(row.try_get("to").map_err(map_error)?)?,
        });
    }
    Ok((columns, ids.len()))
}

/// The table the inbound keys point at, read once for all its children.
struct Parent<'a> {
    table: &'a TableRef,
    shape: &'a TableShape,
    declared: Option<Option<DeclaredComparisons>>,
    primary_key: Vec<String>,
}

impl Parent<'_> {
    /// One child's keys, from its CREATE TABLE, which is let go before
    /// the next child's is read.
    fn keys_of(
        &self,
        child: String,
        columns: Vec<InboundKeyColumn>,
        sql: Option<String>,
        count: usize,
        budget: &mut CatalogBudget,
    ) -> Result<Vec<InboundForeignKey>, DriverError> {
        let names = foreign_key_names(
            &child,
            sql.as_deref().and_then(declared_foreign_key_names),
            count,
            budget,
        )?;
        let declared = sql.as_deref().map(DeclaredComparisons::read);
        release(budget, sql);
        let mut keys = inbound_foreign_keys(
            self.table.schema.as_deref(),
            &child,
            columns,
            &names,
            &self.primary_key,
            budget,
        )?;
        for name in &names {
            budget.release_text(name);
        }
        budget.release_text(&child);
        for key in &mut keys {
            for column in &mut key.referenced_columns {
                *column = declared_spelling(column, self.shape.columns.iter().map(|declared| declared.name.as_str()));
            }
            key.child_compares_alike = compares_alike(
                declared.as_ref(),
                self.declared.as_ref(),
                key.columns.iter().zip(&key.referenced_columns),
            );
        }
        Ok(keys)
    }
}

/// SQLite compares a key under the parent columns' affinity and
/// collation, so `=` on a column declared otherwise finds other rows
/// than the key matches. A definition that does not read says nothing
/// either way, so the key is not followed. A missing table is followed,
/// to say that it is missing.
fn compares_alike<'a>(
    child: Option<&Option<DeclaredComparisons>>,
    parent: Option<&Option<DeclaredComparisons>>,
    pairs: impl IntoIterator<Item = (&'a String, &'a String)>,
) -> bool {
    let (Some(child), Some(parent)) = (child, parent) else {
        return true;
    };
    pairs.into_iter().all(|(child_column, parent_column)| {
        match (
            child.as_ref().and_then(|declared| declared.of(child_column)),
            parent.as_ref().and_then(|declared| declared.of(parent_column)),
        ) {
            (Some(child), Some(parent)) => child.alike(parent),
            _ => false,
        }
    })
}

/// How a row can be named again: the primary key, else a unique index
/// over NOT NULL columns covering every row, else the rowid.
pub(crate) async fn row_identity(
    connection: &mut SqlxConnection,
    table: &TableRef,
) -> Result<RowIdentity, DriverError> {
    let mut budget = CatalogBudget::default();
    let shape = table_shape(connection, table, &mut budget).await?;
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
    let unique = indexes(connection, table, &shape, &mut budget)
        .await?
        .into_iter()
        .find(|index| {
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
    let mut budget = CatalogBudget::default();
    let shape = table_shape(connection, table, &mut budget).await?;
    let schema_sql = quote(schema_of(table));
    let create_statement = create_statement(connection, table, &mut budget).await?;

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
    let primary_key = (!key_columns.is_empty()).then_some(PrimaryKeyConstraint {
        name: None,
        columns: key_columns,
    });
    let indexes = indexes(connection, table, &shape, &mut budget).await?;
    let foreign_keys = foreign_key_rows(connection, table, create_statement.as_deref(), &mut budget).await?;
    let foreign_keys = resolve_foreign_keys(
        connection,
        table,
        foreign_keys,
        create_statement.as_deref(),
        &mut budget,
    )
    .await?;

    let inbound = inbound_keys(connection, table, &shape, &mut budget).await?;

    let source = match create_statement {
        Some(create_statement) => Some(TableSource {
            create_statement,
            dependents: dependents(connection, &schema_sql, &table.name, &mut budget).await?,
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
        options: None,
    })
}

/// The CREATE statement SQLite stored for the table.
async fn create_statement(
    connection: &mut SqlxConnection,
    table: &TableRef,
    budget: &mut CatalogBudget,
) -> Result<Option<String>, DriverError> {
    let schema_sql = quote(schema_of(table));
    let sql = sqlx::query(AssertSqlSafe(catalog::object_sql(&schema_sql)))
        .bind(table.name.as_str())
        .fetch_optional(&mut *connection)
        .await
        .map_err(map_error)?
        .map(|row| row.try_get::<Option<String>, _>("sql"))
        .transpose()
        .map_err(map_error)?
        .flatten();
    budget.keep_optional(sql)
}

fn release(budget: &mut CatalogBudget, text: Option<String>) {
    if let Some(text) = text {
        budget.release_text(&text);
    }
}

async fn dependents(
    connection: &mut SqlxConnection,
    schema_sql: &str,
    table: &str,
    budget: &mut CatalogBudget,
) -> Result<Vec<tablepro_core::ddl::SchemaObjectSource>, DriverError> {
    let mut rows = sqlx::query(AssertSqlSafe(catalog::dependents_sql(schema_sql))).fetch(&mut *connection);
    let mut schema_rows = Vec::new();
    while let Some(row) = rows.try_next().await.map_err(map_error)? {
        let kind = match text(&row, "type")?.as_str() {
            "index" => SchemaObjectKind::Index,
            "trigger" => SchemaObjectKind::Trigger,
            _ => SchemaObjectKind::View,
        };
        schema_rows.push(SchemaRow {
            kind,
            name: budget.keep(text(&row, "name")?)?,
            table: budget.keep(text(&row, "tbl_name")?)?,
            sql: budget.keep(text(&row, "sql")?)?,
        });
    }
    Ok(select_dependents(table, schema_rows))
}

async fn indexes(
    connection: &mut SqlxConnection,
    table: &TableRef,
    shape: &TableShape,
    budget: &mut CatalogBudget,
) -> Result<Vec<IndexInfo>, DriverError> {
    let schema = schema_of(table);
    let mut listed = Vec::new();
    {
        let mut rows = sqlx::query(catalog::INDEX_LIST_SQL)
            .bind(table.name.as_str())
            .bind(schema)
            .fetch(&mut *connection);
        while let Some(entry) = rows.try_next().await.map_err(map_error)? {
            listed.push((
                budget.keep(text(&entry, "name")?)?,
                entry.try_get::<i64, _>("unique").map_err(map_error)? != 0,
                entry.try_get::<i64, _>("partial").map_err(map_error)? != 0,
                text(&entry, "origin")? == "pk",
            ));
        }
    }
    let mut indexes = Vec::with_capacity(listed.len() + 1);
    for (name, unique, partial, primary) in listed {
        indexes.push(index(connection, schema, name, unique, partial, primary, budget).await?);
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
            definition: None,
        });
    }
    Ok(indexes)
}

async fn index(
    connection: &mut SqlxConnection,
    schema: &str,
    name: String,
    unique: bool,
    partial: bool,
    primary: bool,
    budget: &mut CatalogBudget,
) -> Result<IndexInfo, DriverError> {
    let stored_sql: Option<String> = sqlx::query_scalar(AssertSqlSafe(catalog::index_sql(&quote(schema))))
        .bind(name.as_str())
        .fetch_optional(&mut *connection)
        .await
        .map_err(map_error)?
        .flatten();
    let stored_sql = budget.keep_optional(stored_sql)?;
    let parsed = stored_sql.as_deref().and_then(read_index_sql);
    let mut keys = Vec::new();
    let mut rows = sqlx::query(catalog::INDEX_XINFO_SQL)
        .bind(name.as_str())
        .bind(schema)
        .fetch(&mut *connection);
    while let Some(key) = rows.try_next().await.map_err(map_error)? {
        let position = keys.len();
        let cid: i64 = key.try_get("cid").map_err(map_error)?;
        let descending = key.try_get::<i64, _>("desc").map_err(map_error)? != 0;
        let column: Option<String> = budget.keep_optional(key.try_get("name").map_err(map_error)?)?;
        keys.push(match (cid, column) {
            (-2, _) => IndexKey::Expression {
                sql: budget.keep(
                    parsed
                        .as_ref()
                        .and_then(|parsed| parsed.keys.get(position).cloned())
                        .unwrap_or_default(),
                )?,
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
        false => None,
        true => parsed.and_then(|parsed| parsed.predicate),
    };
    let definition = match stored_sql {
        Some(sql) => {
            let definition = budget.keep(in_schema(&sql, schema))?;
            budget.release_text(&sql);
            Some(definition)
        }
        None => None,
    };
    Ok(IndexInfo {
        name,
        keys,
        unique,
        primary,
        predicate,
        definition,
    })
}

async fn table_shape(
    connection: &mut SqlxConnection,
    table: &TableRef,
    budget: &mut CatalogBudget,
) -> Result<TableShape, DriverError> {
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

    let columns = column_rows(connection, &table.name, schema, budget).await?;
    let single_column_key = columns.iter().filter(|column| column.pk > 0).count() == 1;
    let mut facts = TableFacts {
        strict,
        without_rowid,
        single_column_key,
        descending_key: false,
    };
    if let Some(candidate) = columns.iter().find(|column| column.is_rowid_candidate(&facts)) {
        let sql = create_statement(connection, table, budget).await?;
        facts.descending_key = sql
            .as_deref()
            .is_some_and(|sql| declared_descending_key(sql, &candidate.name));
        release(budget, sql);
    }
    Ok(TableShape { kind, facts, columns })
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

// SQLite stores the name bare, and a TEMP table of the same name would catch an unqualified statement.
fn in_schema(sql: &str, schema: &str) -> String {
    let head = ["CREATE UNIQUE INDEX ", "CREATE INDEX "]
        .into_iter()
        .find(|head| sql.starts_with(head));
    match head {
        Some(head) => format!("{head}{}.{}", quote(schema), &sql[head.len()..]),
        None => sql.to_owned(),
    }
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
