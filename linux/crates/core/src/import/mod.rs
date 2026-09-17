//! Reading a file into a table, which is the other direction from
//! `export`.

mod csv_import;

pub use csv_import::{
    CsvImportOptions, CsvRowError, CsvSheet, ImportError, MAX_PREVIEW_ROWS, read_csv, row_to_cells, suggest_mapping,
};
