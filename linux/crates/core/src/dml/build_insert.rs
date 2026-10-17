use crate::column::ColumnInfo;
use crate::dialect::{BindTarget, SqlDialect};
use crate::edit::CellInput;
use crate::meta::TableRef;
use crate::statement::{Statement, StatementBuilder};

use super::BuildSqlError;

/// The INSERT for one row.
///
/// A `Default` cell is left out of the statement, so the server applies
/// its own default or next number. A generated column is never written,
/// because the server computes it. Every other value is written, an
/// auto-increment column's included: a value given for one is a key the
/// caller means to keep, and the caller leaves out the identities an
/// engine refuses a value for.
pub fn build_insert(
    dialect: &dyn SqlDialect,
    table: &TableRef,
    columns: &[ColumnInfo],
    cells: &[CellInput],
) -> Result<Statement, BuildSqlError> {
    if cells.len() != columns.len() {
        return Err(BuildSqlError::LengthMismatch {
            expected: columns.len(),
            found: cells.len(),
        });
    }
    let table_sql = dialect.qualify(table);

    let mut builder = StatementBuilder::new();
    let mut names = Vec::new();
    let mut markers = Vec::new();
    for (column, cell) in columns.iter().zip(cells) {
        let Some(value) = cell.value() else {
            continue;
        };
        if column.is_generated {
            continue;
        }
        markers.push(builder.bind(dialect, value.clone(), BindTarget::Column(column))?);
        names.push(dialect.quote_identifier(&column.name));
    }

    if names.is_empty() {
        // Nothing to say but "a row": the engine has to have a
        // spelling for that, or there is no insert to make.
        let sql = dialect
            .insert_default_row(&table_sql)
            .ok_or(BuildSqlError::NoInsertValues)?;
        builder.push_sql(&sql);
        return Ok(builder.finish());
    }

    builder.push_sql(&format!(
        "INSERT INTO {table_sql} ({}) VALUES ({})",
        names.join(", "),
        markers.join(", ")
    ));
    Ok(builder.finish())
}
