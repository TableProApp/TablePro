use crate::column::ColumnInfo;
use crate::dialect::SqlDialect;
use crate::dml::{BuildSqlError, KeyComponent, key_components};
use crate::meta::{RowIdentity, TableRef};

use super::{BrowseSqlError, SortKey};

/// The visible select list: one projection per column, so the read
/// form each column needs is honoured.
pub(super) fn projection_list(dialect: &dyn SqlDialect, columns: &[ColumnInfo]) -> Result<String, BrowseSqlError> {
    if columns.is_empty() {
        return Err(BrowseSqlError::NoColumns);
    }
    Ok(columns
        .iter()
        .map(|column| dialect.projection(column))
        .collect::<Vec<_>>()
        .join(", "))
}

/// The identity's parts, or none for a table where nothing names a
/// row. Browsing such a table is fine; only editing it is not.
pub(super) fn identity_components<'a>(
    identity: &RowIdentity,
    columns: &'a [ColumnInfo],
) -> Result<Vec<KeyComponent<'a>>, BrowseSqlError> {
    match identity {
        RowIdentity::Unordered => Ok(Vec::new()),
        _ => Ok(key_components(identity, columns)?),
    }
}

/// The ORDER BY terms the user asked for.
pub(super) fn user_order(
    dialect: &dyn SqlDialect,
    table: &TableRef,
    columns: &[ColumnInfo],
    sort: &[SortKey],
) -> Result<Vec<String>, BrowseSqlError> {
    sort.iter()
        .map(|key| {
            let column = columns
                .get(key.column)
                .ok_or(BrowseSqlError::UnknownSortColumn(key.column))?;
            Ok(format!(
                "{} {}",
                dialect.sort_expression(table, column),
                direction(key.ascending)
            ))
        })
        .collect()
}

/// The identity as sort expressions, in key order, leaving out a part
/// that has no ordering of its own.
pub(super) fn identity_order(
    dialect: &dyn SqlDialect,
    table: &TableRef,
    components: &[KeyComponent<'_>],
) -> Result<Vec<String>, BrowseSqlError> {
    components
        .iter()
        .filter_map(|component| match component {
            KeyComponent::Column(column) => Some(Ok(dialect.sort_expression(table, column))),
            KeyComponent::EngineRowId(part) if part.orders_rows() => {
                Some(dialect.engine_row_id_column(*part).ok_or(BuildSqlError::NoRowIdentity))
            }
            KeyComponent::EngineRowId(_) => None,
        })
        .collect::<Result<Vec<_>, _>>()
        .map_err(BrowseSqlError::from)
}

/// The user's order with the identity appended as a tiebreak, so equal
/// sort values still come back in one order every time. An expression
/// the user already sorts by is not repeated: SQL Server refuses a
/// column named twice in ORDER BY.
pub(super) fn with_tiebreak(user: Vec<String>, identity: &[String]) -> Vec<String> {
    let mut terms = user;
    for expression in identity {
        let already = terms
            .iter()
            .any(|term| term.rsplit_once(' ').is_some_and(|(sorted, _)| sorted == expression));
        if !already {
            terms.push(format!("{expression} {}", direction(true)));
        }
    }
    terms
}

pub(super) fn direction(ascending: bool) -> &'static str {
    if ascending { "ASC" } else { "DESC" }
}

/// `WHERE` with each condition in parentheses, or nothing when there
/// are none.
pub(super) fn where_clause(conditions: &[String]) -> String {
    match conditions {
        [] => String::new(),
        [only] => format!(" WHERE {only}"),
        many => format!(
            " WHERE {}",
            many.iter()
                .map(|condition| format!("({condition})"))
                .collect::<Vec<_>>()
                .join(" AND ")
        ),
    }
}
