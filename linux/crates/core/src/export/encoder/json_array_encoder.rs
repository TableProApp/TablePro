use std::sync::Arc;

use serde::Serialize;

use crate::column::ResultColumn;
use crate::value::Value;

use super::super::column_type;
use super::super::json::JsonCell;
use super::super::json_field_names::json_field_names;
use super::{EncodeError, RowEncoder, readable_cells};

/// A JSON array with one object per row, each on a line of its own.
///
/// The objects are written key by key in column order rather than
/// built as a map first: a map would cost a copy of every row and, with
/// serde_json's default map, sort the keys.
pub struct JsonArrayEncoder {
    columns: Arc<[ResultColumn]>,
    /// Each column's key as JSON, followed by its colon.
    keys: Vec<Vec<u8>>,
    rows: u64,
}

impl JsonArrayEncoder {
    pub fn new(columns: Arc<[ResultColumn]>) -> Self {
        let keys = json_field_names(&columns)
            .iter()
            .map(|name| {
                let mut key = Vec::with_capacity(name.len() + 3);
                write_json(&mut key, name);
                key.push(b':');
                key
            })
            .collect();
        Self { columns, keys, rows: 0 }
    }
}

impl RowEncoder for JsonArrayEncoder {
    fn begin(&mut self, out: &mut Vec<u8>) {
        out.push(b'[');
    }

    fn row(&mut self, out: &mut Vec<u8>, cells: &mut dyn Iterator<Item = &Value>) -> Result<(), EncodeError> {
        let cells = readable_cells(&self.columns, cells)?;
        let lead: &[u8] = if self.rows == 0 { b"\n{" } else { b",\n{" };
        out.extend_from_slice(lead);
        for (index, key) in self.keys.iter().enumerate() {
            if index > 0 {
                out.push(b',');
            }
            out.extend_from_slice(key);
            match cells.get(index).copied() {
                Some(value) => write_json(
                    out,
                    &JsonCell {
                        value,
                        kind: &column_type(&self.columns, index).kind,
                    },
                ),
                // A row shorter than its header: the cell is missing,
                // which is not the same as a NULL the row holds.
                None => out.extend_from_slice(b"null"),
            }
        }
        out.push(b'}');
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

/// serde_json fails only when its writer does, and a Vec never does.
fn write_json(out: &mut Vec<u8>, value: &impl Serialize) {
    let _ = serde_json::to_writer(out, value);
}
