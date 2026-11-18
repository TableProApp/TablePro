use std::sync::Arc;

use crate::column::ResultColumn;
use crate::error::DriverError;
use crate::result_event::{ResultEvent, Truncation};
use crate::result_sink::{ResultSink, SinkFlow};
use crate::row_batch::RowBatch;
use crate::value::Value;

/// A whole read's rows into a sink, for an export, in batches of
/// `RowBatch::MAX_ROWS` rows. Each batch is awaited, so a slow consumer
/// slows the read instead of growing a queue.
pub struct ReadEmitter<'a> {
    sink: &'a mut dyn ResultSink,
    batch: Vec<Vec<Value>>,
    open: bool,
    set_rows: u64,
    rows: u64,
}

impl<'a> ReadEmitter<'a> {
    pub fn new(sink: &'a mut dyn ResultSink) -> Self {
        Self {
            sink,
            batch: Vec::new(),
            open: false,
            set_rows: 0,
            rows: 0,
        }
    }

    /// Every row so far, across result sets.
    pub fn rows(&self) -> u64 {
        self.rows
    }

    pub fn is_open(&self) -> bool {
        self.open
    }

    pub async fn start(&mut self, columns: Arc<[ResultColumn]>) -> Result<(), DriverError> {
        self.open = true;
        self.send(ResultEvent::ResultSetStarted { columns }).await
    }

    pub async fn row(&mut self, values: Vec<Value>) -> Result<(), DriverError> {
        self.batch.push(values);
        self.rows += 1;
        self.set_rows += 1;
        if self.batch.len() >= RowBatch::MAX_ROWS {
            self.flush().await?;
        }
        Ok(())
    }

    pub async fn flush(&mut self) -> Result<(), DriverError> {
        if self.batch.is_empty() {
            return Ok(());
        }
        let rows = std::mem::take(&mut self.batch);
        self.send(ResultEvent::Rows(rows)).await
    }

    // Sent whether or not a set is open: a statement that ends with no rows still ends its set.
    pub async fn finish(&mut self) -> Result<(), DriverError> {
        self.flush().await?;
        self.open = false;
        let rows = std::mem::take(&mut self.set_rows);
        self.send(ResultEvent::ResultSetFinished {
            retained: rows,
            total_rows: Some(rows),
            truncation: Truncation::Complete,
        })
        .await
    }

    /// A consumer that went away ends the read: the rows would go
    /// nowhere.
    pub async fn send(&mut self, event: ResultEvent) -> Result<(), DriverError> {
        match self.sink.accept(event).await {
            SinkFlow::Continue => Ok(()),
            SinkFlow::ConsumerGone => Err(DriverError::Cancelled),
        }
    }
}

#[cfg(test)]
mod tests {
    use async_trait::async_trait;

    use super::*;
    use crate::column::ColumnType;

    #[derive(Default)]
    struct Recorded {
        events: Vec<ResultEvent>,
        gone: bool,
    }

    #[async_trait]
    impl ResultSink for Recorded {
        async fn accept(&mut self, event: ResultEvent) -> SinkFlow {
            self.events.push(event);
            match self.gone {
                true => SinkFlow::ConsumerGone,
                false => SinkFlow::Continue,
            }
        }
    }

    fn columns() -> Arc<[ResultColumn]> {
        vec![ResultColumn::new("n", ColumnType::untyped_text(""))].into()
    }

    fn finished(rows: u64) -> ResultEvent {
        ResultEvent::ResultSetFinished {
            retained: rows,
            total_rows: Some(rows),
            truncation: Truncation::Complete,
        }
    }

    fn batch_sizes(events: &[ResultEvent]) -> Vec<usize> {
        events
            .iter()
            .filter_map(|event| match event {
                ResultEvent::Rows(rows) => Some(rows.len()),
                _ => None,
            })
            .collect()
    }

    #[tokio::test]
    async fn rows_go_out_in_batches_of_256() {
        let mut sink = Recorded::default();
        let mut emitter = ReadEmitter::new(&mut sink);
        emitter.start(columns()).await.expect("started");
        for n in 0..257 {
            emitter.row(vec![Value::Int(n)]).await.expect("a row");
        }
        emitter.finish().await.expect("finished");

        assert_eq!(batch_sizes(&sink.events), vec![256, 1]);
        assert_eq!(sink.events.last(), Some(&finished(257)));
    }

    #[tokio::test]
    async fn finish_counts_its_own_set_and_rows_counts_them_all() {
        let mut sink = Recorded::default();
        let mut emitter = ReadEmitter::new(&mut sink);
        emitter.start(columns()).await.expect("started");
        for n in 0..3 {
            emitter.row(vec![Value::Int(n)]).await.expect("a row");
        }
        emitter.finish().await.expect("finished");
        assert!(!emitter.is_open());
        emitter.start(columns()).await.expect("started");
        assert!(emitter.is_open());
        emitter.row(vec![Value::Int(3)]).await.expect("a row");
        emitter.finish().await.expect("finished");
        assert_eq!(emitter.rows(), 4);

        let ends: Vec<&ResultEvent> = sink
            .events
            .iter()
            .filter(|event| matches!(event, ResultEvent::ResultSetFinished { .. }))
            .collect();
        assert_eq!(ends, vec![&finished(3), &finished(1)]);
    }

    #[tokio::test]
    async fn finish_with_no_set_open_still_ends_one() {
        let mut sink = Recorded::default();
        let mut emitter = ReadEmitter::new(&mut sink);
        emitter.finish().await.expect("finished");

        assert_eq!(sink.events, vec![finished(0)]);
    }

    #[tokio::test]
    async fn a_consumer_that_went_away_cancels_the_read() {
        let mut sink = Recorded {
            gone: true,
            ..Recorded::default()
        };
        let mut emitter = ReadEmitter::new(&mut sink);

        assert_eq!(emitter.start(columns()).await, Err(DriverError::Cancelled));
    }
}
