use crate::column::ColumnInfo;
use crate::dialect::SqlDialect;
use crate::meta::{RowIdentity, TableRef};
use crate::statement::Statement;
use crate::value::Value;

use super::predicate::key_predicate;
use super::{BuildSqlError, key_components};

pub fn build_delete(
    dialect: &dyn SqlDialect,
    table: &TableRef,
    columns: &[ColumnInfo],
    identity: &RowIdentity,
    key: &[Value],
) -> Result<Statement, BuildSqlError> {
    let components = key_components(identity, columns)?;
    let (predicate, params) = key_predicate(dialect, &components, key, 1)?;
    let sql = dialect.delete_statement(&dialect.qualify(table), &predicate);
    Ok(Statement::from_parts(sql, params))
}

/// The SELECT that counts what a key matches, for the engines whose
/// affected-row count is an estimate.
pub fn build_key_probe(
    dialect: &dyn SqlDialect,
    table: &TableRef,
    columns: &[ColumnInfo],
    identity: &RowIdentity,
    key: &[Value],
) -> Result<Statement, BuildSqlError> {
    let components = key_components(identity, columns)?;
    let (predicate, params) = key_predicate(dialect, &components, key, 1)?;
    let sql = dialect.key_probe(&dialect.qualify(table), &predicate);
    Ok(Statement::from_parts(sql, params))
}
