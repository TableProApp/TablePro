use crate::column::ColumnInfo;
use crate::dialect::SqlDialect;
use crate::filter::{FilterSet, build_filter};
use crate::meta::TableRef;
use crate::statement::{Statement, StatementBuilder};

use super::BrowseSqlError;
use super::select_parts::where_clause;

/// The count the paginator shows, under the same filter as the page.
///
/// The count expression is the dialect's, because COUNT(*) is a 32-bit
/// int on SQL Server and fails past two billion rows.
pub fn build_count(
    dialect: &dyn SqlDialect,
    table: &TableRef,
    columns: &[ColumnInfo],
    filter: &FilterSet,
) -> Result<Statement, BrowseSqlError> {
    let mut builder = StatementBuilder::new();
    let mut conditions = Vec::new();
    if build_filter(&mut builder, dialect, columns, filter)? {
        conditions.push(builder.take_fragment());
    }
    builder.push_sql(&format!(
        "SELECT {} FROM {}{}",
        dialect.count_all(),
        dialect.qualify(table),
        where_clause(&conditions)
    ));
    Ok(builder.finish())
}
