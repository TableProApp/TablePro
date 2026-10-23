//! Reading a file or pasted text into a table, which is the other
//! direction from `export`.

mod csv_import;
mod import_column;
mod import_plan;
mod pasted_rows;
mod pasted_table;

pub use csv_import::{
    CsvImportOptions, CsvRowError, CsvSheet, ImportError, MAX_CSV_FILE_BYTES, MAX_FIELDS, MAX_PREVIEW_ROWS, read_csv,
    row_to_cells, suggest_mapping,
};
pub use import_column::ImportColumn;
pub use import_plan::{ImportPlan, plan_import};
pub use pasted_rows::PastedRows;
pub use pasted_table::{MAX_PASTED_ROWS, PastedTable};
