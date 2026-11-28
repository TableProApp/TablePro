use std::sync::{Arc, Mutex, PoisonError};

use tablepro_core::column::ResultColumn;
use tablepro_core::script_run::{ScriptEntry, ScriptResultStore};
use tablepro_core::{DriverError, TransactionState, UserSql, Value};

use super::script_runner::sql_preview;
use crate::ui::result_pane::{ResultSetView, ResultSummary};
use crate::workspace::WorkOutcome;

// The batch loop, the error policy and the structured log live in the
// core (`tablepro_core::script_run`); this file words the core's log into
// the GTK results list.
pub use tablepro_core::script_run::{Verdict, continues};

/// One line of the results list.
#[derive(Debug, Clone)]
pub enum EntryKind {
    ResultSet(ResultSetView),
    /// A statement that returned no rows, with what it changed when the
    /// server reports that.
    Command {
        rows_affected: Option<u64>,
    },
    Notice {
        message: String,
    },
    Failed {
        message: String,
        /// Where in the buffer the server says the error is, in
        /// characters, when it says.
        error_char: Option<usize>,
    },
    /// Something the editor noticed before sending, such as a string
    /// that never ends. The text is still sent, so the server has the
    /// last word.
    ClientWarning {
        message: String,
    },
    Cancelled,
    TimedOut {
        server_cancelled: bool,
    },
    /// Never sent: a statement before it failed, or the run was
    /// stopped first.
    NotRun,
}

impl EntryKind {
    pub fn is_failure(&self) -> bool {
        matches!(self, Self::Failed { .. } | Self::TimedOut { .. })
    }
}

#[derive(Debug, Clone)]
pub struct RunLogEntry {
    pub kind: EntryKind,
    /// The batch it came from, `None` for a warning about the script.
    pub batch: Option<usize>,
    pub preview: String,
}

/// One batch's run, worded for the results list.
#[derive(Debug, Clone)]
pub struct BatchReport {
    pub batch: usize,
    pub entries: Vec<EntryKind>,
    pub verdict: Verdict,
    pub transaction: Option<TransactionState>,
    /// The editor session's connection is gone.
    pub lost: bool,
    pub elapsed_ms: u128,
}

#[derive(Debug, Clone)]
pub enum RunEvent {
    Batch(BatchReport),
    Finished,
}

/// Keeps each result set's rows as the core batch loop sends them, so the
/// run can word a set's log line from these rows and the core's summary.
/// ADR 0063 leaves the Linux grid on its own row slots, so the rows stay
/// here rather than in the core's result store.
#[derive(Debug, Default)]
pub(super) struct ResultViews {
    sets: Mutex<Vec<ResultSetView>>,
}

impl ResultViews {
    fn lock(&self) -> std::sync::MutexGuard<'_, Vec<ResultSetView>> {
        self.sets.lock().unwrap_or_else(PoisonError::into_inner)
    }

    // The view the loop filled for `set_index`, with the run's summary and the batch's statement.
    fn view(&self, set_index: usize, summary: ResultSummary, statement: &UserSql) -> ResultSetView {
        let mut view = self
            .lock()
            .get(set_index)
            .cloned()
            .unwrap_or_else(|| ResultSetView::new(Arc::from([]), statement.clone()));
        view.summary = summary;
        view.statement = statement.clone();
        view
    }
}

impl ScriptResultStore for ResultViews {
    fn start_set(&self, columns: Arc<[ResultColumn]>) -> usize {
        let mut sets = self.lock();
        sets.push(ResultSetView::new(columns, UserSql::new("")));
        sets.len() - 1
    }

    fn resolve_columns(&self, set_index: usize, columns: Arc<[ResultColumn]>) {
        if let Some(view) = self.lock().get_mut(set_index) {
            view.columns = columns;
        }
    }

    fn append(&self, set_index: usize, rows: Vec<Vec<Value>>) {
        if let Some(view) = self.lock().get_mut(set_index) {
            view.rows.extend(rows.into_iter().map(Arc::<[Value]>::from));
        }
    }

    fn finish_set(&self, _set_index: usize, _total_rows: Option<u64>, _cut: bool) {}
}

/// Word one of the core's structured log entries into a results-list line.
pub(super) fn entry_kind(entry: ScriptEntry, views: &ResultViews, statement: &UserSql) -> EntryKind {
    match entry {
        ScriptEntry::ResultSet { set_index, summary } => {
            EntryKind::ResultSet(views.view(set_index, ResultSummary::from_core(summary), statement))
        }
        ScriptEntry::Command { rows_affected } => EntryKind::Command { rows_affected },
        ScriptEntry::Notice { severity, message, .. } => EntryKind::Notice {
            message: format!("{severity}: {message}"),
        },
        ScriptEntry::NoticeLimitReached { retained } => EntryKind::Notice {
            message: crate::i18n::ngettext_f(
                "Only the first {n} notice is shown. The server sent more.",
                "Only the first {n} notices are shown. The server sent more.",
                u32::try_from(retained).unwrap_or(u32::MAX),
                &[("n", &retained.to_string())],
            ),
        },
        ScriptEntry::Failed {
            error,
            error_char,
            lost,
            in_transaction,
        } => EntryKind::Failed {
            message: failed_message(&error, lost, in_transaction),
            error_char,
        },
        ScriptEntry::Cancelled => EntryKind::Cancelled,
        ScriptEntry::TimedOut { server_cancelled } => EntryKind::TimedOut { server_cancelled },
    }
}

fn failed_message(error: &DriverError, lost: bool, in_transaction: bool) -> String {
    let mut message = crate::ui::error_text::driver_message(error);
    // An editor session is never reopened behind the user's back: its
    // open transaction and temporary tables went with it. With a
    // transaction open, the next run is refused rather than reopening.
    if lost && in_transaction {
        message = crate::i18n::gettext_f(
            "{error} This tab's connection was lost, so the server rolled back its open transaction.",
            &[("error", &message)],
        );
    } else if lost {
        message = crate::i18n::gettext_f(
            "{error} This tab's connection was lost; the next run opens a new one.",
            &[("error", &message)],
        );
    }
    message
}

/// The results list of one run, built as the batches report.
#[derive(Debug, Default)]
pub struct RunLog {
    /// What each batch sent, for the assistant to fix one that failed.
    statements: Vec<UserSql>,
    previews: Vec<String>,
    entries: Vec<RunLogEntry>,
    /// The first batch no report has arrived for yet.
    next_batch: usize,
    transaction: Option<TransactionState>,
    lost: bool,
    elapsed_ms: u128,
}

impl RunLog {
    /// The log of a run of `statements`, one per batch.
    pub fn new(statements: Vec<UserSql>, warnings: Vec<String>) -> Self {
        let entries = warnings
            .into_iter()
            .map(|message| RunLogEntry {
                kind: EntryKind::ClientWarning { message },
                batch: None,
                preview: String::new(),
            })
            .collect();
        Self {
            previews: statements.iter().map(|sql| sql_preview(sql.as_str())).collect(),
            statements,
            entries,
            ..Self::default()
        }
    }

    /// The text batch `batch` sent.
    pub fn statement(&self, batch: usize) -> Option<&str> {
        self.statements.get(batch).map(UserSql::as_str)
    }

    /// Take one event; returns how many lines the log had before it, so
    /// the caller adds only the new ones.
    pub fn apply(&mut self, event: RunEvent) -> usize {
        let before = self.entries.len();
        match event {
            RunEvent::Batch(report) => {
                let preview = self.previews.get(report.batch).cloned().unwrap_or_default();
                self.entries.extend(report.entries.into_iter().map(|kind| RunLogEntry {
                    kind,
                    batch: Some(report.batch),
                    preview: preview.clone(),
                }));
                self.next_batch = self.next_batch.max(report.batch + 1);
                if report.transaction.is_some() {
                    self.transaction = report.transaction;
                }
                self.lost |= report.lost;
                self.elapsed_ms += report.elapsed_ms;
            }
            RunEvent::Finished => {
                for batch in self.next_batch..self.previews.len() {
                    self.entries.push(RunLogEntry {
                        kind: EntryKind::NotRun,
                        batch: Some(batch),
                        preview: self.previews[batch].clone(),
                    });
                }
                self.next_batch = self.previews.len();
            }
        }
        before
    }

    pub fn entries(&self) -> &[RunLogEntry] {
        &self.entries
    }

    pub fn result(&self, index: usize) -> Option<&ResultSetView> {
        match &self.entries.get(index)?.kind {
            EntryKind::ResultSet(result) => Some(result),
            _ => None,
        }
    }

    pub fn result_mut(&mut self, index: usize) -> Option<&mut ResultSetView> {
        match &mut self.entries.get_mut(index)?.kind {
            EntryKind::ResultSet(result) => Some(result),
            _ => None,
        }
    }

    pub fn first_result(self) -> Option<ResultSetView> {
        self.entries.into_iter().find_map(|entry| match entry.kind {
            EntryKind::ResultSet(result) => Some(result),
            _ => None,
        })
    }

    pub fn transaction(&self) -> Option<TransactionState> {
        self.transaction
    }

    pub fn lost(&self) -> bool {
        self.lost
    }

    pub fn elapsed_ms(&self) -> u128 {
        self.elapsed_ms
    }

    pub fn has_run(&self) -> bool {
        self.next_batch > 0
    }

    /// The line to show first: the first failure, else the first line.
    pub fn first_to_show(&self) -> Option<usize> {
        self.entries
            .iter()
            .position(|entry| entry.kind.is_failure())
            .or_else(|| (!self.entries.is_empty()).then_some(0))
    }

    /// The first failure's sentence, for history.
    pub fn first_failure(&self) -> Option<&str> {
        self.entries.iter().find_map(|entry| match &entry.kind {
            EntryKind::Failed { message, .. } => Some(message.as_str()),
            _ => None,
        })
    }

    /// Whether the run was stopped: a statement says so, or one was
    /// never sent with no failure ahead of it, as when Stop comes before
    /// the first statement goes.
    pub fn was_stopped(&self) -> bool {
        let kinds = || self.entries.iter().map(|entry| &entry.kind);
        kinds().any(|kind| matches!(kind, EntryKind::Cancelled))
            || (kinds().any(|kind| matches!(kind, EntryKind::NotRun)) && !kinds().any(EntryKind::is_failure))
    }

    pub fn timed_out(&self) -> bool {
        self.entries
            .iter()
            .any(|entry| matches!(entry.kind, EntryKind::TimedOut { .. }))
    }

    /// How the run went as a whole: one failed or timed out statement
    /// fails it, as it does in history.
    pub fn outcome(&self) -> WorkOutcome {
        if self.entries.iter().any(|entry| entry.kind.is_failure()) {
            WorkOutcome::Failed
        } else if self.was_stopped() {
            WorkOutcome::Cancelled
        } else {
            WorkOutcome::Succeeded
        }
    }

    /// What the run changed or returned, for the history entry: the
    /// rows statements reported changing, else every row the results
    /// had. A result the row limit cut short with no total makes that
    /// unknown, rather than the rows the grid happens to hold.
    pub fn rows_for_history(&self) -> Option<i64> {
        let mut affected: Option<i64> = None;
        let mut returned: Option<i64> = Some(0);
        for entry in &self.entries {
            match &entry.kind {
                EntryKind::Command {
                    rows_affected: Some(rows),
                } => {
                    let rows = i64::try_from(*rows).unwrap_or(i64::MAX);
                    affected = Some(affected.unwrap_or(0).saturating_add(rows));
                }
                EntryKind::ResultSet(result) => {
                    returned = returned
                        .zip(result.summary.history_row_count())
                        .map(|(sum, rows)| sum.saturating_add(rows));
                }
                _ => {}
            }
        }
        affected.or(returned.filter(|rows| *rows > 0))
    }

    /// The line above the results: how many there are and how long the
    /// run took, and how many failed.
    pub fn summary(&self) -> String {
        let shown = self
            .entries
            .iter()
            .filter(|entry| !matches!(entry.kind, EntryKind::NotRun | EntryKind::ClientWarning { .. }))
            .count();
        let failures = self.entries.iter().filter(|entry| entry.kind.is_failure()).count();
        let ms = self.elapsed_ms.to_string();
        let results = crate::i18n::ngettext_f(
            "{n} result in {ms} ms",
            "{n} results in {ms} ms",
            shown,
            &[("n", &shown.to_string()), ("ms", &ms)],
        );
        if failures == 0 {
            return results;
        }
        let failed = crate::i18n::ngettext_f("{n} failed", "{n} failed", failures, &[("n", &failures.to_string())]);
        format!("{results} · {failed}")
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use tablepro_core::column::{ColumnType, ResultColumn};
    use tablepro_core::sql_syntax::script::BatchErrorPolicy;
    use tablepro_core::{TransactionState, Truncation, UserSql};

    use super::*;
    use crate::ui::result_pane::ResultSummary;

    fn columns(names: &[&str]) -> Arc<[ResultColumn]> {
        names
            .iter()
            .map(|name| ResultColumn::new(*name, ColumnType::untyped_text("text")))
            .collect()
    }

    fn report(batch: usize, entries: Vec<EntryKind>, verdict: Verdict) -> RunEvent {
        RunEvent::Batch(BatchReport {
            batch,
            entries,
            verdict,
            transaction: Some(TransactionState::Idle),
            lost: false,
            elapsed_ms: 2,
        })
    }

    #[test]
    fn history_counts_every_row_a_result_had() {
        let set = |summary: ResultSummary| {
            let mut view = ResultSetView::new(columns(&["a"]), UserSql::new("SELECT a FROM t"));
            view.summary = summary;
            EntryKind::ResultSet(view)
        };
        let capped = ResultSummary {
            retained: 100,
            total_rows: None,
            truncation: Truncation::ServerStopped,
            run_limit: None,
            size_limit: None,
        };
        let counted = ResultSummary {
            retained: 100,
            total_rows: Some(250),
            truncation: Truncation::ReadPastLimit,
            run_limit: None,
            size_limit: None,
        };
        let history = |entries: Vec<EntryKind>| {
            let mut log = RunLog::new(vec![UserSql::new("SELECT a FROM t")], Vec::new());
            log.apply(report(0, entries, Verdict::Completed));
            log.rows_for_history()
        };

        assert_eq!(history(vec![set(counted), set(ResultSummary::complete(3))]), Some(253));
        assert_eq!(history(vec![set(counted), set(capped)]), None);
        assert_eq!(
            history(vec![set(capped), EntryKind::Command { rows_affected: Some(4) }]),
            Some(4),
            "rows a statement changed are what history records"
        );
    }

    #[test]
    fn a_failure_anywhere_fails_the_run_and_a_stop_alone_cancels_it() {
        let outcome = |batches: Vec<(Vec<EntryKind>, Verdict)>| {
            let mut log = RunLog::new(
                (0..batches.len()).map(|_| UserSql::new("SELECT 1")).collect(),
                Vec::new(),
            );
            for (batch, (entries, verdict)) in batches.into_iter().enumerate() {
                log.apply(report(batch, entries, verdict));
            }
            log.apply(RunEvent::Finished);
            log.outcome()
        };
        let done = || (vec![EntryKind::Command { rows_affected: None }], Verdict::Completed);
        let failed = || {
            (
                vec![EntryKind::Failed {
                    message: "boom".to_owned(),
                    error_char: None,
                }],
                Verdict::Failed,
            )
        };

        assert_eq!(outcome(vec![done(), done()]), WorkOutcome::Succeeded);
        assert_eq!(outcome(vec![done(), failed(), done()]), WorkOutcome::Failed);
        assert_eq!(
            outcome(vec![(
                vec![EntryKind::TimedOut { server_cancelled: true }],
                Verdict::Stopped
            )]),
            WorkOutcome::Failed
        );
        assert_eq!(
            outcome(vec![done(), (vec![EntryKind::Cancelled], Verdict::Stopped)]),
            WorkOutcome::Cancelled
        );
    }

    #[test]
    fn a_run_stopped_before_its_first_statement_was_stopped() {
        let mut log = RunLog::new(vec![UserSql::new("SELECT 1"), UserSql::new("SELECT 2")], Vec::new());

        log.apply(RunEvent::Finished);

        assert!(log.was_stopped());
        assert_eq!(log.outcome(), WorkOutcome::Cancelled);
    }

    #[test]
    fn run_log_stop_policy_marks_rest_not_run() {
        let failed = vec![EntryKind::Failed {
            message: "boom".to_owned(),
            error_char: None,
        }];
        assert!(!continues(Verdict::Failed, BatchErrorPolicy::StopScript));
        let mut log = RunLog::new(
            ["SELECT 1", "SELECT boom", "SELECT 3", "SELECT 4"]
                .into_iter()
                .map(UserSql::new)
                .collect(),
            Vec::new(),
        );

        log.apply(report(
            0,
            vec![EntryKind::Command { rows_affected: None }],
            Verdict::Completed,
        ));
        log.apply(report(1, failed, Verdict::Failed));
        log.apply(RunEvent::Finished);

        let kinds: Vec<&EntryKind> = log.entries().iter().map(|entry| &entry.kind).collect();
        assert!(matches!(kinds[0], EntryKind::Command { .. }));
        assert!(matches!(kinds[1], EntryKind::Failed { .. }));
        assert!(matches!(kinds[2], EntryKind::NotRun));
        assert!(matches!(kinds[3], EntryKind::NotRun));
        assert_eq!(log.entries()[3].preview, "SELECT 4");
        assert_eq!(log.first_to_show(), Some(1), "the failure is not what shows first");
    }

    #[test]
    fn run_log_continue_policy_runs_next_batch() {
        assert!(continues(Verdict::Failed, BatchErrorPolicy::ContinueNextBatch));
        assert!(!continues(Verdict::Stopped, BatchErrorPolicy::ContinueNextBatch));
        assert!(continues(Verdict::Completed, BatchErrorPolicy::StopScript));
    }

    #[test]
    fn a_warning_comes_first_and_counts_as_no_result() {
        let mut log = RunLog::new(vec![UserSql::new("SELECT 1")], vec!["Unterminated string".into()]);

        log.apply(report(
            0,
            vec![EntryKind::Command { rows_affected: Some(1) }],
            Verdict::Completed,
        ));
        log.apply(RunEvent::Finished);

        assert!(matches!(log.entries()[0].kind, EntryKind::ClientWarning { .. }));
        assert!(log.summary().starts_with("1 result"), "{}", log.summary());
        assert_eq!(log.rows_for_history(), Some(1));
    }
}
