use tablepro_core::TableRef;

use crate::conformance::ConformanceEngine;

/// An engine that can fill a table with a million rows in seconds, for
/// the case that pages through one and exports it.
pub trait LargeTableEngine: ConformanceEngine {
    /// Statements that fill the empty scratch `table` with `rows` rows:
    /// `id` from 1 to `rows`, and `label` the id left-padded with zeros
    /// to `label_width` characters. They run as one schema-change batch,
    /// which no statement timeout stops.
    fn fill_scratch_table_sql(&self, table: &TableRef, rows: u64, label_width: usize) -> Vec<String>;
}
