use crate::dialect::SqlDialect;
use crate::filter::build_filter;
use crate::statement::{Statement, StatementBuilder};

use super::select_parts::{
    identity_components, identity_order, projection_list, user_order, where_clause, with_tiebreak,
};
use super::{BrowseSqlError, ExportRequest};

/// Every row the grid's filter and sort select, for an export.
///
/// The same projections and filter as a page, so an export holds what
/// the grid showed. No engine row id is selected: it is never data the
/// user asked for. The identity still orders the rows, so two exports
/// of an unchanged table come out the same.
pub fn build_export(dialect: &dyn SqlDialect, request: &ExportRequest<'_>) -> Result<Statement, BrowseSqlError> {
    let projection = projection_list(dialect, request.columns)?;
    let components = identity_components(request.identity, request.columns)?;
    let user = user_order(dialect, request.table, request.columns, request.sort)?;
    let order = with_tiebreak(user, &identity_order(dialect, request.table, &components)?);

    let mut builder = StatementBuilder::new();
    let mut conditions = Vec::new();
    if build_filter(&mut builder, dialect, request.columns, request.filter)? {
        conditions.push(builder.take_fragment());
    }
    let order_by = match order.is_empty() {
        true => String::new(),
        false => format!(" ORDER BY {}", order.join(", ")),
    };
    builder.push_sql(&format!(
        "SELECT {projection} FROM {}{}{order_by}",
        dialect.qualify(request.table),
        where_clause(&conditions)
    ));
    Ok(builder.finish())
}
