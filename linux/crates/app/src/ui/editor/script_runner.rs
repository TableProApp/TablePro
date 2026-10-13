use std::future::Future;
use std::pin::Pin;
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::time::{Duration, Instant};

use tablepro_core::sql_syntax::SqlGrammar;
use tablepro_core::sql_syntax::script::{
    BatchErrorPolicy, LexicalSettings, ScriptDiagnostic, ScriptPlan, text_offsets,
};
use tablepro_core::{
    EditorSession, EditorSessionState, ResultEvent, ResultSink, RowLimit, RunOptions, SinkFlow, UserSql,
};
use tablepro_session::{MonitorSignal, Session};
use tokio::sync::mpsc;
use tokio_util::sync::CancellationToken;

use super::editor_session_slot::{AcquireError, EditorSessionSlot, close_quietly};
use super::run_log::{BatchCollector, BatchReport, EntryKind, RunEvent, Verdict, continues};
use super::run_scope::ScopedText;

/// One unit the server is sent: a statement on most engines, a whole
/// `GO` batch on SQL Server.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RunBatch {
    pub text: String,
    /// How many times `GO n` asks for it.
    pub repeat: u32,
    /// Where the batch starts in the buffer, in characters.
    pub error_base: usize,
    pub preview: String,
}

/// What one press of Run sends, and how.
#[derive(Debug, Clone)]
pub struct ScriptRun {
    pub batches: Vec<RunBatch>,
    pub policy: BatchErrorPolicy,
    pub statement_timeout: Option<Duration>,
    pub row_limit: RowLimit,
}

/// The batches of the scoped text and what the plan warns about.
///
/// Each statement goes on its own, as psql, mysql and sqlite3 send it:
/// no multi-statement text reaches the server, so no implicit
/// transaction can roll back statements that already reported success.
pub fn plan_batches(
    scoped: &ScopedText,
    grammar: SqlGrammar,
    base_line: usize,
) -> (Vec<RunBatch>, BatchErrorPolicy, Vec<String>) {
    let plan = ScriptPlan::build(&scoped.text, grammar, LexicalSettings::default_for(grammar));
    let batches = plan
        .batches()
        .iter()
        .filter_map(|batch| {
            let text = scoped.text.get(batch.range.clone())?.trim();
            (!text.is_empty()).then(|| RunBatch {
                text: text.to_owned(),
                repeat: batch.repeat.get(),
                error_base: scoped.base_char + text_offsets::byte_to_char(&scoped.text, batch.range.start),
                preview: sql_preview(text),
            })
        })
        .collect();
    let warnings = plan
        .diagnostics()
        .iter()
        .map(|diagnostic| match diagnostic {
            ScriptDiagnostic::Unterminated { start, .. } => {
                let line = base_line + scoped.text.get(..*start).unwrap_or_default().matches('\n').count() + 1;
                crate::ui::error_text::script_diagnostic_message(diagnostic, line)
            }
        })
        .collect();
    (batches, plan.batch_error_policy(), warnings)
}

/// The first ~60 characters of a statement on one line, to tell the
/// results list's lines apart.
pub fn sql_preview(sql: &str) -> String {
    let single_line = sql.split_whitespace().collect::<Vec<_>>().join(" ");
    if single_line.chars().count() > 60 {
        let prefix: String = single_line.chars().take(60).collect();
        format!("{prefix}…")
    } else {
        single_line
    }
}

/// Send each batch in turn, reporting each one as it ends.
pub async fn run_batches(
    editor: &Arc<dyn EditorSession>,
    run: &ScriptRun,
    cancel: &CancellationToken,
    events: &mpsc::Sender<RunEvent>,
) {
    'batches: for (index, batch) in run.batches.iter().enumerate() {
        for _ in 0..batch.repeat.max(1) {
            if cancel.is_cancelled() {
                break 'batches;
            }
            let collector = Arc::new(Mutex::new(BatchCollector::default()));
            let options = RunOptions::new(cancel.child_token())
                .with_deadline(run.statement_timeout)
                .with_row_limit(run.row_limit);
            let sink = Box::new(CollectingSink {
                collector: collector.clone(),
            });
            let started = Instant::now();
            let outcome = editor.run(UserSql::new(batch.text.as_str()), options, sink).await;
            let elapsed_ms = started.elapsed().as_millis();
            let collected = std::mem::take(&mut *lock(&collector));
            let state = editor.state();
            let (entries, verdict, transaction) = collected.finish(outcome, state, batch.error_base);
            let report = BatchReport {
                batch: index,
                entries,
                verdict,
                transaction,
                lost: state == EditorSessionState::Lost,
                elapsed_ms,
            };
            if events.send(RunEvent::Batch(report)).await.is_err() {
                // The tab went away; nobody is left to show the rest.
                return;
            }
            if !continues(verdict, run.policy) {
                break 'batches;
            }
        }
    }
    let _ = events.send(RunEvent::Finished).await;
}

/// Run a script on the tab's editor session, opening one first when
/// needed. A session that lost its connection is let go, and the
/// window's own connection is checked, since it may have gone too.
pub async fn run_in_tab(
    session: Arc<Session>,
    slot: Arc<EditorSessionSlot>,
    run: ScriptRun,
    close_timeout: Duration,
    cancel: CancellationToken,
    events: mpsc::Sender<RunEvent>,
) {
    let editor = match slot
        .acquire(&session, run.statement_timeout, close_timeout, &cancel)
        .await
    {
        Ok(editor) => editor,
        Err(AcquireError::Cancelled) => {
            let _ = events.send(RunEvent::Finished).await;
            return;
        }
        Err(AcquireError::Failed(message)) => {
            let report = BatchReport {
                batch: 0,
                entries: vec![EntryKind::Failed {
                    message,
                    error_char: None,
                }],
                verdict: Verdict::Stopped,
                transaction: None,
                lost: false,
                elapsed_ms: 0,
            };
            let _ = events.send(RunEvent::Batch(report)).await;
            let _ = events.send(RunEvent::Finished).await;
            return;
        }
    };
    run_batches(&editor, &run, &cancel, &events).await;
    if editor.state() == EditorSessionState::Lost {
        let generation = *session.link_changes().borrow();
        session.signal(MonitorSignal::ProbeRequested { generation });
        if slot.forget(&editor) {
            close_quietly(editor, close_timeout).await;
        }
    }
}

struct CollectingSink {
    collector: Arc<Mutex<BatchCollector>>,
}

impl ResultSink for CollectingSink {
    fn accept<'life0, 'async_trait>(
        &'life0 mut self,
        event: ResultEvent,
    ) -> Pin<Box<dyn Future<Output = SinkFlow> + Send + 'async_trait>>
    where
        'life0: 'async_trait,
        Self: 'async_trait,
    {
        lock(&self.collector).record(event);
        Box::pin(std::future::ready(SinkFlow::Continue))
    }
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

#[cfg(test)]
mod tests {
    use tablepro_core::{DriverError, LossPhase, RunEnd, TransactionState};
    use tablepro_test_support::{FakeEditorSession, FakeRun, Replies};

    use super::super::run_log::RunLog;
    use super::*;

    fn scoped(text: &str) -> ScopedText {
        ScopedText {
            text: text.to_owned(),
            base_char: 0,
        }
    }

    fn script(text: &str, grammar: SqlGrammar) -> (ScriptRun, Vec<String>, Vec<String>) {
        let (batches, policy, warnings) = plan_batches(&scoped(text), grammar, 0);
        let previews = batches.iter().map(|batch| batch.preview.clone()).collect();
        (
            ScriptRun {
                batches,
                policy,
                statement_timeout: None,
                row_limit: RowLimit::EDITOR_DEFAULT,
            },
            previews,
            warnings,
        )
    }

    fn answering() -> Replies<FakeRun> {
        let mut runs = Replies::default();
        runs.always(FakeRun::completed(Vec::new()));
        runs
    }

    /// Run the script and fold every event into a results list.
    async fn run_with(editor: &Arc<FakeEditorSession>, text: &str, grammar: SqlGrammar) -> RunLog {
        run_cancellable(editor, text, grammar, &CancellationToken::new()).await
    }

    async fn run_cancellable(
        editor: &Arc<FakeEditorSession>,
        text: &str,
        grammar: SqlGrammar,
        cancel: &CancellationToken,
    ) -> RunLog {
        let (run, previews, warnings) = script(text, grammar);
        let (events, mut received) = mpsc::channel(8);
        let session: Arc<dyn EditorSession> = editor.clone();
        let collect = async move {
            let mut log = RunLog::new(previews, warnings);
            while let Some(event) = received.recv().await {
                let finished = matches!(event, RunEvent::Finished);
                log.apply(event);
                if finished {
                    break;
                }
            }
            log
        };
        let (_, log) = tokio::join!(run_batches(&session, &run, cancel, &events), collect);
        log
    }

    fn texts(editor: &FakeEditorSession) -> Vec<String> {
        editor.texts().iter().map(|sql| sql.as_str().to_owned()).collect()
    }

    #[tokio::test]
    async fn pg_script_sends_one_statement_per_run() {
        let editor = Arc::new(FakeEditorSession::new(answering()));

        let log = run_with(&editor, "SELECT 1;\nSELECT 2;\n\nSELECT 3", SqlGrammar::PostgreSql).await;

        assert_eq!(texts(&editor), ["SELECT 1", "SELECT 2", "SELECT 3"]);
        assert_eq!(log.entries().len(), 3);
    }

    #[tokio::test]
    async fn vacuum_then_select_sends_two_runs() {
        let editor = Arc::new(FakeEditorSession::new(answering()));

        run_with(&editor, "VACUUM;\nSELECT 1", SqlGrammar::PostgreSql).await;

        assert_eq!(texts(&editor), ["VACUUM", "SELECT 1"]);
    }

    #[tokio::test]
    async fn failing_third_statement_keeps_first_two_and_marks_rest_not_run() {
        let mut runs = Replies::default();
        runs.when_sql_contains(
            "boom",
            FakeRun::failed(DriverError::server("relation \"boom\" does not exist")),
        );
        runs.always(FakeRun::completed(Vec::new()));
        let editor = Arc::new(FakeEditorSession::new(runs));

        let log = run_with(
            &editor,
            "SELECT 1; SELECT 2; SELECT * FROM boom; SELECT 4; SELECT 5",
            SqlGrammar::PostgreSql,
        )
        .await;

        assert_eq!(texts(&editor).len(), 3, "statements after the failure were sent");
        let kinds: Vec<&EntryKind> = log.entries().iter().map(|entry| &entry.kind).collect();
        assert!(matches!(kinds[0], EntryKind::Command { .. }));
        assert!(matches!(kinds[1], EntryKind::Command { .. }));
        assert!(matches!(kinds[2], EntryKind::Failed { message, .. } if message.contains("boom")));
        assert!(matches!(kinds[3], EntryKind::NotRun));
        assert!(matches!(kinds[4], EntryKind::NotRun));
    }

    #[tokio::test]
    async fn mssql_go_script_sends_two_batches_second_twice() {
        let editor = Arc::new(FakeEditorSession::new(answering()));

        run_with(
            &editor,
            "SELECT 1\nGO\nINSERT INTO t VALUES (1)\nSELECT 2\nGO 2\n",
            SqlGrammar::MsSql,
        )
        .await;

        let sent = texts(&editor);
        assert_eq!(sent.len(), 3, "{sent:?}");
        assert_eq!(sent[0], "SELECT 1");
        assert!(
            sent[1].starts_with("INSERT") && sent[1].ends_with("SELECT 2"),
            "{sent:?}"
        );
        assert_eq!(sent[1], sent[2]);
    }

    #[tokio::test]
    async fn a_failed_go_batch_does_not_stop_the_next_one() {
        let mut runs = Replies::default();
        runs.when_sql_contains(
            "boom",
            FakeRun::failed(DriverError::server("Invalid object name 'boom'.")),
        );
        runs.always(FakeRun::completed(Vec::new()));
        let editor = Arc::new(FakeEditorSession::new(runs));

        let log = run_with(&editor, "SELECT * FROM boom\nGO\nSELECT 2\nGO\n", SqlGrammar::MsSql).await;

        assert_eq!(texts(&editor).len(), 2, "SQL Server batches run on their own");
        assert!(matches!(log.entries()[1].kind, EntryKind::Command { .. }));
    }

    #[tokio::test]
    async fn editor_session_busy_shows_failed_entry() {
        let mut runs = Replies::default();
        runs.always(FakeRun::session_error(DriverError::EditorSessionBusy));
        let editor = Arc::new(FakeEditorSession::new(runs));

        let log = run_with(&editor, "SELECT 1; SELECT 2", SqlGrammar::PostgreSql).await;

        let EntryKind::Failed { message, .. } = &log.entries()[0].kind else {
            panic!("expected a failure: {:?}", log.entries());
        };
        assert!(message.contains("still running"), "{message}");
        assert_eq!(texts(&editor).len(), 1, "the busy batch was retried");
        assert!(matches!(log.entries()[1].kind, EntryKind::NotRun));
    }

    #[tokio::test]
    async fn unterminated_diagnostic_warns_and_still_sends() {
        let editor = Arc::new(FakeEditorSession::new(answering()));

        let log = run_with(&editor, "SELECT 1;\nSELECT $$never closed", SqlGrammar::PostgreSql).await;

        let EntryKind::ClientWarning { message } = &log.entries()[0].kind else {
            panic!("expected a warning first: {:?}", log.entries());
        };
        assert!(message.contains("line 2"), "{message}");
        assert_eq!(texts(&editor).len(), 2, "the unterminated text was not sent");
    }

    #[tokio::test]
    async fn stop_cancels_run_token() {
        let mut runs = Replies::default();
        runs.always(FakeRun::until_stopped());
        let editor = Arc::new(FakeEditorSession::new(runs));
        let cancel = CancellationToken::new();
        let stopping = {
            let cancel = cancel.clone();
            async move {
                tokio::task::yield_now().await;
                cancel.cancel();
            }
        };

        let (log, ()) = tokio::join!(
            run_cancellable(
                &editor,
                "SELECT pg_sleep(60); SELECT 2",
                SqlGrammar::PostgreSql,
                &cancel
            ),
            stopping
        );

        assert!(
            matches!(log.entries()[0].kind, EntryKind::Cancelled),
            "{:?}",
            log.entries()
        );
        assert!(matches!(log.entries()[1].kind, EntryKind::NotRun));
        assert_eq!(editor.stopped_runs(), 1);
        assert!(log.was_stopped());
    }

    #[tokio::test]
    async fn the_last_run_says_where_the_transaction_stands() {
        let mut runs = Replies::default();
        runs.always(FakeRun::completed(Vec::new()).leaving(TransactionState::InTransaction));
        let editor = Arc::new(FakeEditorSession::new(runs));

        let log = run_with(&editor, "BEGIN; UPDATE t SET a = 1", SqlGrammar::PostgreSql).await;

        assert_eq!(log.transaction(), Some(TransactionState::InTransaction));
    }

    #[tokio::test]
    async fn a_lost_session_says_the_next_run_reconnects() {
        let mut runs = Replies::default();
        runs.always(FakeRun::session_error(DriverError::ConnectionLost {
            during: LossPhase::Statement,
        }));
        let editor = Arc::new(FakeEditorSession::new(runs));

        let log = run_with(&editor, "SELECT 1", SqlGrammar::PostgreSql).await;

        let EntryKind::Failed { message, .. } = &log.entries()[0].kind else {
            panic!("expected a failure: {:?}", log.entries());
        };
        assert!(message.contains("next run"), "{message}");
        assert!(log.lost());
    }

    #[test]
    fn batches_know_where_they_start_in_the_buffer() {
        let scoped = ScopedText {
            text: "SELECT 'tên';\nSELECT oops".to_owned(),
            base_char: 50,
        };

        let (batches, _, _) = plan_batches(&scoped, SqlGrammar::PostgreSql, 3);

        assert_eq!(batches[1].text, "SELECT oops");
        assert_eq!(batches[1].error_base, 50 + 14);
    }

    #[test]
    fn a_timed_out_run_is_a_stop() {
        assert!(!continues(Verdict::Stopped, BatchErrorPolicy::ContinueNextBatch));
        let collector = BatchCollector::default();
        let (entries, verdict, _) = collector.finish(
            Ok(tablepro_core::RunSummary {
                elapsed: Duration::from_secs(30),
                end: RunEnd::TimedOut { server_cancelled: true },
                transaction_state: TransactionState::Idle,
            }),
            EditorSessionState::Ready,
            0,
        );
        assert_eq!(verdict, Verdict::Stopped);
        assert!(matches!(
            entries.as_slice(),
            [EntryKind::TimedOut { server_cancelled: true }]
        ));
    }

    #[test]
    fn sql_preview_collapses_whitespace_and_truncates() {
        assert_eq!(
            sql_preview("SELECT *\n  FROM   users\n  WHERE id = 1"),
            "SELECT * FROM users WHERE id = 1"
        );
        let long = "SELECT col1, col2, col3, col4, col5, col6, col7, col8, col9 FROM users WHERE id = 1";
        let preview = sql_preview(long);
        assert!(preview.ends_with('…'));
        assert!(preview.chars().count() <= 61);
    }
}
