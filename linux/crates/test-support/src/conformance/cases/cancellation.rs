use std::time::Duration;

use tablepro_core::{EditorSessionOptions, EditorSessionState, RowLimit, RunEnd, RunOptions};
use tokio::time::Instant;
use tokio_util::sync::CancellationToken;

use crate::conformance::support::{
    SCHEDULING_SLACK, connect, expect, no_deadline, run_completed, run_editor, run_options, statement, unexpected,
    unique, wait_for_running, writable,
};
use crate::conformance::{ConformanceEngine, ConformanceFailure, NetworkConformanceEngine, test_liveness};

const EDITOR_CASE: &str = "editor_cancel_reports_cancelled_and_session_stays_ready";
const DROPPED_CASE: &str = "dropped_caller_stops_server_statement";

/// Long enough for the statement to reach the server before the case
/// stops it, so the stop is tested rather than a race with sending.
const SETTLE: Duration = Duration::from_millis(500);
const SEEN_LIMIT: Duration = Duration::from_secs(10);

/// Case 3: cancelling an editor run ends it as cancelled within the
/// cancel grace, and the session takes the next run.
pub async fn editor_cancel_reports_cancelled_and_session_stays_ready<E: ConformanceEngine>()
-> Result<(), ConformanceFailure> {
    let engine = E::start().await?;
    let grace = test_liveness().cancel_grace + SCHEDULING_SLACK;
    let connection = connect(EDITOR_CASE, &engine, writable()).await?;
    let session = connection
        .open_editor_session(EditorSessionOptions::default(), CancellationToken::new())
        .await?;
    let cancel = CancellationToken::new();
    let unbounded = engine.unbounded_statement_sql(&unique("cancel"));

    let running = async {
        let outcome = run_editor(session.as_ref(), &unbounded, RunOptions::new(cancel.clone())).await;
        (outcome, Instant::now())
    };
    let cancelling = async {
        tokio::time::sleep(SETTLE).await;
        cancel.cancel();
        Instant::now()
    };
    let ((outcome, finished), cancelled) = tokio::join!(running, cancelling);
    let (summary, _) = outcome?;
    let after_cancel = finished.saturating_duration_since(cancelled);

    expect(EDITOR_CASE, summary.end == RunEnd::Cancelled, || {
        format!("the cancelled run ended {:?}", summary.end)
    })?;
    expect(EDITOR_CASE, after_cancel <= grace, || {
        format!("the run ended {after_cancel:?} after its cancel, past the {grace:?} grace")
    })?;
    expect(EDITOR_CASE, session.state() == EditorSessionState::Ready, || {
        format!("the session is {:?} after a cancel", session.state())
    })?;
    run_completed(EDITOR_CASE, session.as_ref(), "SELECT 1", run_options()).await?;

    session.close().await;
    connection.close().await?;
    Ok(())
}

/// Case 4: dropping the caller of a running read stops it on the server
/// too, rather than leaving the server working for nobody.
pub async fn dropped_caller_stops_server_statement<E: NetworkConformanceEngine>() -> Result<(), ConformanceFailure> {
    let engine = E::start().await?;
    let bound = test_liveness().cancel_grace + Duration::from_secs(1);
    let connection = connect(DROPPED_CASE, &engine, writable()).await?;
    // An editor session owns its own connection, so the count never
    // waits behind the statement it is counting.
    let monitor = connection
        .open_editor_session(EditorSessionOptions::default(), CancellationToken::new())
        .await?;
    let marker = unique("dropped");
    let count_sql = engine.running_statement_count_sql(&marker);
    let unbounded = statement(&engine.unbounded_statement_sql(&marker));

    {
        let call = connection.query_bound(&unbounded, RowLimit::EDITOR_DEFAULT, no_deadline());
        let seen = wait_for_running(
            DROPPED_CASE,
            monitor.as_ref(),
            &count_sql,
            |running| running >= 1,
            SEEN_LIMIT,
        );
        tokio::select! {
            outcome = call => {
                return Err(unexpected(DROPPED_CASE, format!("the unbounded read finished on its own: {outcome:?}")));
            }
            seen = seen => {
                seen?;
            }
        }
    }
    wait_for_running(
        DROPPED_CASE,
        monitor.as_ref(),
        &count_sql,
        |running| running == 0,
        bound,
    )
    .await?;

    monitor.close().await;
    connection.close().await?;
    Ok(())
}
