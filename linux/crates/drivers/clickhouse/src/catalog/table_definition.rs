use clickhouse::sql::Identifier;
use tablepro_core::DriverError;
use tablepro_core::ddl::{ColumnDefinition, PrimaryKeyConstraint, TableDefinition, TableSource};
use tablepro_core::meta::TableRef;

use super::{CatalogTable, column_rows, fetch_indexes, table_keys};
use crate::call_client::CallClient;
use crate::key_expression::columns_in_key_order;
use crate::result_reader::{CatalogRow, read_table};

/// The table as structure changes plan against it. ClickHouse has no
/// foreign keys, so nothing points at it from elsewhere.
pub(crate) async fn fetch_table_definition(
    calls: &CallClient,
    table: &TableRef,
    catalog: &CatalogTable,
) -> Result<TableDefinition, DriverError> {
    let rows = column_rows(calls, catalog).await?;
    let keys = table_keys(calls, catalog).await?;
    let primary: Vec<String> = rows
        .iter()
        .filter(|row| row.in_primary_key)
        .map(|row| row.name.clone())
        .collect();
    let primary_key = (!primary.is_empty()).then(|| PrimaryKeyConstraint {
        name: None,
        columns: columns_in_key_order(&keys.primary_key, &primary),
    });
    let columns = rows
        .iter()
        .map(|row| ColumnDefinition::new(row.info(), row.attributes()))
        .collect();
    let indexes = fetch_indexes(calls, catalog).await?;
    let source = create_statement(calls, catalog).await?;
    Ok(TableDefinition {
        table: table.clone(),
        columns,
        primary_key,
        indexes,
        foreign_keys: Vec::new(),
        inbound_foreign_keys: Vec::new(),
        source: source.map(|create_statement| TableSource {
            create_statement,
            dependents: Vec::new(),
        }),
    })
}

/// SHOW CREATE TABLE names the table in SQL, so its name is bound as an
/// identifier by the client rather than quoted here.
async fn create_statement(calls: &CallClient, catalog: &CatalogTable) -> Result<Option<String>, DriverError> {
    let query = calls
        .template("SHOW CREATE TABLE ?.?")?
        .bind(Identifier(&catalog.database))
        .bind(Identifier(&catalog.name));
    let result = read_table(query, None).await?;
    result.rows.first().map(|row| CatalogRow(row).text(0)).transpose()
}
