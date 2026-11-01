//! The catalogue reads behind the sidebar, the grid and the structure
//! tab. Every statement projects built-in types only, so none of them
//! makes tokio-postgres look a type up with a named statement.

mod definitions;
mod estimate;
mod foreign_keys;
mod identity;
mod indexes;
mod objects;

pub(crate) use definitions::fetch_object_definition;
pub(crate) use estimate::table_estimate;
pub(crate) use foreign_keys::{fetch_foreign_keys, fetch_outbound_foreign_keys};
pub(crate) use identity::row_identity;
pub(crate) use indexes::fetch_indexes;
pub(crate) use objects::{list_databases, list_objects, list_schemas};

use futures_util::TryStreamExt;
use postgres_types::{ToSql, Type};
use tablepro_core::DriverError;
use tablepro_core::column::ColumnInfo;
use tablepro_core::ddl::{InboundForeignKey, PrimaryKeyConstraint, TableDefinition};
use tablepro_core::meta::TableRef;
use tokio_postgres::{Client, Row};

use crate::catalog::{
    PRIMARY_KEY_NAME_SQL, PgColumnRow, column_definition, column_info, inbound_foreign_key, inbound_foreign_keys_sql,
};
use crate::codec::TextArray;
use crate::errors::map_error;

/// Rows of a catalogue query whose parameters are all text.
pub(crate) async fn text_rows(client: &Client, sql: &str, params: &[&str]) -> Result<Vec<Row>, DriverError> {
    let typed: Vec<(&(dyn ToSql + Sync), Type)> = params
        .iter()
        .map(|param| (param as &(dyn ToSql + Sync), Type::TEXT))
        .collect();
    let stream = client
        .query_typed_raw(sql, typed)
        .await
        .map_err(|error| map_error(&error))?;
    stream.try_collect().await.map_err(|error| map_error(&error))
}

pub(crate) fn decode_error(table: &'static str) -> impl Fn(tokio_postgres::Error) -> DriverError {
    move |error| DriverError::Decode {
        column: table.to_owned(),
        detail: error.to_string(),
    }
}

/// `relation` is the table's quoted, qualified name, which `::regclass`
/// resolves the same way the server resolves it in a query.
/// `columns_sql` is the column query for the server's release.
pub(crate) async fn fetch_columns(
    client: &Client,
    columns_sql: &str,
    relation: &str,
) -> Result<Vec<ColumnInfo>, DriverError> {
    column_rows(client, columns_sql, relation)
        .await
        .map(|rows| rows.iter().map(column_info).collect())
}

async fn column_rows(client: &Client, columns_sql: &str, relation: &str) -> Result<Vec<PgColumnRow>, DriverError> {
    text_rows(client, columns_sql, &[relation])
        .await?
        .iter()
        .map(PgColumnRow::from_row)
        .collect()
}

pub(crate) async fn fetch_inbound_foreign_keys(
    client: &Client,
    relation: &str,
) -> Result<Vec<InboundForeignKey>, DriverError> {
    text_rows(client, &inbound_foreign_keys_sql(), &[relation])
        .await?
        .iter()
        .map(inbound_foreign_key)
        .collect()
}

pub(crate) async fn fetch_table_definition(
    client: &Client,
    columns_sql: &str,
    table: &TableRef,
    relation: &str,
) -> Result<TableDefinition, DriverError> {
    // Every query is sent before the first answer is awaited, so all of
    // them run inside the flight's transaction, ahead of its COMMIT.
    let params = [relation];
    let (columns, primary_key, indexes, foreign_keys, inbound_foreign_keys) = futures_util::try_join!(
        column_rows(client, columns_sql, relation),
        text_rows(client, PRIMARY_KEY_NAME_SQL, &params),
        fetch_indexes(client, relation),
        fetch_foreign_keys(client, relation),
        fetch_inbound_foreign_keys(client, relation),
    )?;
    let primary_key = primary_key
        .first()
        .map(|row| -> Result<PrimaryKeyConstraint, DriverError> {
            let field = decode_error("pg_constraint");
            Ok(PrimaryKeyConstraint {
                name: Some(row.try_get(0).map_err(&field)?),
                columns: row.try_get::<_, TextArray>(1).map_err(&field)?.0,
            })
        })
        .transpose()?;
    Ok(TableDefinition {
        table: table.clone(),
        columns: columns.iter().map(column_definition).collect(),
        primary_key,
        indexes,
        foreign_keys,
        inbound_foreign_keys,
        // PostgreSQL has no statement that prints a table's own DDL.
        source: None,
        options: None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::catalog::COLUMNS_SQL_BEFORE_14;

    /// Words that take a parenthesis without calling a function by name.
    const SYNTAX: [&str; 14] = [
        "AS", "ARRAY", "COALESCE", "EXISTS", "FROM", "IN", "ANY", "NULLIF", "GREATEST", "ON", "AND", "OR", "NOT",
        "OPERATOR",
    ];

    /// Names called without `pg_catalog.` in front, which the session's
    /// search_path would resolve. An alias's column list after AS is no
    /// call, and neither is text in a string.
    fn bare_calls(sql: &str) -> Vec<String> {
        let mut code = String::with_capacity(sql.len());
        let mut quoted = false;
        for c in sql.chars() {
            if c == '\'' {
                quoted = !quoted;
            }
            code.push(if quoted { ' ' } else { c });
        }
        let mut words: Vec<(usize, usize)> = Vec::new();
        let mut start = None;
        for (index, c) in code.char_indices().chain([(code.len(), ' ')]) {
            match (start, c.is_ascii_alphanumeric() || c == '_') {
                (None, true) => start = Some(index),
                (Some(from), false) => {
                    words.push((from, index));
                    start = None;
                }
                _ => {}
            }
        }
        let mut calls = Vec::new();
        for (nth, &(from, to)) in words.iter().enumerate() {
            let word = &code[from..to];
            let calls_it = code[to..].trim_start().starts_with('(');
            let qualified = code[..from].ends_with('.');
            let after_as = nth > 0 && code[words[nth - 1].0..words[nth - 1].1].eq_ignore_ascii_case("AS");
            let syntax = SYNTAX.iter().any(|keyword| keyword.eq_ignore_ascii_case(word));
            if calls_it && !qualified && !after_as && !syntax {
                calls.push(word.to_owned());
            }
        }
        calls
    }

    #[test]
    fn every_catalog_read_names_its_functions_in_pg_catalog() {
        for (name, sql) in [
            ("schemas", objects::SCHEMAS_SQL.to_owned()),
            ("objects", objects::OBJECTS_SQL.to_owned()),
            ("function definitions", definitions::FUNCTIONS_SQL.to_owned()),
            ("sequence definition", definitions::SEQUENCE_SQL.to_owned()),
            ("trigger definition", definitions::TRIGGER_SQL.to_owned()),
            ("identity", identity::IDENTITY_SQL.to_owned()),
            ("indexes", indexes::INDEXES_SQL.to_owned()),
            ("estimate", estimate::ESTIMATE_SQL.to_owned()),
            ("foreign keys", foreign_keys::foreign_keys_sql()),
            ("inbound foreign keys", inbound_foreign_keys_sql()),
            ("primary key", PRIMARY_KEY_NAME_SQL.to_owned()),
            ("columns", crate::catalog::COLUMNS_SQL.to_owned()),
            ("columns before 14", COLUMNS_SQL_BEFORE_14.to_owned()),
        ] {
            assert_eq!(bare_calls(&sql), Vec::<String>::new(), "{name}");
        }
    }

    #[test]
    fn a_bare_call_is_found_and_a_qualified_one_or_an_alias_is_not() {
        assert_eq!(
            bare_calls("SELECT unnest(a), pg_catalog.unnest(b), COALESCE(x, 'f(y)') FROM t AS k(a, b)"),
            ["unnest"]
        );
    }
}
