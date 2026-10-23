use std::sync::Arc;

use crate::column::ResultColumn;
use crate::value::Value;

use super::super::column_type;
use super::super::value_text::value_text;
use super::{EncodeError, RowEncoder, readable_cells};

/// The cells a grid copy holds, as JSON a paste reads back exactly:
/// each value's full text, a NULL as `null`, and the names of the
/// columns they came from, with `headers` set when the copy showed them.
/// Text loses that: TSV writes a NULL and the text `NULL` alike, and
/// quotes a value it then cannot tell from one that was quoted.
///
/// A number or bytes says so, as `{"int": "42"}`, `{"real": "1.5"}` or
/// `{"bytes": "0x01"}`: a column of no declared type, such as SQLite
/// keeps, stores the value as it comes, and its text alone is text.
pub struct CellsEncoder {
    columns: Arc<[ResultColumn]>,
    with_headers: bool,
    rows: usize,
}

impl CellsEncoder {
    pub fn new(columns: Arc<[ResultColumn]>, with_headers: bool) -> Self {
        Self {
            columns,
            with_headers,
            rows: 0,
        }
    }
}

impl RowEncoder for CellsEncoder {
    fn begin(&mut self, out: &mut Vec<u8>) {
        out.extend_from_slice(b"{\"columns\":");
        write_list(out, self.columns.iter().map(|column| Some(column.name.as_str())));
        out.extend_from_slice(b",\"headers\":");
        match self.with_headers {
            true => write_list(out, self.columns.iter().map(|column| Some(column.name.as_str()))),
            false => out.extend_from_slice(b"null"),
        }
        out.extend_from_slice(b",\"rows\":[");
    }

    fn row(&mut self, out: &mut Vec<u8>, cells: &mut dyn Iterator<Item = &Value>) -> Result<(), EncodeError> {
        let cells = readable_cells(&self.columns, cells)?;
        if self.rows > 0 {
            out.push(b',');
        }
        out.push(b'[');
        for (index, value) in cells.iter().enumerate() {
            if index > 0 {
                out.push(b',');
            }
            let Some(text) = value_text(value, column_type(&self.columns, index)) else {
                out.extend_from_slice(b"null");
                continue;
            };
            let text = serde_json::Value::from(text).to_string();
            match stored_as(value) {
                Some(kind) => out.extend_from_slice(format!("{{\"{kind}\":{text}}}").as_bytes()),
                None => out.extend_from_slice(text.as_bytes()),
            }
        }
        out.push(b']');
        self.rows += 1;
        Ok(())
    }

    fn finish(&mut self, out: &mut Vec<u8>) {
        out.extend_from_slice(b"]}");
    }
}

/// The storage a value's text does not carry.
fn stored_as(value: &Value) -> Option<&'static str> {
    match value {
        Value::Int(_) | Value::UInt(_) | Value::WideInt(_) => Some("int"),
        // A decimal's text is exact, which a binary float is not.
        Value::Float32(_) | Value::Float64(_) => Some("real"),
        Value::Bytes(_) => Some("bytes"),
        _ => None,
    }
}

fn write_list<'a>(out: &mut Vec<u8>, items: impl Iterator<Item = Option<&'a str>>) {
    out.push(b'[');
    for (index, item) in items.enumerate() {
        if index > 0 {
            out.push(b',');
        }
        match item {
            Some(text) => out.extend_from_slice(serde_json::Value::from(text).to_string().as_bytes()),
            None => out.extend_from_slice(b"null"),
        }
    }
    out.push(b']');
}
