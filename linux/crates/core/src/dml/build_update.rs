use crate::column::ColumnInfo;
use crate::dialect::{BindTarget, SqlDialect};
use crate::meta::{RowIdentity, TableRef};
use crate::statement::{Statement, StatementBuilder};
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

    let mut builder = StatementBuilder::new();
    let mut set = Vec::with_capacity(assignments.len());
    for (index, value) in assignments {
        let column = columns.get(*index).ok_or(BuildSqlError::UnknownKeyColumn {
            name: index.to_string(),
        })?;
        let marker = builder.bind(dialect, value.clone(), BindTarget::Column(column))?;
        set.push(format!("{} = {marker}", dialect.quote_identifier(&column.name)));
    }
    let predicate = key_predicate(&mut builder, dialect, &components, key)?;

    builder.push_sql(&dialect.update_statement(&dialect.qualify(table), &set.join(", "), &predicate));
    Ok(builder.finish())
}
