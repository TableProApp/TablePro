use std::sync::Arc;

use crate::column::ResultColumn;
use crate::value::Value;

use super::json_object::JsonObjectWriter;
use super::{EncodeError, RowEncoder};

/// JSON Lines: one object per row, each ended by a line break, with no
/// array around them, so a tool that reads a line at a time takes each
/// row alone.
pub struct JsonLinesEncoder {
    objects: JsonObjectWriter,
}

impl JsonLinesEncoder {
    pub fn new(columns: Arc<[ResultColumn]>) -> Self {
        Self {
            objects: JsonObjectWriter::new(columns),
        }
    }
}

impl RowEncoder for JsonLinesEncoder {
    fn begin(&mut self, _out: &mut Vec<u8>) {}

    fn row(&mut self, out: &mut Vec<u8>, cells: &mut dyn Iterator<Item = &Value>) -> Result<(), EncodeError> {
        let start = out.len();
        self.objects.write(out, b"", cells)?;
        // A JSON column's document goes in as the server wrote it, line
        // breaks included. A raw break can only sit between its tokens,
        // since a JSON string escapes its own, so a space keeps it valid.
        for byte in &mut out[start..] {
            if matches!(byte, b'\n' | b'\r') {
                *byte = b' ';
            }
        }
        out.push(b'\n');
        Ok(())
    }

    fn finish(&mut self, _out: &mut Vec<u8>) {}
}
