use std::sync::Arc;

use crate::column::ResultColumn;
use crate::value::Value;

use super::super::column_type;
use super::super::value_text::value_text;
use super::{EncodeError, RowEncoder, readable_cells};

/// Every value on one line, separated by a comma and a space, row after
/// row: the list a user pastes into a message or a query by hand.
pub struct OneRowEncoder {
    columns: Arc<[ResultColumn]>,
    values: u64,
}

impl OneRowEncoder {
    pub fn new(columns: Arc<[ResultColumn]>) -> Self {
        Self { columns, values: 0 }
    }
}

/// A value holding the separator, a quote or a line break is quoted as
/// CSV quotes it, so the list still reads back value by value and stays
/// on one line.
fn one_row_text(text: String) -> String {
    match text.contains([',', '"', '\n', '\r']) {
        true => format!(
            "\"{}\"",
            text.replace('"', "\"\"")
                .replace("\r\n", "\\n")
                .replace(['\r', '\n'], "\\n")
        ),
        false => text,
    }
}

impl RowEncoder for OneRowEncoder {
    fn begin(&mut self, _out: &mut Vec<u8>) {}

    fn row(&mut self, out: &mut Vec<u8>, cells: &mut dyn Iterator<Item = &Value>) -> Result<(), EncodeError> {
        let cells = readable_cells(&self.columns, cells)?;
        for (index, value) in cells.into_iter().enumerate() {
            if self.values > 0 {
                out.extend_from_slice(b", ");
            }
            let text =
                value_text(value, column_type(&self.columns, index)).map_or_else(|| "NULL".to_owned(), one_row_text);
            out.extend_from_slice(text.as_bytes());
            self.values += 1;
        }
        Ok(())
    }

    fn finish(&mut self, _out: &mut Vec<u8>) {}
}
