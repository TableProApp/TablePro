use std::time::Duration;

use tablepro_core::TableRef;

use crate::conformance::ConformanceEngine;

/// An engine whose statement timeout also stops a schema change, so the
/// suite can prove a schema-change batch runs without it.
pub trait BoundedDdlEngine: ConformanceEngine {
    /// A schema change that creates `table` and takes at least
    /// `duration`.
    fn schema_change_exceeding_sql(&self, table: &TableRef, duration: Duration) -> String;
}
