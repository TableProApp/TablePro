use std::sync::Arc;

use tablepro_core::Value;
use tablepro_core::column::ResultColumn;
use tablepro_core::dialect::SqlDialect;
use tablepro_core::export::{self, CsvEncoder, CsvOptions, JsonArrayEncoder, MarkdownEncoder, RenderError, RowEncoder};

/// What an export writes.
#[derive(Debug, Clone)]
pub(crate) enum ExportFormat {
    /// Encoded a row at a time, as the rows arrive.
    Rows(RowFormat),
    /// Rendered whole on the blocking pool: a workbook is a zip archive
    /// written once the last row is in, and the HTML, XML and SQL
    /// writers build their text in one piece.
    Document(DocumentFormat),
}

#[derive(Debug, Clone)]
pub(crate) enum RowFormat {
    Csv(CsvOptions),
    Json,
    Markdown,
}

impl RowFormat {
    /// An encoder for rows under `columns`, the ones the stream itself
    /// announced.
    pub(crate) fn encoder(&self, columns: Arc<[ResultColumn]>) -> Box<dyn RowEncoder> {
        match self {
            Self::Csv(options) => Box::new(CsvEncoder::new(columns, options.clone())),
            Self::Json => Box::new(JsonArrayEncoder::new(columns)),
            Self::Markdown => Box::new(MarkdownEncoder::new(columns)),
        }
    }
}

#[derive(Debug, Clone)]
pub(crate) enum DocumentFormat {
    Xlsx { sheet: String },
    Html { title: String },
    Xml,
    Sql(InsertTarget),
}

impl DocumentFormat {
    pub(crate) fn render(&self, columns: &[ResultColumn], rows: &[Vec<Value>]) -> Result<Vec<u8>, RenderError> {
        match self {
            Self::Xlsx { sheet } => export::render_xlsx(columns, rows, sheet),
            Self::Html { title } => Ok(export::render_html(columns, rows, title).into_bytes()),
            Self::Xml => Ok(export::render_xml(columns, rows).into_bytes()),
            Self::Sql(target) => {
                Ok(export::render_sql_insert(&*target.dialect, &target.table, columns, rows).into_bytes())
            }
        }
    }
}

/// A table to insert into and the spelling of the server the rows came
/// from. SQL is offered only with both.
#[derive(Debug, Clone)]
pub(crate) struct InsertTarget {
    pub table: String,
    pub dialect: Arc<dyn SqlDialect>,
}
