use std::sync::Arc;

use crate::column::ResultColumn;
use crate::value::Value;

use super::super::column_type;
use super::super::csv::neutralise_formula;
use super::super::tsv::tsv_writer_builder;
use super::super::value_text::value_text;
use super::{EncodeError, RecordWriter, RowEncoder, readable_cells};

/// Tab-separated values, the form a spreadsheet pastes into cells. A
/// paste reads a cell that starts like a formula as one, so free text
/// gets the apostrophe a CSV export gives it.
pub struct TsvEncoder {
    columns: Arc<[ResultColumn]>,
    with_headers: bool,
    writer: RecordWriter,
}

impl TsvEncoder {
    pub fn new(columns: Arc<[ResultColumn]>, with_headers: bool) -> Self {
        let writer = RecordWriter::new(tsv_writer_builder());
        Self {
            columns,
            with_headers,
            writer,
        }
    }
}

impl RowEncoder for TsvEncoder {
    fn begin(&mut self, out: &mut Vec<u8>) {
        if self.with_headers {
            self.writer.write(
                out,
                self.columns
                    .iter()
                    .map(|column| neutralise_formula(&Value::Null, column.name.clone(), true)),
            );
        }
    }

    fn row(&mut self, out: &mut Vec<u8>, cells: &mut dyn Iterator<Item = &Value>) -> Result<(), EncodeError> {
        let cells = readable_cells(&self.columns, cells)?;
        self.writer.write(
            out,
            cells.iter().enumerate().map(
                |(index, value)| match value_text(value, column_type(&self.columns, index)) {
                    Some(text) => neutralise_formula(value, text, false),
                    None => "NULL".to_owned(),
                },
            ),
        );
        Ok(())
    }

    fn finish(&mut self, _out: &mut Vec<u8>) {}
}
