use crate::column::ColumnInfo;
use crate::dialect::{BindTarget, SqlDialect};
use crate::meta::{RowIdentity, TableRef};
use crate::statement::{BoundParam, Statement};
use crate::value::Value;

use super::predicate::key_predicate;
use super::{BuildSqlError, key_components};

/// The UPDATE for one row's changed cells.
///
/// Only the cells that moved are assigned, so a save does not rewrite
/// columns the user never touched and trigger their side effects.
pub fn build_update(
    dialect: &dyn SqlDialect,
    table: &TableRef,
    columns: &[ColumnInfo],
    identity: &RowIdentity,
    key: &[Value],
    assignments: &[(usize, Value)],
) -> Result<Statement, BuildSqlError> {
    if assignments.is_empty() {
        return Err(BuildSqlError::NothingToUpdate);
    }
    let components = key_components(identity, columns)?;

    let mut sql = String::new();
    let mut params: Vec<BoundParam> = Vec::new();
    for (position, (index, value)) in assignments.iter().enumerate() {
        let column = columns.get(*index).ok_or(BuildSqlError::UnknownKeyColumn {
            name: index.to_string(),
        })?;
        if position > 0 {
            sql.push_str(", ");
        }
        let placeholder = dialect.placeholder(params.len() + 1, value.clone(), BindTarget::Column(column))?;
        sql.push_str(&dialect.quote_identifier(&column.name));
        sql.push_str(" = ");
        sql.push_str(&placeholder.sql);
        if let Some(param) = placeholder.param {
            params.push(param);
        }
    }

    let (predicate, key_params) = key_predicate(dialect, &components, key, params.len() + 1)?;
    params.extend(key_params);
    let statement_sql = dialect.update_statement(&dialect.qualify(table), &sql, &predicate);
    Ok(Statement::from_parts(statement_sql, params))
}
