use tablepro_core::{DriverError, WriteAtomicity, WriteKind};

use crate::conformance::support::{
    apply, connect, count, create_scratch_table, expect, insert_sql, unexpected, writable,
};
use crate::conformance::{ConformanceEngine, ConformanceFailure};

const COMMITS_CASE: &str = "write_batch_commits_every_step";
const FAILED_CASE: &str = "failed_write_batch_outcome_matches_dml_atomicity";

/// Case 8: a save of three inserts reports each one and lands all three.
pub async fn write_batch_commits_every_step<E: ConformanceEngine>() -> Result<(), ConformanceFailure> {
    let engine = E::start().await?;
    let connection = connect(COMMITS_CASE, &engine, writable()).await?;
    let table = create_scratch_table(&engine, connection.as_ref(), "writes").await?;
    let dialect = connection.dialect();
    let inserts = (1..=3)
        .map(|id| insert_sql(dialect.as_ref(), &table, id, "row"))
        .collect();

    let report = apply(connection.as_ref(), &table, WriteKind::RowChanges, inserts).await?;
    let rows = count(connection.as_ref(), &table).await?;

    expect(COMMITS_CASE, report.rows_affected.len() == 3, || {
        format!("the report covers {:?}, not three statements", report.rows_affected)
    })?;
    expect(COMMITS_CASE, rows == 3, || format!("{rows} rows landed, not 3"))?;
    connection.close().await?;
    Ok(())
}

/// Case 9: a save whose second statement fails leaves what the engine's
/// atomicity promises: nothing on a transactional engine, the first row
/// on one that applies statement by statement.
pub async fn failed_write_batch_outcome_matches_dml_atomicity<E: ConformanceEngine>() -> Result<(), ConformanceFailure>
{
    let engine = E::start().await?;
    let atomicity = E::driver().capabilities().dml_writes;
    let connection = connect(FAILED_CASE, &engine, writable()).await?;
    let table = create_scratch_table(&engine, connection.as_ref(), "failed_write").await?;
    let dialect = connection.dialect();
    let missing_column = format!(
        "INSERT INTO {} ({}, {}, {}) VALUES (2, 'second', 0)",
        dialect.qualify(&table),
        dialect.quote_identifier("id"),
        dialect.quote_identifier("label"),
        dialect.quote_identifier("tp_missing_column"),
    );
    let statements = vec![
        insert_sql(dialect.as_ref(), &table, 1, "first"),
        missing_column,
        insert_sql(dialect.as_ref(), &table, 3, "third"),
    ];

    let outcome = apply(connection.as_ref(), &table, WriteKind::RowChanges, statements).await;
    let expected_rows = match (atomicity, &outcome) {
        (WriteAtomicity::Transactional, Err(DriverError::RolledBack { statement_index: 1, .. })) => 0,
        (WriteAtomicity::StatementByStatement, Err(DriverError::PartiallyApplied { applied: 1, .. })) => 1,
        _ => {
            return Err(unexpected(
                FAILED_CASE,
                format!("a {atomicity:?} engine answered a save failing at statement 1 with {outcome:?}"),
            ));
        }
    };
    let rows = count(connection.as_ref(), &table).await?;
    expect(FAILED_CASE, rows == expected_rows, || {
        format!("{rows} rows remain after the failed save, not {expected_rows}")
    })?;
    connection.close().await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use tablepro_core::{StatementOutcome, WriteReport};

    use super::*;
    use crate::conformance::fake_engine::{FakeEngine, FakeScenario};
    use crate::{ConnectionScript, FakeReply};

    /// A transactional engine that reports a partial save, which only an
    /// engine without transactions may do.
    struct PartialOnTransactional;

    impl FakeScenario for PartialOnTransactional {
        fn script() -> ConnectionScript {
            let mut script = FakeEngine::<Self>::base_script();
            script.write_batch.when_sql_contains(
                "tp_missing_column",
                FakeReply::err(DriverError::PartiallyApplied {
                    applied: 1,
                    statement_index: 1,
                    failed_outcome: StatementOutcome::Failed,
                    source: Box::new(DriverError::server("column tp_missing_column does not exist")),
                }),
            );
            script.count_rows.always(FakeReply::ok(1));
            script
        }
    }

    struct RollsBack;

    impl FakeScenario for RollsBack {
        fn script() -> ConnectionScript {
            let mut script = FakeEngine::<Self>::base_script();
            script.write_batch.when_sql_contains(
                "tp_missing_column",
                FakeReply::err(DriverError::RolledBack {
                    statement_index: 1,
                    source: Box::new(DriverError::server("column tp_missing_column does not exist")),
                }),
            );
            script.count_rows.always(FakeReply::ok(0));
            script
                .write_batch
                .always(FakeReply::ok(WriteReport::new(vec![Some(1); 3])));
            script
        }
    }

    #[tokio::test]
    async fn case_reports_expectation_on_wrong_outcome() {
        let outcome = failed_write_batch_outcome_matches_dml_atomicity::<FakeEngine<PartialOnTransactional>>().await;

        assert!(
            matches!(&outcome, Err(ConformanceFailure::Expectation { case: FAILED_CASE, detail }) if detail.contains("Transactional")),
            "{outcome:?}"
        );
    }

    #[tokio::test]
    async fn failed_write_case_passes_when_a_transactional_engine_rolls_back() {
        failed_write_batch_outcome_matches_dml_atomicity::<FakeEngine<RollsBack>>()
            .await
            .unwrap();
    }
}
