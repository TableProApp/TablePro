use std::sync::Arc;

use tablepro_core::browse::{DeclaredPrecisionSink, build_export};
use tablepro_core::column::ResultColumn;
use tablepro_core::{ReadStatement, ResultEvent, ResultSink, SinkFlow, StreamSummary, Truncation};
use tablepro_session::runtime::{TaskResult, Tasks};
use tablepro_session::{OperationError, OperationKind, Session};
use tokio_util::sync::CancellationToken;

use super::{ExportQuery, ExportSinkParts};
use crate::services::grid::RowSnapshot;

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

/// Stream every row of `query` through `session` into a sink built
/// from `parts`, on a connection of the read's own. The SQL is built
/// from the lease that streams it, so it is spelled for that server.
pub(crate) fn start_query_producer(
    tasks: &Tasks,
    session: Arc<Session>,
    query: ExportQuery,
    parts: ExportSinkParts,
    cancel: CancellationToken,
) -> TaskResult<Result<StreamSummary, OperationError>> {
    let query = Arc::new(query);
    tasks.spawn_task(async move {
        session
            .run_cancellable(OperationKind::Export, &cancel, move |lease, options| {
                let parts = parts.clone();
                let query = Arc::clone(&query);
                async move {
                    let (read, sink): (_, Box<dyn ResultSink>) = match &*query {
                        ExportQuery::Table(export) => (
                            ReadStatement::Generated(build_export(&*lease.dialect(), &export.request())?),
                            Box::new(DeclaredPrecisionSink::new(parts.sink(), Arc::clone(&export.columns))),
                        ),
                        ExportQuery::Editor { sql } => (ReadStatement::User(sql.clone()), parts.sink()),
                    };
                    Ok(lease.stream_read(&read, sink, options).await?)
                }
            })
            .await
    })
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use tablepro_core::Value;
    use tablepro_core::column::ColumnType;
    use tablepro_core::export::CsvOptions;
    use tokio::sync::mpsc;

    use super::*;
    use crate::test_support::paused_tasks;
    use crate::ui::export::{ExportFormat, ExportMessage, RowFormat};

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
            format: ExportFormat::Rows(RowFormat::Csv(CsvOptions::default())),
            tasks: paused_tasks(),
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
