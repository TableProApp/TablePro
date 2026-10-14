use std::sync::Arc;

use tablepro_core::Value;
use tablepro_core::column::ResultColumn;
use tablepro_core::dialect::SqlDialect;
use tablepro_core::export::{
    self, CsvEncoder, CsvOptions, HtmlEncoder, JsonArrayEncoder, MarkdownEncoder, RenderError, RowEncoder,
    SqlInsertEncoder, XlsxSheetWriter, XmlEncoder,
};

/// What an export writes.
#[derive(Debug, Clone)]
pub(crate) enum ExportFormat {
    /// Encoded a row at a time, as the rows arrive.
    Rows(RowFormat),
    /// Written on the blocking pool as the rows arrive, and handed on
    /// whole once the last is in: a workbook is a zip archive.
    Document(DocumentFormat),
}

#[derive(Debug, Clone)]
pub(crate) enum RowFormat {
    Csv(CsvOptions),
    Json,
    Markdown,
    Html { title: String },
    Xml,
    Sql(InsertTarget),
}

impl RowFormat {
    /// An encoder for rows under `columns`, the ones the stream itself
    /// announced.
    pub(crate) fn encoder(&self, columns: Arc<[ResultColumn]>) -> Box<dyn RowEncoder> {
        match self {
            Self::Csv(options) => Box::new(CsvEncoder::new(columns, options.clone())),
            Self::Json => Box::new(JsonArrayEncoder::new(columns)),
            Self::Markdown => Box::new(MarkdownEncoder::new(columns)),
            Self::Html { title } => Box::new(HtmlEncoder::new(columns, title.clone())),
            Self::Xml => Box::new(XmlEncoder::new(columns)),
            Self::Sql(target) => Box::new(SqlInsertEncoder::new(target.dialect.clone(), &target.table, columns)),
        }
    }
}

#[derive(Debug, Clone)]
pub(crate) enum DocumentFormat {
    Xlsx { sheet: String },
}

impl DocumentFormat {
    /// The most rows the document can hold.
    pub(crate) fn row_limit(&self) -> usize {
        match self {
            Self::Xlsx { .. } => export::XLSX_MAX_DATA_ROWS,
        }
    }

    /// A document for rows under `columns`, written on the blocking
    /// pool.
    pub(crate) fn start(&self, columns: Arc<[ResultColumn]>) -> Result<DocumentWriter, RenderError> {
        match self {
            Self::Xlsx { sheet } => XlsxSheetWriter::new(columns, sheet).map(DocumentWriter::Xlsx),
        }
    }
}

/// A document part way through, which takes rows a batch at a time.
pub(crate) enum DocumentWriter {
    Xlsx(XlsxSheetWriter),
}

impl DocumentWriter {
    pub(crate) fn write_rows(&mut self, rows: &[Vec<Value>]) -> Result<(), RenderError> {
        match self {
            Self::Xlsx(writer) => writer.write_rows(rows),
        }
    }

    pub(crate) fn finish(self) -> Result<Vec<u8>, RenderError> {
        match self {
            Self::Xlsx(writer) => writer.finish(),
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
