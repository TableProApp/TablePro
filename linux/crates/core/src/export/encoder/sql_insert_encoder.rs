use std::sync::Arc;

use crate::column::ResultColumn;
use crate::dialect::SqlDialect;
use crate::meta::TableRef;
use crate::value::Value;

use super::super::sql::{InsertShape, insert_row, insert_shape};
use super::{EncodeError, RowEncoder, readable_cells};

/// The statements `render_sql_insert` writes, a row at a time.
pub struct SqlInsertEncoder {
    dialect: Arc<dyn SqlDialect>,
    columns: Arc<[ResultColumn]>,
    /// `None` for a result with no column to write, which writes
    /// nothing.
    shape: Option<InsertShape>,
}

impl SqlInsertEncoder {
    /// `generated` names the columns the server computes, which every
    /// statement leaves out.
    pub fn new(
        dialect: Arc<dyn SqlDialect>,
        table: &TableRef,
        columns: Arc<[ResultColumn]>,
        generated: &[String],
    ) -> Self {
        let shape = insert_shape(&*dialect, table, &columns, generated);
        Self {
            dialect,
            columns,
            shape,
        }
    }
}

impl RowEncoder for SqlInsertEncoder {
    fn begin(&mut self, _out: &mut Vec<u8>) {}

    fn row(&mut self, out: &mut Vec<u8>, cells: &mut dyn Iterator<Item = &Value>) -> Result<(), EncodeError> {
        let cells = readable_cells(&self.columns, cells)?;
        let Some(shape) = &self.shape else {
            return Ok(());
        };
        let mut row = String::new();
        insert_row(&mut row, &*self.dialect, shape, &self.columns, cells);
        out.extend_from_slice(row.as_bytes());
        Ok(())
    }

    fn finish(&mut self, _out: &mut Vec<u8>) {}
}
