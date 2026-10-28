use std::sync::Arc;

use crate::column::ResultColumn;
use crate::value::Value;

use super::json_object::JsonObjectWriter;
use super::{EncodeError, RowEncoder};

/// JSON Lines: one object per row, each a line, with no array around
/// them, so a tool that reads a line at a time takes each row alone.
/// The last line has no line break after it, as the other copies end.
pub struct JsonLinesEncoder {
    objects: JsonObjectWriter,
    rows: u64,
}

impl JsonLinesEncoder {
    pub fn new(columns: Arc<[ResultColumn]>) -> Self {
        Self {
            objects: JsonObjectWriter::new(columns),
            rows: 0,
        }
    }
}

impl RowEncoder for JsonLinesEncoder {
    fn begin(&mut self, _out: &mut Vec<u8>) {}

    fn row(&mut self, out: &mut Vec<u8>, cells: &mut dyn Iterator<Item = &Value>) -> Result<(), EncodeError> {
        let lead: &[u8] = if self.rows == 0 { b"" } else { b"\n" };
        self.objects.write(out, lead, cells)?;
        self.rows += 1;
        Ok(())
    }

    fn finish(&mut self, _out: &mut Vec<u8>) {}
}
