use tablepro_core::ResultSink;
use tablepro_session::runtime::Tasks;
use tokio::sync::mpsc;

use super::{DocumentSink, EncodingSink, ExportFormat, ExportMessage};

/// What a sink for one export is made from. The channel is bounded, so
/// a disk slower than the encoder holds the encoder back rather than
/// queueing the whole result in memory.
#[derive(Clone)]
pub(crate) struct ExportSinkParts {
    pub messages: mpsc::Sender<ExportMessage>,
    pub format: ExportFormat,
    /// Where a document is rendered once its last row is in.
    pub tasks: Tasks,
}

impl ExportSinkParts {
    /// A fresh sink, for one run of the read.
    pub(crate) fn sink(&self) -> Box<dyn ResultSink> {
        match &self.format {
            ExportFormat::Rows(format) => Box::new(EncodingSink::new(self.messages.clone(), format.clone())),
            ExportFormat::Document(format) => Box::new(DocumentSink::new(
                self.messages.clone(),
                format.clone(),
                self.tasks.clone(),
            )),
        }
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use tablepro_core::column::{ColumnType, ResultColumn};
    use tablepro_core::{ResultEvent, SinkFlow, Value};
    use tablepro_test_support::FakeDialect;

    use super::*;
    use crate::test_support::paused_tasks;
    use crate::ui::export::{InsertTarget, RowFormat};

    #[tokio::test(start_paused = true)]
    async fn html_xml_and_sql_are_written_before_the_last_row_is_in() {
        let formats = [
            RowFormat::Html { title: "t".to_owned() },
            RowFormat::Xml,
            RowFormat::Sql(InsertTarget {
                table: "t".to_owned(),
                dialect: Arc::new(FakeDialect),
            }),
        ];
        for format in formats {
            let (messages, mut received) = mpsc::channel(64);
            let parts = ExportSinkParts {
                messages,
                format: ExportFormat::Rows(format.clone()),
                tasks: paused_tasks(),
            };
            let mut sink = parts.sink();
            let columns: Arc<[ResultColumn]> = vec![ResultColumn::new("a", ColumnType::untyped_text("text"))].into();
            let rows = (0..200).map(|row| vec![Value::Text(format!("{row:01023}"))]).collect();

            sink.accept(ResultEvent::ResultSetStarted { columns }).await;
            assert_eq!(sink.accept(ResultEvent::Rows(rows)).await, SinkFlow::Continue);

            let first = received.try_recv();
            assert!(
                matches!(first, Ok(ExportMessage::Chunk { .. })),
                "{format:?} held its rows until the end: {first:?}"
            );
        }
    }
}
