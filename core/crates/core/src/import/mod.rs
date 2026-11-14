//! Reading a file or pasted text into a table, or a SQL file into a
//! connection, which is the other direction from `export` and `dump`.

mod csv_import;
mod import_column;
mod import_plan;
mod pasted_rows;
mod pasted_table;
mod sql_file;
mod sql_import;

pub use csv_import::{
    CsvImportOptions, CsvRecords, CsvRowError, CsvSheet, ImportError, MAX_CSV_FILE_BYTES, MAX_FIELDS, MAX_PREVIEW_ROWS,
    padded_row, read_csv, read_csv_records, row_to_cells, suggest_mapping,
};
pub use import_column::ImportColumn;
pub use import_plan::{ImportPlan, plan_import};
pub use pasted_rows::PastedRows;
pub use pasted_table::{MAX_PASTED_CELLS, MAX_PASTED_ROWS, PastedTable};
pub use sql_file::{SqlFileError, SqlFileReader};
pub use sql_import::{
    MAX_KEPT_FAILURES, SqlImportEnd, SqlImportErrorPolicy, SqlImportFailure, SqlImportFault, SqlImportOptions,
    SqlImportProgress, SqlImportReport, TransactionOutcome, run_sql_import,
};
