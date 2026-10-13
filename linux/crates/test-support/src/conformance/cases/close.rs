use tablepro_core::RowLimit;

use crate::conformance::support::{CALL_DEADLINE, SCHEDULING_SLACK, connect, expect, statement, within, writable};
use crate::conformance::{ConformanceEngine, ConformanceFailure, test_liveness};

const CASE: &str = "close_is_idempotent";

/// Case 14: closing twice is fine and quick, and a call after the close
/// fails rather than reopening the pool or hanging.
pub async fn close_is_idempotent<E: ConformanceEngine>(engine: E) -> Result<(), ConformanceFailure> {
    let liveness = test_liveness();
    let connection = connect(CASE, &engine, writable()).await?;
    connection.probe(within(liveness.probe_timeout)).await?;
    let close_bound = liveness.close_timeout + liveness.cancel_grace + SCHEDULING_SLACK;

    for attempt in ["first", "second"] {
        let closed = tokio::time::timeout(close_bound, connection.close()).await;
        expect(CASE, matches!(closed, Ok(Ok(()))), || {
            format!("the {attempt} close gave {closed:?} within {close_bound:?}")
        })?;
    }
    let call_bound = liveness.pool_wait + liveness.cancel_grace + SCHEDULING_SLACK;
    let after = tokio::time::timeout(
        call_bound,
        connection.query_bound(&statement("SELECT 1"), RowLimit::EDITOR_DEFAULT, within(CALL_DEADLINE)),
    )
    .await;
    expect(CASE, matches!(after, Ok(Err(_))), || {
        format!("a read after close gave {after:?} within {call_bound:?}")
    })?;
    Ok(())
}
