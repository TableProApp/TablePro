use async_trait::async_trait;
use tablepro_core::export::RowEncoder;
use tablepro_core::{ResultEvent, ResultSink, SinkFlow, Value};

use super::{ExportMessage, ExportSinkParts, ExportStreamFailure};

/// How much encoded output a sink holds before it hands it to the
/// writer.
pub(crate) const CHUNK_BYTES: usize = 64 * 1024;

/// Encodes a result's rows as they arrive, and hands the bytes on in
/// chunks. A send waits while the writer is behind, which stops the
/// read until the disk catches up.
pub(crate) struct EncodingSink {
    parts: ExportSinkParts,
    /// Built from the columns the stream announces, which are the ones
    /// its rows carry.
    encoder: Option<Box<dyn RowEncoder>>,
    buffer: Vec<u8>,
    rows: u64,
    result_sets: u32,
}

impl EncodingSink {
    pub(crate) fn new(parts: ExportSinkParts) -> Self {
        Self {
            parts,
            encoder: None,
            buffer: Vec::with_capacity(CHUNK_BYTES),
            rows: 0,
            result_sets: 0,
        }
    }

    // `&mut self` throughout: the encoder is not Sync, so a shared
    // borrow held across an await would make the future not Send.
    async fn send(&mut self, message: ExportMessage) -> SinkFlow {
        match self.parts.messages.send(message).await {
            Ok(()) => SinkFlow::Continue,
            Err(_) => SinkFlow::ConsumerGone,
        }
    }

    async fn flush(&mut self) -> SinkFlow {
        if self.buffer.is_empty() {
            return SinkFlow::Continue;
        }
        let bytes = std::mem::replace(&mut self.buffer, Vec::with_capacity(CHUNK_BYTES));
        self.send(ExportMessage::Chunk { bytes, rows: self.rows }).await
    }

    /// The export cannot go on, so the run is stopped too.
    async fn fail(&mut self, failure: ExportStreamFailure) -> SinkFlow {
        self.send(ExportMessage::Failed(failure)).await;
        SinkFlow::ConsumerGone
    }

    async fn rows(&mut self, rows: Vec<Vec<Value>>) -> SinkFlow {
        for row in &rows {
            let Some(encoder) = self.encoder.as_mut() else {
                tracing::warn!("rows arrived before their result set started");
                return SinkFlow::ConsumerGone;
            };
            if let Err(error) = encoder.row(&mut self.buffer, &mut row.iter()) {
                return self.fail(error.into()).await;
            }
            self.rows += 1;
            if self.buffer.len() >= CHUNK_BYTES && self.flush().await == SinkFlow::ConsumerGone {
                return SinkFlow::ConsumerGone;
            }
        }
        SinkFlow::Continue
    }
}

#[async_trait]
impl ResultSink for EncodingSink {
    async fn accept(&mut self, event: ResultEvent) -> SinkFlow {
        match event {
            ResultEvent::ResultSetStarted { columns } => {
                self.result_sets += 1;
                // A file holds one result, and a second set would come
                // out as a second document glued to the first.
                if self.result_sets > 1 {
                    return self.fail(ExportStreamFailure::MultipleResultSets).await;
                }
                let mut encoder = self.parts.format.encoder(columns);
                encoder.begin(&mut self.buffer);
                self.encoder = Some(encoder);
                SinkFlow::Continue
            }
            ResultEvent::Rows(rows) => self.rows(rows).await,
            ResultEvent::ResultSetFinished { .. } => {
                if let Some(encoder) = self.encoder.as_mut() {
                    encoder.finish(&mut self.buffer);
                }
                if self.flush().await == SinkFlow::ConsumerGone {
                    return SinkFlow::ConsumerGone;
                }
                self.send(ExportMessage::Finished { rows: self.rows }).await
            }
            _ => SinkFlow::Continue,
        }
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::time::Duration;

    use tablepro_core::Truncation;
    use tablepro_core::column::{ColumnType, ResultColumn};
    use tablepro_core::export::CsvOptions;
    use tokio::sync::mpsc;

    use super::*;
    use crate::test_support::paused_tasks;
    use crate::ui::export::RowFormat;

    fn columns(names: &[&str]) -> Arc<[ResultColumn]> {
        names
            .iter()
            .map(|name| ResultColumn::new(*name, ColumnType::untyped_text("text")))
            .collect()
    }

    fn plain_csv() -> RowFormat {
        RowFormat::Csv(CsvOptions {
            header_row: false,
            sanitize_formulas: false,
            ..CsvOptions::default()
        })
    }

    fn sink(format: RowFormat, capacity: usize) -> (EncodingSink, mpsc::Receiver<ExportMessage>) {
        let (messages, received) = mpsc::channel(capacity);
        (ExportSinkParts { messages, format }.sink(), received)
    }

    /// One-cell rows that each encode to exactly 1 KiB of plain CSV.
    fn kib_rows(count: usize) -> Vec<Vec<Value>> {
        (0..count)
            .map(|row| vec![Value::Text(format!("{row:01023}"))])
            .collect()
    }

    fn started(names: &[&str]) -> ResultEvent {
        ResultEvent::ResultSetStarted {
            columns: columns(names),
        }
    }

    fn finished() -> ResultEvent {
        ResultEvent::ResultSetFinished {
            retained: 0,
            total_rows: None,
            truncation: Truncation::Complete,
        }
    }

    async fn drain(received: &mut mpsc::Receiver<ExportMessage>) -> (Vec<(Vec<u8>, u64)>, Option<u64>) {
        let mut chunks = Vec::new();
        let mut finished = None;
        while let Some(message) = received.recv().await {
            match message {
                ExportMessage::Chunk { bytes, rows } => chunks.push((bytes, rows)),
                ExportMessage::Finished { rows } => finished = Some(rows),
                ExportMessage::Failed(failure) => panic!("the export failed: {failure}"),
            }
        }
        (chunks, finished)
    }

    #[tokio::test(start_paused = true)]
    async fn encoding_sink_chunks_at_64_kib() {
        let (mut sink, mut received) = sink(plain_csv(), 64);

        assert_eq!(sink.accept(started(&["a"])).await, SinkFlow::Continue);
        assert_eq!(
            sink.accept(ResultEvent::Rows(kib_rows(1_000))).await,
            SinkFlow::Continue
        );
        assert_eq!(sink.accept(finished()).await, SinkFlow::Continue);
        drop(sink);
        let (chunks, finished) = drain(&mut received).await;

        assert_eq!(finished, Some(1_000));
        let (last, full) = chunks.split_last().expect("chunks");
        assert_eq!(full.len(), 15);
        for (index, (bytes, rows)) in full.iter().enumerate() {
            assert_eq!(bytes.len(), CHUNK_BYTES, "chunk {index}");
            assert_eq!(*rows, 64 * (index as u64 + 1), "chunk {index}");
        }
        assert_eq!(last.0.len(), 40 * 1024);
        assert_eq!(last.1, 1_000);
    }

    #[tokio::test(start_paused = true)]
    async fn encoding_sink_applies_backpressure() {
        let (mut sink, mut received) = sink(plain_csv(), 4);
        let done = Arc::new(AtomicBool::new(false));
        let finished = done.clone();
        let running = paused_tasks().spawn_task(async move {
            sink.accept(started(&["a"])).await;
            sink.accept(ResultEvent::Rows(kib_rows(1_000))).await;
            finished.store(true, Ordering::SeqCst);
        });

        tokio::time::sleep(Duration::from_secs(60)).await;
        assert_eq!(received.len(), 4, "the sink did not fill the channel");
        assert!(!done.load(Ordering::SeqCst), "the sink ran ahead of the writer");

        received.recv().await.expect("a chunk");
        tokio::time::sleep(Duration::from_secs(60)).await;
        assert_eq!(received.len(), 4, "a freed slot was not filled");
        assert!(!done.load(Ordering::SeqCst));

        while !done.load(Ordering::SeqCst) {
            received.recv().await.expect("a chunk");
            tokio::time::sleep(Duration::from_millis(1)).await;
        }
        running.await.expect("the sink's task");
    }

    #[tokio::test(start_paused = true)]
    async fn encoding_sink_builds_encoder_from_stream_columns() {
        let (mut sink, mut received) = sink(RowFormat::Csv(CsvOptions::default()), 4);

        sink.accept(started(&["x", "y"])).await;
        sink.accept(ResultEvent::Rows(vec![vec![Value::Int(1), Value::Int(2)]]))
            .await;
        sink.accept(finished()).await;
        drop(sink);
        let (chunks, finished) = drain(&mut received).await;

        assert_eq!(finished, Some(1));
        let text: Vec<u8> = chunks.into_iter().flat_map(|(bytes, _)| bytes).collect();
        assert_eq!(String::from_utf8(text).expect("utf-8"), "\"x\",\"y\"\n\"1\",\"2\"\n");
    }

    #[tokio::test(start_paused = true)]
    async fn encoding_sink_rejects_second_result_set() {
        let (mut sink, mut received) = sink(RowFormat::Json, 4);

        sink.accept(started(&["a"])).await;
        sink.accept(finished()).await;
        let flow = sink.accept(started(&["b"])).await;

        assert_eq!(flow, SinkFlow::ConsumerGone);
        drop(sink);
        let mut failed = false;
        while let Some(message) = received.recv().await {
            failed |= matches!(message, ExportMessage::Failed(ExportStreamFailure::MultipleResultSets));
        }
        assert!(failed, "no failure was sent");
    }
}
