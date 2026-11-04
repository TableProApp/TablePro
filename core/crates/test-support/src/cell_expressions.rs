//! Every expression an engine lists for a cell, saved the way the grid
//! saves one, so each driver's tests prove its list against the engine.

use tablepro_core::dialect::SqlDialect;
use tablepro_core::edit::{CellInput, cell_expressions};
use tablepro_core::meta::TableRef;
use tablepro_core::save::{ChangeSet, RowChange, RowUpdate, plan_save};
use tablepro_core::statement::StatementBuilder;
use tablepro_core::{CallOptions, ColumnInfo, Connection, RowLimit, Value};

/// The column a table may add to prove `SET c = DEFAULT`; it needs a
/// declared default.
pub const DEFAULTED_COLUMN: &str = "defaulted";

/// Save each expression `table` takes into row 1 and read it back as a
/// value the server wrote, then insert row 2 with the first expression
/// of each column. The table's first column is an integer key named
/// `id`, and row 1 is there. Returns how many expressions were saved.
pub async fn check_cell_expressions(
    connection: &dyn Connection,
    table: &TableRef,
    call: impl Fn() -> CallOptions,
) -> Result<usize, String> {
    let dialect = connection.dialect();
    let columns = connection
        .fetch_columns(table, call())
        .await
        .map_err(|error| error.to_string())?;
    let mut checked = 0;
    for (index, column) in columns.iter().enumerate() {
        for expression in cell_expressions(dialect.as_ref(), &column.column_type) {
            let input = CellInput::Expression(expression);
            save(
                connection,
                table,
                &columns,
                update(index, CellInput::Value(Value::Null)),
                &call,
            )
            .await?;
            save(connection, table, &columns, update(index, input), &call).await?;
            if read(connection, dialect.as_ref(), table, &columns, 1, index, &call)
                .await?
                .is_null()
            {
                return Err(format!("{} left {} NULL", expression.sql, column.name));
            }
            checked += 1;
        }
    }

    let cells: Vec<CellInput> = columns
        .iter()
        .enumerate()
        .map(|(index, column)| match index {
            0 => CellInput::Value(Value::Int(2)),
            _ => cell_expressions(dialect.as_ref(), &column.column_type)
                .first()
                .map_or(CellInput::Default, |expression| CellInput::Expression(*expression)),
        })
        .collect();
    let written: Vec<usize> = (1..columns.len())
        .filter(|index| matches!(cells.get(*index), Some(CellInput::Expression(_))))
        .collect();
    save(connection, table, &columns, RowChange::Insert { cells }, &call).await?;
    for index in written {
        if read(connection, dialect.as_ref(), table, &columns, 2, index, &call)
            .await?
            .is_null()
        {
            return Err(format!("the insert left {} NULL", columns[index].name));
        }
    }

    if let Some(index) = columns.iter().position(|column| column.name == DEFAULTED_COLUMN) {
        save(
            connection,
            table,
            &columns,
            update(index, CellInput::Value(Value::Null)),
            &call,
        )
        .await?;
        save(connection, table, &columns, update(index, CellInput::Default), &call).await?;
        if read(connection, dialect.as_ref(), table, &columns, 1, index, &call)
            .await?
            .is_null()
        {
            return Err(format!("SET {DEFAULTED_COLUMN} = DEFAULT left it NULL"));
        }
    }
    Ok(checked)
}

fn update(index: usize, input: CellInput) -> RowChange {
    RowChange::Update(RowUpdate {
        key: vec![Value::Int(1)],
        assignments: vec![(index, input)],
    })
}

async fn save(
    connection: &dyn Connection,
    table: &TableRef,
    columns: &[ColumnInfo],
    change: RowChange,
    call: &impl Fn() -> CallOptions,
) -> Result<(), String> {
    let identity = connection
        .row_identity(table, call())
        .await
        .map_err(|error| error.to_string())?;
    let changes = ChangeSet { changes: vec![change] };
    let plan = plan_save(connection.dialect().as_ref(), table, columns, &identity, &changes)
        .map_err(|error| error.to_string())?;
    connection
        .write_batch(&plan.batch, call())
        .await
        .map_err(|error| format!("{error} in {:?}", plan.batch.steps))?;
    Ok(())
}

async fn read(
    connection: &dyn Connection,
    dialect: &dyn SqlDialect,
    table: &TableRef,
    columns: &[ColumnInfo],
    id: i64,
    index: usize,
    call: &impl Fn() -> CallOptions,
) -> Result<Value, String> {
    let names: Vec<String> = columns
        .iter()
        .map(|column| dialect.quote_identifier(&column.name))
        .collect();
    let sql = format!("SELECT {} FROM {}", names.join(", "), dialect.qualify(table));
    let mut statement = StatementBuilder::new();
    statement.push_sql(&sql);
    let result = connection
        .query_bound(&statement.finish(), RowLimit::EDITOR_DEFAULT, call())
        .await
        .map_err(|error| error.to_string())?;
    result
        .rows
        .into_iter()
        .find(|row| row.first().and_then(Value::as_exact_u64) == u64::try_from(id).ok())
        .and_then(|row| row.into_iter().nth(index))
        .ok_or_else(|| format!("row {id} is not in {}", table.name))
}
