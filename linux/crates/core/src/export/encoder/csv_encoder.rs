use std::sync::Arc;

use crate::column::ResultColumn;
use crate::value::Value;

use super::super::column_type;
use super::super::csv::{csv_cell, csv_header, csv_writer_builder};
use super::super::csv_options::CsvOptions;
use super::{EncodeError, RecordWriter, RowEncoder, readable_cells};

/// CSV under the user's options, with formula-like text neutralised
/// when they ask for it.
pub struct CsvEncoder {
    columns: Arc<[ResultColumn]>,
    options: CsvOptions,
    writer: RecordWriter,
}

impl CsvEncoder {
    pub fn new(columns: Arc<[ResultColumn]>, options: CsvOptions) -> Self {
        let writer = RecordWriter::new(csv_writer_builder(&options));
        Self {
            columns,
            options,
            writer,
        }
    }
}

impl RowEncoder for CsvEncoder {
    fn begin(&mut self, out: &mut Vec<u8>) {
        if self.options.header_row {
            self.writer.write(
                out,
                self.columns
                    .iter()
                    .map(|column| csv_header(&column.name, &self.options)),
            );
        }
    }

    fn row(&mut self, out: &mut Vec<u8>, cells: &mut dyn Iterator<Item = &Value>) -> Result<(), EncodeError> {
        let cells = readable_cells(&self.columns, cells)?;
        self.writer.write(
            out,
            cells
                .iter()
                .enumerate()
                .map(|(index, value)| csv_cell(value, column_type(&self.columns, index), &self.options)),
        );
        Ok(())
    }

    fn finish(&mut self, _out: &mut Vec<u8>) {}
}
