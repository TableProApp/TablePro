use std::time::Duration;

use tablepro_core::{ErrorCategory, LinkState, RowLimit};
use tokio::time::Instant;

use crate::conformance::support::{CALL_DEADLINE, SCHEDULING_SLACK, dial, expect, statement, within, writable};
use crate::conformance::{ConformanceFailure, NetworkConformanceEngine, test_liveness};

const CASE: &str = "lost_transport_reports_connection_lost";
const DEADLINE: Duration = Duration::from_secs(1);

/// Case 12: once the route goes quiet, a read reports the connection
/// lost within its deadline plus the cancel grace, and the link says so
/// to everything watching it.
pub async fn lost_transport_reports_connection_lost<E: NetworkConformanceEngine>() -> Result<(), ConformanceFailure> {
    let engine = E::start().await?;
    let liveness = test_liveness();
    let (options, fault) = engine.faulty_connect_options(writable(), liveness).await?;
    let connection = dial(CASE, E::driver(), options).await??;
    let select = statement("SELECT 1");
    connection
        .query_bound(&select, RowLimit::EDITOR_DEFAULT, within(CALL_DEADLINE))
        .await?;

    fault.black_hole();
    let started = Instant::now();
    let outcome = connection
        .query_bound(&select, RowLimit::EDITOR_DEFAULT, within(DEADLINE))
        .await;
    let elapsed = started.elapsed();
    let bound = DEADLINE + liveness.cancel_grace + SCHEDULING_SLACK;

    let lost = matches!(&outcome, Err(error) if error.category() == ErrorCategory::ConnectionLost);
    expect(CASE, lost, || format!("a read over a dropped route gave {outcome:?}"))?;
    expect(CASE, elapsed <= bound, || {
        format!("the loss was reported after {elapsed:?}, past the {bound:?} bound")
    })?;
    expect(CASE, connection.link_state() == LinkState::Lost, || {
        format!("the link is {:?} after the loss", connection.link_state())
    })?;
    let noticed = tokio::time::timeout(liveness.cancel_grace, connection.lost()).await;
    expect(CASE, noticed.is_ok(), || {
        "lost() did not resolve after the loss".to_owned()
    })?;

    // A close over a dead route may fail on its own; what this case
    // checks is the loss, already proven above.
    drop(connection.close().await);
    Ok(())
}
