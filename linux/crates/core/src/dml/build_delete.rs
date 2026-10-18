use crate::column::ColumnInfo;
use crate::dialect::SqlDialect;
use crate::meta::{RowIdentity, TableRef};
use crate::statement::{Statement, StatementBuilder};
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
    let mut builder = StatementBuilder::new();
    let predicate = key_predicate(&mut builder, dialect, &components, key)?;
    builder.push_sql(&dialect.delete_statement(&dialect.qualify(table), &predicate));
    Ok(builder.finish())
}
