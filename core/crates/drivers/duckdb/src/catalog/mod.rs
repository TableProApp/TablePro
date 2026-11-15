//! What the database holds, read from DuckDB's `duckdb_*()` functions.
//!
//! Every read names the file's own catalogue: a database attached in an
//! editor tab lists in the same functions, and its tables are not this
//! connection's to browse. The functions work with no extension loaded.

mod declared_columns;

use std::collections::{HashMap, HashSet};

use tablepro_core::column::{ColumnDefault, ColumnInfo, ColumnType, SqlExpression};
use tablepro_core::ddl::{
    CollationName, ColumnAttributes, ColumnDefinition, GeneratedColumn, GeneratedStorage, IdentityStyle,
    InboundForeignKey, OutboundForeignKey, PrimaryKeyConstraint, ReferentialAction, SchemaObjectKind,
    SchemaObjectSource, TableDefinition, TableSource,
};
use tablepro_core::edit::parse_literal_text;
use tablepro_core::meta::{
    IndexInfo, IndexKey, ObjectInfo, ObjectKind, ObjectScope, RowCountEstimate, RowIdentity, SchemaInfo, TableEstimate,
    TableRef,
};
use tablepro_core::sql_syntax::{LiteralToken, MAX_EXPRESSION_LEN, SqlGrammar, parse_expression};
use tablepro_core::value::Value;
use tablepro_core::{CatalogBudget, DriverError, ForeignKeyInfo};

use self::declared_columns::declared_columns;
use crate::duck_type::column_type_from_text;
use crate::errors::map_error;
use crate::instance::Link;

/// The schema a name without one lives in.
pub(crate) const DEFAULT_SCHEMA: &str = "main";

fn schema_of(table: &TableRef) -> &str {
    table
        .schema
        .as_deref()
        .filter(|schema| !schema.is_empty())
        .unwrap_or(DEFAULT_SCHEMA)
}

/// Rows of a catalogue query whose columns are all text or NULL.
fn text_rows(
    link: &Link,
    sql: &str,
    params: &[&str],
    budget: &mut CatalogBudget,
) -> Result<Vec<Vec<Option<String>>>, DriverError> {
    let mut statement = link.connection.prepare(sql).map_err(map_error)?;
    let mut rows = statement
        .query(duckdb::params_from_iter(params.iter()))
        .map_err(map_error)?;
    let width = rows.as_ref().map_or(0, duckdb::Statement::column_count);
    let mut read = Vec::new();
    while let Some(row) = rows.next().map_err(map_error)? {
        let mut values = Vec::with_capacity(width);
        for index in 0..width {
            values.push(budget.keep_optional(row.get::<_, Option<String>>(index).map_err(map_error)?)?);
        }
        read.push(values);
    }
    Ok(read)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Constraints {
    Own,
    Referencing,
}

// A table's constraints: REFERENCES, CHECK, UNIQUE and PRIMARY in its text, and a NOT NULL per column. DOUBLE, since
// the file chooses the numbers.
const CONSTRAINT_COUNT: &str = "CAST((strlen(lower(t.sql)) - strlen(replace(lower(t.sql), 'references', ''))) / 10 \
       + (strlen(lower(t.sql)) - strlen(replace(lower(t.sql), 'check', ''))) / 5 \
       + (strlen(lower(t.sql)) - strlen(replace(lower(t.sql), 'unique', ''))) / 6 \
       + (strlen(lower(t.sql)) - strlen(replace(lower(t.sql), 'primary', ''))) / 7 + t.column_count + 1 AS DOUBLE)";

// Beside its table's name, a constraint row's own words. Not `duckdb_columns()`, which repeats each table's name on
// every column row it builds, for every table, before a filter.
const ROW_BYTES: &str = "512";

// DuckDB builds every table's constraint rows, 2,048 to a chunk across tables, before a query filters them, and holds
// the whole result before its first row; it names each constraint after its table. A read runs only once the result,
// its table's name `names` times a row and four copies of the text, and the costliest 2,048 rows of any tables fit.
fn constraint_bounds(names: &str, tables: &str) -> String {
    format!(
        "SELECT \
           (SELECT sum({CONSTRAINT_COUNT} * ({names} * strlen(t.table_name) + {ROW_BYTES}) + 4 * strlen(t.sql)) \
            FROM duckdb_tables() t WHERE {tables}), \
           (SELECT coalesce(sum(bytes * greatest(0, least(rows, 2048 - (upto - rows)))), 0) FROM \
             (SELECT rows, bytes, sum(rows) OVER (ORDER BY bytes DESC ROWS UNBOUNDED PRECEDING) AS upto FROM \
               (SELECT least({CONSTRAINT_COUNT}, 2048) AS rows, 2 * strlen(t.table_name) + {ROW_BYTES} AS bytes \
                FROM duckdb_tables() t))) \
           + 3 * coalesce((SELECT sum(b) FROM (SELECT CAST(strlen(sql) AS DOUBLE) AS b FROM duckdb_tables() \
             ORDER BY b DESC LIMIT 2048)), 0)"
    )
}

fn constraints_fit(
    link: &Link,
    catalog: &str,
    table: &TableRef,
    from: Constraints,
    budget: &CatalogBudget,
) -> Result<(), DriverError> {
    // A constraint's name holds its table's, and the keys into a table also read the child's name.
    let (names, tables) = match from {
        Constraints::Own => ("1", "t.database_name = ? AND t.schema_name = ? AND t.table_name = ?"),
        Constraints::Referencing => (
            "2",
            "t.table_oid IN (SELECT d.refobjid FROM duckdb_dependencies() d \
             JOIN duckdb_tables() p ON d.objid = p.table_oid \
             WHERE p.database_name = ? AND p.schema_name = ? AND p.table_name = ?)",
        ),
    };
    let (kept, built): (Option<f64>, Option<f64>) = link
        .connection
        .query_row(
            &constraint_bounds(names, tables),
            duckdb::params![catalog, schema_of(table), table.name],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .map_err(map_error)?;
    let bytes = kept.unwrap_or(0.0) + built.unwrap_or(0.0);
    budget.fits(match bytes < usize::MAX as f64 {
        true => bytes as usize,
        false => usize::MAX,
    })
}

fn text(row: &[Option<String>], index: usize) -> String {
    row.get(index).cloned().flatten().unwrap_or_default()
}

// Moved out rather than copied, so a row of long names is not held twice.
fn take(row: &mut [Option<String>], index: usize) -> String {
    row.get_mut(index).and_then(Option::take).unwrap_or_default()
}

fn flag(row: &[Option<String>], index: usize) -> bool {
    row.get(index)
        .and_then(Option::as_deref)
        .is_some_and(|value| value.eq_ignore_ascii_case("true"))
}

pub(crate) fn list_schemas(link: &Link, catalog: &str) -> Result<Vec<SchemaInfo>, DriverError> {
    let rows = text_rows(
        link,
        "SELECT schema_name FROM duckdb_schemas() WHERE database_name = ? ORDER BY schema_name",
        &[catalog],
        &mut CatalogBudget::default(),
    )?;
    Ok(rows
        .iter()
        .map(|row| {
            let name = text(row, 0);
            SchemaInfo {
                is_default: name == DEFAULT_SCHEMA,
                is_system: false,
                name,
            }
        })
        .collect())
}

pub(crate) fn list_objects(
    link: &Link,
    catalog: &str,
    scope: &ObjectScope,
    budget: &mut CatalogBudget,
) -> Result<Vec<ObjectInfo>, DriverError> {
    let schema = match scope {
        ObjectScope::DefaultSchema => Some(DEFAULT_SCHEMA),
        ObjectScope::Schema(schema) => Some(schema.as_str()),
        ObjectScope::AllSchemas => None,
    };
    let sql = "SELECT schema_name, table_name, 'table' FROM duckdb_tables() \
               WHERE database_name = ? AND NOT temporary AND (? IS NULL OR schema_name = ?) \
               UNION ALL \
               SELECT schema_name, view_name, 'view' FROM duckdb_views() \
               WHERE database_name = ? AND NOT internal AND NOT temporary AND (? IS NULL OR schema_name = ?) \
               ORDER BY 1, 2";
    let mut statement = link.connection.prepare(sql).map_err(map_error)?;
    let mut rows = statement
        .query(duckdb::params![catalog, schema, schema, catalog, schema, schema])
        .map_err(map_error)?;
    let mut objects = Vec::new();
    while let Some(row) = rows.next().map_err(map_error)? {
        let kind: String = row.get(2).map_err(map_error)?;
        objects.push(ObjectInfo {
            schema: Some(budget.keep(row.get(0).map_err(map_error)?)?),
            name: budget.keep(row.get(1).map_err(map_error)?)?,
            kind: match kind.as_str() {
                "view" => ObjectKind::View,
                _ => ObjectKind::Table,
            },
            parent_table: None,
        });
    }
    Ok(objects)
}

/// A table's columns, with the primary key marked and the generated
/// columns told apart from defaults.
pub(crate) fn fetch_columns(
    link: &Link,
    catalog: &str,
    table: &TableRef,
    budget: &mut CatalogBudget,
) -> Result<Vec<ColumnInfo>, DriverError> {
    let schema = schema_of(table);
    let rows = text_rows(
        link,
        "SELECT column_name, data_type, CAST(is_nullable AS VARCHAR), column_default, comment \
         FROM duckdb_columns() WHERE database_name = ? AND schema_name = ? AND table_name = ? \
         ORDER BY column_index",
        &[catalog, schema, &table.name],
        budget,
    )?;
    let keys = primary_key(link, catalog, table, budget)?
        .map(|key| key.columns)
        .unwrap_or_default();
    let sql = table_sql(link, catalog, table, budget)?;
    let generated: HashSet<String> = sql
        .as_deref()
        .map(|sql| {
            declared_columns(sql)
                .into_iter()
                .filter(|column| column.generated)
                .map(|column| column.name)
                .collect()
        })
        .unwrap_or_default();
    release(budget, sql);
    Ok(rows
        .iter()
        .map(|row| {
            let name = text(row, 0);
            let column_type = column_type_from_text(&text(row, 1));
            let default_text = row.get(3).cloned().flatten();
            let is_generated = generated.contains(&name);
            let default = match is_generated {
                true => ColumnDefault::None,
                false => classify_default(default_text.as_deref(), &column_type),
            };
            ColumnInfo {
                primary_key: keys.contains(&name),
                nullable: flag(row, 2),
                is_auto_increment: !is_generated && is_sequence_default(default_text.as_deref()),
                is_generated,
                partition_scoped: false,
                default,
                comment: row.get(4).cloned().flatten(),
                column_type,
                name,
            }
        })
        .collect())
}

fn is_sequence_default(text: Option<&str>) -> bool {
    text.is_some_and(|text| text.trim_start().to_ascii_lowercase().starts_with("nextval("))
}

/// A DEFAULT as a value the insert path can bind where it is a literal,
/// and as DuckDB's expression otherwise.
pub(crate) fn classify_default(text: Option<&str>, column_type: &ColumnType) -> ColumnDefault {
    let Some(text) = text.map(str::trim).filter(|text| !text.is_empty()) else {
        return ColumnDefault::None;
    };
    let expression = || ColumnDefault::Expression(SqlExpression::from_catalog_text(text));
    let Ok(parsed) = parse_expression(SqlGrammar::DuckDb, text, MAX_EXPRESSION_LEN) else {
        return expression();
    };
    let literal_text = match parsed.literal {
        None => return expression(),
        Some(LiteralToken::Null) => return ColumnDefault::None,
        Some(LiteralToken::Text(text)) => text,
        Some(LiteralToken::Number(number)) => number.to_string(),
        Some(LiteralToken::Boolean(flag)) => flag.to_string(),
    };
    match parse_literal_text(&literal_text, column_type) {
        Ok(Value::Null) | Err(_) => expression(),
        Ok(value) => ColumnDefault::Literal(value),
    }
}

/// The CREATE TABLE statement DuckDB keeps for a table, which a view has
/// none of.
fn table_sql(
    link: &Link,
    catalog: &str,
    table: &TableRef,
    budget: &mut CatalogBudget,
) -> Result<Option<String>, DriverError> {
    let mut rows = text_rows(
        link,
        "SELECT sql FROM duckdb_tables() WHERE database_name = ? AND schema_name = ? AND table_name = ?",
        &[catalog, schema_of(table), &table.name],
        budget,
    )?;
    Ok(rows.first_mut().and_then(|row| row.first_mut().and_then(Option::take)))
}

// For a text read, used and dropped before the next one is read.
fn release(budget: &mut CatalogBudget, text: Option<String>) {
    if let Some(text) = text {
        budget.release_text(&text);
    }
}

/// The columns of a table's PRIMARY KEY and UNIQUE constraints, in key
/// order, by constraint.
fn key_constraints(
    link: &Link,
    catalog: &str,
    table: &TableRef,
    budget: &mut CatalogBudget,
) -> Result<Vec<(String, String, Vec<String>)>, DriverError> {
    constraints_fit(link, catalog, table, Constraints::Own, budget)?;
    let rows = text_rows(
        link,
        "SELECT constraint_name, constraint_type, array_to_string(constraint_column_names, chr(31)) \
         FROM duckdb_constraints() \
         WHERE database_name = ? AND schema_name = ? AND table_name = ? \
           AND constraint_type IN ('PRIMARY KEY', 'UNIQUE') \
         ORDER BY constraint_index",
        &[catalog, schema_of(table), &table.name],
        budget,
    )?;
    Ok(rows
        .into_iter()
        .map(|mut row| (take(&mut row, 0), take(&mut row, 1), split_names(&take(&mut row, 2))))
        .collect())
}

pub(crate) fn primary_key(
    link: &Link,
    catalog: &str,
    table: &TableRef,
    budget: &mut CatalogBudget,
) -> Result<Option<PrimaryKeyConstraint>, DriverError> {
    Ok(key_constraints(link, catalog, table, budget)?
        .into_iter()
        .find(|(_, kind, _)| kind == "PRIMARY KEY")
        .map(|(name, _, columns)| PrimaryKeyConstraint {
            name: Some(name),
            columns,
        }))
}

/// The table's indexes: the ones created with CREATE INDEX, and the
/// index behind each PRIMARY KEY and UNIQUE constraint, which DuckDB
/// lists only as the constraint.
pub(crate) fn fetch_indexes(
    link: &Link,
    catalog: &str,
    table: &TableRef,
    budget: &mut CatalogBudget,
) -> Result<Vec<IndexInfo>, DriverError> {
    let mut indexes: Vec<IndexInfo> = key_constraints(link, catalog, table, budget)?
        .into_iter()
        .map(|(name, kind, columns)| IndexInfo {
            name,
            keys: columns
                .into_iter()
                .map(|name| IndexKey::Column {
                    name,
                    descending: false,
                })
                .collect(),
            unique: true,
            primary: kind == "PRIMARY KEY",
            predicate: None,
            definition: None,
        })
        .collect();
    let columns: HashSet<String> = fetch_columns(link, catalog, table, budget)?
        .into_iter()
        .map(|column| column.name)
        .collect();
    let rows = text_rows(
        link,
        // DuckDB lists an index's keys as the text of a list.
        "SELECT index_name, CAST(is_unique AS VARCHAR), CAST(is_primary AS VARCHAR), \
                array_to_string(CAST(expressions AS VARCHAR[]), chr(31)), sql \
         FROM duckdb_indexes() WHERE database_name = ? AND schema_name = ? AND table_name = ? \
         ORDER BY index_name",
        &[catalog, schema_of(table), &table.name],
        budget,
    )?;
    let quote = |name: &str| format!("\"{}\"", name.replace('"', "\"\""));
    let target = format!("{}.{}.{}", quote(catalog), quote(schema_of(table)), quote(&table.name));
    indexes.extend(rows.iter().map(|row| {
        IndexInfo {
            name: text(row, 0),
            keys: split_names(&text(row, 3))
                .iter()
                .map(|key| index_key(key, &columns))
                .collect(),
            unique: flag(row, 1),
            primary: flag(row, 2),
            predicate: None,
            definition: statement(&text(row, 4)).and_then(|sql| on_own_table(&sql, &target)),
        }
    }));
    Ok(indexes)
}

// DuckDB ends its index text with a semicolon, which the app adds itself.
fn statement(sql: &str) -> Option<String> {
    let sql = sql.trim().trim_end_matches(';').trim_end();
    (!sql.is_empty()).then(|| sql.to_owned())
}

// DuckDB writes a table of schema main bare, and a temp table of the same name catches that and
// `main.t` alike: only the catalog's name reaches the database's own table.
fn on_own_table(sql: &str, target: &str) -> Option<String> {
    let rest = sql
        .strip_prefix("CREATE UNIQUE INDEX ")
        .or_else(|| sql.strip_prefix("CREATE INDEX "))?;
    let rest = rest.get(identifier_length(rest)?..)?.strip_prefix(" ON ")?;
    let start = sql.len() - rest.len();
    let end = start + reference_length(rest)?;
    Some(format!("{}{target}{}", &sql[..start], &sql[end..]))
}

fn reference_length(text: &str) -> Option<usize> {
    let mut length = identifier_length(text)?;
    while text.get(length..)?.starts_with('.') {
        length += 1 + identifier_length(text.get(length + 1..)?)?;
    }
    Some(length)
}

fn identifier_length(text: &str) -> Option<usize> {
    let Some(quoted) = text.strip_prefix('"') else {
        let length = text
            .find(|character: char| !(character.is_alphanumeric() || character == '_'))
            .unwrap_or(text.len());
        return (length > 0).then_some(length);
    };
    let mut position = 0;
    loop {
        let close = position + quoted.get(position..)?.find('"')?;
        match quoted.get(close + 1..)?.starts_with('"') {
            true => position = close + 2,
            false => return Some(close + 2),
        }
    }
}

/// One key of an index: a column where the text names one, an
/// expression otherwise.
fn index_key(text: &str, columns: &HashSet<String>) -> IndexKey {
    let trimmed = text.trim();
    let unquoted = trimmed
        .strip_prefix('"')
        .and_then(|inner| inner.strip_suffix('"'))
        .map(|inner| inner.replace("\"\"", "\""));
    let name = unquoted.unwrap_or_else(|| trimmed.to_owned());
    match columns.contains(&name) {
        true => IndexKey::Column {
            name,
            descending: false,
        },
        false => IndexKey::Expression {
            sql: trimmed.to_owned(),
            descending: false,
        },
    }
}

/// Foreign keys: DuckDB keeps the referenced table by name in the same
/// schema, and enforces no action but refusing the change.
pub(crate) fn fetch_foreign_keys(
    link: &Link,
    catalog: &str,
    table: &TableRef,
    budget: &mut CatalogBudget,
) -> Result<Vec<ForeignKeyInfo>, DriverError> {
    constraints_fit(link, catalog, table, Constraints::Own, budget)?;
    let rows = text_rows(
        link,
        "SELECT constraint_name, referenced_table, \
                array_to_string(constraint_column_names, chr(31)), \
                array_to_string(referenced_column_names, chr(31)) \
         FROM duckdb_constraints() \
         WHERE database_name = ? AND schema_name = ? AND table_name = ? AND constraint_type = 'FOREIGN KEY' \
         ORDER BY constraint_index",
        &[catalog, schema_of(table), &table.name],
        budget,
    )?;
    let schema = schema_of(table);
    rows.into_iter()
        .map(|mut row| {
            // Each key holds its own copy of the schema's name, which the file chose.
            Ok(ForeignKeyInfo {
                name: take(&mut row, 0),
                columns: split_names(&take(&mut row, 2)),
                ref_schema: Some(budget.keep(schema.to_owned())?),
                ref_table: take(&mut row, 1),
                ref_columns: split_names(&take(&mut row, 3)),
                on_delete: Some(ReferentialAction::NoAction),
                on_update: Some(ReferentialAction::NoAction),
            })
        })
        .collect()
}

/// The table's own keys, each with whether `=` on the referenced columns
/// finds the rows it matches: not when one of them is declared with a
/// collation, since DuckDB matches a key byte for byte.
pub(crate) fn outbound_foreign_keys(
    link: &Link,
    catalog: &str,
    table: &TableRef,
    budget: &mut CatalogBudget,
) -> Result<Vec<OutboundForeignKey>, DriverError> {
    let keys = fetch_foreign_keys(link, catalog, table, budget)?;
    let mut outbound = Vec::with_capacity(keys.len());
    // Each parent's CREATE TABLE once, however many keys point at it.
    let mut parents: HashMap<(Option<String>, String), Vec<String>> = HashMap::new();
    for key in keys {
        let parent = (key.ref_schema.clone(), key.ref_table.clone());
        let collated = match parents.get(&parent) {
            Some(collated) => collated,
            None => {
                let referenced = TableRef::new(key.ref_schema.clone(), key.ref_table.clone());
                let collated = collated_columns(link, catalog, &referenced, budget)?;
                budget.charge_texts(parent.0.iter().chain([&parent.1]))?;
                parents.entry(parent).or_insert(collated)
            }
        };
        let parent_compares_alike = !key
            .ref_columns
            .iter()
            .any(|column| collated.iter().any(|name| name.eq_ignore_ascii_case(column)));
        outbound.push(OutboundForeignKey {
            key,
            parent_compares_alike,
        });
    }
    Ok(outbound)
}

/// The columns of a table declared with a collation, as its stored SQL
/// spells them.
fn collated_columns(
    link: &Link,
    catalog: &str,
    table: &TableRef,
    budget: &mut CatalogBudget,
) -> Result<Vec<String>, DriverError> {
    let sql = table_sql(link, catalog, table, budget)?;
    let collated: Vec<String> = sql
        .as_deref()
        .map(|sql| {
            declared_columns(sql)
                .into_iter()
                .filter(|column| column.collation.is_some())
                .map(|column| column.name)
                .collect()
        })
        .unwrap_or_default();
    release(budget, sql);
    budget.charge_texts(&collated)?;
    Ok(collated)
}

fn release_names(budget: &mut CatalogBudget, names: &[String]) {
    for name in names {
        budget.release_text(name);
    }
}

fn split_names(joined: &str) -> Vec<String> {
    match joined.is_empty() {
        true => Vec::new(),
        false => joined.split('\u{1f}').map(str::to_owned).collect(),
    }
}

/// The keys of other tables that point at this one. DuckDB matches a key
/// byte for byte and refuses one whose two sides differ in type, so `=`
/// on the referencing columns finds the rows the key matches unless one
/// of them is declared with a collation.
pub(crate) fn inbound_foreign_keys(
    link: &Link,
    catalog: &str,
    table: &TableRef,
    budget: &mut CatalogBudget,
) -> Result<Vec<InboundForeignKey>, DriverError> {
    // Not the child's CREATE TABLE on every key: it grows with the keys the child declares.
    constraints_fit(link, catalog, table, Constraints::Referencing, budget)?;
    let rows = text_rows(
        link,
        "SELECT c.constraint_name, c.schema_name, c.table_name, \
                array_to_string(c.constraint_column_names, chr(31)), \
                array_to_string(c.referenced_column_names, chr(31)) \
         FROM duckdb_constraints() c \
         WHERE c.database_name = ? AND c.schema_name = ? AND c.referenced_table = ? \
           AND c.constraint_type = 'FOREIGN KEY' \
         ORDER BY c.table_name, c.constraint_index",
        &[catalog, schema_of(table), &table.name],
        budget,
    )?;
    let mut keys = Vec::with_capacity(rows.len());
    let mut child: Option<(TableRef, Vec<String>)> = None;
    for mut row in rows {
        let referencing = TableRef::new(Some(take(&mut row, 1)), take(&mut row, 2));
        // The rows come by child, so each child's CREATE TABLE is read once.
        if child.as_ref().is_none_or(|(read, _)| *read != referencing) {
            if let Some((_, collated)) = &child {
                release_names(budget, collated);
            }
            let collated = collated_columns(link, catalog, &referencing, budget)?;
            child = Some((referencing.clone(), collated));
        }
        let collated: &[String] = child.as_ref().map_or(&[], |(_, collated)| collated);
        let columns = split_names(&take(&mut row, 3));
        let compares_alike = !columns
            .iter()
            .any(|column| collated.iter().any(|name| name.eq_ignore_ascii_case(column)));
        keys.push(InboundForeignKey {
            name: take(&mut row, 0),
            table: referencing,
            child_compares_alike: compares_alike,
            columns,
            referenced_columns: split_names(&take(&mut row, 4)),
        });
    }
    Ok(keys)
}

/// How a row is named again: by the primary key, else by a UNIQUE key
/// whose columns are all NOT NULL. DuckDB's rowid moves when a
/// checkpoint compacts the table, so it names no row. Neither does a key
/// over a column declared with a collation: DuckDB keeps the key unique
/// byte for byte, while `=` and ORDER BY compare under the collation, so
/// `'ABC'` and `'abc'` are two rows one predicate finds.
pub(crate) fn row_identity(
    link: &Link,
    catalog: &str,
    table: &TableRef,
    budget: &mut CatalogBudget,
) -> Result<RowIdentity, DriverError> {
    let collated = collated_columns(link, catalog, table, budget)?;
    let compares_bytes = |columns: &[String]| {
        !columns
            .iter()
            .any(|column| collated.iter().any(|name| name.eq_ignore_ascii_case(column)))
    };
    let constraints = key_constraints(link, catalog, table, budget)?;
    if let Some((_, _, columns)) = constraints
        .iter()
        .find(|(_, kind, columns)| kind == "PRIMARY KEY" && compares_bytes(columns))
    {
        return Ok(RowIdentity::UniqueKey {
            columns: columns.clone(),
        });
    }
    let not_null: HashSet<String> = fetch_columns(link, catalog, table, budget)?
        .into_iter()
        .filter(|column| !column.nullable)
        .map(|column| column.name)
        .collect();
    let unique = constraints
        .into_iter()
        .filter(|(_, kind, columns)| kind == "UNIQUE" && compares_bytes(columns))
        .map(|(_, _, columns)| columns)
        .find(|columns| columns.iter().all(|column| not_null.contains(column)));
    Ok(match unique {
        Some(columns) => RowIdentity::UniqueKey { columns },
        None => RowIdentity::Unordered,
    })
}

/// DuckDB's own row count for the table, which counts what its storage
/// holds rather than what a query would see.
pub(crate) fn table_estimate(link: &Link, catalog: &str, table: &TableRef) -> Result<TableEstimate, DriverError> {
    let rows = text_rows(
        link,
        "SELECT CAST(estimated_size AS VARCHAR) FROM duckdb_tables() \
         WHERE database_name = ? AND schema_name = ? AND table_name = ?",
        &[catalog, schema_of(table), &table.name],
        &mut CatalogBudget::default(),
    )?;
    let estimate = rows
        .first()
        .and_then(|row| row.first().cloned().flatten())
        .and_then(|count| count.parse::<u64>().ok());
    Ok(TableEstimate {
        rows: estimate.map_or(RowCountEstimate::Unknown, RowCountEstimate::Approximate),
        heap_blocks: None,
    })
}

/// The table as structure changes plan against it.
pub(crate) fn fetch_table_definition(
    link: &Link,
    catalog: &str,
    table: &TableRef,
    budget: &mut CatalogBudget,
) -> Result<TableDefinition, DriverError> {
    let create_sql = table_sql(link, catalog, table, budget)?;
    let columns = fetch_columns(link, catalog, table, budget)?;
    let check_columns = check_constraints(link, catalog, table, budget)?;
    let collations: Vec<(String, String)> = create_sql
        .as_deref()
        .map(declared_columns)
        .unwrap_or_default()
        .into_iter()
        .filter_map(|column| Some((column.name, column.collation?)))
        .collect();
    let definitions = columns
        .into_iter()
        .map(|info| {
            let generated = info
                .is_generated
                .then(|| generation_expression(link, catalog, table, &info.name))
                .flatten()
                .map(|expression| GeneratedColumn {
                    expression,
                    storage: GeneratedStorage::Virtual,
                });
            let collation = collations
                .iter()
                .find(|(name, _)| name.eq_ignore_ascii_case(&info.name))
                .map(|(_, collation)| CollationName::new(None, collation.clone()));
            let attributes = ColumnAttributes {
                generated,
                collation,
                check: check_columns.get(&info.name).cloned(),
                identity: match info.is_auto_increment {
                    true => IdentityStyle::SequenceDefault,
                    false => IdentityStyle::None,
                },
                ..ColumnAttributes::default()
            };
            ColumnDefinition::new(info, attributes)
        })
        .collect();
    let indexes = fetch_indexes(link, catalog, table, budget)?;
    let source = match create_sql {
        Some(create_statement) => Some(TableSource {
            create_statement,
            // Missing indexes would be dropped by a rebuild, so a definition past the budget is no definition.
            dependents: match dependent_sources(link, catalog, table, budget) {
                Err(error @ DriverError::CatalogTooLarge { .. }) => return Err(error),
                read => read.unwrap_or_default(),
            },
        }),
        None => None,
    };
    Ok(TableDefinition {
        table: TableRef::new(Some(schema_of(table).to_owned()), table.name.clone()),
        columns: definitions,
        primary_key: primary_key(link, catalog, table, budget)?,
        indexes,
        foreign_keys: fetch_foreign_keys(link, catalog, table, budget)?,
        inbound_foreign_keys: inbound_foreign_keys(link, catalog, table, budget)?,
        source,
        options: None,
    })
}

/// A generated column's expression: what DuckDB lists as its default.
fn generation_expression(link: &Link, catalog: &str, table: &TableRef, column: &str) -> Option<SqlExpression> {
    let rows = text_rows(
        link,
        "SELECT column_default FROM duckdb_columns() \
         WHERE database_name = ? AND schema_name = ? AND table_name = ? AND column_name = ?",
        &[catalog, schema_of(table), &table.name, column],
        &mut CatalogBudget::default(),
    )
    .ok()?;
    rows.first()
        .and_then(|row| row.first().cloned().flatten())
        .map(SqlExpression::from_catalog_text)
}

/// The CHECK constraints each column is part of, joined with AND. A
/// CHECK over several columns is every one's: DuckDB refuses a new type
/// for any column a CHECK names, and takes the expression back on the
/// column itself.
fn check_constraints(
    link: &Link,
    catalog: &str,
    table: &TableRef,
    budget: &mut CatalogBudget,
) -> Result<std::collections::HashMap<String, SqlExpression>, DriverError> {
    constraints_fit(link, catalog, table, Constraints::Own, budget)?;
    let rows = text_rows(
        link,
        "SELECT array_to_string(constraint_column_names, chr(31)), expression FROM duckdb_constraints() \
         WHERE database_name = ? AND schema_name = ? AND table_name = ? AND constraint_type = 'CHECK' \
         ORDER BY constraint_index",
        &[catalog, schema_of(table), &table.name],
        budget,
    )?;
    // A CHECK over every column is each column's, so its text is held once per column it names.
    let mut checks: std::collections::HashMap<String, Vec<usize>> = std::collections::HashMap::new();
    for (index, row) in rows.iter().enumerate() {
        if row.get(1).is_some_and(Option::is_some) {
            for column in split_names(&text(row, 0)) {
                checks.entry(column).or_default().push(index);
            }
        }
    }
    let expression = |index: &usize| {
        rows.get(*index)
            .map_or("", |row| row.get(1).and_then(Option::as_deref).unwrap_or(""))
    };
    checks
        .into_iter()
        .map(|(column, expressions)| {
            let joined = match expressions.as_slice() {
                [only] => expression(only).to_owned(),
                many => many
                    .iter()
                    .map(|one| format!("({})", expression(one)))
                    .collect::<Vec<_>>()
                    .join(" AND "),
            };
            Ok((column, SqlExpression::from_catalog_text(budget.keep(joined)?)))
        })
        .collect()
}

/// The indexes created on the table, which a table rebuilt from its
/// CREATE TABLE text would lose.
fn dependent_sources(
    link: &Link,
    catalog: &str,
    table: &TableRef,
    budget: &mut CatalogBudget,
) -> Result<Vec<SchemaObjectSource>, DriverError> {
    let rows = text_rows(
        link,
        "SELECT index_name, sql FROM duckdb_indexes() \
         WHERE database_name = ? AND schema_name = ? AND table_name = ? AND sql IS NOT NULL ORDER BY index_name",
        &[catalog, schema_of(table), &table.name],
        budget,
    )?;
    rows.into_iter()
        .map(|mut row| {
            Ok(SchemaObjectSource {
                kind: SchemaObjectKind::Index,
                name: take(&mut row, 0),
                table: budget.keep(table.name.clone())?,
                sql: take(&mut row, 1),
            })
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use tablepro_core::column::{ColumnKind, IntegerKind, IntegerWidth};

    use super::*;

    #[test]
    fn an_index_statement_names_its_catalog() {
        let target = "\"dd\".\"main\".\"t\"";

        assert_eq!(
            on_own_table("CREATE INDEX i0 ON t(a)", target).as_deref(),
            Some("CREATE INDEX i0 ON \"dd\".\"main\".\"t\"(a)")
        );
        assert_eq!(
            on_own_table(
                "CREATE UNIQUE INDEX \"we\"\"ird\" ON s.\"T t\"((lower(b)))",
                "\"dd\".\"s\".\"T t\""
            )
            .as_deref(),
            Some("CREATE UNIQUE INDEX \"we\"\"ird\" ON \"dd\".\"s\".\"T t\"((lower(b)))")
        );
        assert_eq!(on_own_table("CREATE INDEX \"open ON t(a)", target), None);
    }

    #[test]
    fn a_literal_default_reads_as_its_value() {
        let integer = column_type_from_text("INTEGER");
        let text = column_type_from_text("VARCHAR");

        assert_eq!(
            classify_default(Some("42"), &integer),
            ColumnDefault::Literal(Value::Int(42))
        );
        assert_eq!(
            classify_default(Some("'it''s'"), &text),
            ColumnDefault::Literal(Value::Text("it's".to_owned()))
        );
        assert_eq!(classify_default(Some("NULL"), &text), ColumnDefault::None);
        assert!(matches!(
            classify_default(Some("current_timestamp"), &column_type_from_text("TIMESTAMP")),
            ColumnDefault::Expression(expression) if expression.as_sql() == "current_timestamp"
        ));
        assert_eq!(classify_default(None, &integer), ColumnDefault::None);
        assert_eq!(
            integer.kind,
            ColumnKind::Integer(IntegerKind {
                width: IntegerWidth::W32,
                signed: true
            })
        );
    }

    #[test]
    fn a_sequence_default_numbers_the_column() {
        assert!(is_sequence_default(Some("nextval('s1')")));
        assert!(!is_sequence_default(Some("'nextval'")));
        assert!(!is_sequence_default(None));
    }

    #[test]
    fn an_index_key_that_names_a_column_reads_as_one() {
        let columns: HashSet<String> = ["note".to_owned(), "Odd Name".to_owned()].into_iter().collect();

        assert_eq!(
            index_key("note", &columns),
            IndexKey::Column {
                name: "note".to_owned(),
                descending: false
            }
        );
        assert_eq!(
            index_key("\"Odd Name\"", &columns),
            IndexKey::Column {
                name: "Odd Name".to_owned(),
                descending: false
            }
        );
        assert_eq!(
            index_key("(lower(note))", &columns),
            IndexKey::Expression {
                sql: "(lower(note))".to_owned(),
                descending: false
            }
        );
    }
}
