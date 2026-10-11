use std::io;

use crate::sql_dialect::BuildSqlError;

#[derive(Debug, thiserror::Error)]
pub enum ExportError {
    #[error("{0}")]
    Write(#[from] io::Error),
    #[error("The export was cancelled")]
    Cancelled,
    #[error("This connection cannot produce SQL statements")]
    SqlLiteralsUnsupported { driver_id: String },
    #[error("A SQL export needs the table the rows came from")]
    MissingSqlTarget,
    #[error(transparent)]
    Statement(#[from] BuildSqlError),
    #[error("An Excel worksheet holds at most {limit} rows and this result has {rows}")]
    WorkbookTooLarge { limit: usize, rows: usize },
    #[error("An Excel worksheet holds at most 16384 columns and this result has {columns}")]
    WorkbookColumnLimit { columns: usize },
    #[error(
        "Workbook export cannot preserve empty text at row {row}, column {column}. Export as CSV or JSON to keep empty text distinct from NULL"
    )]
    WorkbookEmptyText { row: usize, column: usize },
    #[error(
        "XML 1.0 cannot preserve U+{codepoint:04X} at row {row}, column {column}. Export as JSON to keep the original text"
    )]
    XmlCharacter { row: usize, column: usize, codepoint: u32 },
    #[error(
        "HTML cannot preserve U+{codepoint:04X} at row {row}, column {column}. Export as JSON to keep the original text"
    )]
    HtmlCharacter { row: usize, column: usize, codepoint: u32 },
    #[error(
        "The text {marker} that stands for NULL also appears as a value at row {row}. Export as JSON or choose another format"
    )]
    NullMarkerCollision { marker: String, row: usize },
    #[error("The rows could not be read: {0}")]
    Source(String),
    #[error("The Excel workbook could not be built")]
    Workbook(#[from] rust_xlsxwriter::XlsxError),
}

impl ExportError {
    pub fn is_cancelled(&self) -> bool {
        matches!(self, Self::Cancelled)
    }
}
