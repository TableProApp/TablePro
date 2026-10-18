use std::sync::Arc;

use crate::column::ResultColumn;
use crate::value::Value;

use super::super::column_type;
use super::super::markdown::{markdown_cell, markdown_text};
use super::{EncodeError, RowEncoder, readable_cells};

/// A Markdown table. Each row starts on a line of its own, so the table
/// ends without a trailing line break.
pub struct MarkdownEncoder {
    columns: Arc<[ResultColumn]>,
}

impl MarkdownEncoder {
    pub fn new(columns: Arc<[ResultColumn]>) -> Self {
        Self { columns }
    }
}

impl RowEncoder for MarkdownEncoder {
    fn begin(&mut self, out: &mut Vec<u8>) {
        let header: Vec<String> = self.columns.iter().map(|column| markdown_text(&column.name)).collect();
        let separator: Vec<&str> = self.columns.iter().map(|_| "---").collect();
        out.extend_from_slice(format!("| {} |\n| {} |", header.join(" | "), separator.join(" | ")).as_bytes());
    }

    fn row(&mut self, out: &mut Vec<u8>, cells: &mut dyn Iterator<Item = &Value>) -> Result<(), EncodeError> {
        let cells: Vec<String> = readable_cells(&self.columns, cells)?
            .into_iter()
            .enumerate()
            .map(|(index, value)| markdown_cell(value, column_type(&self.columns, index)))
            .collect();
        out.extend_from_slice(format!("\n| {} |", cells.join(" | ")).as_bytes());
        Ok(())
    }

    fn finish(&mut self, _out: &mut Vec<u8>) {}
}
