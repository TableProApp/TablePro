mod csv_encoder;
mod encode_error;
mod html_encoder;
mod json_array_encoder;
mod markdown_encoder;
mod row_encoder;
mod sql_insert_encoder;
mod tsv_encoder;
mod xml_encoder;

use std::cell::Cell;
use std::io;

use crate::column::ResultColumn;
use crate::value::Value;

pub use csv_encoder::CsvEncoder;
pub use encode_error::EncodeError;
pub use html_encoder::HtmlEncoder;
pub use json_array_encoder::JsonArrayEncoder;
pub use markdown_encoder::MarkdownEncoder;
pub use row_encoder::RowEncoder;
pub use sql_insert_encoder::SqlInsertEncoder;
pub use tsv_encoder::TsvEncoder;
pub use xml_encoder::XmlEncoder;

/// A whole result through `encoder`, as text.
pub(super) fn encode_rows(mut encoder: impl RowEncoder, rows: &[Vec<Value>]) -> Result<String, EncodeError> {
    let mut out = Vec::new();
    encoder.begin(&mut out);
    for row in rows {
        encoder.row(&mut out, &mut row.iter())?;
    }
    encoder.finish(&mut out);
    // Every encoder writes UTF-8 text and ASCII punctuation, so the
    // lossy branch is never taken.
    Ok(String::from_utf8(out).unwrap_or_else(|error| String::from_utf8_lossy(error.as_bytes()).into_owned()))
}

/// The row's cells, refused when one of them could not be read: a value
/// the driver could not decode has no text, and writing it as a NULL
/// would put a value in the file that the table does not hold.
fn readable_cells<'a>(
    columns: &[ResultColumn],
    cells: &mut dyn Iterator<Item = &'a Value>,
) -> Result<Vec<&'a Value>, EncodeError> {
    cells
        .enumerate()
        .map(|(index, value)| match value {
            Value::Undecodable(_) => Err(EncodeError::Undecodable {
                column: column_name(columns, index),
            }),
            value => Ok(value),
        })
        .collect()
}

/// A column's name, or its position for a cell past the header.
fn column_name(columns: &[ResultColumn], index: usize) -> String {
    columns
        .get(index)
        .map_or_else(|| (index + 1).to_string(), |column| column.name.clone())
}

/// Writes one record at a time into the caller's buffer, through one
/// CSV writer kept for the whole export: building a writer allocates and
/// zeroes its buffer, which per row would cost more than the row.
struct RecordWriter {
    writer: csv::Writer<LentBuffer>,
}

/// The caller's buffer, lent to the writer for one record. csv::Writer
/// has no `get_mut`, so the buffer goes in and out through a `Cell`.
#[derive(Default)]
struct LentBuffer(Cell<Vec<u8>>);

impl io::Write for LentBuffer {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        self.0.get_mut().extend_from_slice(bytes);
        Ok(bytes.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

impl RecordWriter {
    /// A row may have more cells than the header, so the writer does
    /// not hold every record to the first one's length.
    fn new(mut builder: csv::WriterBuilder) -> Self {
        builder.flexible(true);
        Self {
            writer: builder.from_writer(LentBuffer::default()),
        }
    }

    /// Writing into memory cannot fail, and a flexible writer has no
    /// field count to disagree with, so neither result carries anything.
    fn write<I, T>(&mut self, out: &mut Vec<u8>, record: I)
    where
        I: IntoIterator<Item = T>,
        T: AsRef<[u8]>,
    {
        self.writer.get_ref().0.set(std::mem::take(out));
        let _ = self.writer.write_record(record);
        let _ = self.writer.flush();
        *out = self.writer.get_ref().0.take();
    }
}

#[cfg(test)]
mod tests;
