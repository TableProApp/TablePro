use crate::dialect::{SqlDialect, TablePaging};
use crate::filter::build_filter;
use crate::meta::RowIdentity;
use crate::statement::{Statement, StatementBuilder};

use super::select_parts::{
    identity_components, identity_order, projection_list, user_order, where_clause, with_tiebreak,
};
use super::{BrowseSqlError, ExportRequest};

/// Every row the grid's filter and sort select, for an export.
///
/// The same projections and filter as a page, so an export holds what
/// the grid showed. No engine row id is selected: it is never data the
/// user asked for. A key still orders the rows, so two exports of an
/// unchanged table come out the same. A heap address orders them only
/// behind the user's sort: on its own it would sort the whole table
/// before the first row could be written.
pub fn build_export(dialect: &dyn SqlDialect, request: &ExportRequest<'_>) -> Result<Statement, BrowseSqlError> {
    if crate::document::speaks_shell(dialect) {
        return crate::document::export(request);
    }
    let projection = projection_list(dialect, request.columns)?;
    let components = identity_components(request.identity, request.columns)?;
    let user = user_order(dialect, request.table, request.columns, request.sort)?;
    let heap_order_only =
        user.is_empty() && matches!(request.identity, RowIdentity::EngineRowId(id) if id.is_heap_address());
    // An engine that pages on the server reads in its own order, which is
    // already the same for two exports of an unchanged table.
    let order = match (dialect.table_paging(), heap_order_only) {
        (TablePaging::ServerState, _) if !user.is_empty() => return Err(BrowseSqlError::SortUnsupported),
        (TablePaging::ServerState, _) | (TablePaging::InStatement, true) => Vec::new(),
        (TablePaging::InStatement, false) => with_tiebreak(user, &identity_order(dialect, request.table, &components)?),
    };

    let mut builder = StatementBuilder::new();
    let mut conditions = Vec::new();
    if build_filter(&mut builder, dialect, request.columns, request.filter)? {
        conditions.push(builder.take_fragment());
    }
    let order_by = match order.is_empty() {
        true => String::new(),
        false => format!(" ORDER BY {}", order.join(", ")),
    };
    let suffix = match conditions.is_empty() {
        true => "",
        false => dialect.filtered_read_suffix(),
    };
    builder.push_sql(&format!(
        "SELECT {projection} FROM {}{}{order_by}{suffix}",
        dialect.qualify(request.table),
        where_clause(&conditions)
    ));
    Ok(builder.finish())
}
