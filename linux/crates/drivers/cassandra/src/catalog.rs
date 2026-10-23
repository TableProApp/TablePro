//! What the server's schema tables say about keyspaces and tables.

use std::collections::{HashMap, HashSet};

use tablepro_core::DriverError;
use tablepro_core::column::{ColumnDefault, ColumnInfo};
use tablepro_core::ddl::{
    ColumnAttributes, ColumnDefinition, ColumnKeyRoles, PrimaryKeyConstraint, SchemaObjectKind, SchemaObjectSource,
    TableDefinition, TableSource,
};
use tablepro_core::meta::{
    IndexInfo, IndexKey, ObjectInfo, ObjectKind, ObjectScope, RowIdentity, SchemaInfo, TableRef,
};

use scylla::value::{CqlValue, Row};

use crate::cql_type::CqlType;
use crate::decode::literal;
use crate::session::CqlLink;

/// A table or view as the schema tables name it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct CatalogTable {
    pub(crate) keyspace: String,
    pub(crate) name: String,
}

/// The keyspaces the server keeps for itself.
pub(crate) fn is_system_keyspace(name: &str) -> bool {
    name == "system" || name.starts_with("system_")
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
enum Role {
    PartitionKey(i32),
    Clustering(i32),
    Static,
    Regular,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ColumnRow {
    pub(crate) name: String,
    pub(crate) cql_type: CqlType,
    /// The type as the schema table spells it.
    pub(crate) declaration: String,
    role: Role,
    descending: bool,
}

impl ColumnRow {
    pub(crate) fn is_key(&self) -> bool {
        matches!(self.role, Role::PartitionKey(_) | Role::Clustering(_))
    }

    fn info(&self) -> ColumnInfo {
        ColumnInfo {
            name: self.name.clone(),
            column_type: self.cql_type.column_type(Some(&self.declaration)),
            nullable: !self.is_key(),
            primary_key: self.is_key(),
            is_auto_increment: false,
            is_generated: false,
            partition_scoped: matches!(self.role, Role::PartitionKey(_) | Role::Static),
            default: ColumnDefault::None,
            comment: None,
        }
    }

    fn definition(&self) -> ColumnDefinition {
        ColumnDefinition::new(
            self.info(),
            ColumnAttributes {
                key_roles: ColumnKeyRoles {
                    sorting_key: matches!(self.role, Role::Clustering(_)),
                    partition_key: matches!(self.role, Role::PartitionKey(_)),
                },
                ..ColumnAttributes::default()
            },
        )
    }
}

fn rows_error(error: impl std::fmt::Display) -> DriverError {
    DriverError::Protocol(error.to_string())
}

pub(crate) async fn list_schemas(link: &CqlLink, default: Option<&str>) -> Result<Vec<SchemaInfo>, DriverError> {
    let rows = link
        .catalogue("SELECT keyspace_name FROM system_schema.keyspaces", ())
        .await?
        .into_rows_result()
        .map_err(rows_error)?;
    let mut keyspaces = rows
        .rows::<(String,)>()
        .map_err(rows_error)?
        .map(|row| row.map(|(name,)| name).map_err(rows_error))
        .collect::<Result<Vec<_>, _>>()?;
    keyspaces.sort();
    Ok(keyspaces
        .into_iter()
        .map(|name| SchemaInfo {
            is_default: Some(name.as_str()) == default,
            is_system: is_system_keyspace(&name),
            name,
        })
        .collect())
}

/// Tables, then materialized views. ScyllaDB keeps each secondary index
/// as a view named after it, which is the index's and not listed, and a
/// table's lightweight transaction state in a `<table>$paxos` table, a
/// name CQL cannot spell.
pub(crate) async fn list_objects(
    link: &CqlLink,
    scope: &ObjectScope,
    default: Option<&str>,
) -> Result<Vec<ObjectInfo>, DriverError> {
    let keyspace = match scope {
        ObjectScope::DefaultSchema => match default {
            Some(keyspace) => Some(keyspace),
            None => return Ok(Vec::new()),
        },
        ObjectScope::Schema(keyspace) => Some(keyspace.as_str()),
        ObjectScope::AllSchemas => None,
    };
    let tables = names(
        link,
        "SELECT keyspace_name, table_name FROM system_schema.tables",
        keyspace,
    )
    .await?;
    let views = names(
        link,
        "SELECT keyspace_name, view_name FROM system_schema.views",
        keyspace,
    )
    .await?;
    let index_views: HashSet<(String, String)> = names(
        link,
        "SELECT keyspace_name, index_name FROM system_schema.indexes",
        keyspace,
    )
    .await?
    .into_iter()
    .map(|(keyspace, index)| (keyspace, format!("{index}_index")))
    .collect();
    let mut objects: Vec<ObjectInfo> = tables
        .into_iter()
        .map(|name| (name, ObjectKind::Table))
        .chain(
            views
                .into_iter()
                .filter(|view| !index_views.contains(view))
                .map(|name| (name, ObjectKind::MaterializedView)),
        )
        .filter(|((_, name), _)| !name.contains('$'))
        .filter(|((keyspace, _), _)| matches!(scope, ObjectScope::Schema(_)) || !is_system_keyspace(keyspace))
        .map(|((keyspace, name), kind)| ObjectInfo {
            schema: Some(keyspace),
            name,
            kind,
        })
        .collect();
    objects.sort_by(|a, b| (&a.schema, &a.name).cmp(&(&b.schema, &b.name)));
    Ok(objects)
}

/// `(keyspace, name)` pairs from a schema table, in one keyspace or all.
async fn names(link: &CqlLink, select: &str, keyspace: Option<&str>) -> Result<Vec<(String, String)>, DriverError> {
    let result = match keyspace {
        Some(keyspace) => {
            link.catalogue(&format!("{select} WHERE keyspace_name = ?"), (keyspace,))
                .await?
        }
        None => link.catalogue(select, ()).await?,
    };
    let rows = result.into_rows_result().map_err(rows_error)?;
    rows.rows::<(String, String)>()
        .map_err(rows_error)?
        .map(|row| row.map_err(rows_error))
        .collect()
}

/// The columns as `SELECT *` returns them: partition key, clustering
/// columns, then the rest by name.
pub(crate) async fn column_rows(link: &CqlLink, table: &CatalogTable) -> Result<Vec<ColumnRow>, DriverError> {
    let sql = "SELECT column_name, type, kind, position, clustering_order FROM system_schema.columns \
               WHERE keyspace_name = ? AND table_name = ?";
    let rows = link
        .catalogue(sql, (table.keyspace.as_str(), table.name.as_str()))
        .await?
        .into_rows_result()
        .map_err(rows_error)?;
    let mut columns = Vec::new();
    for row in rows
        .rows::<(String, String, String, i32, Option<String>)>()
        .map_err(rows_error)?
    {
        let (name, declaration, kind, position, order) = row.map_err(rows_error)?;
        let role = match kind.as_str() {
            "partition_key" => Role::PartitionKey(position),
            "clustering" => Role::Clustering(position),
            "static" => Role::Static,
            _ => Role::Regular,
        };
        let cql_type = CqlType::parse(&declaration).unwrap_or_else(|| CqlType::Custom(declaration.clone()));
        columns.push(ColumnRow {
            name,
            cql_type,
            declaration,
            role,
            descending: order.is_some_and(|order| order.eq_ignore_ascii_case("desc")),
        });
    }
    columns.sort_by(|a, b| {
        let rank = |row: &ColumnRow| match row.role {
            Role::PartitionKey(position) => (0, position),
            Role::Clustering(position) => (1, position),
            Role::Static | Role::Regular => (2, 0),
        };
        rank(a).cmp(&rank(b)).then_with(|| a.name.cmp(&b.name))
    });
    Ok(columns)
}

/// A key the grid cannot write rows by is not reported as one, since
/// the columns are what browse edits by: a view, a counter table and a
/// key the app holds only as text read as having none.
pub(crate) async fn fetch_columns(link: &CqlLink, table: &CatalogTable) -> Result<Vec<ColumnInfo>, DriverError> {
    let columns = column_rows(link, table).await?;
    let writable = rows_writable(link, table, &columns).await?;
    Ok(columns
        .iter()
        .map(|column| {
            let mut info = column.info();
            info.primary_key &= writable;
            info
        })
        .collect())
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct IndexRow {
    name: String,
    custom_class: Option<String>,
    target: String,
    options: Vec<(String, String)>,
}

async fn index_rows(link: &CqlLink, table: &CatalogTable) -> Result<Vec<IndexRow>, DriverError> {
    let sql = "SELECT index_name, kind, options FROM system_schema.indexes \
               WHERE keyspace_name = ? AND table_name = ?";
    let rows = link
        .catalogue(sql, (table.keyspace.as_str(), table.name.as_str()))
        .await?
        .into_rows_result()
        .map_err(rows_error)?;
    let mut indexes = Vec::new();
    for row in rows
        .rows::<(String, String, Option<HashMap<String, String>>)>()
        .map_err(rows_error)?
    {
        let (name, kind, options) = row.map_err(rows_error)?;
        let mut options = options.unwrap_or_default();
        let target = options.remove("target").unwrap_or_default();
        let custom_class = match kind.eq_ignore_ascii_case("custom") {
            true => options.remove("class_name"),
            false => None,
        };
        let mut options: Vec<(String, String)> = options.into_iter().collect();
        options.sort();
        indexes.push(IndexRow {
            name,
            custom_class,
            target,
            options,
        });
    }
    indexes.sort_by(|a, b| a.name.cmp(&b.name));
    Ok(indexes)
}

/// An index's target as a key: a column, or `keys(m)` and its kind on a
/// collection, which names no column on its own.
fn index_key(target: &str) -> IndexKey {
    match unquoted_column(target) {
        Some(name) => IndexKey::Column {
            name,
            descending: false,
        },
        None => IndexKey::Expression {
            sql: target.to_owned(),
            descending: false,
        },
    }
}

/// A target that is one column name, bare or in double quotes.
fn unquoted_column(target: &str) -> Option<String> {
    if let Some(inner) = target.strip_prefix('"').and_then(|rest| rest.strip_suffix('"')) {
        return Some(inner.replace("\"\"", "\""));
    }
    let plain = !target.is_empty() && target.chars().all(|c| c.is_ascii_alphanumeric() || c == '_');
    plain.then(|| target.to_owned())
}

fn primary_index(table: &CatalogTable, columns: &[ColumnRow]) -> Option<IndexInfo> {
    let keys: Vec<IndexKey> = columns
        .iter()
        .filter(|column| column.is_key())
        .map(|column| IndexKey::Column {
            name: column.name.clone(),
            descending: column.descending,
        })
        .collect();
    (!keys.is_empty()).then(|| IndexInfo {
        name: format!("{}_primary_key", table.name),
        keys,
        unique: true,
        primary: true,
        predicate: None,
    })
}

fn secondary_index(index: &IndexRow) -> IndexInfo {
    IndexInfo {
        name: index.name.clone(),
        keys: vec![index_key(&index.target)],
        unique: false,
        primary: false,
        predicate: None,
    }
}

pub(crate) async fn fetch_indexes(link: &CqlLink, table: &CatalogTable) -> Result<Vec<IndexInfo>, DriverError> {
    let columns = column_rows(link, table).await?;
    let indexes = index_rows(link, table).await?;
    Ok(primary_index(table, &columns)
        .into_iter()
        .chain(indexes.iter().map(secondary_index))
        .collect())
}

/// The base table of a materialized view, where `table` is one.
#[derive(Debug, Clone, PartialEq, Eq)]
struct ViewRow {
    base_table: String,
    where_clause: String,
    include_all_columns: bool,
}

async fn view_row(link: &CqlLink, table: &CatalogTable) -> Result<Option<ViewRow>, DriverError> {
    let sql = "SELECT base_table_name, where_clause, include_all_columns FROM system_schema.views \
               WHERE keyspace_name = ? AND view_name = ?";
    let rows = link
        .catalogue(sql, (table.keyspace.as_str(), table.name.as_str()))
        .await?
        .into_rows_result()
        .map_err(rows_error)?;
    let row = rows
        .maybe_first_row::<(String, Option<String>, Option<bool>)>()
        .map_err(rows_error)?;
    Ok(row.map(|(base_table, where_clause, include_all_columns)| ViewRow {
        base_table,
        where_clause: where_clause.unwrap_or_default(),
        include_all_columns: include_all_columns.unwrap_or(false),
    }))
}

/// The options a CREATE statement sets, in the order cqlsh's DESCRIBE
/// writes them. A release keeps only some of them; the rest are left
/// out.
const TABLE_OPTIONS: &[&str] = &[
    "additional_write_policy",
    "allow_auto_snapshot",
    "bloom_filter_fp_chance",
    "caching",
    "cdc",
    "comment",
    "compaction",
    "compression",
    "crc_check_chance",
    "dclocal_read_repair_chance",
    "default_time_to_live",
    "gc_grace_seconds",
    "incremental_backups",
    "max_index_interval",
    "memtable",
    "memtable_flush_period_in_ms",
    "min_index_interval",
    "read_repair",
    "read_repair_chance",
    "speculative_retry",
];

/// The table's or view's options as `name = literal`, from its row in
/// the schema table, whose columns differ between releases.
async fn options(link: &CqlLink, table: &CatalogTable, view: bool) -> Result<Vec<String>, DriverError> {
    let sql = match view {
        true => "SELECT * FROM system_schema.views WHERE keyspace_name = ? AND view_name = ?",
        false => "SELECT * FROM system_schema.tables WHERE keyspace_name = ? AND table_name = ?",
    };
    let rows = link
        .catalogue(sql, (table.keyspace.as_str(), table.name.as_str()))
        .await?
        .into_rows_result()
        .map_err(rows_error)?;
    let names: Vec<String> = rows.column_specs().iter().map(|spec| spec.name().to_owned()).collect();
    let Some(row) = rows.maybe_first_row::<Row>().map_err(rows_error)? else {
        return Ok(Vec::new());
    };
    Ok(written_options(&names, row.columns))
}

fn written_options(names: &[String], values: Vec<Option<CqlValue>>) -> Vec<String> {
    let by_name: HashMap<&str, CqlValue> = names
        .iter()
        .map(String::as_str)
        .zip(values)
        .filter_map(|(name, value)| Some((name, value?)))
        .collect();
    TABLE_OPTIONS
        .iter()
        .filter_map(|option| Some(format!("{option} = {}", literal(by_name.get(option)?)?)))
        .collect()
}

pub(crate) async fn fetch_table_definition(
    link: &CqlLink,
    table_ref: &TableRef,
    table: &CatalogTable,
) -> Result<TableDefinition, DriverError> {
    let columns = column_rows(link, table).await?;
    let view = view_row(link, table).await?;
    let indexes = match view {
        Some(_) => Vec::new(),
        None => index_rows(link, table).await?,
    };
    let options = options(link, table, view.is_some()).await?;
    let create_statement = match &view {
        Some(view) => create_view(table, view, &columns, &options),
        None => create_table(table, &columns, &options),
    };
    let dependents = indexes
        .iter()
        .map(|index| SchemaObjectSource {
            kind: SchemaObjectKind::Index,
            name: index.name.clone(),
            table: table.name.clone(),
            sql: create_index(table, index),
        })
        .collect();
    let key: Vec<String> = columns
        .iter()
        .filter(|column| column.is_key())
        .map(|column| column.name.clone())
        .collect();
    Ok(TableDefinition {
        table: table_ref.clone(),
        primary_key: (!key.is_empty()).then_some(PrimaryKeyConstraint {
            name: None,
            columns: key,
        }),
        indexes: primary_index(table, &columns)
            .into_iter()
            .chain(indexes.iter().map(secondary_index))
            .collect(),
        columns: columns.iter().map(ColumnRow::definition).collect(),
        foreign_keys: Vec::new(),
        inbound_foreign_keys: Vec::new(),
        source: (!columns.is_empty()).then_some(TableSource {
            create_statement,
            dependents,
        }),
    })
}

/// A row is named by its whole primary key, except where no write can
/// name one (`rows_writable`).
pub(crate) async fn row_identity(link: &CqlLink, table: &CatalogTable) -> Result<RowIdentity, DriverError> {
    let columns = column_rows(link, table).await?;
    let key: Vec<String> = columns
        .iter()
        .filter(|column| column.is_key())
        .map(|column| column.name.clone())
        .collect();
    Ok(match rows_writable(link, table, &columns).await? {
        true => RowIdentity::UniqueKey { columns: key },
        false => RowIdentity::Unordered,
    })
}

/// Whether the grid can write a row of the table by its key. A view
/// takes no writes, a counter table takes neither a set value nor a
/// lightweight transaction, and a key of a map or user type is held
/// only as text, which no predicate can bind.
async fn rows_writable(link: &CqlLink, table: &CatalogTable, columns: &[ColumnRow]) -> Result<bool, DriverError> {
    let keyed = columns.iter().any(ColumnRow::is_key);
    let counted = columns.iter().any(|column| column.cql_type.is_counter());
    let opaque_key = columns
        .iter()
        .any(|column| column.is_key() && column.cql_type.is_opaque_composite());
    if !keyed || counted || opaque_key {
        return Ok(false);
    }
    Ok(view_row(link, table).await?.is_none())
}

fn quote(name: &str) -> String {
    format!("\"{}\"", name.replace('"', "\"\""))
}

fn qualified(table: &CatalogTable) -> String {
    format!("{}.{}", quote(&table.keyspace), quote(&table.name))
}

/// `PRIMARY KEY (("a", "b"), "c")`, the partition key in its own
/// parentheses only when it has more than one column.
fn primary_key_clause(columns: &[ColumnRow]) -> String {
    let partition: Vec<String> = columns
        .iter()
        .filter(|column| matches!(column.role, Role::PartitionKey(_)))
        .map(|column| quote(&column.name))
        .collect();
    let clustering = columns
        .iter()
        .filter(|column| matches!(column.role, Role::Clustering(_)))
        .map(|column| quote(&column.name));
    let partition = match partition.len() {
        1 => partition.join(""),
        _ => format!("({})", partition.join(", ")),
    };
    let mut parts = vec![partition];
    parts.extend(clustering);
    format!("PRIMARY KEY ({})", parts.join(", "))
}

/// `WITH CLUSTERING ORDER BY (...)` where a clustering column descends.
fn clustering_order(columns: &[ColumnRow]) -> Option<String> {
    let clustering: Vec<&ColumnRow> = columns
        .iter()
        .filter(|column| matches!(column.role, Role::Clustering(_)))
        .collect();
    clustering.iter().any(|column| column.descending).then(|| {
        let terms: Vec<String> = clustering
            .iter()
            .map(|column| {
                format!(
                    "{} {}",
                    quote(&column.name),
                    if column.descending { "DESC" } else { "ASC" }
                )
            })
            .collect();
        format!("CLUSTERING ORDER BY ({})", terms.join(", "))
    })
}

fn create_table(table: &CatalogTable, columns: &[ColumnRow], table_options: &[String]) -> String {
    let mut lines: Vec<String> = columns
        .iter()
        .map(|column| {
            let static_marker = if column.role == Role::Static { " static" } else { "" };
            format!("    {} {}{static_marker}", quote(&column.name), column.declaration)
        })
        .collect();
    lines.push(format!("    {}", primary_key_clause(columns)));
    let mut options: Vec<String> = clustering_order(columns).into_iter().collect();
    options.extend(table_options.iter().cloned());
    let with = match options.is_empty() {
        true => String::new(),
        false => format!(" WITH {}", options.join("\n    AND ")),
    };
    format!("CREATE TABLE {} (\n{}\n){with}", qualified(table), lines.join(",\n"))
}

fn create_view(view: &CatalogTable, row: &ViewRow, columns: &[ColumnRow], view_options: &[String]) -> String {
    let selected = match row.include_all_columns {
        true => "*".to_owned(),
        false => columns
            .iter()
            .map(|column| quote(&column.name))
            .collect::<Vec<_>>()
            .join(", "),
    };
    let base = CatalogTable {
        keyspace: view.keyspace.clone(),
        name: row.base_table.clone(),
    };
    let mut statement = format!(
        "CREATE MATERIALIZED VIEW {} AS\n    SELECT {selected}\n    FROM {}",
        qualified(view),
        qualified(&base)
    );
    if !row.where_clause.is_empty() {
        statement.push_str(&format!("\n    WHERE {}", row.where_clause));
    }
    statement.push_str(&format!("\n    {}", primary_key_clause(columns)));
    let options: Vec<String> = clustering_order(columns)
        .into_iter()
        .chain(view_options.iter().cloned())
        .collect();
    if !options.is_empty() {
        statement.push_str(&format!("\n    WITH {}", options.join("\n    AND ")));
    }
    statement
}

fn create_index(table: &CatalogTable, index: &IndexRow) -> String {
    let target = match unquoted_column(&index.target) {
        Some(name) => quote(&name),
        None => index.target.clone(),
    };
    let name = quote(&index.name);
    match &index.custom_class {
        None => format!("CREATE INDEX {name} ON {} ({target})", qualified(table)),
        Some(class) => {
            let mut statement = format!(
                "CREATE CUSTOM INDEX {name} ON {} ({target}) USING '{}'",
                qualified(table),
                class.replace('\'', "''")
            );
            if !index.options.is_empty() {
                let options: Vec<String> = index
                    .options
                    .iter()
                    .map(|(key, value)| format!("'{}': '{}'", key.replace('\'', "''"), value.replace('\'', "''")))
                    .collect();
                statement.push_str(&format!(" WITH OPTIONS = {{{}}}", options.join(", ")));
            }
            statement
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn column(name: &str, declaration: &str, role: Role, descending: bool) -> ColumnRow {
        ColumnRow {
            name: name.to_owned(),
            cql_type: CqlType::parse(declaration).unwrap(),
            declaration: declaration.to_owned(),
            role,
            descending,
        }
    }

    fn events() -> (CatalogTable, Vec<ColumnRow>) {
        (
            CatalogTable {
                keyspace: "shop".to_owned(),
                name: "events".to_owned(),
            },
            vec![
                column("tenant", "uuid", Role::PartitionKey(0), false),
                column("day", "date", Role::PartitionKey(1), false),
                column("at", "timestamp", Role::Clustering(0), true),
                column("seq", "int", Role::Clustering(1), false),
                column("owner", "text", Role::Static, false),
                column("Payload", "frozen<map<text, int>>", Role::Regular, false),
            ],
        )
    }

    #[test]
    fn a_composite_partition_key_keeps_its_parentheses_and_its_order() {
        let (table, columns) = events();

        assert_eq!(
            create_table(&table, &columns, &["comment = 'it''s'".to_owned()]),
            "CREATE TABLE \"shop\".\"events\" (\n    \"tenant\" uuid,\n    \"day\" date,\n    \"at\" timestamp,\n    \"seq\" int,\n    \"owner\" text static,\n    \"Payload\" frozen<map<text, int>>,\n    PRIMARY KEY ((\"tenant\", \"day\"), \"at\", \"seq\")\n) WITH CLUSTERING ORDER BY (\"at\" DESC, \"seq\" ASC)\n    AND comment = 'it''s'"
        );
    }

    #[test]
    fn options_are_written_in_describes_order_and_only_where_the_release_keeps_them() {
        let names: Vec<String> = ["keyspace_name", "default_time_to_live", "caching", "comment", "flags"]
            .into_iter()
            .map(str::to_owned)
            .collect();
        let values = vec![
            Some(CqlValue::Text("shop".to_owned())),
            Some(CqlValue::Int(86_400)),
            Some(CqlValue::Map(vec![(
                CqlValue::Text("keys".to_owned()),
                CqlValue::Text("ALL".to_owned()),
            )])),
            None,
            Some(CqlValue::Set(vec![CqlValue::Text("compound".to_owned())])),
        ];

        assert_eq!(
            written_options(&names, values),
            ["caching = {'keys': 'ALL'}", "default_time_to_live = 86400"]
        );
    }

    #[test]
    fn a_single_column_key_needs_no_inner_parentheses_or_options() {
        let table = CatalogTable {
            keyspace: "shop".to_owned(),
            name: "users".to_owned(),
        };
        let columns = vec![column("id", "uuid", Role::PartitionKey(0), false)];

        assert_eq!(
            create_table(&table, &columns, &[]),
            "CREATE TABLE \"shop\".\"users\" (\n    \"id\" uuid,\n    PRIMARY KEY (\"id\")\n)"
        );
    }

    #[test]
    fn the_primary_index_follows_the_clustering_order() {
        let (table, columns) = events();
        let index = primary_index(&table, &columns).unwrap();

        assert!(index.primary && index.unique);
        assert_eq!(
            index.keys,
            vec![
                IndexKey::Column {
                    name: "tenant".to_owned(),
                    descending: false
                },
                IndexKey::Column {
                    name: "day".to_owned(),
                    descending: false
                },
                IndexKey::Column {
                    name: "at".to_owned(),
                    descending: true
                },
                IndexKey::Column {
                    name: "seq".to_owned(),
                    descending: false
                },
            ]
        );
    }

    #[test]
    fn index_targets_read_as_columns_or_collection_expressions() {
        assert_eq!(
            index_key("name"),
            IndexKey::Column {
                name: "name".to_owned(),
                descending: false
            }
        );
        assert_eq!(
            index_key("\"Na\"\"me\""),
            IndexKey::Column {
                name: "Na\"me".to_owned(),
                descending: false
            }
        );
        assert_eq!(
            index_key("keys(tags)"),
            IndexKey::Expression {
                sql: "keys(tags)".to_owned(),
                descending: false
            }
        );
        let (table, _) = events();
        let custom = IndexRow {
            name: "by_owner".to_owned(),
            custom_class: Some("StorageAttachedIndex".to_owned()),
            target: "owner".to_owned(),
            options: vec![("case_sensitive".to_owned(), "false".to_owned())],
        };
        assert_eq!(
            create_index(&table, &custom),
            "CREATE CUSTOM INDEX \"by_owner\" ON \"shop\".\"events\" (\"owner\") USING 'StorageAttachedIndex' WITH OPTIONS = {'case_sensitive': 'false'}"
        );
    }

    #[test]
    fn a_view_is_written_as_the_view_it_is() {
        let view = CatalogTable {
            keyspace: "shop".to_owned(),
            name: "by_day".to_owned(),
        };
        let row = ViewRow {
            base_table: "events".to_owned(),
            where_clause: "day IS NOT NULL AND tenant IS NOT NULL".to_owned(),
            include_all_columns: true,
        };
        let columns = vec![
            column("day", "date", Role::PartitionKey(0), false),
            column("tenant", "uuid", Role::Clustering(0), false),
        ];

        assert_eq!(
            create_view(&view, &row, &columns, &[]),
            "CREATE MATERIALIZED VIEW \"shop\".\"by_day\" AS\n    SELECT *\n    FROM \"shop\".\"events\"\n    WHERE day IS NOT NULL AND tenant IS NOT NULL\n    PRIMARY KEY (\"day\", \"tenant\")"
        );
    }

    #[test]
    fn system_keyspaces_are_the_servers_own() {
        for name in [
            "system",
            "system_schema",
            "system_auth",
            "system_distributed_everywhere",
        ] {
            assert!(is_system_keyspace(name), "{name}");
        }
        assert!(!is_system_keyspace("systems"));
        assert!(!is_system_keyspace("shop"));
    }
}
