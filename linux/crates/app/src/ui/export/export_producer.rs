use std::sync::Arc;

use tablepro_core::browse::{DeclaredPrecisionSink, build_export};
use tablepro_core::column::ResultColumn;
use tablepro_core::masking::{ColumnMasks, MaskingScope, table_name};
use tablepro_core::{ReadStatement, ResultEvent, ResultSink, SinkFlow, StreamSummary, Truncation};
use tablepro_session::runtime::{TaskResult, Tasks};
use tablepro_session::{OperationError, OperationKind, Session};
use tokio_util::sync::CancellationToken;

use super::live_masking_sink::LiveMaskingSink;
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
    masks: ColumnMasks,
    parts: ExportSinkParts,
    cancel: CancellationToken,
) -> TaskResult<()> {
    tasks.spawn_task(async move {
        let mut sink = parts.sink();
        if sink
            .accept(ResultEvent::ResultSetStarted {
                columns: columns.clone(),
            })
            .await
            == SinkFlow::ConsumerGone
        {
            return;
        }
        for batch in rows.chunks(ROWS_PER_BATCH) {
            if cancel.is_cancelled() {
                return;
            }
            let mut batch: Vec<Vec<tablepro_core::Value>> = batch.iter().map(RowSnapshot::to_values).collect();
            masks.apply_rows(&columns, &mut batch);
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
    let masking = session.masking();
    tasks.spawn_task(async move {
        session
            .run_cancellable(OperationKind::Export, &cancel, move |lease, options| {
                let parts = parts.clone();
                let query = Arc::clone(&query);
                let rules = masking.clone();
                async move {
                    let (read, sink): (_, Box<dyn ResultSink>) = match &*query {
                        ExportQuery::Table(export) => {
                            let scope = MaskingScope::External {
                                table: Some(table_name(&export.table)),
                            };
                            // After the declared precision, so a mask reads the value as the file would hold it.
                            let masked = Box::new(LiveMaskingSink::new(parts.sink(), rules, scope));
                            (
                                ReadStatement::Generated(build_export(&*lease.dialect(), &export.request())?),
                                Box::new(DeclaredPrecisionSink::new(masked, Arc::clone(&export.columns))),
                            )
                        }
                        ExportQuery::Editor { sql } => (
                            ReadStatement::User(sql.clone()),
                            Box::new(LiveMaskingSink::new(
                                parts.sink(),
                                rules,
                                MaskingScope::External { table: None },
                            )),
                        ),
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

    async fn written(mut received: mpsc::Receiver<ExportMessage>) -> String {
        let mut bytes = Vec::new();
        while let Some(message) = received.recv().await {
            if let ExportMessage::Chunk { bytes: chunk, .. } = message {
                bytes.extend(chunk);
            }
        }
        String::from_utf8(bytes).expect("UTF-8")
    }

    fn csv_parts(messages: mpsc::Sender<ExportMessage>) -> ExportSinkParts {
        ExportSinkParts {
            messages,
            format: ExportFormat::Rows(RowFormat::Csv(CsvOptions::default())),
            tasks: paused_tasks(),
        }
    }

    #[tokio::test(start_paused = true)]
    async fn held_rows_leave_masked_by_the_rules_the_grid_did_not_apply() {
        use tablepro_core::masking::MaskingStyle;

        let columns: Arc<[ResultColumn]> = ["id", "email"]
            .into_iter()
            .map(|name| ResultColumn::new(name, ColumnType::untyped_text("text")))
            .collect();
        let rows = vec![RowSnapshot::new(
            vec![Value::Text("1".to_owned()), Value::Text("ann@example.com".to_owned())].into(),
            Vec::new(),
        )];
        let (messages, received) = mpsc::channel(16);
        let masks = ColumnMasks::new(vec![None, Some(MaskingStyle::Email)]);

        let producer = start_rows_producer(
            &paused_tasks(),
            columns,
            rows,
            masks,
            csv_parts(messages),
            CancellationToken::new(),
        );
        let file = written(received).await;

        producer.await.expect("the producer");
        assert!(file.contains("a•••@example.com"), "{file}");
        assert!(!file.contains("ann@example.com"), "{file}");
    }

    #[tokio::test]
    async fn a_streamed_statement_leaves_masked_by_what_each_column_reads() {
        use tablepro_core::masking::{MaskingPolicy, MaskingRule, MaskingStyle, MaskingTarget};
        use tablepro_test_support::{ConnectionScript, FakeReply};

        let columns: Arc<[ResultColumn]> = vec![ResultColumn::new("total", ColumnType::untyped_text("text"))].into();
        let mut script = ConnectionScript::default();
        script.stream_read.always(FakeReply::ok(vec![
            ResultEvent::ResultSetStarted { columns },
            ResultEvent::Rows(vec![vec![Value::Text("42".to_owned())]]),
            ResultEvent::ResultSetFinished {
                retained: 1,
                total_rows: Some(1),
                truncation: Truncation::Complete,
            },
        ]));
        let fake = crate::test_support::FakeSession::start(script, [], paused_tasks());
        fake.session.set_masking_policy(MaskingPolicy::new([MaskingRule::new(
            "ssn",
            MaskingTarget::Column,
            MaskingStyle::LastFour,
        )]));
        let (messages, received) = mpsc::channel(16);

        let producer = start_query_producer(
            &paused_tasks(),
            fake.session.clone(),
            ExportQuery::Editor {
                sql: tablepro_core::UserSql::new("SELECT 40 + 2 AS total"),
            },
            csv_parts(messages),
            CancellationToken::new(),
        );
        let file = written(received).await;

        producer.await.expect("the producer").expect("the read");
        assert!(file.contains("••••"), "an untraced column left unmasked: {file}");
        assert!(!file.contains("42"), "{file}");
    }

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
        let producer = start_rows_producer(
            &paused_tasks(),
            columns,
            rows,
            ColumnMasks::none(),
            parts,
            cancel.clone(),
        );

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
