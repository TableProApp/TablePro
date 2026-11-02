use tablepro_core::TableRef;
use tablepro_core::ddl::DraftColumn;
use tablepro_core::dialect::SqlDialect;

use crate::conformance::ConformanceEngine;

/// What the DDL suite needs on top of the connection suite: the
/// engine's spelling of the three column types its tables use.
pub trait ConformanceDdlEngine: ConformanceEngine {
    fn integer_type(&self) -> &'static str;

    fn text_type(&self) -> &'static str;

    /// A type that takes `current_timestamp_expression` as its default.
    fn timestamp_type(&self) -> &'static str;

    fn current_timestamp_expression(&self) -> &'static str;

    /// CREATE TABLE for an engine whose DDL dialect does not create
    /// tables, keyed on `id`. Only read when `DdlCapabilities::create_table`
    /// is off.
    fn create_table_sql(
        &self,
        _dialect: &dyn SqlDialect,
        _table: &TableRef,
        _columns: &[DraftColumn],
    ) -> Option<String> {
        None
    }
}
