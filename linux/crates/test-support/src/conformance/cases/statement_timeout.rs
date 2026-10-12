use std::time::Duration;

use tablepro_core::{DriverError, ErrorCategory, WorkspaceSettings, WriteKind};
use tokio::time::Instant;

use crate::conformance::support::{apply, connect, expect, unexpected, unique};
use crate::conformance::{BoundedDdlEngine, ConformanceFailure};

const CASE: &str = "schema_changes_batch_is_not_bounded_by_statement_timeout";
const STATEMENT_TIMEOUT: Duration = Duration::from_secs(1);
const SCHEMA_CHANGE: Duration = Duration::from_secs(3);

/// Case 11: the workspace statement timeout stops a slow row change, and
/// the same work saved as a schema change runs to the end.
pub async fn schema_changes_batch_is_not_bounded_by_statement_timeout<E: BoundedDdlEngine>()
-> Result<(), ConformanceFailure> {
    let engine = E::start().await?;
    let settings = WorkspaceSettings {
        statement_timeout: STATEMENT_TIMEOUT,
        ..WorkspaceSettings::workspace(false)
    };
    let connection = connect(CASE, &engine, settings).await?;
    let bounded = engine.scratch_table(&unique("ddl_bounded"));
    let unbounded = engine.scratch_table(&unique("ddl_unbounded"));

    // The row-change run proves the bound is real, so the schema-change
    // run below passes for the right reason.
    let slow = engine.schema_change_exceeding_sql(&bounded, SCHEMA_CHANGE);
    let stopped = apply(connection.as_ref(), &bounded, WriteKind::RowChanges, vec![slow]).await;
    let timed_out = match &stopped {
        Err(DriverError::RolledBack { source, .. }) => source.category() == ErrorCategory::Timeout,
        Err(error) => error.category() == ErrorCategory::Timeout,
        Ok(_) => false,
    };
    expect(CASE, timed_out, || {
        format!(
            "a {SCHEMA_CHANGE:?} change saved as row changes under a {STATEMENT_TIMEOUT:?} timeout gave {stopped:?}"
        )
    })?;

    let slow = engine.schema_change_exceeding_sql(&unbounded, SCHEMA_CHANGE);
    let started = Instant::now();
    let finished = apply(connection.as_ref(), &unbounded, WriteKind::SchemaChanges, vec![slow]).await;
    let elapsed = started.elapsed();
    if let Err(error) = finished {
        return Err(unexpected(CASE, format!("the schema change was stopped: {error:?}")));
    }
    expect(CASE, elapsed >= SCHEMA_CHANGE, || {
        format!("the schema change finished in {elapsed:?}, so it never ran long enough to test the bound")
    })?;
    connection.close().await?;
    Ok(())
}
