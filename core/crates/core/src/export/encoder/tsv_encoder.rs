use std::sync::Arc;

use crate::column::ResultColumn;
use crate::value::Value;

use super::super::column_type;
use super::super::tsv::{TSV_NULL, tsv_writer_builder};
use super::super::value_text::value_text;
use super::{EncodeError, RecordWriter, RowEncoder, readable_cells};

/// Tab-separated values, the form a spreadsheet pastes into cells. It
/// is what the clipboard carries, so each value goes as the user sees
/// it: a leading apostrophe on `-` or `@alice` would be pasted into
/// every other place the text goes too.
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
            self.writer
                .write(out, self.columns.iter().map(|column| column.name.as_str()));
        }
    }

    fn row(&mut self, out: &mut Vec<u8>, cells: &mut dyn Iterator<Item = &Value>) -> Result<(), EncodeError> {
        let cells = readable_cells(&self.columns, cells)?;
        self.writer.write(
            out,
            cells.iter().enumerate().map(|(index, value)| {
                value_text(value, column_type(&self.columns, index)).unwrap_or_else(|| TSV_NULL.to_owned())
            }),
        );
        Ok(())
    }

    fn finish(&mut self, _out: &mut Vec<u8>) {}
}
