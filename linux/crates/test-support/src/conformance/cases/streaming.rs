use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use tablepro_core::{DriverError, ReadStatement, ResultEvent, ResultSink, RowLimit, SinkFlow, Truncation, UserSql};

use crate::conformance::support::{CALL_DEADLINE, connect, expect, statement, within, writable};
use crate::conformance::{ConformanceEngine, ConformanceFailure};
use crate::lock;

const CASE: &str = "stream_read_streams_every_row_in_bounded_batches";

/// Enough rows that a driver gathering the whole result before handing
/// any of it on shows up as one oversized batch.
const ROWS: u64 = 50_000;

/// Far above the batch a driver sends and far below the whole read, so
/// the rows held between two sink calls stay bounded.
const MAX_BATCH_ROWS: usize = 4_096;

/// A read long enough that running it to its end after the sink stopped
/// would deliver far more than the one batch the sink took.
const STOPPED_ROWS: u64 = 1_000_000;

/// An export takes as long as it takes; this only keeps a stuck driver
/// from hanging the suite.
const STREAM_DEADLINE: Duration = Duration::from_secs(120);

/// Case 15: an export streams every row of a 50,000-row read through the
/// sink in bounded batches, inside one started and finished result set,
/// and a sink that stops reading ends the read without being reported
/// as a whole one. The connection answers afterwards.
pub async fn stream_read_streams_every_row_in_bounded_batches<E: ConformanceEngine>() -> Result<(), ConformanceFailure>
{
    let engine = E::start().await?;
    let connection = connect(CASE, &engine, writable()).await?;

    let whole = Tally::default();
    let read = ReadStatement::User(UserSql::new(engine.row_source_sql(ROWS)));
    let summary = connection
        .stream_read(&read, whole.sink(None), within(STREAM_DEADLINE))
        .await?;
    let tally = whole.snapshot();
    let delivered: u64 = tally.batches.iter().map(|rows| *rows as u64).sum();
    expect(CASE, summary.rows == ROWS && delivered == ROWS, || {
        format!(
            "the read reported {} rows and delivered {delivered}, not {ROWS}",
            summary.rows
        )
    })?;
    expect(
        CASE,
        tally.started == 1 && tally.finished == [Truncation::Complete] && !tally.out_of_set,
        || format!("the events did not form one complete result set: {tally:?}"),
    )?;
    let largest = tally.batches.iter().copied().max().unwrap_or_default();
    expect(CASE, largest <= MAX_BATCH_ROWS, || {
        format!("one batch held {largest} rows, past the {MAX_BATCH_ROWS}-row bound")
    })?;

    let stopping = Tally::default();
    let read = ReadStatement::User(UserSql::new(engine.row_source_sql(STOPPED_ROWS)));
    let stopped = connection
        .stream_read(&read, stopping.sink(Some(1)), within(STREAM_DEADLINE))
        .await;
    let tally = stopping.snapshot();
    expect(CASE, tally.after_stop == 0, || {
        format!("the driver sent {} events after the sink stopped", tally.after_stop)
    })?;
    let reported_whole = matches!(&stopped, Ok(summary) if summary.rows >= STOPPED_ROWS);
    let failed_otherwise = matches!(&stopped, Err(error) if *error != DriverError::Cancelled);
    expect(CASE, !reported_whole && !failed_otherwise, || {
        format!("a read the sink stopped ended {stopped:?}")
    })?;
    let after = connection
        .query_bound(&statement("SELECT 1"), RowLimit::EDITOR_DEFAULT, within(CALL_DEADLINE))
        .await;
    expect(CASE, after.is_ok(), || {
        format!("SELECT 1 after the stopped read gave {after:?}")
    })?;

    connection.close().await?;
    Ok(())
}

/// What a sink saw, without keeping the rows themselves.
#[derive(Debug, Clone, Default)]
struct Seen {
    started: usize,
    batches: Vec<usize>,
    finished: Vec<Truncation>,
    /// Rows or a finish that arrived outside a started result set.
    out_of_set: bool,
    open: bool,
    stopped: bool,
    after_stop: usize,
}

#[derive(Debug, Clone, Default)]
struct Tally(Arc<Mutex<Seen>>);

impl Tally {
    /// A sink that stops reading once it has taken `stop_after` batches,
    /// or never.
    fn sink(&self, stop_after: Option<usize>) -> Box<dyn ResultSink> {
        Box::new(TallySink {
            seen: self.0.clone(),
            stop_after,
        })
    }

    fn snapshot(&self) -> Seen {
        lock(&self.0).clone()
    }
}

struct TallySink {
    seen: Arc<Mutex<Seen>>,
    stop_after: Option<usize>,
}

#[async_trait]
impl ResultSink for TallySink {
    async fn accept(&mut self, event: ResultEvent) -> SinkFlow {
        let mut seen = lock(&self.seen);
        if seen.stopped {
            seen.after_stop += 1;
            return SinkFlow::ConsumerGone;
        }
        match event {
            ResultEvent::ResultSetStarted { .. } => {
                seen.started += 1;
                seen.open = true;
            }
            ResultEvent::Rows(rows) => {
                seen.out_of_set |= !seen.open;
                seen.batches.push(rows.len());
            }
            ResultEvent::ResultSetFinished { truncation, .. } => {
                seen.out_of_set |= !seen.open;
                seen.open = false;
                seen.finished.push(truncation);
            }
            _ => {}
        }
        if self.stop_after.is_some_and(|limit| seen.batches.len() >= limit) {
            seen.stopped = true;
            return SinkFlow::ConsumerGone;
        }
        SinkFlow::Continue
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use tablepro_core::column::ResultColumn;
    use tablepro_core::{QueryResult, Value};

    use super::*;
    use crate::conformance::fake_engine::{FakeEngine, FakeScenario};
    use crate::{ConnectionScript, FakeReply};

    fn result_set(batches: &[usize]) -> Vec<ResultEvent> {
        let columns: Arc<[ResultColumn]> = Arc::from(Vec::new());
        let mut events = vec![ResultEvent::ResultSetStarted { columns }];
        let mut total = 0_u64;
        for rows in batches {
            events.push(ResultEvent::Rows(vec![vec![Value::Int(1)]; *rows]));
            total += *rows as u64;
        }
        events.push(ResultEvent::ResultSetFinished {
            retained: total,
            total_rows: Some(total),
            truncation: Truncation::Complete,
        });
        events
    }

    fn script(whole_read: Vec<ResultEvent>) -> ConnectionScript {
        let mut script = FakeEngine::<Batched>::base_script();
        script
            .stream_read
            .when_sql_contains(format!("ROWS {ROWS}"), FakeReply::ok(whole_read))
            .when_sql_contains(format!("ROWS {STOPPED_ROWS}"), FakeReply::ok(result_set(&[256; 8])));
        script.query_bound.always(FakeReply::ok(QueryResult::empty()));
        script
    }

    struct Batched;

    impl FakeScenario for Batched {
        fn script() -> ConnectionScript {
            let mut batches = vec![256; (ROWS / 256) as usize];
            batches.push((ROWS % 256) as usize);
            script(result_set(&batches))
        }
    }

    struct OneBlock;

    impl FakeScenario for OneBlock {
        fn script() -> ConnectionScript {
            script(result_set(&[ROWS as usize]))
        }
    }

    #[tokio::test]
    async fn stream_case_passes_when_rows_arrive_in_batches() {
        stream_read_streams_every_row_in_bounded_batches::<FakeEngine<Batched>>()
            .await
            .unwrap();
    }

    #[tokio::test]
    async fn stream_case_fails_when_rows_arrive_in_one_block() {
        let outcome = stream_read_streams_every_row_in_bounded_batches::<FakeEngine<OneBlock>>().await;

        assert!(
            matches!(&outcome, Err(ConformanceFailure::Expectation { case: CASE, detail }) if detail.contains("one batch held")),
            "{outcome:?}"
        );
    }
}
