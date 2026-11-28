use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;
use std::time::Duration;

use tablepro_core::script_run::{
    BatchReporter, ReportFlow, ScriptBatchReport, ScriptResultStore, run_batches as drive_batches,
};
use tablepro_core::sql_syntax::SqlGrammar;
use tablepro_core::sql_syntax::script::text_offsets::CharCounter;
use tablepro_core::sql_syntax::script::{BatchErrorPolicy, LexicalSettings, ScriptDiagnostic, ScriptPlan};
use tablepro_core::{DriverError, EditorSession, EditorSessionState, ReadOnlyRefusal, TransactionState, UserSql};
use tablepro_session::{MonitorSignal, Session};
use tokio::sync::mpsc;
use tokio_util::sync::CancellationToken;

use super::editor_session_slot::{AcquireError, EditorSessionSlot, close_quietly, transaction_open};
use super::run_log::{BatchReport, EntryKind, ResultViews, RunEvent, Verdict, continues, entry_kind};
use super::run_scope::ScopedText;

// The batch loop, the error policy, the run-wide budget and the
// structured log live in the core (`tablepro_core::script_run`). This
// file plans the batches, drives the core loop on the tab's session and
// words the core's reports for the GTK results pane.
pub use tablepro_core::script_run::{AfterRun, RUN_ROW_LIMIT, RunBatch, ScriptRun};

/// The batches of the scoped text and what the plan warns about.
///
/// Each statement goes on its own, as psql, mysql and sqlite3 send it,
/// so no implicit transaction can roll back statements that already
/// reported success. On SQL Server the unit is the `GO` batch, sent
/// whole as sqlcmd sends it.
pub fn plan_batches(
    scoped: &ScopedText,
    grammar: SqlGrammar,
    base_line: usize,
) -> (Vec<RunBatch>, BatchErrorPolicy, Vec<String>) {
    let plan = ScriptPlan::build(&scoped.text, grammar, LexicalSettings::default_for(grammar));
    let mut chars = CharCounter::new(&scoped.text);
    let batches = plan
        .batches()
        .iter()
        .filter_map(|batch| {
            let text = scoped.text.get(batch.range.clone())?;
            // A Redis command's range is exact, and a blank Rust trims but
            // Redis does not, such as U+00A0, is part of an argument.
            let text = if grammar.is_sql() { text.trim() } else { text };
            (!text.is_empty()).then(|| RunBatch {
                text: text.to_owned(),
                repeat: batch.repeat.get(),
                error_base: scoped.base_char + chars.char_at(batch.range.start),
                refused: false,
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

/// Send each batch in turn on the tab's editor session, reporting each
/// one as it ends. Rows go to the `ResultViews` the reports draw from.
/// `transaction` is where the session's transaction stood before the run;
/// the caller says `Finished` once the tab knows where the run left it.
pub async fn run_batches(
    editor: &Arc<dyn EditorSession>,
    run: &ScriptRun,
    cancel: &CancellationToken,
    events: &mpsc::Sender<RunEvent>,
    transaction: Option<TransactionState>,
) -> AfterRun {
    let views = Arc::new(ResultViews::default());
    let store: Arc<dyn ScriptResultStore> = views.clone();
    let mut reporter = EditorReporter {
        run,
        views,
        events: events.clone(),
    };
    drive_batches(editor, run, cancel, &store, &mut reporter, transaction).await
}

// Words each batch's structured report into a results-list report and
// sends it on the run's channel.
struct EditorReporter<'a> {
    run: &'a ScriptRun,
    views: Arc<ResultViews>,
    events: mpsc::Sender<RunEvent>,
}

impl BatchReporter for EditorReporter<'_> {
    fn report<'a>(&'a mut self, report: ScriptBatchReport) -> Pin<Box<dyn Future<Output = ReportFlow> + Send + 'a>> {
        let statement = UserSql::new(
            self.run
                .batches
                .get(report.batch)
                .map_or("", |batch| batch.text.as_str()),
        );
        let entries: Vec<EntryKind> = report
            .entries
            .into_iter()
            .map(|entry| entry_kind(entry, &self.views, &statement))
            .collect();
        let batch_report = BatchReport {
            batch: report.batch,
            entries,
            verdict: report.verdict,
            transaction: report.transaction,
            lost: report.lost,
            elapsed_ms: report.elapsed_ms,
        };
        let events = self.events.clone();
        Box::pin(async move {
            if events.send(RunEvent::Batch(batch_report)).await.is_err() {
                // The tab went away; nobody is left to show the rest.
                ReportFlow::ConsumerGone
            } else {
                ReportFlow::Continue
            }
        })
    }
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
    // Nothing would be sent, so no connection is opened for it.
    if run.batches.iter().all(|batch| batch.refused) {
        for (index, _) in run.batches.iter().enumerate() {
            let _ = events.send(RunEvent::Batch(refusal(index))).await;
            if !continues(Verdict::Failed, run.policy) {
                break;
            }
        }
        let _ = events.send(RunEvent::Finished).await;
        return;
    }
    let editor = match slot
        .acquire(&session, run.statement_timeout, close_timeout, &cancel)
        .await
    {
        Ok(editor) => editor,
        Err(AcquireError::Cancelled) => {
            let _ = events.send(RunEvent::Finished).await;
            return;
        }
        Err(AcquireError::TransactionRolledBack) => {
            let message = crate::i18n::gettext(
                "This tab's connection was lost, so the server rolled back its open transaction. Nothing was run; run again to open a new connection.",
            );
            refuse(&events, message, true).await;
            return;
        }
        Err(AcquireError::Moved { database, reason }) => {
            let message = crate::i18n::gettext_f(
                "Could not move this tab to the database “{database}”: {reason}",
                &[("database", &database), ("reason", &reason)],
            );
            refuse(&events, message, false).await;
            return;
        }
        Err(AcquireError::Failed(message)) => {
            refuse(&events, message, false).await;
            return;
        }
    };
    let before = slot.transaction(&editor);
    let after = run_batches(&editor, &run, &cancel, &events, before).await;
    slot.follow(&editor);
    if editor.state() != EditorSessionState::Lost {
        slot.note_transaction(&editor, after.transaction);
        let _ = events.send(RunEvent::Finished).await;
        return;
    }
    let generation = *session.link_changes().borrow();
    session.signal(MonitorSignal::ProbeRequested { generation });
    let refuse_next = transaction_open(after.transaction) && !after.rollback_told;
    let forgotten = slot.forget(&editor, refuse_next);
    let _ = events.send(RunEvent::Finished).await;
    if forgotten {
        close_quietly(editor, close_timeout).await;
    }
}

/// A batch Safe Mode kept from the server, which fails the way a write
/// the server refused would.
fn refusal(batch: usize) -> BatchReport {
    BatchReport {
        batch,
        entries: vec![EntryKind::Failed {
            message: crate::ui::error_text::driver_message(&DriverError::ReadOnly(ReadOnlyRefusal::ClientGuard)),
            error_char: None,
        }],
        verdict: Verdict::Failed,
        transaction: None,
        lost: false,
        elapsed_ms: 0,
    }
}

/// End a run that sent nothing, with `message` as its one line.
async fn refuse(events: &mpsc::Sender<RunEvent>, message: String, lost: bool) {
    let report = BatchReport {
        batch: 0,
        entries: vec![EntryKind::Failed {
            message,
            error_char: None,
        }],
        verdict: Verdict::Stopped,
        transaction: None,
        lost,
        elapsed_ms: 0,
    };
    let _ = events.send(RunEvent::Batch(report)).await;
    let _ = events.send(RunEvent::Finished).await;
}

#[cfg(test)]
mod tests {
    use tablepro_core::column::{ColumnType, ResultColumn};
    use tablepro_core::{ByteLimit, LossPhase, ResultEvent, RowLimit, RunEnd, TransactionState, Truncation, Value};
    use tablepro_test_support::{FakeEditorSession, FakeRun, Replies};

    use super::super::editor_session_slot::tests::session_opening;
    use super::super::run_log::RunLog;
    use super::*;

    fn scoped(text: &str) -> ScopedText {
        ScopedText {
            text: text.to_owned(),
            base_char: 0,
        }
    }

    fn script(text: &str, grammar: SqlGrammar) -> (ScriptRun, Vec<UserSql>, Vec<String>) {
        let (batches, policy, warnings) = plan_batches(&scoped(text), grammar, 0);
        let statements = batches.iter().map(|batch| UserSql::new(batch.text.as_str())).collect();
        (
            ScriptRun {
                batches,
                policy,
                statement_timeout: None,
                row_limit: RowLimit::EDITOR_DEFAULT,
                run_row_limit: RUN_ROW_LIMIT,
                byte_limit: ByteLimit::EDITOR_DEFAULT,
            },
            statements,
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
        let (run, statements, warnings) = script(text, grammar);
        play(editor, &run, statements, warnings, cancel).await
    }

    async fn play(
        editor: &Arc<FakeEditorSession>,
        run: &ScriptRun,
        statements: Vec<UserSql>,
        warnings: Vec<String>,
        cancel: &CancellationToken,
    ) -> RunLog {
        let (events, mut received) = mpsc::channel(8);
        let session: Arc<dyn EditorSession> = editor.clone();
        let collect = async move {
            let mut log = RunLog::new(statements, warnings);
            while let Some(event) = received.recv().await {
                let finished = matches!(event, RunEvent::Finished);
                log.apply(event);
                if finished {
                    break;
                }
            }
            log
        };
        let running = async {
            run_batches(&session, run, cancel, &events, None).await;
            let _ = events.send(RunEvent::Finished).await;
        };
        let (_, log) = tokio::join!(running, collect);
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

    /// Run the script the way a tab does, through its slot, and fold
    /// every event into a results list.
    async fn run_in_slot(session: &Arc<Session>, slot: &Arc<EditorSessionSlot>, text: &str) -> RunLog {
        let (run, statements, warnings) = script(text, SqlGrammar::PostgreSql);
        run_script_in_slot(session, slot, run, statements, warnings).await
    }

    async fn run_script_in_slot(
        session: &Arc<Session>,
        slot: &Arc<EditorSessionSlot>,
        run: ScriptRun,
        statements: Vec<UserSql>,
        warnings: Vec<String>,
    ) -> RunLog {
        let (events, mut received) = mpsc::channel(8);
        let running = run_in_tab(
            session.clone(),
            slot.clone(),
            run,
            Duration::from_secs(10),
            CancellationToken::new(),
            events,
        );
        let collect = async move {
            let mut log = RunLog::new(statements, warnings);
            while let Some(event) = received.recv().await {
                let finished = matches!(event, RunEvent::Finished);
                log.apply(event);
                if finished {
                    break;
                }
            }
            log
        };
        let ((), log) = tokio::join!(running, collect);
        log
    }

    fn first_failure(log: &RunLog) -> String {
        match &log.entries()[0].kind {
            EntryKind::Failed { message, .. } => message.clone(),
            other => panic!("expected a failure: {other:?}"),
        }
    }

    fn opening(transaction: TransactionState) -> Arc<FakeEditorSession> {
        let mut runs = Replies::default();
        runs.always(FakeRun::completed(Vec::new()).leaving(transaction));
        Arc::new(FakeEditorSession::new(runs))
    }

    #[tokio::test]
    async fn a_session_lost_idle_in_a_transaction_refuses_the_next_run() {
        let first = opening(TransactionState::InTransaction);
        let second = Arc::new(FakeEditorSession::new(answering()));
        let (session, _) = session_opening(vec![first.clone(), second.clone()]);
        let slot = Arc::new(EditorSessionSlot::new());

        run_in_slot(&session, &slot, "BEGIN").await;
        first.lose();
        let refused = run_in_slot(&session, &slot, "UPDATE a SET x = 0 WHERE id = 2").await;
        let reopened = run_in_slot(&session, &slot, "UPDATE a SET x = 0 WHERE id = 2").await;

        assert!(
            first_failure(&refused).contains("rolled back"),
            "{:?}",
            refused.entries()
        );
        assert!(refused.lost());
        assert_eq!(refused.transaction(), None);
        assert_eq!(
            first.texts(),
            [UserSql::new("BEGIN")],
            "the lost session ran the statement"
        );
        assert_eq!(first.close_count(), 1, "the lost session was left open");
        assert!(matches!(reopened.entries()[0].kind, EntryKind::Command { .. }));
        assert_eq!(second.texts(), [UserSql::new("UPDATE a SET x = 0 WHERE id = 2")]);
    }

    #[tokio::test]
    async fn a_session_lost_mid_run_in_a_transaction_says_so_and_the_next_run_reopens() {
        let mut runs = Replies::default();
        runs.once(FakeRun::completed(Vec::new()).leaving(TransactionState::Failed));
        runs.always(FakeRun::session_error(DriverError::ConnectionLost {
            during: LossPhase::Statement,
        }));
        let first = Arc::new(FakeEditorSession::new(runs));
        let second = Arc::new(FakeEditorSession::new(answering()));
        let (session, _) = session_opening(vec![first.clone(), second.clone()]);
        let slot = Arc::new(EditorSessionSlot::new());

        run_in_slot(&session, &slot, "BEGIN").await;
        let lost = run_in_slot(&session, &slot, "ROLLBACK").await;
        let reopened = run_in_slot(&session, &slot, "SELECT 1").await;

        let message = first_failure(&lost);
        assert!(
            message.contains("rolled back") && !message.contains("next run"),
            "{message}"
        );
        assert!(lost.lost());
        assert!(matches!(reopened.entries()[0].kind, EntryKind::Command { .. }));
        assert_eq!(second.texts(), [UserSql::new("SELECT 1")]);
    }

    /// A stop the server never acknowledged gives the connection up, and
    /// the run's results say only that it timed out.
    #[tokio::test]
    async fn a_stop_that_gives_up_a_session_in_a_transaction_refuses_the_next_run() {
        let mut runs = Replies::default();
        runs.once(FakeRun::completed(Vec::new()).leaving(TransactionState::InTransaction));
        runs.always(
            FakeRun {
                end: Ok(RunEnd::TimedOut {
                    server_cancelled: false,
                }),
                ..FakeRun::completed(Vec::new())
            }
            .losing_the_session(),
        );
        let first = Arc::new(FakeEditorSession::new(runs));
        let second = Arc::new(FakeEditorSession::new(answering()));
        let (session, _) = session_opening(vec![first.clone(), second.clone()]);
        let slot = Arc::new(EditorSessionSlot::new());

        run_in_slot(&session, &slot, "BEGIN").await;
        let stopped = run_in_slot(&session, &slot, "UPDATE a SET x = 0").await;
        let refused = run_in_slot(&session, &slot, "UPDATE a SET x = 1").await;
        let reopened = run_in_slot(&session, &slot, "UPDATE a SET x = 1").await;

        assert!(matches!(stopped.entries()[0].kind, EntryKind::TimedOut { .. }));
        assert!(
            first_failure(&refused).contains("rolled back"),
            "{:?}",
            refused.entries()
        );
        assert!(matches!(reopened.entries()[0].kind, EntryKind::Command { .. }));
        assert_eq!(second.texts(), [UserSql::new("UPDATE a SET x = 1")]);
    }

    #[tokio::test]
    async fn a_session_lost_with_no_transaction_reopens_on_the_next_run() {
        let first = opening(TransactionState::Idle);
        let second = Arc::new(FakeEditorSession::new(answering()));
        let (session, _) = session_opening(vec![first.clone(), second.clone()]);
        let slot = Arc::new(EditorSessionSlot::new());

        run_in_slot(&session, &slot, "SELECT 1").await;
        first.lose();
        let reopened = run_in_slot(&session, &slot, "SELECT 2").await;

        assert!(matches!(reopened.entries()[0].kind, EntryKind::Command { .. }));
        assert_eq!(second.texts(), [UserSql::new("SELECT 2")]);
    }

    fn sixty_rows() -> FakeRun {
        let columns: Arc<[ResultColumn]> = vec![ResultColumn::new("n", ColumnType::untyped_text("int4"))].into();
        FakeRun::completed(vec![
            ResultEvent::ResultSetStarted { columns },
            ResultEvent::Rows((0..60).map(|n| vec![Value::Int(n)]).collect()),
            ResultEvent::ResultSetFinished {
                retained: 60,
                total_rows: None,
                truncation: Truncation::Complete,
            },
        ])
    }

    #[tokio::test]
    async fn a_run_keeps_rows_up_to_its_limit_across_all_results() {
        let mut runs = Replies::default();
        runs.always(sixty_rows());
        let editor = Arc::new(FakeEditorSession::new(runs));
        let (mut run, statements, warnings) = script("SELECT 1; SELECT 2; SELECT 3", SqlGrammar::PostgreSql);
        run.run_row_limit = 100;

        let log = play(&editor, &run, statements, warnings, &CancellationToken::new()).await;

        assert_eq!(texts(&editor).len(), 3, "a statement past the limit was not sent");
        let kept: Vec<(usize, Option<u64>)> = log
            .entries()
            .iter()
            .filter_map(|entry| match &entry.kind {
                EntryKind::ResultSet(result) => Some((result.row_count(), result.summary.run_limit)),
                _ => None,
            })
            .collect();
        assert_eq!(kept, [(60, None), (40, Some(100)), (0, Some(100))]);
    }

    fn wide_rows(rows: usize) -> FakeRun {
        let columns: Arc<[ResultColumn]> = vec![ResultColumn::new("blob", ColumnType::untyped_text("text"))].into();
        FakeRun::completed(vec![
            ResultEvent::ResultSetStarted { columns },
            ResultEvent::Rows((0..rows).map(|_| vec![Value::Text("x".repeat(1_000))]).collect()),
            ResultEvent::ResultSetFinished {
                retained: rows as u64,
                total_rows: Some(rows as u64),
                truncation: Truncation::Complete,
            },
        ])
    }

    // Through the window's session, whose editor sessions cut each statement at the bytes its run has left.
    #[tokio::test]
    async fn a_run_keeps_bytes_up_to_its_limit_across_all_results() {
        let mut runs = Replies::default();
        runs.always(wide_rows(60));
        let editor = Arc::new(FakeEditorSession::new(runs));
        let (session, _) = session_opening(vec![editor.clone()]);
        let slot = Arc::new(EditorSessionSlot::new());
        let (mut run, statements, warnings) = script("SELECT 1; SELECT 2; SELECT 3", SqlGrammar::PostgreSql);
        let row = Value::Text("x".repeat(1_000)).retained_bytes() as u64;
        run.byte_limit = ByteLimit::new(row * 100).unwrap();
        let limit = run.byte_limit.get();

        let log = run_script_in_slot(&session, &slot, run, statements, warnings).await;

        assert_eq!(texts(&editor).len(), 3, "a statement past the limit was not sent");
        let kept: Vec<(usize, Option<u64>)> = log
            .entries()
            .iter()
            .filter_map(|entry| match &entry.kind {
                EntryKind::ResultSet(result) => Some((result.row_count(), result.summary.size_limit)),
                _ => None,
            })
            .collect();
        assert_eq!(kept, [(60, None), (40, Some(limit)), (0, Some(limit))]);
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
    fn a_redis_command_keeps_the_unicode_blanks_its_arguments_hold() {
        let (batches, _, _) = plan_batches(&scoped("  SET k \u{a0}v\u{a0}\nGET k\n"), SqlGrammar::Redis, 0);

        let texts: Vec<&str> = batches.iter().map(|batch| batch.text.as_str()).collect();
        assert_eq!(texts, ["SET k \u{a0}v\u{a0}", "GET k"]);
        assert_eq!(batches[0].error_base, 2);
    }

    #[test]
    fn a_long_script_finds_every_start_in_one_pass() {
        // Counting each start from the top of the text is about 10^11
        // steps here, which no run finishes; one pass is about 10^6.
        const STATEMENTS: usize = 100_000;
        let statement = "SELECT 'é';\n";
        let scoped = ScopedText {
            text: statement.repeat(STATEMENTS),
            base_char: 7,
        };

        let (batches, _, _) = plan_batches(&scoped, SqlGrammar::PostgreSql, 0);

        assert_eq!(batches.len(), STATEMENTS);
        let width = statement.chars().count();
        for (index, batch) in batches.iter().enumerate() {
            assert_eq!(batch.error_base, 7 + index * width, "batch {index}");
        }
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
