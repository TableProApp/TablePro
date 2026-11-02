use std::sync::Arc;

use crate::column::ResultColumn;
use crate::value::Value;

use super::super::html::{HTML_TAIL, html_head, html_row};
use super::{EncodeError, RowEncoder, readable_cells};

/// The document `render_html` writes, a row at a time.
pub struct HtmlEncoder {
    columns: Arc<[ResultColumn]>,
    title: String,
}

impl HtmlEncoder {
    pub fn new(columns: Arc<[ResultColumn]>, title: impl Into<String>) -> Self {
        Self {
            columns,
            title: title.into(),
        }
    }
}

impl RowEncoder for HtmlEncoder {
    fn begin(&mut self, out: &mut Vec<u8>) {
        let mut head = String::new();
        html_head(&mut head, &self.columns, &self.title);
        out.extend_from_slice(head.as_bytes());
    }

    fn row(&mut self, out: &mut Vec<u8>, cells: &mut dyn Iterator<Item = &Value>) -> Result<(), EncodeError> {
        let cells = readable_cells(&self.columns, cells)?;
        let mut row = String::new();
        html_row(&mut row, &self.columns, cells);
        out.extend_from_slice(row.as_bytes());
        Ok(())
    }

    fn finish(&mut self, out: &mut Vec<u8>) {
        out.extend_from_slice(HTML_TAIL.as_bytes());
    }
}
