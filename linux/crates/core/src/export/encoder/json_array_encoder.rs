use std::sync::Arc;

use crate::column::ResultColumn;
use crate::value::Value;

use super::json_object::JsonObjectWriter;
use super::{EncodeError, RowEncoder};

/// A JSON array with one object per row, each on a line of its own.
pub struct JsonArrayEncoder {
    objects: JsonObjectWriter,
    rows: u64,
}

impl JsonArrayEncoder {
    pub fn new(columns: Arc<[ResultColumn]>) -> Self {
        Self {
            objects: JsonObjectWriter::new(columns),
            rows: 0,
        }
    }
}

impl RowEncoder for JsonArrayEncoder {
    fn begin(&mut self, out: &mut Vec<u8>) {
        out.push(b'[');
    }

    fn row(&mut self, out: &mut Vec<u8>, cells: &mut dyn Iterator<Item = &Value>) -> Result<(), EncodeError> {
        let lead: &[u8] = if self.rows == 0 { b"\n" } else { b",\n" };
        self.objects.write(out, lead, cells)?;
        self.rows += 1;
        Ok(())
    }

    fn finish(&mut self, out: &mut Vec<u8>) {
        if self.rows > 0 {
            out.push(b'\n');
        }
        out.push(b']');
    }
}
