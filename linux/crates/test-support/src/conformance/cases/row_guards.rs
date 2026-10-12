use tablepro_core::save::{ChangeSet, RowUpdate, plan_save};
use tablepro_core::value::Value;
use tablepro_core::{DriverError, WriteKind};

use crate::conformance::support::{
    CALL_DEADLINE, apply, connect, count, create_scratch_table, expect, insert_sql, statement, unexpected, within,
    writable,
};
use crate::conformance::{ConformanceEngine, ConformanceFailure};

const CASE: &str = "row_guard_mismatch_applies_nothing";
const MISSING_ID: i64 = 999;

/// Case 10: a save that edits a row which is no longer there matches no
/// row, and fails on its guard without changing anything. The save is
/// planned the way the grid plans one, so the guard is the one the app
/// would send to this engine.
pub async fn row_guard_mismatch_applies_nothing<E: ConformanceEngine>() -> Result<(), ConformanceFailure> {
    let engine = E::start().await?;
    let connection = connect(CASE, &engine, writable()).await?;
    let table = create_scratch_table(&engine, connection.as_ref(), "row_guard").await?;
    let dialect = connection.dialect();
    let insert = insert_sql(dialect.as_ref(), &table, 1, "kept");
    apply(connection.as_ref(), &table, WriteKind::RowChanges, vec![insert]).await?;

    let columns = connection.fetch_columns(&table, within(CALL_DEADLINE)).await?;
    let identity = connection.row_identity(&table, within(CALL_DEADLINE)).await?;
    let label = columns
        .iter()
        .position(|column| column.name == "label")
        .ok_or_else(|| ConformanceFailure::setup(format!("the scratch table has no label column: {columns:?}")))?;
    let changes = ChangeSet {
        updates: vec![RowUpdate {
            key: vec![Value::Int(MISSING_ID)],
            assignments: vec![(label, Value::Text("changed".to_owned()))],
        }],
        ..ChangeSet::default()
    };
    let plan = plan_save(dialect.as_ref(), &table, &columns, &identity, &changes).map_err(ConformanceFailure::setup)?;

    let outcome = connection.write_batch(&plan.batch, within(CALL_DEADLINE)).await;
    if !matches!(outcome, Err(DriverError::RowGuardFailed { actual: 0, .. })) {
        return Err(unexpected(CASE, format!("an update of a missing row gave {outcome:?}")));
    }
    let table_sql = dialect.qualify(&table);
    let kept = format!(
        "SELECT {} FROM {table_sql} WHERE {} = 'kept'",
        dialect.count_all(),
        dialect.quote_identifier("label"),
    );
    let unchanged = connection.count_rows(&statement(&kept), within(CALL_DEADLINE)).await?;
    let rows = count(connection.as_ref(), &table).await?;
    expect(CASE, unchanged == 1 && rows == 1, || {
        format!("after the refused update {unchanged} of {rows} rows still read 'kept'")
    })?;
    connection.close().await?;
    Ok(())
}
