use std::sync::Arc;

use crate::column::ResultColumn;
use crate::dialect::SqlDialect;
use crate::meta::TableRef;
use crate::value::Value;

use super::super::sql::InsertWriter;
use super::{EncodeError, RowEncoder, readable_cells};

/// The statements `render_sql_insert` writes, a row at a time.
pub struct SqlInsertEncoder {
    dialect: Arc<dyn SqlDialect>,
    columns: Arc<[ResultColumn]>,
    /// `None` for a result with no column to write, which writes
    /// nothing.
    writer: Option<InsertWriter>,
}

impl SqlInsertEncoder {
    /// `generated` names the columns the server computes, which every
    /// statement leaves out, and `numbered` the ones it numbers, which
    /// keep their values through the engine's override.
    pub fn new(
        dialect: Arc<dyn SqlDialect>,
        table: &TableRef,
        columns: Arc<[ResultColumn]>,
        generated: &[String],
        numbered: &[String],
    ) -> Self {
        let writer = InsertWriter::new(&*dialect, table, &columns, generated, numbered);
        Self {
            dialect,
            columns,
            writer,
        }
    }
}

impl RowEncoder for SqlInsertEncoder {
    fn begin(&mut self, _out: &mut Vec<u8>) {}

    fn row(&mut self, out: &mut Vec<u8>, cells: &mut dyn Iterator<Item = &Value>) -> Result<(), EncodeError> {
        let cells = readable_cells(&self.columns, cells)?;
        let Some(writer) = &mut self.writer else {
            return Ok(());
        };
        let mut row = String::new();
        writer.row(&mut row, &*self.dialect, &self.columns, cells);
        out.extend_from_slice(row.as_bytes());
        Ok(())
    }

    fn finish(&mut self, out: &mut Vec<u8>) {
        let Some(writer) = &mut self.writer else {
            return;
        };
        let mut end = String::new();
        writer.finish(&mut end, &*self.dialect);
        out.extend_from_slice(end.as_bytes());
    }
}
