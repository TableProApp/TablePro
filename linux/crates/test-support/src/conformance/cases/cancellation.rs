use std::time::Duration;

use tablepro_core::{
    DriverError, EditorSession, EditorSessionOptions, EditorSessionState, RowLimit, RunEnd, RunOptions,
};
use tokio::time::Instant;
use tokio_util::sync::CancellationToken;

use crate::conformance::support::{
    CALL_DEADLINE, SCHEDULING_SLACK, connect, expect, no_deadline, run_completed, run_editor, run_options, statement,
    unexpected, unique, wait_for_running, within, writable,
};
use crate::conformance::{ConformanceEngine, ConformanceFailure, ServerStopEngine, test_liveness};

const EDITOR_CASE: &str = "editor_cancel_reports_cancelled_and_session_stays_ready";
const DROPPED_CASE: &str = "dropped_caller_stops_server_statement";
const DROPPED_EDITOR_CASE: &str = "dropped_editor_run_stops_server_statement";
const DROPPED_FILE_EDITOR_CASE: &str = "dropped_editor_run_frees_the_session";
const ABANDONED_CASE: &str = "dropped_caller_leaves_the_connection_serving";

/// Long enough for the statement to reach the server before the case
/// stops it, so the stop is tested rather than a race with sending.
const SETTLE: Duration = Duration::from_millis(500);
const SEEN_LIMIT: Duration = Duration::from_secs(10);

/// Case 3: cancelling an editor run ends it as cancelled within the
/// cancel grace, and the session takes the next run.
pub async fn editor_cancel_reports_cancelled_and_session_stays_ready<E: ConformanceEngine>(
    engine: E,
) -> Result<(), ConformanceFailure> {
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
    run_completed(EDITOR_CASE, session.as_ref(), &engine.trivial_read_sql(), run_options()).await?;

    session.close().await;
    connection.close().await?;
    Ok(())
}

/// Case 4: dropping the caller of a running read stops it on the server
/// too, rather than leaving the server working for nobody.
pub async fn dropped_caller_stops_server_statement<E: ServerStopEngine>(engine: E) -> Result<(), ConformanceFailure> {
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

/// Case 4b: dropping the caller of an editor run stops its statement on
/// the server too, and the session then takes the next run or reports
/// itself lost, rather than staying busy for nobody.
pub async fn dropped_editor_run_stops_server_statement<E: ServerStopEngine>(
    engine: E,
) -> Result<(), ConformanceFailure> {
    let bound = test_liveness().cancel_grace + Duration::from_secs(1);
    let connection = connect(DROPPED_EDITOR_CASE, &engine, writable()).await?;
    let monitor = connection
        .open_editor_session(EditorSessionOptions::default(), CancellationToken::new())
        .await?;
    let session = connection
        .open_editor_session(EditorSessionOptions::default(), CancellationToken::new())
        .await?;
    let marker = unique("dropped_editor");
    let count_sql = engine.running_statement_count_sql(&marker);
    let unbounded = engine.unbounded_statement_sql(&marker);

    {
        let run = run_editor(session.as_ref(), &unbounded, run_options());
        let seen = wait_for_running(
            DROPPED_EDITOR_CASE,
            monitor.as_ref(),
            &count_sql,
            |running| running >= 1,
            SEEN_LIMIT,
        );
        tokio::select! {
            outcome = run => {
                return Err(unexpected(
                    DROPPED_EDITOR_CASE,
                    format!("the unbounded run finished on its own: {outcome:?}"),
                ));
            }
            seen = seen => {
                seen?;
            }
        }
    }
    wait_for_running(
        DROPPED_EDITOR_CASE,
        monitor.as_ref(),
        &count_sql,
        |running| running == 0,
        bound,
    )
    .await?;
    let trivial = engine.trivial_read_sql();
    let ready = settled_after_drop(DROPPED_EDITOR_CASE, session.as_ref(), bound, &trivial).await?;
    if !ready {
        let refused = run_editor(session.as_ref(), &trivial, run_options()).await;
        expect(
            DROPPED_EDITOR_CASE,
            matches!(refused, Err(DriverError::ConnectionLost { .. })),
            || format!("a lost session answered a run with {refused:?}"),
        )?;
    }

    session.close().await;
    monitor.close().await;
    connection.close().await?;
    Ok(())
}

/// Case 4 for an engine whose protocol carries no stop: dropping the
/// caller of a running read ends the call at once, and the connection
/// takes the next read within the cancel grace while the server finishes
/// the dropped one on its own.
pub async fn dropped_caller_leaves_the_connection_serving<E: ConformanceEngine>(
    engine: E,
) -> Result<(), ConformanceFailure> {
    let bound = test_liveness().cancel_grace + SCHEDULING_SLACK;
    let connection = connect(ABANDONED_CASE, &engine, writable()).await?;
    let unbounded = statement(&engine.unbounded_statement_sql(&unique("abandoned")));

    {
        let call = connection.query_bound(&unbounded, RowLimit::EDITOR_DEFAULT, no_deadline());
        tokio::select! {
            outcome = call => {
                return Err(unexpected(ABANDONED_CASE, format!("the unbounded read finished on its own: {outcome:?}")));
            }
            () = tokio::time::sleep(SETTLE) => {}
        }
    }
    let started = Instant::now();
    let after = connection
        .query_bound(
            &statement(&engine.trivial_read_sql()),
            RowLimit::EDITOR_DEFAULT,
            within(CALL_DEADLINE),
        )
        .await;
    let took = started.elapsed();
    expect(ABANDONED_CASE, after.is_ok(), || {
        format!("a read after the dropped one gave {after:?}")
    })?;
    expect(ABANDONED_CASE, took <= bound, || {
        format!("the next read took {took:?}, so the dropped one still held the connection")
    })?;

    connection.close().await?;
    Ok(())
}

/// Case 4b for an engine without a server: with nothing to ask what is
/// still running, the next run on the same connection is the proof that
/// the dropped one stopped.
pub async fn dropped_editor_run_frees_the_session<E: ConformanceEngine>(engine: E) -> Result<(), ConformanceFailure> {
    let bound = test_liveness().cancel_grace + SCHEDULING_SLACK;
    let connection = connect(DROPPED_FILE_EDITOR_CASE, &engine, writable()).await?;
    let session = connection
        .open_editor_session(EditorSessionOptions::default(), CancellationToken::new())
        .await?;
    let unbounded = engine.unbounded_statement_sql(&unique("dropped_editor"));

    {
        let run = run_editor(session.as_ref(), &unbounded, run_options());
        tokio::select! {
            outcome = run => {
                return Err(unexpected(
                    DROPPED_FILE_EDITOR_CASE,
                    format!("the unbounded run finished on its own: {outcome:?}"),
                ));
            }
            () = tokio::time::sleep(SETTLE) => {}
        }
    }
    let ready = settled_after_drop(
        DROPPED_FILE_EDITOR_CASE,
        session.as_ref(),
        bound,
        &engine.trivial_read_sql(),
    )
    .await?;
    expect(DROPPED_FILE_EDITOR_CASE, ready, || {
        "the session was lost to a dropped run".to_owned()
    })?;

    session.close().await;
    connection.close().await?;
    Ok(())
}

/// Wait out a dropped run: within `bound` the session must stop saying
/// `Running`. A ready session must then complete a run, which it cannot
/// while the dropped statement still holds its connection. Says whether
/// the session was ready rather than lost.
async fn settled_after_drop(
    case: &'static str,
    session: &dyn EditorSession,
    bound: Duration,
    trivial: &str,
) -> Result<bool, ConformanceFailure> {
    let give_up = Instant::now() + bound;
    while session.state() == EditorSessionState::Running {
        if Instant::now() >= give_up {
            return Err(unexpected(
                case,
                format!("the session still says Running {bound:?} after its run was dropped"),
            ));
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    if session.state() == EditorSessionState::Lost {
        return Ok(false);
    }
    let next = run_options().with_deadline(Some(CALL_DEADLINE));
    let started = Instant::now();
    run_completed(case, session, trivial, next).await?;
    let took = started.elapsed();
    expect(case, took <= bound, || {
        format!("the next run took {took:?}, so the dropped statement still held the connection")
    })?;
    Ok(true)
}
