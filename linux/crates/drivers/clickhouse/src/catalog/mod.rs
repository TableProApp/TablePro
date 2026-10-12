//! What `system.columns` and `system.tables` say about one table.

mod clickhouse_column_row;
mod table_definition;

use clickhouse::query::Query;
use tablepro_core::DriverError;
use tablepro_core::meta::{IndexInfo, RowIdentity, TableEstimate};

pub(crate) use clickhouse_column_row::ClickHouseColumnRow;
pub(crate) use table_definition::fetch_table_definition;

use crate::call_client::CallClient;
use crate::key_expression::{columns_in_key_order, index_keys};
use crate::result_reader::{CatalogRow, read_table};
use clickhouse_column_row::COLUMN_SELECT;
use tablepro_core::meta::RowCountEstimate;

/// A table, as the catalogue queries name it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct CatalogTable {
    pub(crate) database: String,
    pub(crate) name: String,
}

impl CatalogTable {
    fn bind(&self, query: Query) -> Query {
        query
            .param("db", self.database.as_str())
            .param("tbl", self.name.as_str())
    }
}

/// The keys `system.tables` keeps for a table.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub(crate) struct TableKeys {
    pub(crate) sorting_key: String,
    pub(crate) primary_key: String,
    pub(crate) total_rows: Option<u64>,
}

pub(crate) async fn column_rows(
    calls: &CallClient,
    table: &CatalogTable,
) -> Result<Vec<ClickHouseColumnRow>, DriverError> {
    let result = read_table(table.bind(calls.raw(COLUMN_SELECT)), None).await?;
    result.rows.iter().map(|row| ClickHouseColumnRow::read(row)).collect()
}

pub(crate) async fn table_keys(calls: &CallClient, table: &CatalogTable) -> Result<TableKeys, DriverError> {
    let sql = "SELECT sorting_key, primary_key, total_rows FROM system.tables \
               WHERE database = {db:String} AND name = {tbl:String}";
    let result = read_table(table.bind(calls.raw(sql)), None).await?;
    let Some(row) = result.rows.first() else {
        return Ok(TableKeys::default());
    };
    let row = CatalogRow(row);
    Ok(TableKeys {
        sorting_key: row.text(0)?,
        primary_key: row.text(1)?,
        total_rows: row.optional_u64(2)?,
    })
}

/// The sorting key as the table's primary index, then its skipping
/// indexes. A MergeTree key is sparse and allows duplicates, so none of
/// them is unique.
pub(crate) async fn fetch_indexes(calls: &CallClient, table: &CatalogTable) -> Result<Vec<IndexInfo>, DriverError> {
    let keys = table_keys(calls, table).await?;
    let mut indexes = Vec::new();
    let sorting = index_keys(&keys.sorting_key);
    if !sorting.is_empty() {
        indexes.push(IndexInfo {
            name: format!("{}_sorting_key", table.name),
            keys: sorting,
            unique: false,
            primary: true,
            predicate: None,
        });
    }
    let sql = "SELECT name, expr FROM system.data_skipping_indices \
               WHERE database = {db:String} AND table = {tbl:String} ORDER BY name";
    let skipping = read_table(table.bind(calls.raw(sql)), None).await?;
    for row in &skipping.rows {
        let row = CatalogRow(row);
        indexes.push(IndexInfo {
            name: row.text(0)?,
            keys: index_keys(&row.text(1)?),
            unique: false,
            primary: false,
            predicate: None,
        });
    }
    Ok(indexes)
}

/// The sorting key's columns name a row well enough to probe for, but
/// not uniquely: duplicates are legal, so every write proves its row.
pub(crate) async fn row_identity(calls: &CallClient, table: &CatalogTable) -> Result<RowIdentity, DriverError> {
    let flagged: Vec<String> = column_rows(calls, table)
        .await?
        .into_iter()
        .filter(|row| row.in_sorting_key)
        .map(|row| row.name)
        .collect();
    if flagged.is_empty() {
        return Ok(RowIdentity::Unordered);
    }
    let keys = table_keys(calls, table).await?;
    Ok(RowIdentity::SortingKey {
        expressions: columns_in_key_order(&keys.sorting_key, &flagged),
    })
}

/// MergeTree keeps an exact count in its metadata; an engine that does
/// not reports NULL.
pub(crate) async fn table_estimate(calls: &CallClient, table: &CatalogTable) -> Result<TableEstimate, DriverError> {
    let keys = table_keys(calls, table).await?;
    Ok(TableEstimate {
        rows: keys
            .total_rows
            .map_or(RowCountEstimate::Unknown, RowCountEstimate::Exact),
        heap_blocks: None,
    })
}
