use crate::column::ColumnInfo;
use crate::dialect::SqlDialect;
use crate::meta::{RowIdentity, TableRef};
use crate::statement::{Statement, StatementBuilder};
use crate::value::Value;

use super::predicate::key_predicate;
use super::{BuildSqlError, key_components};

/// The SELECT that counts what a key matches, for the engines whose
/// affected-row count is not proof that a write hit exactly one row.
pub fn build_key_probe(
    dialect: &dyn SqlDialect,
    table: &TableRef,
    columns: &[ColumnInfo],
    identity: &RowIdentity,
    key: &[Value],
) -> Result<Statement, BuildSqlError> {
    let components = key_components(identity, columns)?;
    let mut builder = StatementBuilder::new();
    let predicate = key_predicate(&mut builder, dialect, &components, key)?;
    builder.push_sql(&dialect.key_probe(&dialect.qualify(table), &predicate));
    Ok(builder.finish())
}
