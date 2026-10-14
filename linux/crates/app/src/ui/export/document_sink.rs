use std::sync::Arc;

use async_trait::async_trait;
use tablepro_core::column::ResultColumn;
use tablepro_core::{ResultEvent, ResultSink, SinkFlow, Value};
use tablepro_session::runtime::Tasks;
use tokio::sync::mpsc;

use super::{DocumentFormat, ExportMessage, ExportStreamFailure};

/// Rows a document takes in between progress reports.
const ROWS_PER_PROGRESS: u64 = 4_096;

/// Keeps a result's rows until the last one is in, then renders the
/// document on the blocking pool and hands it on as one chunk. A
/// workbook is a zip archive, which cannot be written as rows arrive,
/// and a sheet's row limit bounds what it holds.
pub(crate) struct DocumentSink {
    messages: mpsc::Sender<ExportMessage>,
    format: DocumentFormat,
    /// The most rows the document can hold.
    limit: usize,
    tasks: Tasks,
    columns: Option<Arc<[ResultColumn]>>,
    rows: Vec<Vec<Value>>,
    result_sets: u32,
}

impl DocumentSink {
    pub(crate) fn new(messages: mpsc::Sender<ExportMessage>, format: DocumentFormat, tasks: Tasks) -> Self {
        Self {
            messages,
            limit: format.row_limit(),
            format,
            tasks,
            columns: None,
            rows: Vec::new(),
            result_sets: 0,
        }
    }

    async fn send(&mut self, message: ExportMessage) -> SinkFlow {
        match self.messages.send(message).await {
            Ok(()) => SinkFlow::Continue,
            Err(_) => SinkFlow::ConsumerGone,
        }
    }

    async fn fail(&mut self, failure: ExportStreamFailure) -> SinkFlow {
        self.send(ExportMessage::Failed(failure)).await;
        SinkFlow::ConsumerGone
    }

    async fn take(&mut self, rows: Vec<Vec<Value>>) -> SinkFlow {
        if self.columns.is_none() {
            tracing::warn!("rows arrived before their result set started");
            return SinkFlow::ConsumerGone;
        }
        let before = self.rows.len() as u64;
        self.rows.extend(rows);
        // A sheet past its last row is refused at render time anyway,
        // so the read stops here rather than holding the rest.
        if self.rows.len() > self.limit {
            let limit = self.limit;
            return self.fail(ExportStreamFailure::SheetFull { limit }).await;
        }
        let now = self.rows.len() as u64;
        if before / ROWS_PER_PROGRESS != now / ROWS_PER_PROGRESS {
            return self.send(ExportMessage::Progress { rows: now }).await;
        }
        SinkFlow::Continue
    }

    async fn render(&mut self) -> SinkFlow {
        let Some(columns) = self.columns.clone() else {
            return SinkFlow::Continue;
        };
        let rows = std::mem::take(&mut self.rows);
        let count = rows.len() as u64;
        let format = self.format.clone();
        let rendered = self
            .tasks
            .spawn_blocking_task(move || format.render(&columns, &rows))
            .await;
        match rendered {
            Ok(Ok(bytes)) => {
                if self.send(ExportMessage::Chunk { bytes, rows: count }).await == SinkFlow::ConsumerGone {
                    return SinkFlow::ConsumerGone;
                }
                self.send(ExportMessage::Finished { rows: count }).await
            }
            Ok(Err(error)) => self.fail(error.into()).await,
            Err(failure) => self.fail(failure.into()).await,
        }
    }
}

#[async_trait]
impl ResultSink for DocumentSink {
    async fn accept(&mut self, event: ResultEvent) -> SinkFlow {
        match event {
            ResultEvent::ResultSetStarted { columns } => {
                self.result_sets += 1;
                if self.result_sets > 1 {
                    return self.fail(ExportStreamFailure::MultipleResultSets).await;
                }
                self.columns = Some(columns);
                SinkFlow::Continue
            }
            ResultEvent::Rows(rows) => self.take(rows).await,
            ResultEvent::ResultSetFinished { .. } => self.render().await,
            _ => SinkFlow::Continue,
        }
    }
}

#[cfg(test)]
mod tests {
    use tablepro_core::Truncation;
    use tablepro_core::column::ColumnType;

    use super::*;
    use crate::test_support::paused_tasks;

    fn started() -> ResultEvent {
        ResultEvent::ResultSetStarted {
            columns: vec![ResultColumn::new("a", ColumnType::untyped_text("text"))].into(),
        }
    }

    fn finished() -> ResultEvent {
        ResultEvent::ResultSetFinished {
            retained: 0,
            total_rows: None,
            truncation: Truncation::Complete,
        }
    }

    fn rows(count: usize) -> Vec<Vec<Value>> {
        (0..count).map(|row| vec![Value::Int(row as i64)]).collect()
    }

    fn sheet() -> DocumentFormat {
        DocumentFormat::Xlsx {
            sheet: "rows".to_owned(),
        }
    }

    #[tokio::test]
    async fn a_document_is_rendered_once_its_last_row_is_in() {
        let (messages, mut received) = mpsc::channel(16);
        let mut sink = DocumentSink::new(messages, sheet(), paused_tasks());

        sink.accept(started()).await;
        sink.accept(ResultEvent::Rows(rows(5_000))).await;
        assert_eq!(sink.accept(finished()).await, SinkFlow::Continue);
        drop(sink);

        let mut seen = Vec::new();
        while let Some(message) = received.recv().await {
            seen.push(message);
        }
        let [
            ExportMessage::Progress { rows: 5_000 },
            ExportMessage::Chunk { bytes, rows: 5_000 },
            ExportMessage::Finished { rows: 5_000 },
        ] = seen.as_slice()
        else {
            panic!("{seen:?}");
        };
        assert!(bytes.starts_with(b"PK"), "the workbook is not a zip archive");
    }

    #[tokio::test]
    async fn a_sheet_stops_the_read_once_it_is_full() {
        let (messages, mut received) = mpsc::channel(16);
        let mut sink = DocumentSink::new(messages, sheet(), paused_tasks());
        let limit = 10;
        sink.limit = limit;

        sink.accept(started()).await;
        let flow = sink.accept(ResultEvent::Rows(rows(limit + 1))).await;

        assert_eq!(flow, SinkFlow::ConsumerGone);
        drop(sink);
        let mut full = false;
        while let Some(message) = received.recv().await {
            full |=
                matches!(message, ExportMessage::Failed(ExportStreamFailure::SheetFull { limit: got }) if got == limit);
        }
        assert!(full, "the full sheet was not reported");
    }
}
