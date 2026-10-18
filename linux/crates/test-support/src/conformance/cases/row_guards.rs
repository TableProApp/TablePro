use tablepro_core::meta::RowIdentity;
use tablepro_core::save::{ChangeSet, RowChange, RowUpdate, plan_save};
use tablepro_core::statement::RowGuard;
use tablepro_core::value::Value;
use tablepro_core::{ColumnInfo, Connection, DriverError, TableRef, WriteBatch, WriteKind};

use crate::conformance::support::{
    CALL_DEADLINE, apply, connect, count, create_scratch_table, expect, insert_sql, statement, unexpected, within,
    writable,
};
use crate::conformance::{ConformanceEngine, ConformanceFailure};

const CASE: &str = "row_guard_mismatch_applies_nothing";
const KEPT_ID: i64 = 1;
const MISSING_ID: i64 = 999;

/// Case 10: a save whose guard fails changes nothing. One update names
/// a row that is gone, so it matches nothing. The other names the row
/// that is there under a guard asking for one row more, so a driver
/// that applies the write despite its guard leaves the row changed. The
/// saves are planned the way the grid plans one, so the kind of guard
/// is the one the app would send to this engine.
pub async fn row_guard_mismatch_applies_nothing<E: ConformanceEngine>(engine: E) -> Result<(), ConformanceFailure> {
    let connection = connect(CASE, &engine, writable()).await?;
    let table = create_scratch_table(&engine, connection.as_ref(), "row_guard").await?;
    let dialect = connection.dialect();
    let insert = insert_sql(dialect.as_ref(), &table, KEPT_ID, "kept");
    apply(connection.as_ref(), &table, WriteKind::RowChanges, vec![insert]).await?;

    let columns = connection.fetch_columns(&table, within(CALL_DEADLINE)).await?;
    let identity = connection.row_identity(&table, within(CALL_DEADLINE)).await?;
    let label = columns
        .iter()
        .position(|column| column.name == "label")
        .ok_or_else(|| ConformanceFailure::setup(format!("the scratch table has no label column: {columns:?}")))?;
    let update = |id: i64| relabel(connection.as_ref(), &table, &columns, &identity, label, id);

    let missing = update(MISSING_ID)?;
    let outcome = connection.write_batch(&missing, within(CALL_DEADLINE)).await;
    if !matches!(outcome, Err(DriverError::RowGuardFailed { actual: 0, .. })) {
        return Err(unexpected(CASE, format!("an update of a missing row gave {outcome:?}")));
    }

    let mut present = update(KEPT_ID)?;
    for step in &mut present.steps {
        step.guard = one_row_more(&step.guard)?;
    }
    let outcome = connection.write_batch(&present, within(CALL_DEADLINE)).await;
    if !matches!(outcome, Err(DriverError::RowGuardFailed { actual: 1, .. })) {
        return Err(unexpected(
            CASE,
            format!("an update of a present row under a guard it cannot meet gave {outcome:?}"),
        ));
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
        format!("after the refused updates {unchanged} of {rows} rows still read 'kept'")
    })?;
    connection.close().await?;
    Ok(())
}

fn relabel(
    connection: &dyn Connection,
    table: &TableRef,
    columns: &[ColumnInfo],
    identity: &RowIdentity,
    label: usize,
    id: i64,
) -> Result<WriteBatch, ConformanceFailure> {
    let changes = ChangeSet {
        changes: vec![RowChange::Update(RowUpdate {
            key: vec![Value::Int(id)],
            assignments: vec![(label, Value::Text("changed".to_owned()))],
        })],
    };
    let plan = plan_save(connection.dialect().as_ref(), table, columns, identity, &changes)
        .map_err(ConformanceFailure::setup)?;
    Ok(plan.batch)
}

fn one_row_more(guard: &RowGuard) -> Result<RowGuard, ConformanceFailure> {
    match guard {
        RowGuard::AffectedExactly(rows) => Ok(RowGuard::AffectedExactly(rows.saturating_add(1))),
        RowGuard::ProbeExactly { probe, rows } => Ok(RowGuard::ProbeExactly {
            probe: probe.clone(),
            rows: rows.saturating_add(1),
        }),
        RowGuard::None => Err(unexpected(CASE, "the grid planned an update with no row guard")),
    }
}

#[cfg(test)]
mod tests {
    use tablepro_core::WriteReport;
    use tablepro_core::column::{ColumnDefault, ColumnType};

    use super::*;
    use crate::conformance::fake_engine::{FakeEngine, FakeScenario};
    use crate::{ConnectionScript, FakeReply};

    fn column(name: &str) -> ColumnInfo {
        ColumnInfo {
            name: name.to_owned(),
            column_type: ColumnType::untyped_text("text"),
            nullable: false,
            primary_key: name == "id",
            is_auto_increment: false,
            is_generated: false,
            default: ColumnDefault::None,
            comment: None,
        }
    }

    fn guard_failed(actual: u64) -> FakeReply<WriteReport> {
        FakeReply::err(DriverError::RowGuardFailed {
            statement_index: 0,
            expected: actual.saturating_add(1),
            actual,
        })
    }

    /// A table holding the one 'kept' row. The update of the missing row
    /// fails its guard; the update of the present row answers `present`
    /// and leaves `kept_after` rows reading 'kept'.
    fn script(present: FakeReply<WriteReport>, kept_after: u64) -> ConnectionScript {
        let mut script = FakeEngine::<()>::base_script();
        script
            .write_batch
            .when_sql_contains("INSERT", FakeReply::ok(WriteReport::new(vec![Some(1)])))
            .once(guard_failed(0))
            .once(present);
        script
            .fetch_columns
            .always(FakeReply::ok(vec![column("id"), column("label")]));
        script.row_identity.always(FakeReply::ok(RowIdentity::UniqueKey {
            columns: vec!["id".to_owned()],
        }));
        script
            .count_rows
            .when_sql_contains("'kept'", FakeReply::ok(kept_after))
            .always(FakeReply::ok(1));
        script
    }

    struct RollsBack;

    impl FakeScenario for RollsBack {
        fn script() -> ConnectionScript {
            script(guard_failed(1), 1)
        }
    }

    struct IgnoresTheGuard;

    impl FakeScenario for IgnoresTheGuard {
        fn script() -> ConnectionScript {
            script(FakeReply::ok(WriteReport::new(vec![Some(1)])), 0)
        }
    }

    #[tokio::test(start_paused = true)]
    async fn row_guard_case_passes_when_both_updates_are_refused() {
        row_guard_mismatch_applies_nothing(FakeEngine::<RollsBack>::new())
            .await
            .unwrap();
    }

    #[tokio::test(start_paused = true)]
    async fn row_guard_case_fails_when_the_present_row_is_written_despite_its_guard() {
        let outcome = row_guard_mismatch_applies_nothing(FakeEngine::<IgnoresTheGuard>::new()).await;

        assert!(
            matches!(&outcome, Err(ConformanceFailure::Expectation { case: CASE, detail }) if detail.contains("present row")),
            "{outcome:?}"
        );
    }
}
