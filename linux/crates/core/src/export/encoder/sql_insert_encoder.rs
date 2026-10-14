use std::sync::Arc;

use crate::column::ResultColumn;
use crate::dialect::SqlDialect;
use crate::value::Value;

use super::super::sql::{insert_row, insert_start};
use super::{EncodeError, RowEncoder, readable_cells};

/// The statements `render_sql_insert` writes, a row at a time.
pub struct SqlInsertEncoder {
    dialect: Arc<dyn SqlDialect>,
    columns: Arc<[ResultColumn]>,
    /// `None` for a result with no columns, which writes nothing.
    start: Option<String>,
}

impl SqlInsertEncoder {
    pub fn new(dialect: Arc<dyn SqlDialect>, table: &str, columns: Arc<[ResultColumn]>) -> Self {
        let start = insert_start(&*dialect, table, &columns);
        Self {
            dialect,
            columns,
            start,
        }
    }
}

impl RowEncoder for SqlInsertEncoder {
    fn begin(&mut self, _out: &mut Vec<u8>) {}

    fn row(&mut self, out: &mut Vec<u8>, cells: &mut dyn Iterator<Item = &Value>) -> Result<(), EncodeError> {
        let cells = readable_cells(&self.columns, cells)?;
        let Some(start) = &self.start else {
            return Ok(());
        };
        let mut row = String::new();
        insert_row(&mut row, &*self.dialect, start, &self.columns, cells);
        out.extend_from_slice(row.as_bytes());
        Ok(())
    }

    fn finish(&mut self, _out: &mut Vec<u8>) {}
}
