//! What the database holds, read from DuckDB's `duckdb_*()` functions.
//!
//! Every read names the file's own catalogue: a database attached in an
//! editor tab lists in the same functions, and its tables are not this
//! connection's to browse. The functions work with no extension loaded.

mod declared_columns;

use std::collections::HashSet;

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
use tablepro_core::{DriverError, ForeignKeyInfo};

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
fn text_rows(link: &Link, sql: &str, params: &[&str]) -> Result<Vec<Vec<Option<String>>>, DriverError> {
    let mut statement = link.connection.prepare(sql).map_err(map_error)?;
    let mut rows = statement
        .query(duckdb::params_from_iter(params.iter()))
        .map_err(map_error)?;
    let width = rows.as_ref().map_or(0, duckdb::Statement::column_count);
    let mut read = Vec::new();
    while let Some(row) = rows.next().map_err(map_error)? {
        let mut values = Vec::with_capacity(width);
        for index in 0..width {
            values.push(row.get::<_, Option<String>>(index).map_err(map_error)?);
        }
        read.push(values);
    }
    Ok(read)
}

fn text(row: &[Option<String>], index: usize) -> String {
    row.get(index).cloned().flatten().unwrap_or_default()
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

pub(crate) fn list_objects(link: &Link, catalog: &str, scope: &ObjectScope) -> Result<Vec<ObjectInfo>, DriverError> {
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
            schema: Some(row.get(0).map_err(map_error)?),
            name: row.get(1).map_err(map_error)?,
            kind: match kind.as_str() {
                "view" => ObjectKind::View,
                _ => ObjectKind::Table,
            },
        });
    }
    Ok(objects)
}

/// A table's columns, with the primary key marked and the generated
/// columns told apart from defaults.
pub(crate) fn fetch_columns(link: &Link, catalog: &str, table: &TableRef) -> Result<Vec<ColumnInfo>, DriverError> {
    let schema = schema_of(table);
    let rows = text_rows(
        link,
        "SELECT column_name, data_type, CAST(is_nullable AS VARCHAR), column_default, comment \
         FROM duckdb_columns() WHERE database_name = ? AND schema_name = ? AND table_name = ? \
         ORDER BY column_index",
        &[catalog, schema, &table.name],
    )?;
    let keys = primary_key(link, catalog, table)?
        .map(|key| key.columns)
        .unwrap_or_default();
    let generated: HashSet<String> = table_sql(link, catalog, table)?
        .map(|sql| {
            declared_columns(&sql)
                .into_iter()
                .filter(|column| column.generated)
                .map(|column| column.name)
                .collect()
        })
        .unwrap_or_default();
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
fn table_sql(link: &Link, catalog: &str, table: &TableRef) -> Result<Option<String>, DriverError> {
    let rows = text_rows(
        link,
        "SELECT sql FROM duckdb_tables() WHERE database_name = ? AND schema_name = ? AND table_name = ?",
        &[catalog, schema_of(table), &table.name],
    )?;
    Ok(rows.first().and_then(|row| row.first().cloned().flatten()))
}

/// The columns of a table's PRIMARY KEY and UNIQUE constraints, in key
/// order, by constraint.
fn key_constraints(
    link: &Link,
    catalog: &str,
    table: &TableRef,
) -> Result<Vec<(String, String, Vec<String>)>, DriverError> {
    let rows = text_rows(
        link,
        "SELECT constraint_name, constraint_type, array_to_string(constraint_column_names, chr(31)) \
         FROM duckdb_constraints() \
         WHERE database_name = ? AND schema_name = ? AND table_name = ? \
           AND constraint_type IN ('PRIMARY KEY', 'UNIQUE') \
         ORDER BY constraint_index",
        &[catalog, schema_of(table), &table.name],
    )?;
    Ok(rows
        .iter()
        .map(|row| (text(row, 0), text(row, 1), split_names(&text(row, 2))))
        .collect())
}

pub(crate) fn primary_key(
    link: &Link,
    catalog: &str,
    table: &TableRef,
) -> Result<Option<PrimaryKeyConstraint>, DriverError> {
    Ok(key_constraints(link, catalog, table)?
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
pub(crate) fn fetch_indexes(link: &Link, catalog: &str, table: &TableRef) -> Result<Vec<IndexInfo>, DriverError> {
    let mut indexes: Vec<IndexInfo> = key_constraints(link, catalog, table)?
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
    let columns: HashSet<String> = fetch_columns(link, catalog, table)?
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
) -> Result<Vec<ForeignKeyInfo>, DriverError> {
    let rows = text_rows(
        link,
        "SELECT constraint_name, referenced_table, \
                array_to_string(constraint_column_names, chr(31)), \
                array_to_string(referenced_column_names, chr(31)) \
         FROM duckdb_constraints() \
         WHERE database_name = ? AND schema_name = ? AND table_name = ? AND constraint_type = 'FOREIGN KEY' \
         ORDER BY constraint_index",
        &[catalog, schema_of(table), &table.name],
    )?;
    let schema = schema_of(table).to_owned();
    Ok(rows
        .iter()
        .map(|row| ForeignKeyInfo {
            name: text(row, 0),
            columns: split_names(&text(row, 2)),
            ref_schema: Some(schema.clone()),
            ref_table: text(row, 1),
            ref_columns: split_names(&text(row, 3)),
            on_delete: Some(ReferentialAction::NoAction),
            on_update: Some(ReferentialAction::NoAction),
        })
        .collect())
}

/// The table's own keys, each with whether `=` on the referenced columns
/// finds the rows it matches: not when one of them is declared with a
/// collation, since DuckDB matches a key byte for byte.
pub(crate) fn outbound_foreign_keys(
    link: &Link,
    catalog: &str,
    table: &TableRef,
) -> Result<Vec<OutboundForeignKey>, DriverError> {
    let keys = fetch_foreign_keys(link, catalog, table)?;
    let mut outbound = Vec::with_capacity(keys.len());
    for key in keys {
        let referenced = TableRef::new(key.ref_schema.clone(), key.ref_table.clone());
        let collated = collated_columns(link, catalog, &referenced)?;
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
fn collated_columns(link: &Link, catalog: &str, table: &TableRef) -> Result<Vec<String>, DriverError> {
    Ok(table_sql(link, catalog, table)?
        .map(|sql| {
            declared_columns(&sql)
                .into_iter()
                .filter(|column| column.collation.is_some())
                .map(|column| column.name)
                .collect()
        })
        .unwrap_or_default())
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
) -> Result<Vec<InboundForeignKey>, DriverError> {
    let rows = text_rows(
        link,
        "SELECT c.constraint_name, c.schema_name, c.table_name, \
                array_to_string(c.constraint_column_names, chr(31)), \
                array_to_string(c.referenced_column_names, chr(31)), t.sql \
         FROM duckdb_constraints() c \
         JOIN duckdb_tables() t \
           ON t.database_name = c.database_name AND t.schema_name = c.schema_name AND t.table_name = c.table_name \
         WHERE c.database_name = ? AND c.schema_name = ? AND c.referenced_table = ? \
           AND c.constraint_type = 'FOREIGN KEY' \
         ORDER BY c.table_name, c.constraint_index",
        &[catalog, schema_of(table), &table.name],
    )?;
    Ok(rows
        .iter()
        .map(|row| {
            let columns = split_names(&text(row, 3));
            let collated: Vec<String> = declared_columns(&text(row, 5))
                .into_iter()
                .filter(|column| column.collation.is_some())
                .map(|column| column.name)
                .collect();
            let compares_alike = !columns
                .iter()
                .any(|column| collated.iter().any(|name| name.eq_ignore_ascii_case(column)));
            InboundForeignKey {
                name: text(row, 0),
                table: TableRef::new(Some(text(row, 1)), text(row, 2)),
                child_compares_alike: compares_alike,
                columns,
                referenced_columns: split_names(&text(row, 4)),
            }
        })
        .collect())
}

/// How a row is named again: by the primary key, else by a UNIQUE key
/// whose columns are all NOT NULL. DuckDB's rowid moves when a
/// checkpoint compacts the table, so it names no row. Neither does a key
/// over a column declared with a collation: DuckDB keeps the key unique
/// byte for byte, while `=` and ORDER BY compare under the collation, so
/// `'ABC'` and `'abc'` are two rows one predicate finds.
pub(crate) fn row_identity(link: &Link, catalog: &str, table: &TableRef) -> Result<RowIdentity, DriverError> {
    let collated = collated_columns(link, catalog, table)?;
    let compares_bytes = |columns: &[String]| {
        !columns
            .iter()
            .any(|column| collated.iter().any(|name| name.eq_ignore_ascii_case(column)))
    };
    let constraints = key_constraints(link, catalog, table)?;
    if let Some((_, _, columns)) = constraints
        .iter()
        .find(|(_, kind, columns)| kind == "PRIMARY KEY" && compares_bytes(columns))
    {
        return Ok(RowIdentity::UniqueKey {
            columns: columns.clone(),
        });
    }
    let not_null: HashSet<String> = fetch_columns(link, catalog, table)?
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
) -> Result<TableDefinition, DriverError> {
    let create_sql = table_sql(link, catalog, table)?;
    let columns = fetch_columns(link, catalog, table)?;
    let check_columns = check_constraints(link, catalog, table)?;
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
    let indexes = fetch_indexes(link, catalog, table)?;
    let source = create_sql.map(|create_statement| TableSource {
        create_statement,
        dependents: dependent_sources(link, catalog, table).unwrap_or_default(),
    });
    Ok(TableDefinition {
        table: TableRef::new(Some(schema_of(table).to_owned()), table.name.clone()),
        columns: definitions,
        primary_key: primary_key(link, catalog, table)?,
        indexes,
        foreign_keys: fetch_foreign_keys(link, catalog, table)?,
        inbound_foreign_keys: inbound_foreign_keys(link, catalog, table)?,
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
) -> Result<std::collections::HashMap<String, SqlExpression>, DriverError> {
    let rows = text_rows(
        link,
        "SELECT array_to_string(constraint_column_names, chr(31)), expression FROM duckdb_constraints() \
         WHERE database_name = ? AND schema_name = ? AND table_name = ? AND constraint_type = 'CHECK' \
         ORDER BY constraint_index",
        &[catalog, schema_of(table), &table.name],
    )?;
    let mut checks: std::collections::HashMap<String, Vec<String>> = std::collections::HashMap::new();
    for row in &rows {
        let Some(expression) = row.get(1).cloned().flatten() else {
            continue;
        };
        for column in split_names(&text(row, 0)) {
            checks.entry(column).or_default().push(expression.clone());
        }
    }
    Ok(checks
        .into_iter()
        .map(|(column, expressions)| {
            let joined = match expressions.as_slice() {
                [only] => only.clone(),
                many => many
                    .iter()
                    .map(|one| format!("({one})"))
                    .collect::<Vec<_>>()
                    .join(" AND "),
            };
            (column, SqlExpression::from_catalog_text(joined))
        })
        .collect())
}

/// The indexes created on the table, which a table rebuilt from its
/// CREATE TABLE text would lose.
fn dependent_sources(link: &Link, catalog: &str, table: &TableRef) -> Result<Vec<SchemaObjectSource>, DriverError> {
    let rows = text_rows(
        link,
        "SELECT index_name, sql FROM duckdb_indexes() \
         WHERE database_name = ? AND schema_name = ? AND table_name = ? AND sql IS NOT NULL ORDER BY index_name",
        &[catalog, schema_of(table), &table.name],
    )?;
    Ok(rows
        .iter()
        .map(|row| SchemaObjectSource {
            kind: SchemaObjectKind::Index,
            name: text(row, 0),
            table: table.name.clone(),
            sql: text(row, 1),
        })
        .collect())
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
