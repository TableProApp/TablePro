use std::sync::Arc;

use serde::Serialize;

use crate::column::ResultColumn;
use crate::value::Value;

use super::super::column_type;
use super::super::json::JsonCell;
use super::super::json_field_names::json_field_names;
use super::{EncodeError, readable_cells};

/// One row as a JSON object, shared by the array and the line forms.
///
/// The objects are written key by key in column order rather than
/// built as a map first: a map would cost a copy of every row and, with
/// serde_json's default map, sort the keys.
pub(super) struct JsonObjectWriter {
    columns: Arc<[ResultColumn]>,
    /// Each column's key as JSON, followed by its colon.
    keys: Vec<Vec<u8>>,
}

impl JsonObjectWriter {
    pub(super) fn new(columns: Arc<[ResultColumn]>) -> Self {
        let keys = json_field_names(&columns)
            .iter()
            .map(|name| {
                let mut key = Vec::with_capacity(name.len() + 3);
                write_json(&mut key, name);
                key.push(b':');
                key
            })
            .collect();
        Self { columns, keys }
    }

    /// The object after `lead`. A row that fails leaves `out` as it was.
    pub(super) fn write(
        &self,
        out: &mut Vec<u8>,
        lead: &[u8],
        cells: &mut dyn Iterator<Item = &Value>,
    ) -> Result<(), EncodeError> {
        let cells = readable_cells(&self.columns, cells)?;
        out.extend_from_slice(lead);
        out.push(b'{');
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
        Ok(())
    }
}

/// serde_json fails only when its writer does, and a Vec never does.
fn write_json(out: &mut Vec<u8>, value: &impl Serialize) {
    let _ = serde_json::to_writer(out, value);
}
