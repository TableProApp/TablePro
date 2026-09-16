mod csv;
mod csv_options;
mod html;
mod in_clause;
mod json;
mod json_field_names;
mod markdown;
mod tsv;
mod value_text;
mod xml;

use thiserror::Error;

use crate::column::{ColumnType, ResultColumn};
use crate::value::Value;

pub use csv::{FORMULA_LEADS, csv_writer_builder, neutralise_formula, render_csv, render_text_csv};
pub use csv_options::{CsvDecimal, CsvDelimiter, CsvLineBreak, CsvOptions, CsvQuote};
pub use html::render_html;
pub use in_clause::{InClause, render_in_clause};
pub use json::{render_json, row_to_json};
pub use json_field_names::json_field_names;
pub use markdown::render_markdown;
pub use tsv::{render_tsv, tsv_writer_builder};
pub use value_text::{value_text, value_to_text};
pub use xml::render_xml;

#[derive(Debug, Error)]
pub enum EncodeError {
    #[error("CSV encoding failed: {0}")]
    Csv(#[from] ::csv::Error),

    #[error("CSV output could not be flushed: {0}")]
    Flush(#[from] std::io::Error),

    #[error("CSV output is not valid UTF-8: {0}")]
    Utf8(#[from] std::string::FromUtf8Error),
}

/// The text of one cell, at the precision its column declares.
pub fn cell_text(columns: &[ResultColumn], index: usize, value: &Value) -> Option<String> {
    value_text(value, column_type(columns, index))
}

/// The column a cell belongs to, or an untyped one for a row longer
/// than its header, which is a driver fault rather than a reason to
/// drop the value.
fn column_type(columns: &[ResultColumn], index: usize) -> &ColumnType {
    static UNTYPED: std::sync::LazyLock<ColumnType> = std::sync::LazyLock::new(ColumnType::unknown);
    columns
        .get(index)
        .map(|column| &column.column_type)
        .unwrap_or_else(|| &UNTYPED)
}

fn finish(writer: ::csv::Writer<Vec<u8>>) -> Result<String, EncodeError> {
    let bytes = writer
        .into_inner()
        .map_err(|error| EncodeError::Flush(error.into_error()))?;
    Ok(String::from_utf8(bytes)?)
}

#[cfg(test)]
mod test_columns {
    use crate::column::{CatalogType, ColumnKind, ColumnType, ReadForm, ResultColumn, SqlTypeExpr, TextKind};

    pub fn text_type() -> ColumnType {
        ColumnType::new(
            SqlTypeExpr::from_catalog_text("text"),
            ColumnKind::Text(TextKind::Variable),
            CatalogType::Unknown,
            true,
            ReadForm::Native,
        )
    }

    pub fn typed(name: &str, sql: &str, kind: ColumnKind) -> ResultColumn {
        ResultColumn::new(
            name,
            ColumnType::new(
                SqlTypeExpr::from_catalog_text(sql),
                kind,
                CatalogType::Unknown,
                false,
                ReadForm::Native,
            ),
        )
    }

    pub fn col(name: &str) -> ResultColumn {
        ResultColumn::new(name, text_type())
    }

    pub fn cols(names: &[&str]) -> Vec<ResultColumn> {
        names.iter().map(|name| col(name)).collect()
    }
}
