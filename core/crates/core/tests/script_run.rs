//! The batch loop against a fake editor session. The collector and
//! budget have their own unit tests next to the module; this drives whole
//! scripts, where only the public API and the test fakes reach.

use std::future::{Future, ready};
use std::pin::Pin;
use std::sync::{Arc, Mutex, PoisonError};

use tokio_util::sync::CancellationToken;

use tablepro_core::column::{ColumnType, ResultColumn};
use tablepro_core::script_run::{
    BatchReporter, RUN_ROW_LIMIT, ReportFlow, RunBatch, ScriptBatchReport, ScriptEntry, ScriptResultStore, ScriptRun,
    run_batches,
};
use tablepro_core::sql_syntax::SqlGrammar;
use tablepro_core::sql_syntax::script::text_offsets::CharCounter;
use tablepro_core::sql_syntax::script::{LexicalSettings, ScriptPlan};
use tablepro_core::value::Value;
use tablepro_core::{
    ByteLimit, DriverError, EditorSession, LossPhase, ResultEvent, RowLimit, TransactionState, Truncation,
};
use tablepro_test_support::{FakeEditorSession, FakeRun, Replies};

#[derive(Default)]
struct TestStore {
    sets: Mutex<Vec<Vec<Vec<Value>>>>,
}

impl TestStore {
    fn lock(&self) -> std::sync::MutexGuard<'_, Vec<Vec<Vec<Value>>>> {
        self.sets.lock().unwrap_or_else(PoisonError::into_inner)
    }

    fn row_count(&self, set_index: usize) -> usize {
        self.lock().get(set_index).map_or(0, Vec::len)
    }
}

impl ScriptResultStore for TestStore {
    fn start_set(&self, _columns: Arc<[ResultColumn]>) -> usize {
        let mut sets = self.lock();
        sets.push(Vec::new());
        sets.len() - 1
    }

    fn resolve_columns(&self, _set_index: usize, _columns: Arc<[ResultColumn]>) {}

    fn append(&self, set_index: usize, rows: Vec<Vec<Value>>) {
        if let Some(set) = self.lock().get_mut(set_index) {
            set.extend(rows);
        }
    }

    fn finish_set(&self, _set_index: usize, _total_rows: Option<u64>, _cut: bool) {}
}

#[derive(Default)]
struct Collect {
    reports: Vec<ScriptBatchReport>,
}

impl BatchReporter for Collect {
    fn report<'a>(&'a mut self, report: ScriptBatchReport) -> Pin<Box<dyn Future<Output = ReportFlow> + Send + 'a>> {
        self.reports.push(report);
        Box::pin(ready(ReportFlow::Continue))
    }
}

struct Flat {
    entries: Vec<ScriptEntry>,
    transaction: Option<TransactionState>,
    lost: bool,
    not_run: usize,
}

impl Flat {
    fn of(reports: &[ScriptBatchReport], batches: usize) -> Self {
        let mut entries = Vec::new();
        let mut transaction = None;
        let mut lost = false;
        let mut next_batch = 0;
        for report in reports {
            entries.extend(report.entries.iter().cloned());
            next_batch = next_batch.max(report.batch + 1);
            if report.transaction.is_some() {
                transaction = report.transaction;
            }
            lost |= report.lost;
        }
        Self {
            entries,
            transaction,
            lost,
            not_run: batches.saturating_sub(next_batch),
        }
    }

    fn was_stopped(&self) -> bool {
        self.entries.iter().any(|entry| matches!(entry, ScriptEntry::Cancelled))
            || (self.not_run > 0 && !self.entries.iter().any(ScriptEntry::is_failure))
    }
}

fn plan(text: &str, grammar: SqlGrammar) -> (Vec<RunBatch>, ScriptPlan) {
    let built = ScriptPlan::build(text, grammar, LexicalSettings::default_for(grammar));
    let mut chars = CharCounter::new(text);
    let batches = built
        .batches()
        .iter()
        .filter_map(|batch| {
            let slice = text.get(batch.range.clone())?;
            let slice = if grammar.is_sql() { slice.trim() } else { slice };
            (!slice.is_empty()).then(|| RunBatch {
                text: slice.to_owned(),
                repeat: batch.repeat.get(),
                error_base: chars.char_at(batch.range.start),
                refused: false,
            })
        })
        .collect();
    (batches, built)
}

fn script(text: &str, grammar: SqlGrammar) -> ScriptRun {
    let (batches, built) = plan(text, grammar);
    ScriptRun {
        batches,
        policy: built.batch_error_policy(),
        statement_timeout: None,
        row_limit: RowLimit::EDITOR_DEFAULT,
        run_row_limit: RUN_ROW_LIMIT,
        byte_limit: ByteLimit::EDITOR_DEFAULT,
    }
}

fn answering() -> Replies<FakeRun> {
    let mut runs = Replies::default();
    runs.always(FakeRun::completed(Vec::new()));
    runs
}

async fn run(editor: &Arc<FakeEditorSession>, spec: &ScriptRun, cancel: &CancellationToken) -> (Flat, Arc<TestStore>) {
    let store = Arc::new(TestStore::default());
    let dyn_store: Arc<dyn ScriptResultStore> = store.clone();
    let editor_dyn: Arc<dyn EditorSession> = editor.clone();
    let mut reporter = Collect::default();
    run_batches(&editor_dyn, spec, cancel, &dyn_store, &mut reporter, None).await;
    (Flat::of(&reporter.reports, spec.batches.len()), store)
}

async fn run_text(editor: &Arc<FakeEditorSession>, text: &str, grammar: SqlGrammar) -> (Flat, Arc<TestStore>) {
    run(editor, &script(text, grammar), &CancellationToken::new()).await
}

fn texts(editor: &FakeEditorSession) -> Vec<String> {
    editor.texts().iter().map(|sql| sql.as_str().to_owned()).collect()
}

#[tokio::test]
async fn pg_script_sends_one_statement_per_run() {
    let editor = Arc::new(FakeEditorSession::new(answering()));

    let (log, _) = run_text(&editor, "SELECT 1;\nSELECT 2;\n\nSELECT 3", SqlGrammar::PostgreSql).await;

    assert_eq!(texts(&editor), ["SELECT 1", "SELECT 2", "SELECT 3"]);
    assert_eq!(log.entries.len(), 3);
}

#[tokio::test]
async fn vacuum_then_select_sends_two_runs() {
    let editor = Arc::new(FakeEditorSession::new(answering()));

    run_text(&editor, "VACUUM;\nSELECT 1", SqlGrammar::PostgreSql).await;

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

    let (log, _) = run_text(
        &editor,
        "SELECT 1; SELECT 2; SELECT * FROM boom; SELECT 4; SELECT 5",
        SqlGrammar::PostgreSql,
    )
    .await;

    assert_eq!(texts(&editor).len(), 3, "statements after the failure were not sent");
    assert!(matches!(log.entries[0], ScriptEntry::Command { .. }));
    assert!(matches!(log.entries[1], ScriptEntry::Command { .. }));
    assert!(
        matches!(&log.entries[2], ScriptEntry::Failed { error: DriverError::Server(diag), .. } if diag.message.contains("boom"))
    );
    assert_eq!(log.not_run, 2);
}

#[tokio::test]
async fn mssql_go_script_sends_two_batches_second_twice() {
    let editor = Arc::new(FakeEditorSession::new(answering()));

    run_text(
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

    let (log, _) = run_text(&editor, "SELECT * FROM boom\nGO\nSELECT 2\nGO\n", SqlGrammar::MsSql).await;

    assert_eq!(texts(&editor).len(), 2, "SQL Server batches run on their own");
    assert!(matches!(log.entries[1], ScriptEntry::Command { .. }));
}

#[tokio::test]
async fn editor_session_busy_shows_failed_entry() {
    let mut runs = Replies::default();
    runs.always(FakeRun::session_error(DriverError::EditorSessionBusy));
    let editor = Arc::new(FakeEditorSession::new(runs));

    let (log, _) = run_text(&editor, "SELECT 1; SELECT 2", SqlGrammar::PostgreSql).await;

    assert!(
        matches!(
            &log.entries[0],
            ScriptEntry::Failed {
                error: DriverError::EditorSessionBusy,
                ..
            }
        ),
        "{:?}",
        log.entries
    );
    assert_eq!(texts(&editor).len(), 1, "the busy batch was not retried");
    assert_eq!(log.not_run, 1);
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

    let spec = script("SELECT pg_sleep(60); SELECT 2", SqlGrammar::PostgreSql);
    let ((log, _), ()) = tokio::join!(run(&editor, &spec, &cancel), stopping);

    assert!(matches!(log.entries[0], ScriptEntry::Cancelled), "{:?}", log.entries);
    assert_eq!(log.not_run, 1);
    assert_eq!(editor.stopped_runs(), 1);
    assert!(log.was_stopped());
}

#[tokio::test]
async fn the_last_run_says_where_the_transaction_stands() {
    let mut runs = Replies::default();
    runs.always(FakeRun::completed(Vec::new()).leaving(TransactionState::InTransaction));
    let editor = Arc::new(FakeEditorSession::new(runs));

    let (log, _) = run_text(&editor, "BEGIN; UPDATE t SET a = 1", SqlGrammar::PostgreSql).await;

    assert_eq!(log.transaction, Some(TransactionState::InTransaction));
}

#[tokio::test]
async fn a_lost_session_carries_the_loss_on_its_failure() {
    let mut runs = Replies::default();
    runs.always(FakeRun::session_error(DriverError::ConnectionLost {
        during: LossPhase::Statement,
    }));
    let editor = Arc::new(FakeEditorSession::new(runs));

    let (log, _) = run_text(&editor, "SELECT 1", SqlGrammar::PostgreSql).await;

    assert!(
        matches!(
            log.entries[0],
            ScriptEntry::Failed {
                lost: true,
                in_transaction: false,
                ..
            }
        ),
        "{:?}",
        log.entries
    );
    assert!(log.lost);
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
    let mut spec = script("SELECT 1; SELECT 2; SELECT 3", SqlGrammar::PostgreSql);
    spec.run_row_limit = 100;

    let (log, store) = run(&editor, &spec, &CancellationToken::new()).await;

    assert_eq!(texts(&editor).len(), 3, "a statement past the limit was still sent");
    let kept: Vec<(usize, Option<u64>)> = log
        .entries
        .iter()
        .filter_map(|entry| match entry {
            ScriptEntry::ResultSet { set_index, summary } => Some((store.row_count(*set_index), summary.run_limit)),
            _ => None,
        })
        .collect();
    assert_eq!(kept, [(60, None), (40, Some(100)), (0, Some(100))]);
}
