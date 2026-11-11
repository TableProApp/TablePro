use async_trait::async_trait;

use crate::byte_limit::{ByteLimit, row_bytes};
use crate::result_event::{ResultEvent, Truncation};
use crate::result_sink::{ResultSink, SinkFlow};
use crate::value::Value;

// The row that crosses the limit is kept whole, so a run shows at least one row and every kept value is exact.
pub struct ByteLimitSink {
    inner: Box<dyn ResultSink>,
    limit: u64,
    kept: u64,
    set_rows: u64,
    set_cut: bool,
}

impl ByteLimitSink {
    pub fn new(inner: Box<dyn ResultSink>, limit: ByteLimit) -> Self {
        Self {
            inner,
            limit: limit.get(),
            kept: 0,
            set_rows: 0,
            set_cut: false,
        }
    }

    // Never ConsumerGone past the cut: that cancels the statement, which aborts the user's transaction on some engines.
    async fn rows(&mut self, mut rows: Vec<Vec<Value>>) -> SinkFlow {
        if self.set_cut {
            return SinkFlow::Continue;
        }
        let mut keep = 0;
        for row in &rows {
            if self.kept >= self.limit {
                break;
            }
            self.kept = self.kept.saturating_add(row_bytes(row));
            keep += 1;
        }
        self.set_rows += keep as u64;
        if keep == rows.len() {
            return self.inner.accept(ResultEvent::Rows(rows)).await;
        }
        rows.truncate(keep);
        if !rows.is_empty() && self.inner.accept(ResultEvent::Rows(rows)).await == SinkFlow::ConsumerGone {
            return SinkFlow::ConsumerGone;
        }
        self.set_cut = true;
        self.inner
            .accept(ResultEvent::ByteLimitReached {
                retained: self.set_rows,
            })
            .await
    }

    fn start_set(&mut self) {
        self.set_rows = 0;
        self.set_cut = false;
    }
}

#[async_trait]
impl ResultSink for ByteLimitSink {
    async fn accept(&mut self, event: ResultEvent) -> SinkFlow {
        let event = match event {
            ResultEvent::Rows(rows) => return self.rows(rows).await,
            ResultEvent::ResultSetStarted { columns } => {
                self.start_set();
                ResultEvent::ResultSetStarted { columns }
            }
            ResultEvent::RowLimitReached { .. } | ResultEvent::ByteLimitReached { .. } if self.set_cut => {
                return SinkFlow::Continue;
            }
            // A driver that holds a set before its first event stops at the limit itself.
            ResultEvent::ByteLimitReached { retained } => {
                self.set_cut = true;
                self.kept = self.kept.max(self.limit);
                ResultEvent::ByteLimitReached { retained }
            }
            ResultEvent::ResultSetFinished {
                total_rows, truncation, ..
            } if self.set_cut => {
                // A statement the server stopped did less than one read to its end, which the app has to say.
                let truncation = match truncation {
                    Truncation::ServerStopped => Truncation::ServerStopped,
                    Truncation::Complete | Truncation::ReadPastLimit | Truncation::ByteLimit => Truncation::ByteLimit,
                };
                let finished = ResultEvent::ResultSetFinished {
                    retained: self.set_rows,
                    total_rows,
                    truncation,
                };
                self.start_set();
                finished
            }
            ResultEvent::ResultSetFinished {
                retained,
                total_rows,
                truncation,
            } => {
                self.start_set();
                ResultEvent::ResultSetFinished {
                    retained,
                    total_rows,
                    truncation,
                }
            }
            other => other,
        };
        self.inner.accept(event).await
    }
}

#[cfg(test)]
mod tests {
    use std::sync::{Arc, Mutex};

    use super::*;
    use crate::column::{ColumnType, ResultColumn};

    const SLOT: usize = size_of::<Value>();

    #[derive(Clone, Default)]
    struct Seen {
        events: Arc<Mutex<Vec<ResultEvent>>>,
        gone: bool,
    }

    #[async_trait]
    impl ResultSink for Seen {
        async fn accept(&mut self, event: ResultEvent) -> SinkFlow {
            self.events.lock().expect("the events").push(event);
            match self.gone {
                true => SinkFlow::ConsumerGone,
                false => SinkFlow::Continue,
            }
        }
    }

    impl Seen {
        fn events(&self) -> Vec<ResultEvent> {
            self.events.lock().expect("the events").clone()
        }
    }

    fn sink(seen: &Seen, bytes: u64) -> ByteLimitSink {
        ByteLimitSink::new(Box::new(seen.clone()), ByteLimit::new(bytes).expect("a limit"))
    }

    fn started() -> ResultEvent {
        let columns: Arc<[ResultColumn]> = vec![ResultColumn::new("label", ColumnType::untyped_text(""))].into();
        ResultEvent::ResultSetStarted { columns }
    }

    // One text value whose row measures exactly `bytes`.
    fn row(bytes: usize, mark: char) -> Vec<Value> {
        vec![Value::Text(mark.to_string().repeat(bytes - SLOT))]
    }

    fn rows(count: usize, bytes: usize) -> Vec<Vec<Value>> {
        (0..count).map(|_| row(bytes, 'x')).collect()
    }

    fn finished(retained: u64, total_rows: Option<u64>, truncation: Truncation) -> ResultEvent {
        ResultEvent::ResultSetFinished {
            retained,
            total_rows,
            truncation,
        }
    }

    async fn play(sink: &mut ByteLimitSink, events: Vec<ResultEvent>) -> Vec<SinkFlow> {
        let mut flows = Vec::new();
        for event in events {
            flows.push(sink.accept(event).await);
        }
        flows
    }

    #[tokio::test]
    async fn a_set_under_the_limit_passes_as_it_came() {
        let seen = Seen::default();
        let events = vec![
            started(),
            ResultEvent::Rows(rows(3, 100)),
            finished(3, Some(3), Truncation::Complete),
        ];

        play(&mut sink(&seen, 1_000), events.clone()).await;

        assert_eq!(seen.events(), events);
    }

    #[tokio::test]
    async fn a_set_read_to_its_end_is_cut_with_its_exact_total() {
        let seen = Seen::default();

        let flows = play(
            &mut sink(&seen, 250),
            vec![
                started(),
                ResultEvent::Rows(rows(10, 100)),
                finished(10, Some(10), Truncation::Complete),
            ],
        )
        .await;

        assert_eq!(
            seen.events(),
            [
                started(),
                ResultEvent::Rows(rows(3, 100)),
                ResultEvent::ByteLimitReached { retained: 3 },
                finished(3, Some(10), Truncation::ByteLimit),
            ]
        );
        assert!(flows.iter().all(|flow| *flow == SinkFlow::Continue), "{flows:?}");
    }

    #[tokio::test]
    async fn the_drivers_row_limit_is_swallowed_for_a_set_already_cut() {
        let seen = Seen::default();

        play(
            &mut sink(&seen, 250),
            vec![
                started(),
                ResultEvent::Rows(rows(2, 100)),
                ResultEvent::Rows(rows(8, 100)),
                ResultEvent::RowLimitReached { retained: 10 },
                finished(10, None, Truncation::ServerStopped),
            ],
        )
        .await;

        assert_eq!(
            seen.events(),
            [
                started(),
                ResultEvent::Rows(rows(2, 100)),
                ResultEvent::Rows(rows(1, 100)),
                ResultEvent::ByteLimitReached { retained: 3 },
                finished(3, None, Truncation::ServerStopped),
            ]
        );
    }

    #[tokio::test]
    async fn a_counted_total_past_the_row_limit_passes_through() {
        let seen = Seen::default();

        play(
            &mut sink(&seen, 150),
            vec![
                started(),
                ResultEvent::Rows(rows(10, 100)),
                ResultEvent::RowLimitReached { retained: 10 },
                finished(10, Some(50), Truncation::ReadPastLimit),
            ],
        )
        .await;

        assert_eq!(
            seen.events().last(),
            Some(&finished(2, Some(50), Truncation::ByteLimit))
        );
    }

    #[tokio::test]
    async fn the_row_that_crosses_the_limit_is_kept_whole() {
        let seen = Seen::default();

        play(
            &mut sink(&seen, 10),
            vec![
                started(),
                ResultEvent::Rows(vec![row(5_000, 'a'), row(5_000, 'b')]),
                finished(2, Some(2), Truncation::Complete),
            ],
        )
        .await;

        assert_eq!(seen.events()[1], ResultEvent::Rows(vec![row(5_000, 'a')]));
        assert_eq!(seen.events()[2], ResultEvent::ByteLimitReached { retained: 1 });
    }

    #[tokio::test]
    async fn a_set_after_the_limit_keeps_nothing_and_an_empty_one_stays_complete() {
        let seen = Seen::default();

        play(
            &mut sink(&seen, 200),
            vec![
                started(),
                ResultEvent::Rows(rows(2, 100)),
                finished(2, Some(2), Truncation::Complete),
                started(),
                ResultEvent::Rows(rows(4, 100)),
                finished(4, Some(4), Truncation::Complete),
                started(),
                finished(0, Some(0), Truncation::Complete),
                ResultEvent::CommandCompleted { rows_affected: Some(1) },
            ],
        )
        .await;

        assert_eq!(
            seen.events(),
            [
                started(),
                ResultEvent::Rows(rows(2, 100)),
                finished(2, Some(2), Truncation::Complete),
                started(),
                ResultEvent::ByteLimitReached { retained: 0 },
                finished(0, Some(4), Truncation::ByteLimit),
                started(),
                finished(0, Some(0), Truncation::Complete),
                ResultEvent::CommandCompleted { rows_affected: Some(1) },
            ]
        );
    }

    #[tokio::test]
    async fn a_byte_limit_the_driver_sent_passes_once_and_fills_the_run() {
        let seen = Seen::default();

        play(
            &mut sink(&seen, 1_000),
            vec![
                started(),
                ResultEvent::Rows(rows(2, 100)),
                ResultEvent::ByteLimitReached { retained: 2 },
                ResultEvent::ByteLimitReached { retained: 2 },
                finished(2, None, Truncation::ByteLimit),
                started(),
                ResultEvent::Rows(rows(1, 100)),
                finished(1, Some(1), Truncation::Complete),
            ],
        )
        .await;

        assert_eq!(
            seen.events(),
            [
                started(),
                ResultEvent::Rows(rows(2, 100)),
                ResultEvent::ByteLimitReached { retained: 2 },
                finished(2, None, Truncation::ByteLimit),
                started(),
                ResultEvent::ByteLimitReached { retained: 0 },
                finished(0, Some(1), Truncation::ByteLimit),
            ]
        );
    }

    #[tokio::test]
    async fn the_inner_sinks_consumer_gone_passes() {
        let seen = Seen {
            gone: true,
            ..Seen::default()
        };
        let mut sink = sink(&seen, 150);

        let flows = play(&mut sink, vec![started(), ResultEvent::Rows(rows(4, 100))]).await;

        assert_eq!(flows, [SinkFlow::ConsumerGone, SinkFlow::ConsumerGone]);
        assert_eq!(seen.events().len(), 2, "nothing after the inner sink left");
    }
}
