use std::sync::Arc;

use async_trait::async_trait;
use tablepro_core::column::ResultColumn;
use tablepro_core::export::RenderError;
use tablepro_core::{ResultEvent, ResultSink, SinkFlow, Value};
use tablepro_session::runtime::Tasks;
use tokio::sync::mpsc;

use super::export_format::DocumentWriter;
use super::{DocumentFormat, ExportMessage, ExportStreamFailure};

/// Rows a document takes in between progress reports.
const ROWS_PER_PROGRESS: u64 = 4_096;

/// Writes a result's rows into its document on the blocking pool as
/// they arrive, and hands the finished document on as one chunk. A
/// workbook is a zip archive, which is written whole, but its sheet
/// spills the rows to a temporary file meanwhile, so the result is
/// never held.
pub(crate) struct DocumentSink {
    messages: mpsc::Sender<ExportMessage>,
    format: DocumentFormat,
    /// The most rows the document can hold.
    limit: u64,
    tasks: Tasks,
    /// Out on the blocking pool while a batch is written, and `None`
    /// before the result set starts.
    writer: Option<DocumentWriter>,
    rows: u64,
    result_sets: u32,
}

impl DocumentSink {
    pub(crate) fn new(messages: mpsc::Sender<ExportMessage>, format: DocumentFormat, tasks: Tasks) -> Self {
        Self {
            messages,
            limit: format.row_limit() as u64,
            format,
            tasks,
            writer: None,
            rows: 0,
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

    async fn in_pool<T: Send + 'static>(
        &mut self,
        work: impl FnOnce() -> Result<T, RenderError> + Send + 'static,
    ) -> Result<T, SinkFlow> {
        match self.tasks.spawn_blocking_task(work).await {
            Ok(Ok(done)) => Ok(done),
            Ok(Err(error)) => Err(self.fail(error.into()).await),
            Err(failure) => Err(self.fail(failure.into()).await),
        }
    }

    async fn start(&mut self, columns: Arc<[ResultColumn]>) -> SinkFlow {
        let format = self.format.clone();
        match self.in_pool(move || format.start(columns)).await {
            Ok(writer) => {
                self.writer = Some(writer);
                SinkFlow::Continue
            }
            Err(flow) => flow,
        }
    }

    async fn take(&mut self, rows: Vec<Vec<Value>>) -> SinkFlow {
        let Some(mut writer) = self.writer.take() else {
            tracing::warn!("rows arrived before their result set started");
            return SinkFlow::ConsumerGone;
        };
        let before = self.rows;
        let now = before + rows.len() as u64;
        // The sheet refuses a row past its last, so the read stops here
        // rather than reading the rest.
        if now > self.limit {
            let limit = self.limit as usize;
            return self.fail(ExportStreamFailure::SheetFull { limit }).await;
        }
        let written = self.in_pool(move || writer.write_rows(&rows).map(|()| writer)).await;
        match written {
            Ok(writer) => self.writer = Some(writer),
            Err(flow) => return flow,
        }
        self.rows = now;
        if before / ROWS_PER_PROGRESS != now / ROWS_PER_PROGRESS {
            return self.send(ExportMessage::Progress { rows: now }).await;
        }
        SinkFlow::Continue
    }

    async fn finish(&mut self) -> SinkFlow {
        let Some(writer) = self.writer.take() else {
            return SinkFlow::Continue;
        };
        let rows = self.rows;
        let bytes = match self.in_pool(move || writer.finish()).await {
            Ok(bytes) => bytes,
            Err(flow) => return flow,
        };
        if self.send(ExportMessage::Chunk { bytes, rows }).await == SinkFlow::ConsumerGone {
            return SinkFlow::ConsumerGone;
        }
        self.send(ExportMessage::Finished { rows }).await
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
                self.start(columns).await
            }
            ResultEvent::Rows(rows) => self.take(rows).await,
            ResultEvent::ResultSetFinished { .. } => self.finish().await,
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

    /// Each batch goes into the sheet as it arrives, so the sink holds
    /// no rows between batches.
    #[tokio::test]
    async fn rows_are_written_into_the_sheet_as_they_arrive() {
        let (messages, _received) = mpsc::channel(16);
        let mut sink = DocumentSink::new(messages, sheet(), paused_tasks());

        sink.accept(started()).await;
        sink.accept(ResultEvent::Rows(rows(300))).await;
        sink.accept(ResultEvent::Rows(rows(200))).await;

        let Some(DocumentWriter::Xlsx(writer)) = sink.writer.as_ref() else {
            panic!("no sheet is being written");
        };
        assert_eq!(writer.rows(), 500);
    }

    #[tokio::test]
    async fn a_sheet_stops_the_read_once_it_is_full() {
        let (messages, mut received) = mpsc::channel(16);
        let mut sink = DocumentSink::new(messages, sheet(), paused_tasks());
        let limit = 10;
        sink.limit = limit as u64;

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
