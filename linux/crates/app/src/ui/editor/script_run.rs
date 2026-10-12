use std::future::Future;
use std::pin::Pin;
use std::sync::{Arc, Mutex, MutexGuard, PoisonError, Weak};
use std::time::{Duration, Instant};

use tablepro_core::{
    DriverError, EditorSession, EditorSessionOptions, EditorSessionState, ErrorCategory, QueryResult, ResultEvent,
    ResultSink, RowLimit, RunEnd, RunOptions, SinkFlow, Truncation, UserSql,
};
use tablepro_session::{OperationError, Session};
use tokio_util::sync::CancellationToken;

/// One statement's outcome inside a multi-statement script. The editor
/// renders these as sub-tabs of the results pane so a user running a
/// migration script sees every step's result, not just the last one.
/// `sql_preview` is the leading ~60 chars of the statement, for the tab
/// tooltip.
#[derive(Debug, Clone)]
pub struct StatementOutcome {
    pub sql_preview: String,
    pub elapsed_ms: u128,
    /// What the server said the statement changed. `None` where it
    /// reported no count, which is not the same as zero rows.
    pub rows_affected: Option<u64>,
    pub kind: StatementOutcomeKind,
}

#[derive(Debug, Clone)]
pub enum StatementOutcomeKind {
    /// A result set, empty for a statement that returned none.
    Rows(QueryResult),
    /// The statement failed; the ones after it are `NotRun`.
    Error(String),
    /// Queued behind a failure, so never sent.
    NotRun,
}

/// How a whole script run ended.
#[derive(Debug, Clone)]
pub enum ScriptEnd {
    Outcomes(Vec<StatementOutcome>),
    Cancelled,
    TimedOut,
    /// No editor session could be opened, so nothing ran.
    Unavailable(String),
}

/// What every statement of one run is allowed to do.
#[derive(Debug, Clone, Copy)]
pub struct ScriptOptions {
    pub statement_timeout: Option<Duration>,
    pub row_limit: RowLimit,
    pub close_timeout: Duration,
}

/// What a run's events add up to, in the shape the results pane draws.
#[derive(Debug, Clone, Default)]
pub struct CollectedRun {
    pub results: Vec<QueryResult>,
    pub rows_affected: Option<u64>,
}

impl CollectedRun {
    pub fn record(&mut self, event: ResultEvent) {
        match event {
            ResultEvent::ResultSetStarted { columns } => self.results.push(QueryResult::new(columns, Vec::new())),
            ResultEvent::ColumnsResolved { set_index, columns } => {
                if let Some(result) = self.results.get_mut(set_index) {
                    result.columns = columns;
                }
            }
            ResultEvent::Rows(rows) => match self.results.last_mut() {
                Some(result) => result.rows.extend(rows),
                // Rows with no columns would draw a grid that cannot
                // say what any cell is.
                None => tracing::warn!(rows = rows.len(), "rows arrived before their result set"),
            },
            ResultEvent::RowLimitReached { .. } => self.mark_truncated(),
            ResultEvent::ResultSetFinished { truncation, .. } => {
                if truncation == Truncation::ReadPastLimit {
                    self.mark_truncated();
                }
            }
            ResultEvent::CommandCompleted { rows_affected } => {
                if let Some(rows) = rows_affected {
                    self.rows_affected = Some(self.rows_affected.unwrap_or(0).saturating_add(rows));
                }
            }
            ResultEvent::Notice(notice) => {
                tracing::debug!(severity = %notice.severity, message = %notice.message, "server notice");
            }
        }
    }

    fn mark_truncated(&mut self) {
        if let Some(result) = self.results.last_mut() {
            result.truncated = true;
        }
    }

    /// One outcome per result set, or one empty outcome for a statement
    /// that only changed rows, so every statement shows up in the pane.
    pub fn into_outcomes(self, sql_preview: &str, elapsed_ms: u128) -> Vec<StatementOutcome> {
        let rows_affected = self.rows_affected;
        let mut results = self.results;
        if results.is_empty() {
            results.push(QueryResult::empty());
        }
        let last = results.len() - 1;
        results
            .into_iter()
            .enumerate()
            .map(|(index, result)| StatementOutcome {
                sql_preview: sql_preview.to_owned(),
                elapsed_ms,
                rows_affected: (index == last).then_some(rows_affected).flatten(),
                kind: StatementOutcomeKind::Rows(result),
            })
            .collect()
    }
}

/// Collects a run's events for the results pane. The grid shows a
/// finished result, so nothing is streamed to the GTK thread here.
struct CollectingSink {
    run: Arc<Mutex<CollectedRun>>,
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
        lock(&self.run).record(event);
        Box::pin(std::future::ready(SinkFlow::Continue))
    }
}

/// The editor tab's own connection, shared with the run on the runtime.
///
/// The run opens it and the tab closes it, possibly while a run is
/// still opening one, so the slot remembers it was closed and a session
/// opened after that is handed back to be closed rather than kept.
#[derive(Default)]
pub struct EditorSessionSlot {
    state: Mutex<SlotState>,
}

#[derive(Default)]
struct SlotState {
    open: Option<OpenEditor>,
    closed: bool,
}

struct OpenEditor {
    /// The window session it was opened from. A tab outliving a switch
    /// to another database must not run on the old one.
    owner: Weak<Session>,
    editor: Arc<dyn EditorSession>,
}

enum Lookup {
    Ready(Arc<dyn EditorSession>),
    /// None usable; `stale` is one to close before opening another.
    Missing {
        stale: Option<Arc<dyn EditorSession>>,
    },
    Closed,
}

impl EditorSessionSlot {
    pub fn new() -> Self {
        Self::default()
    }

    fn lookup(&self, owner: &Arc<Session>) -> Lookup {
        let mut state = lock(&self.state);
        if state.closed {
            return Lookup::Closed;
        }
        match state.open.take() {
            Some(open)
                if open.owner.ptr_eq(&Arc::downgrade(owner)) && open.editor.state() != EditorSessionState::Lost =>
            {
                let editor = open.editor.clone();
                state.open = Some(open);
                Lookup::Ready(editor)
            }
            stale => Lookup::Missing {
                stale: stale.map(|open| open.editor),
            },
        }
    }

    /// Keep a newly opened session, or hand it back when the tab closed
    /// while it was opening.
    fn adopt(&self, owner: &Arc<Session>, editor: Arc<dyn EditorSession>) -> Result<(), Arc<dyn EditorSession>> {
        let mut state = lock(&self.state);
        if state.closed {
            return Err(editor);
        }
        state.open = Some(OpenEditor {
            owner: Arc::downgrade(owner),
            editor,
        });
        Ok(())
    }

    fn forget(&self, editor: &Arc<dyn EditorSession>) -> bool {
        let mut state = lock(&self.state);
        let held = state.open.as_ref().is_some_and(|open| open.editor.id() == editor.id());
        if held {
            state.open = None;
        }
        held
    }

    /// Mark the tab gone and take its session to close. Every later
    /// open is closed straight away.
    pub fn close(&self) -> Option<Arc<dyn EditorSession>> {
        let mut state = lock(&self.state);
        state.closed = true;
        state.open.take().map(|open| open.editor)
    }
}

impl std::fmt::Debug for EditorSessionSlot {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let state = lock(&self.state);
        f.debug_struct("EditorSessionSlot")
            .field("open", &state.open.is_some())
            .field("closed", &state.closed)
            .finish()
    }
}

/// Run a script on the tab's editor session, opening one first when
/// the tab has none, or only one that was lost or belongs to a session
/// the window has since replaced.
pub async fn run_script(
    session: Arc<Session>,
    slot: Arc<EditorSessionSlot>,
    statements: Vec<String>,
    options: ScriptOptions,
    cancel: CancellationToken,
) -> ScriptEnd {
    if statements.is_empty() {
        return ScriptEnd::Outcomes(Vec::new());
    }
    let editor = match slot.lookup(&session) {
        Lookup::Ready(editor) => editor,
        Lookup::Closed => return ScriptEnd::Cancelled,
        Lookup::Missing { stale } => {
            if let Some(stale) = stale {
                close_quietly(stale, options.close_timeout).await;
            }
            let opening = EditorSessionOptions {
                statement_timeout: options.statement_timeout,
            };
            match session.open_editor_session(opening, &cancel).await {
                Ok(editor) => match slot.adopt(&session, editor.clone()) {
                    Ok(()) => editor,
                    Err(orphan) => {
                        close_quietly(orphan, options.close_timeout).await;
                        return ScriptEnd::Cancelled;
                    }
                },
                Err(OperationError::Cancelled) => return ScriptEnd::Cancelled,
                Err(error) => return ScriptEnd::Unavailable(crate::ui::error_text::operation_error_message(&error)),
            }
        }
    };
    let end = run_statements(&editor, statements, &options, &cancel).await;
    if editor.state() == EditorSessionState::Lost && slot.forget(&editor) {
        close_quietly(editor, options.close_timeout).await;
    }
    end
}

/// Send each statement in turn on one editor session. The first one
/// that fails stops the script, because the ones after it were written
/// assuming it worked.
pub async fn run_statements(
    editor: &Arc<dyn EditorSession>,
    statements: Vec<String>,
    options: &ScriptOptions,
    cancel: &CancellationToken,
) -> ScriptEnd {
    let mut outcomes = Vec::with_capacity(statements.len());
    let mut failed = false;
    for sql in statements {
        let preview = sql_preview(&sql);
        if failed {
            outcomes.push(StatementOutcome {
                sql_preview: preview,
                elapsed_ms: 0,
                rows_affected: None,
                kind: StatementOutcomeKind::NotRun,
            });
            continue;
        }
        if cancel.is_cancelled() {
            return ScriptEnd::Cancelled;
        }
        let collected = Arc::new(Mutex::new(CollectedRun::default()));
        let run_options = RunOptions::new(cancel.clone())
            .with_deadline(options.statement_timeout)
            .with_row_limit(options.row_limit);
        let sink = Box::new(CollectingSink { run: collected.clone() });
        let started = Instant::now();
        let summary = editor.run(UserSql::new(sql), run_options, sink).await;
        let elapsed_ms = started.elapsed().as_millis();
        let collected = std::mem::take(&mut *lock(&collected));
        match summary {
            Ok(summary) => match summary.end {
                RunEnd::Completed => outcomes.extend(collected.into_outcomes(&preview, elapsed_ms)),
                RunEnd::Failed(error) => {
                    failed = true;
                    outcomes.push(failure(preview, elapsed_ms, &error, editor.state()));
                }
                RunEnd::Cancelled => return ScriptEnd::Cancelled,
                RunEnd::TimedOut { .. } => return ScriptEnd::TimedOut,
            },
            Err(error) => match error.category() {
                ErrorCategory::Interrupted => return ScriptEnd::Cancelled,
                ErrorCategory::Timeout => return ScriptEnd::TimedOut,
                _ => {
                    failed = true;
                    outcomes.push(failure(preview, elapsed_ms, &error, editor.state()));
                }
            },
        }
    }
    ScriptEnd::Outcomes(outcomes)
}

fn failure(sql_preview: String, elapsed_ms: u128, error: &DriverError, state: EditorSessionState) -> StatementOutcome {
    let mut message = crate::ui::error_text::driver_message(error);
    if state == EditorSessionState::Lost {
        // An editor session is never reopened behind the user's back:
        // its open transaction and temporary tables went with it.
        message = crate::i18n::gettext_f(
            "{error} This tab's connection was lost; the next run opens a new one.",
            &[("error", &message)],
        );
    }
    StatementOutcome {
        sql_preview,
        elapsed_ms,
        rows_affected: None,
        kind: StatementOutcomeKind::Error(message),
    }
}

async fn close_quietly(editor: Arc<dyn EditorSession>, close_timeout: Duration) {
    if tokio::time::timeout(close_timeout, editor.close()).await.is_err() {
        tracing::warn!("an editor session did not close in time");
    }
}

/// First ~60 chars of `sql`, single-line, used for tab tooltips so the
/// user can tell sub-tabs apart on long scripts without reading the
/// editor.
pub fn sql_preview(sql: &str) -> String {
    let single_line: String = sql.split_whitespace().collect::<Vec<_>>().join(" ");
    if single_line.chars().count() > 60 {
        let prefix: String = single_line.chars().take(60).collect();
        format!("{prefix}…")
    } else {
        single_line
    }
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

#[cfg(test)]
mod tests {
    use tablepro_core::column::{ColumnType, ResultColumn};
    use tablepro_core::{DriverError, LossPhase, RunEnd, ServerNotice, Value};
    use tablepro_test_support::{FakeEditorSession, FakeRun, Replies};

    use super::*;

    fn columns(names: &[&str]) -> Arc<[ResultColumn]> {
        names
            .iter()
            .map(|name| ResultColumn::new(*name, ColumnType::untyped_text("text")))
            .collect()
    }

    fn rows(values: &[i64]) -> Vec<Vec<Value>> {
        values.iter().map(|value| vec![Value::Int(*value)]).collect()
    }

    fn collect(events: Vec<ResultEvent>) -> CollectedRun {
        let mut run = CollectedRun::default();
        for event in events {
            run.record(event);
        }
        run
    }

    fn finished(retained: u64, truncation: Truncation) -> ResultEvent {
        ResultEvent::ResultSetFinished {
            retained,
            total_rows: None,
            truncation,
        }
    }

    fn options() -> ScriptOptions {
        ScriptOptions {
            statement_timeout: None,
            row_limit: RowLimit::EDITOR_DEFAULT,
            close_timeout: Duration::from_secs(10),
        }
    }

    #[test]
    fn one_result_set_becomes_one_result() {
        let run = collect(vec![
            ResultEvent::ResultSetStarted {
                columns: columns(&["id"]),
            },
            ResultEvent::Rows(rows(&[1, 2])),
            ResultEvent::Rows(rows(&[3])),
            finished(3, Truncation::Complete),
        ]);

        let outcomes = run.into_outcomes("SELECT id FROM t", 5);

        assert_eq!(outcomes.len(), 1);
        let StatementOutcomeKind::Rows(result) = &outcomes[0].kind else {
            panic!("expected rows: {outcomes:?}");
        };
        assert_eq!(result.row_count(), 3);
        assert_eq!(result.columns.len(), 1);
        assert!(!result.truncated);
        assert_eq!(outcomes[0].rows_affected, None);
    }

    #[test]
    fn two_result_sets_become_two_results_in_order() {
        let run = collect(vec![
            ResultEvent::ResultSetStarted {
                columns: columns(&["a"]),
            },
            ResultEvent::Rows(rows(&[1])),
            finished(1, Truncation::Complete),
            ResultEvent::ResultSetStarted {
                columns: columns(&["b", "c"]),
            },
            ResultEvent::ColumnsResolved {
                set_index: 1,
                columns: columns(&["b", "c", "d"]),
            },
            ResultEvent::Rows(Vec::new()),
            finished(0, Truncation::Complete),
        ]);

        let outcomes = run.into_outcomes("EXEC report", 7);

        let widths: Vec<_> = outcomes
            .iter()
            .map(|outcome| match &outcome.kind {
                StatementOutcomeKind::Rows(result) => (result.columns.len(), result.row_count()),
                other => panic!("expected rows: {other:?}"),
            })
            .collect();
        assert_eq!(widths, [(1, 1), (3, 0)]);
    }

    #[test]
    fn a_command_with_no_result_set_reports_what_it_changed() {
        let run = collect(vec![
            ResultEvent::CommandCompleted { rows_affected: Some(4) },
            ResultEvent::Notice(ServerNotice {
                severity: "NOTICE".to_owned(),
                message: "vacuumed".to_owned(),
                code: None,
            }),
            ResultEvent::CommandCompleted { rows_affected: Some(2) },
        ]);

        let outcomes = run.into_outcomes("UPDATE t SET a = 1", 3);

        assert_eq!(outcomes.len(), 1);
        assert_eq!(outcomes[0].rows_affected, Some(6));
        let StatementOutcomeKind::Rows(result) = &outcomes[0].kind else {
            panic!("expected an empty result: {outcomes:?}");
        };
        assert_eq!(result.row_count(), 0);
    }

    #[test]
    fn reaching_the_row_limit_marks_the_result_truncated() {
        let by_event = collect(vec![
            ResultEvent::ResultSetStarted {
                columns: columns(&["id"]),
            },
            ResultEvent::Rows(rows(&[1, 2])),
            ResultEvent::RowLimitReached { retained: 2 },
            finished(2, Truncation::ServerStopped),
        ]);
        let by_finish = collect(vec![
            ResultEvent::ResultSetStarted {
                columns: columns(&["id"]),
            },
            ResultEvent::Rows(rows(&[1])),
            finished(1, Truncation::ReadPastLimit),
        ]);
        let stopped_by_its_own_limit = collect(vec![
            ResultEvent::ResultSetStarted {
                columns: columns(&["id"]),
            },
            finished(0, Truncation::ServerStopped),
        ]);

        assert!(by_event.results[0].truncated);
        assert!(by_finish.results[0].truncated);
        assert!(!stopped_by_its_own_limit.results[0].truncated);
    }

    #[tokio::test]
    async fn a_failing_statement_keeps_the_ones_before_and_skips_the_rest() {
        let mut runs = Replies::default();
        runs.when_sql_contains(
            "boom",
            FakeRun::failed(DriverError::server("relation \"boom\" does not exist")),
        );
        runs.always(FakeRun::completed(vec![
            ResultEvent::ResultSetStarted {
                columns: columns(&["n"]),
            },
            ResultEvent::Rows(rows(&[1])),
            finished(1, Truncation::Complete),
        ]));
        let editor: Arc<dyn EditorSession> = Arc::new(FakeEditorSession::new(runs));

        let end = run_statements(
            &editor,
            vec![
                "SELECT 1".to_owned(),
                "SELECT * FROM boom".to_owned(),
                "SELECT 3".to_owned(),
            ],
            &options(),
            &CancellationToken::new(),
        )
        .await;

        let ScriptEnd::Outcomes(outcomes) = end else {
            panic!("expected outcomes: {end:?}");
        };
        assert!(matches!(outcomes[0].kind, StatementOutcomeKind::Rows(_)));
        let StatementOutcomeKind::Error(message) = &outcomes[1].kind else {
            panic!("expected the failure: {outcomes:?}");
        };
        assert!(message.contains("boom"), "{message}");
        assert!(matches!(outcomes[2].kind, StatementOutcomeKind::NotRun));
    }

    #[tokio::test]
    async fn a_lost_editor_session_says_the_next_run_reconnects() {
        let mut runs = Replies::default();
        runs.always(FakeRun::session_error(DriverError::ConnectionLost {
            during: LossPhase::Statement,
        }));
        let editor: Arc<dyn EditorSession> = Arc::new(FakeEditorSession::new(runs));

        let end = run_statements(
            &editor,
            vec!["SELECT 1".to_owned()],
            &options(),
            &CancellationToken::new(),
        )
        .await;

        let ScriptEnd::Outcomes(outcomes) = end else {
            panic!("expected outcomes: {end:?}");
        };
        let StatementOutcomeKind::Error(message) = &outcomes[0].kind else {
            panic!("expected the failure: {outcomes:?}");
        };
        assert!(message.contains("next run"), "{message}");
        assert_eq!(editor.state(), EditorSessionState::Lost);
    }

    #[tokio::test]
    async fn a_cancelled_or_timed_out_run_ends_the_script() {
        for (end, expect_cancelled) in [
            (RunEnd::Cancelled, true),
            (RunEnd::TimedOut { server_cancelled: true }, false),
        ] {
            let mut runs = Replies::default();
            runs.always(FakeRun {
                end: Ok(end),
                ..FakeRun::completed(Vec::new())
            });
            let editor: Arc<dyn EditorSession> = Arc::new(FakeEditorSession::new(runs));

            let ended = run_statements(
                &editor,
                vec!["SELECT 1".to_owned(), "SELECT 2".to_owned()],
                &options(),
                &CancellationToken::new(),
            )
            .await;

            match ended {
                ScriptEnd::Cancelled => assert!(expect_cancelled),
                ScriptEnd::TimedOut => assert!(!expect_cancelled),
                other => panic!("the script kept going: {other:?}"),
            }
        }
    }

    fn session_opening(
        editors: Vec<Arc<dyn EditorSession>>,
    ) -> (Arc<Session>, Arc<tablepro_test_support::FakeConnection>) {
        use tablepro_session::fakes::{FakeConnector, FakeCredentialSource};
        use tablepro_session::operation::DefaultDeadlines;
        use tablepro_test_support::{ConnectionScript, FakeReply};

        let mut script = ConnectionScript::default();
        for editor in editors {
            script.open_editor_session.once(FakeReply::ok(editor));
        }
        let (pending, connection) = FakeConnector::pending_session(FakeConnector::request().unwrap(), script);
        let session = Session::start(
            pending,
            tablepro_session::SessionDeps {
                connector: Arc::new(FakeConnector::new([])),
                credentials: Arc::new(FakeCredentialSource::new()),
                deadlines: Arc::new(DefaultDeadlines::new(tablepro_core::LivenessPolicy::DESKTOP)),
                tasks: crate::test_support::paused_tasks(),
                prompter: None,
            },
        );
        (session, connection)
    }

    fn answering() -> Arc<FakeEditorSession> {
        let mut runs = Replies::default();
        runs.always(FakeRun::completed(Vec::new()));
        Arc::new(FakeEditorSession::new(runs))
    }

    #[tokio::test]
    async fn a_tab_opens_its_editor_session_once_and_reuses_it() {
        let editor = answering();
        let (session, connection) = session_opening(vec![editor.clone()]);
        let slot = Arc::new(EditorSessionSlot::new());

        for _ in 0..2 {
            let end = run_script(
                session.clone(),
                slot.clone(),
                vec!["SELECT 1".to_owned()],
                options(),
                CancellationToken::new(),
            )
            .await;
            assert!(matches!(end, ScriptEnd::Outcomes(_)), "{end:?}");
        }

        assert_eq!(
            tablepro_test_support::CallCounters::get(&connection.counters().open_editor_session),
            1
        );
        assert_eq!(editor.texts().len(), 2);
    }

    #[tokio::test]
    async fn a_new_window_session_replaces_the_old_editor_session() {
        let old_editor = answering();
        let new_editor = answering();
        let (old_session, _) = session_opening(vec![old_editor.clone()]);
        let (new_session, _) = session_opening(vec![new_editor.clone()]);
        let slot = Arc::new(EditorSessionSlot::new());

        for session in [old_session, new_session] {
            run_script(
                session,
                slot.clone(),
                vec!["SELECT 1".to_owned()],
                options(),
                CancellationToken::new(),
            )
            .await;
        }

        assert_eq!(old_editor.close_count(), 1, "the old session was left open");
        assert_eq!(new_editor.texts().len(), 1);
        assert_eq!(new_editor.close_count(), 0);
    }

    #[tokio::test]
    async fn a_session_opened_after_the_tab_closed_is_handed_back() {
        let editor = answering();
        let (session, _) = session_opening(Vec::new());
        let slot = EditorSessionSlot::new();

        assert!(slot.close().is_none());
        let opened: Arc<dyn EditorSession> = editor;

        assert!(slot.adopt(&session, opened).is_err());
        let end = run_script(
            session,
            Arc::new(slot),
            vec!["SELECT 1".to_owned()],
            options(),
            CancellationToken::new(),
        )
        .await;
        assert!(matches!(end, ScriptEnd::Cancelled), "{end:?}");
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
