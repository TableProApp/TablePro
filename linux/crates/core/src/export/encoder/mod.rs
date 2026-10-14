mod csv_encoder;
mod encode_error;
mod json_array_encoder;
mod markdown_encoder;
mod row_encoder;
mod tsv_encoder;

use crate::column::ResultColumn;
use crate::value::Value;

pub use csv_encoder::CsvEncoder;
pub use encode_error::EncodeError;
pub use json_array_encoder::JsonArrayEncoder;
pub use markdown_encoder::MarkdownEncoder;
pub use row_encoder::RowEncoder;
pub use tsv_encoder::TsvEncoder;

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

/// One record through a writer of its own, straight into `out`.
///
/// Writing into memory cannot fail, and a writer that sees a single
/// record has no earlier field count to disagree with, so neither
/// result carries anything.
fn write_record<I, T>(builder: &csv::WriterBuilder, out: &mut Vec<u8>, record: I)
where
    I: IntoIterator<Item = T>,
    T: AsRef<[u8]>,
{
    let mut writer = builder.from_writer(out);
    let _ = writer.write_record(record);
    let _ = writer.flush();
}

/// A record rarely needs more, and the writer zeroes its whole buffer
/// for every row.
const RECORD_BUFFER: usize = 1024;

#[cfg(test)]
mod tests;
