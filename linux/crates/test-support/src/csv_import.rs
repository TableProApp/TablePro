//! The CSV import as the app runs it, from the file's bytes to the rows
//! in the table, so each driver's tests run it against the real engine.

use tablepro_core::dml::BuildSqlError;
use tablepro_core::import::{
    CsvImportOptions, CsvRowError, ImportColumn, ImportError, plan_import, read_csv, row_to_cells, suggest_mapping,
};
use tablepro_core::meta::TableRef;
use tablepro_core::{CallOptions, Connection, DriverError, WriteReport};

/// Where an import stopped.
#[derive(Debug)]
pub enum CsvImportFailure {
    Read(ImportError),
    Row(CsvRowError),
    Build(BuildSqlError),
    Driver(DriverError),
}

/// Import `csv` into `table`, each column taking the field its header
/// names, as the mapping dialog first suggests.
pub async fn import_csv(
    connection: &dyn Connection,
    table: &TableRef,
    csv: &[u8],
    options: &CsvImportOptions,
    call: CallOptions,
) -> Result<WriteReport, CsvImportFailure> {
    let definition = connection
        .fetch_table_definition(table, call.clone())
        .await
        .map_err(CsvImportFailure::Driver)?;
    let columns: Vec<ImportColumn> = definition.columns.iter().map(ImportColumn::from_definition).collect();
    let sheet = read_csv(csv, options, None).map_err(CsvImportFailure::Read)?;
    let mapping = suggest_mapping(&sheet.headers, &columns);
    let first_line = if options.has_header { 2 } else { 1 };
    let rows = sheet
        .rows
        .iter()
        .enumerate()
        .map(|(index, row)| row_to_cells(row, &mapping, &columns, options, first_line + index))
        .collect::<Result<Vec<_>, _>>()
        .map_err(CsvImportFailure::Row)?;
    let batch = plan_import(connection.dialect().as_ref(), table, &columns, &rows).map_err(CsvImportFailure::Build)?;
    connection
        .write_batch(&batch, call)
        .await
        .map_err(CsvImportFailure::Driver)
}
