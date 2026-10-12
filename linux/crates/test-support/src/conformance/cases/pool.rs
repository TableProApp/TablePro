use std::time::Duration;

use tablepro_core::{Connection, EditorSessionOptions, ErrorCategory, RowLimit};
use tokio::task::JoinSet;
use tokio::time::Instant;
use tokio_util::sync::CancellationToken;

use crate::conformance::support::{
    SCHEDULING_SLACK, connect, expect, no_deadline, run_completed, run_options, single_count, statement, unexpected,
    unique, within, writable,
};
use crate::conformance::{ConformanceFailure, NetworkConformanceEngine, PooledConformanceEngine, test_liveness};

const CASE: &str = "probe_succeeds_while_every_pool_slot_is_busy";
const HOLD: Duration = Duration::from_secs(6);
const SATURATION_WINDOW: Duration = Duration::from_secs(2);
const RETRY: Duration = Duration::from_millis(50);

/// Case 5: with every pool slot running a statement, the probe still
/// answers, because a busy pool is not a dead server.
pub async fn probe_succeeds_while_every_pool_slot_is_busy<E: PooledConformanceEngine>() -> Result<(), ConformanceFailure>
{
    let engine = E::start().await?;
    pool_case(&engine, None).await
}

/// Case 5 on a network engine, which also asks the server that exactly
/// the pool's size of statements is running.
pub async fn probe_succeeds_while_every_network_pool_slot_is_busy<E>() -> Result<(), ConformanceFailure>
where
    E: PooledConformanceEngine + NetworkConformanceEngine,
{
    let engine = E::start().await?;
    let count_sql = |marker: &str| engine.running_statement_count_sql(marker);
    pool_case(&engine, Some(&count_sql)).await
}

async fn pool_case<E: PooledConformanceEngine>(
    engine: &E,
    count_sql: Option<&(dyn Fn(&str) -> String + Sync)>,
) -> Result<(), ConformanceFailure> {
    let liveness = test_liveness();
    let size = E::WORKSPACE_POOL_MAX_SIZE;
    let connection = connect(CASE, engine, writable()).await?;
    let monitor = match count_sql {
        Some(_) => Some(
            connection
                .open_editor_session(EditorSessionOptions::default(), CancellationToken::new())
                .await?,
        ),
        None => None,
    };
    let marker = unique("pool");
    let mut blockers = JoinSet::new();
    for _ in 0..size {
        let blocking = statement(&engine.blocking_statement_sql(&marker, HOLD).await?);
        let connection = connection.clone();
        blockers.spawn(async move {
            connection
                .query_bound(&blocking, RowLimit::EDITOR_DEFAULT, no_deadline())
                .await
        });
    }

    prove_saturated(connection.as_ref(), size).await?;
    if let (Some(monitor), Some(count_sql)) = (&monitor, count_sql) {
        let rows = run_completed(CASE, monitor.as_ref(), &count_sql(&marker), run_options())
            .await?
            .rows();
        let running = single_count(&rows);
        expect(CASE, running == u64::try_from(size).ok(), || {
            format!("the server runs {running:?} of the pool's {size} statements")
        })?;
    }
    let started = Instant::now();
    let probed = connection.probe(within(liveness.probe_timeout)).await;
    let elapsed = started.elapsed();
    let bound = liveness.probe_timeout + liveness.cancel_grace + SCHEDULING_SLACK;
    expect(CASE, probed.is_ok(), || {
        format!("the probe of a busy pool gave {probed:?}")
    })?;
    expect(CASE, elapsed <= bound, || {
        format!("the probe took {elapsed:?}, past the {bound:?} bound")
    })?;
    while let Some(joined) = blockers.join_next().await {
        let outcome = joined.map_err(ConformanceFailure::setup)?;
        expect(CASE, outcome.is_ok(), || {
            format!("a statement holding a pool slot gave {outcome:?}")
        })?;
    }

    if let Some(monitor) = monitor {
        monitor.close().await;
    }
    connection.close().await?;
    Ok(())
}

/// Show the pool is full before probing it: one more read must wait out
/// the pool wait and come back busy. A slot can still be free for a
/// moment while the statements reach the server, so a read that runs is
/// retried for a short window rather than failing the case at once.
async fn prove_saturated(connection: &dyn Connection, size: usize) -> Result<(), ConformanceFailure> {
    let give_up = Instant::now() + SATURATION_WINDOW;
    loop {
        let extra = connection
            .query_bound(&statement("SELECT 1"), RowLimit::EDITOR_DEFAULT, no_deadline())
            .await;
        match extra {
            Err(error) if error.category() == ErrorCategory::Busy => return Ok(()),
            Ok(_) if Instant::now() < give_up => tokio::time::sleep(RETRY).await,
            Ok(_) => {
                return Err(unexpected(
                    CASE,
                    format!("a read beyond the pool's {size} slots still ran after {SATURATION_WINDOW:?}"),
                ));
            }
            Err(error) => {
                return Err(unexpected(
                    CASE,
                    format!("a read beyond the pool's {size} slots failed with {error:?}, not Busy"),
                ));
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use tablepro_core::{DriverError, QueryResult};

    use super::*;
    use crate::conformance::fake_engine::{FakeEngine, FakeScenario};
    use crate::{ConnectionScript, FakeReply};

    fn holding() -> FakeReply<QueryResult> {
        FakeReply::Bounded {
            after: HOLD,
            outcome: Ok(QueryResult::empty()),
        }
    }

    struct NeverFull;

    impl FakeScenario for NeverFull {
        fn script() -> ConnectionScript {
            let mut script = FakeEngine::<Self>::base_script();
            script
                .query_bound
                .when_sql_contains("BLOCK", holding())
                .always(FakeReply::ok(QueryResult::empty()));
            script
        }
    }

    struct FillsUp;

    impl FakeScenario for FillsUp {
        fn script() -> ConnectionScript {
            let mut script = FakeEngine::<Self>::base_script();
            script
                .query_bound
                .when_sql_contains("BLOCK", holding())
                .always(FakeReply::Bounded {
                    after: test_liveness().pool_wait,
                    outcome: Err(DriverError::Busy),
                });
            script
        }
    }

    #[tokio::test(start_paused = true)]
    async fn pool_case_fails_when_saturation_never_appears() {
        let outcome = probe_succeeds_while_every_pool_slot_is_busy::<FakeEngine<NeverFull>>().await;

        assert!(
            matches!(&outcome, Err(ConformanceFailure::Expectation { case: CASE, detail }) if detail.contains("still ran")),
            "{outcome:?}"
        );
    }

    #[tokio::test(start_paused = true)]
    async fn pool_case_passes_when_the_full_pool_reports_busy() {
        probe_succeeds_while_every_pool_slot_is_busy::<FakeEngine<FillsUp>>()
            .await
            .unwrap();
    }
}
