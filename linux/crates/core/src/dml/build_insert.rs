use crate::column::ColumnInfo;
use crate::dialect::{BindTarget, SqlDialect};
use crate::edit::CellInput;
use crate::meta::TableRef;
use crate::statement::{Statement, StatementBuilder};
use crate::value::Value;

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

    builder.push_sql(&dialect.insert_statement(&table_sql, &names.join(", "), &format!("({})", markers.join(", "))));
    Ok(builder.finish())
}

/// One INSERT of several rows into the same columns, each row holding
/// one value per column, in column order.
///
/// One statement takes one round trip for every row in it, and
/// ClickHouse makes one part of it rather than one per row.
pub fn build_multi_row_insert(
    dialect: &dyn SqlDialect,
    table: &TableRef,
    columns: &[&ColumnInfo],
    rows: Vec<Vec<Value>>,
) -> Result<Statement, BuildSqlError> {
    if columns.is_empty() || rows.is_empty() {
        return Err(BuildSqlError::NoInsertValues);
    }
    let mut builder = StatementBuilder::new();
    let mut tuples = Vec::with_capacity(rows.len());
    for row in rows {
        if row.len() != columns.len() {
            return Err(BuildSqlError::LengthMismatch {
                expected: columns.len(),
                found: row.len(),
            });
        }
        let mut markers = Vec::with_capacity(columns.len());
        for (&column, value) in columns.iter().zip(row) {
            markers.push(builder.bind(dialect, value, BindTarget::Column(column))?);
        }
        tuples.push(format!("({})", markers.join(", ")));
    }
    let names: Vec<String> = columns
        .iter()
        .map(|column| dialect.quote_identifier(&column.name))
        .collect();
    builder.push_sql(&dialect.insert_statement(&dialect.qualify(table), &names.join(", "), &tuples.join(", ")));
    Ok(builder.finish())
}
