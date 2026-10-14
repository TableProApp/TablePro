use std::sync::Arc;

use tablepro_core::column::ResultColumn;
use tablepro_core::{ResultEvent, ResultSink, SinkFlow, Truncation, Value};
use tablepro_session::runtime::{TaskResult, Tasks};
use tokio::sync::mpsc;
use tokio_util::sync::CancellationToken;

use super::{DocumentFormat, ExportMessage, ExportSinkParts, ExportStreamFailure};
use crate::ui::grid::RowSnapshot;

/// Rows a producer encodes before it looks at the cancel again.
const ROWS_PER_BATCH: usize = 256;

/// Encode rows the grid already holds, on the runtime, through the same
/// sink a streamed read feeds, so both kinds of export write the same
/// bytes.
pub(crate) fn start_rows_producer(
    tasks: &Tasks,
    columns: Arc<[ResultColumn]>,
    rows: Vec<RowSnapshot>,
    parts: ExportSinkParts,
    cancel: CancellationToken,
) -> TaskResult<()> {
    tasks.spawn_task(async move {
        let mut sink = parts.sink();
        if sink.accept(ResultEvent::ResultSetStarted { columns }).await == SinkFlow::ConsumerGone {
            return;
        }
        for batch in rows.chunks(ROWS_PER_BATCH) {
            if cancel.is_cancelled() {
                return;
            }
            let batch = batch.iter().map(RowSnapshot::to_values).collect();
            if sink.accept(ResultEvent::Rows(batch)).await == SinkFlow::ConsumerGone {
                return;
            }
        }
        if cancel.is_cancelled() {
            return;
        }
        let count = rows.len() as u64;
        sink.accept(ResultEvent::ResultSetFinished {
            retained: count,
            total_rows: Some(count),
            truncation: Truncation::Complete,
        })
        .await;
    })
}

/// Render a whole document on the blocking pool and hand it on as one
/// chunk.
pub(crate) fn start_document_producer(
    tasks: &Tasks,
    format: DocumentFormat,
    columns: Arc<[ResultColumn]>,
    rows: Vec<RowSnapshot>,
    messages: mpsc::Sender<ExportMessage>,
    cancel: CancellationToken,
) -> TaskResult<()> {
    tasks.spawn_blocking_task(move || {
        if cancel.is_cancelled() {
            return;
        }
        let values: Vec<Vec<Value>> = rows.iter().map(RowSnapshot::to_values).collect();
        let count = values.len() as u64;
        let rendered = format.render(&columns, &values);
        drop(values);
        if cancel.is_cancelled() {
            return;
        }
        // The channel holds more than the two messages a document
        // sends, so neither waits, and a closed one has nobody to tell.
        match rendered {
            Ok(bytes) => {
                let _ = messages.try_send(ExportMessage::Chunk { bytes, rows: count });
                let _ = messages.try_send(ExportMessage::Finished { rows: count });
            }
            Err(error) => {
                let _ = messages.try_send(ExportMessage::Failed(ExportStreamFailure::Document(error)));
            }
        }
    })
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use tablepro_core::column::ColumnType;
    use tablepro_core::export::CsvOptions;

    use super::*;
    use crate::test_support::paused_tasks;
    use crate::ui::export::RowFormat;

    #[tokio::test(start_paused = true)]
    async fn rows_producer_stops_on_cancel() {
        let columns: Arc<[ResultColumn]> = vec![ResultColumn::new("a", ColumnType::untyped_text("text"))].into();
        let rows: Vec<RowSnapshot> = (0..10_000)
            .map(|row| RowSnapshot::new(vec![Value::Text(format!("{row:01023}"))].into(), Vec::new()))
            .collect();
        let (messages, mut received) = mpsc::channel(1);
        let cancel = CancellationToken::new();
        let parts = ExportSinkParts {
            messages,
            format: RowFormat::Csv(CsvOptions::default()),
        };
        let producer = start_rows_producer(&paused_tasks(), columns, rows, parts, cancel.clone());

        let first = received.recv().await;
        assert!(matches!(first, Some(ExportMessage::Chunk { .. })), "{first:?}");
        cancel.cancel();
        let mut last_rows = 0;
        while let Some(message) = received.recv().await {
            match message {
                ExportMessage::Chunk { rows, .. } => last_rows = rows,
                other => panic!("the producer went on past the cancel: {other:?}"),
            }
            tokio::time::sleep(Duration::from_millis(1)).await;
        }

        producer.await.expect("the producer");
        assert!(last_rows < 10_000, "every row was encoded");
    }
}
