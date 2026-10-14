use std::sync::Arc;

use crate::column::ResultColumn;
use crate::value::Value;

use super::super::xml::{XML_HEAD, XML_TAIL, xml_row};
use super::{EncodeError, RowEncoder, readable_cells};

/// The document `render_xml` writes, a row at a time.
pub struct XmlEncoder {
    columns: Arc<[ResultColumn]>,
}

impl XmlEncoder {
    pub fn new(columns: Arc<[ResultColumn]>) -> Self {
        Self { columns }
    }
}

impl RowEncoder for XmlEncoder {
    fn begin(&mut self, out: &mut Vec<u8>) {
        out.extend_from_slice(XML_HEAD.as_bytes());
    }

    fn row(&mut self, out: &mut Vec<u8>, cells: &mut dyn Iterator<Item = &Value>) -> Result<(), EncodeError> {
        let cells = readable_cells(&self.columns, cells)?;
        let mut row = String::new();
        xml_row(&mut row, &self.columns, cells);
        out.extend_from_slice(row.as_bytes());
        Ok(())
    }

    fn finish(&mut self, out: &mut Vec<u8>) {
        out.extend_from_slice(XML_TAIL.as_bytes());
    }
}
