use std::time::Duration;

use tablepro_core::{DriverError, RowLimit, TimeoutPhase};
use tokio::time::Instant;

use crate::conformance::support::{
    CALL_DEADLINE, SCHEDULING_SLACK, connect, expect, statement, unique, within, writable,
};
use crate::conformance::{ConformanceEngine, ConformanceFailure, test_liveness};

const CASE: &str = "query_bound_times_out_within_deadline_plus_cancel_grace";
const DEADLINE: Duration = Duration::from_secs(1);

/// Case 2: a read that never finishes returns a statement timeout within
/// its deadline plus the cancel grace, and the connection still works.
pub async fn query_bound_times_out_within_deadline_plus_cancel_grace<E: ConformanceEngine>(
    engine: E,
) -> Result<(), ConformanceFailure> {
    let bound = DEADLINE + test_liveness().cancel_grace + SCHEDULING_SLACK;
    let connection = connect(CASE, &engine, writable()).await?;
    let unbounded = statement(&engine.unbounded_statement_sql(&unique("deadline")));

    let started = Instant::now();
    let outcome = connection
        .query_bound(&unbounded, RowLimit::EDITOR_DEFAULT, within(DEADLINE))
        .await;
    let elapsed = started.elapsed();

    let timed_out = matches!(
        outcome,
        Err(DriverError::Timeout {
            phase: TimeoutPhase::Statement,
            ..
        })
    );
    expect(CASE, timed_out, || {
        format!("expected a statement timeout, got {outcome:?}")
    })?;
    expect(CASE, elapsed <= bound, || {
        format!("the timeout came after {elapsed:?}, past the {bound:?} bound")
    })?;
    let after = connection
        .query_bound(&statement("SELECT 1"), RowLimit::EDITOR_DEFAULT, within(CALL_DEADLINE))
        .await;
    expect(CASE, after.is_ok(), || {
        format!("SELECT 1 after the timeout gave {after:?}")
    })?;

    connection.close().await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use tablepro_core::QueryResult;

    use super::*;
    use crate::conformance::fake_engine::{FakeEngine, FakeScenario};
    use crate::{ConnectionScript, FakeReply};

    struct Overruns;

    impl FakeScenario for Overruns {
        fn script() -> ConnectionScript {
            let mut script = FakeEngine::<Self>::base_script();
            script.query_bound.when_sql_contains(
                "UNBOUNDED",
                FakeReply::Late {
                    after: Duration::from_secs(10),
                    outcome: Err(DriverError::Timeout {
                        phase: TimeoutPhase::Statement,
                        server_cancelled: true,
                    }),
                },
            );
            script
        }
    }

    struct Honours;

    impl FakeScenario for Honours {
        fn script() -> ConnectionScript {
            let mut script = FakeEngine::<Self>::base_script();
            script
                .query_bound
                .when_sql_contains("UNBOUNDED", FakeReply::UntilStopped)
                .always(FakeReply::ok(QueryResult::empty()));
            script
        }
    }

    #[tokio::test(start_paused = true)]
    async fn deadline_case_fails_when_bound_exceeded() {
        let outcome = query_bound_times_out_within_deadline_plus_cancel_grace(FakeEngine::<Overruns>::new()).await;

        assert!(
            matches!(&outcome, Err(ConformanceFailure::Expectation { case: CASE, detail }) if detail.contains("past the")),
            "{outcome:?}"
        );
    }

    #[tokio::test(start_paused = true)]
    async fn deadline_case_passes_when_the_driver_stops_at_the_deadline() {
        query_bound_times_out_within_deadline_plus_cancel_grace(FakeEngine::<Honours>::new())
            .await
            .unwrap();
    }
}
