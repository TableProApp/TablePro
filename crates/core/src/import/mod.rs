//! Reading a delimited file into rows a governed INSERT can bind.
//!
//! Everything here is pure: no connection, no execution, no I/O beyond
//! reading a file the caller names. The file is untrusted input, so every
//! dimension it controls is bounded before anything is allocated from it.

mod cell;
mod csv_import;
mod extended_temporal;
mod infer;
mod plan;

pub use cell::{CellError, ColumnKind, CsvRowError, column_kind, parse_cell, row_to_values};
pub use csv_import::{
    CsvFormat, CsvImportOptions, CsvSheet, ImportError, MAX_COLUMNS, MAX_FIELD_BYTES, MAX_FILE_BYTES, MAX_IMPORT_ROWS,
    MAX_PREVIEW_ROWS, detect_format, read_csv, read_csv_file, suggest_mapping,
};
pub use extended_temporal::duckdb_extended_timestamptz_nanos;
pub use infer::{INFER_SAMPLE_ROWS, infer_columns, supports_table_creation, type_name};
pub use plan::{
    DEFAULT_IMPORT_BATCH_ROWS, ImportTarget, InsertPlan, MAX_REPORTED_ROW_ERRORS, PlanError, build_insert_plan,
};
