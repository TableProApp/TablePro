use tablepro_core::{EditorSessionOptions, RowLimit, RunEnd, RunOptions, Truncation};
use tokio_util::sync::CancellationToken;

use crate::conformance::support::{
    connect, count, create_scratch_table, expect, insert_sql, run_completed, run_editor, run_options, writable,
};
use crate::conformance::{ConformanceFailure, EditorTransactionEngine};

const CASE: &str = "row_limit_keeps_transaction_and_later_statements";
const KEPT_ROWS: u64 = 100;

/// Case 6: a run that stops at its row limit inside a transaction keeps
/// the transaction, and what runs after it still commits.
pub async fn row_limit_keeps_transaction_and_later_statements<E: EditorTransactionEngine>(
    engine: E,
) -> Result<(), ConformanceFailure> {
    let connection = connect(CASE, &engine, writable()).await?;
    let table = create_scratch_table(&engine, connection.as_ref(), "row_limit").await?;
    let dialect = connection.dialect();
    let session = connection
        .open_editor_session(EditorSessionOptions::default(), CancellationToken::new())
        .await?;
    let limit = RowLimit::new(KEPT_ROWS).ok_or_else(|| ConformanceFailure::setup("a row limit of zero"))?;

    for sql in [engine.begin_sql(), insert_sql(dialect.as_ref(), &table, 1, "first")] {
        run_completed(CASE, session.as_ref(), &sql, run_options()).await?;
    }
    let limited = RunOptions::new(CancellationToken::new()).with_row_limit(limit);
    let (summary, events) = run_editor(session.as_ref(), &engine.row_source_sql(1_000), limited).await?;
    let kept = events.rows().len();
    let truncations = events.truncations();
    expect(CASE, summary.end == RunEnd::Completed, || {
        format!("the limited read ended {:?}", summary.end)
    })?;
    expect(CASE, u64::try_from(kept).ok() == Some(KEPT_ROWS), || {
        format!("the limited read kept {kept} rows, not {KEPT_ROWS}")
    })?;
    expect(CASE, truncations == [Truncation::ReadPastLimit], || {
        format!("the limited read finished with {truncations:?}")
    })?;
    for sql in [insert_sql(dialect.as_ref(), &table, 2, "second"), engine.commit_sql()] {
        run_completed(CASE, session.as_ref(), &sql, run_options()).await?;
    }
    let rows = count(connection.as_ref(), &table).await?;
    expect(CASE, rows == 2, || format!("{rows} rows were committed, not 2"))?;

    session.close().await;
    connection.close().await?;
    Ok(())
}
