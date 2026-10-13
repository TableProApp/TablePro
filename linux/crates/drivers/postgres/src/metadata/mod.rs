//! The catalogue reads behind the sidebar, the grid and the structure
//! tab. Every statement projects built-in types only, so none of them
//! makes tokio-postgres look a type up with a named statement.

mod estimate;
mod foreign_keys;
mod identity;
mod indexes;
mod objects;

pub(crate) use estimate::table_estimate;
pub(crate) use foreign_keys::fetch_foreign_keys;
pub(crate) use identity::row_identity;
pub(crate) use indexes::fetch_indexes;
pub(crate) use objects::{list_objects, list_schemas};

use futures_util::TryStreamExt;
use postgres_types::{ToSql, Type};
use tablepro_core::DriverError;
use tablepro_core::column::ColumnInfo;
use tablepro_core::ddl::{PrimaryKeyConstraint, TableDefinition};
use tablepro_core::meta::TableRef;
use tokio_postgres::{Client, Row};

use crate::catalog::{
    COLUMNS_SQL, INBOUND_FOREIGN_KEYS_SQL, PRIMARY_KEY_NAME_SQL, PgColumnRow, column_definition, column_info,
    inbound_foreign_key,
};
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
pub(crate) async fn fetch_columns(client: &Client, relation: &str) -> Result<Vec<ColumnInfo>, DriverError> {
    column_rows(client, relation)
        .await
        .map(|rows| rows.iter().map(column_info).collect())
}

async fn column_rows(client: &Client, relation: &str) -> Result<Vec<PgColumnRow>, DriverError> {
    text_rows(client, COLUMNS_SQL, &[relation])
        .await?
        .iter()
        .map(PgColumnRow::from_row)
        .collect()
}

pub(crate) async fn fetch_table_definition(
    client: &Client,
    table: &TableRef,
    relation: &str,
) -> Result<TableDefinition, DriverError> {
    // Every query is sent before the first answer is awaited, so all of
    // them run inside the flight's transaction, ahead of its COMMIT.
    let params = [relation];
    let (columns, primary_key, indexes, foreign_keys, inbound_foreign_keys) = futures_util::try_join!(
        column_rows(client, relation),
        text_rows(client, PRIMARY_KEY_NAME_SQL, &params),
        fetch_indexes(client, relation),
        fetch_foreign_keys(client, relation),
        text_rows(client, INBOUND_FOREIGN_KEYS_SQL, &params),
    )?;
    let primary_key = primary_key
        .first()
        .map(|row| -> Result<PrimaryKeyConstraint, DriverError> {
            let field = decode_error("pg_constraint");
            Ok(PrimaryKeyConstraint {
                name: Some(row.try_get(0).map_err(&field)?),
                columns: row.try_get(1).map_err(&field)?,
            })
        })
        .transpose()?;
    let inbound_foreign_keys = inbound_foreign_keys
        .iter()
        .map(inbound_foreign_key)
        .collect::<Result<_, _>>()?;
    Ok(TableDefinition {
        table: table.clone(),
        columns: columns.iter().map(column_definition).collect(),
        primary_key,
        indexes,
        foreign_keys,
        inbound_foreign_keys,
        // PostgreSQL has no statement that prints a table's own DDL.
        source: None,
    })
}
