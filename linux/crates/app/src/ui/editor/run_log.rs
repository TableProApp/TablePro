use tablepro_core::sql_syntax::script::BatchErrorPolicy;
use tablepro_core::{
    DriverError, EditorSessionState, ErrorCategory, QueryResult, ResultEvent, RunEnd, RunSummary, TransactionState,
    Truncation,
};

/// One line of the results list.
#[derive(Debug, Clone)]
pub enum EntryKind {
    ResultSet {
        result: QueryResult,
        /// What the server says the whole set held, when it says.
        total_rows: Option<u64>,
    },
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
    /// Queued behind a failure, so never sent.
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

/// How one run of a batch ended, for deciding whether the next is sent.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Verdict {
    Completed,
    Failed,
    /// Cancelled, timed out, or the session itself failed: nothing more
    /// can run, whatever the engine's batch rules say.
    Stopped,
}

/// Whether the script goes on after a batch ended this way. A failed
/// statement stops it, because the statements after it were written
/// assuming it worked, unless the engine runs batches independently.
pub fn continues(verdict: Verdict, policy: BatchErrorPolicy) -> bool {
    match verdict {
        Verdict::Completed => true,
        Verdict::Failed => policy == BatchErrorPolicy::ContinueNextBatch,
        Verdict::Stopped => false,
    }
}

/// One batch's run, as the runner hands it to the results list.
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

/// Turns the events of one run into results list lines, on the runtime,
/// so only finished lines cross to the GTK thread.
#[derive(Debug, Default)]
pub struct BatchCollector {
    entries: Vec<EntryKind>,
    /// Where each result set of this run sits in `entries`.
    sets: Vec<usize>,
}

impl BatchCollector {
    pub fn record(&mut self, event: ResultEvent) {
        match event {
            ResultEvent::ResultSetStarted { columns } => {
                self.sets.push(self.entries.len());
                self.entries.push(EntryKind::ResultSet {
                    result: QueryResult::new(columns, Vec::new()),
                    total_rows: None,
                });
            }
            ResultEvent::ColumnsResolved { set_index, columns } => {
                if let Some(result) = self.set(set_index) {
                    result.columns = columns;
                }
            }
            ResultEvent::Rows(rows) => match self.last_set() {
                Some(result) => result.rows.extend(rows),
                // Rows with no columns would draw a grid that cannot say
                // what any cell is.
                None => tracing::warn!(rows = rows.len(), "rows arrived before their result set"),
            },
            ResultEvent::RowLimitReached { .. } => {
                if let Some(result) = self.last_set() {
                    result.truncated = true;
                }
            }
            ResultEvent::ResultSetFinished {
                total_rows, truncation, ..
            } => {
                if let Some(EntryKind::ResultSet {
                    result,
                    total_rows: total,
                }) = self.sets.last().and_then(|index| self.entries.get_mut(*index))
                {
                    result.truncated |= truncation == Truncation::ReadPastLimit;
                    *total = total_rows;
                }
            }
            ResultEvent::CommandCompleted { rows_affected } => {
                self.entries.push(EntryKind::Command { rows_affected });
            }
            ResultEvent::Notice(notice) => self.entries.push(EntryKind::Notice {
                message: format!("{}: {}", notice.severity, notice.message),
            }),
        }
    }

    /// Close the run with how it ended. `error_base` is where the batch
    /// starts in the buffer, so a server's error position becomes a
    /// buffer position.
    pub fn finish(
        mut self,
        outcome: Result<RunSummary, DriverError>,
        state: EditorSessionState,
        error_base: usize,
    ) -> (Vec<EntryKind>, Verdict, Option<TransactionState>) {
        let (verdict, transaction) = match outcome {
            Ok(summary) => {
                let verdict = match summary.end {
                    RunEnd::Completed => {
                        if self.entries.is_empty() {
                            // Every statement shows up, even one that
                            // neither returned rows nor counted any.
                            self.entries.push(EntryKind::Command { rows_affected: None });
                        }
                        Verdict::Completed
                    }
                    RunEnd::Failed(error) => {
                        self.entries.push(failed(&error, state, error_base));
                        Verdict::Failed
                    }
                    RunEnd::Cancelled => {
                        self.entries.push(EntryKind::Cancelled);
                        Verdict::Stopped
                    }
                    RunEnd::TimedOut { server_cancelled } => {
                        self.entries.push(EntryKind::TimedOut { server_cancelled });
                        Verdict::Stopped
                    }
                };
                (verdict, Some(summary.transaction_state))
            }
            Err(error) if error.category() == ErrorCategory::Interrupted => {
                self.entries.push(EntryKind::Cancelled);
                (Verdict::Stopped, None)
            }
            Err(error) => {
                self.entries.push(failed(&error, state, error_base));
                (Verdict::Stopped, None)
            }
        };
        (self.entries, verdict, transaction)
    }

    fn set(&mut self, set_index: usize) -> Option<&mut QueryResult> {
        let index = *self.sets.get(set_index)?;
        match self.entries.get_mut(index) {
            Some(EntryKind::ResultSet { result, .. }) => Some(result),
            _ => None,
        }
    }

    fn last_set(&mut self) -> Option<&mut QueryResult> {
        let last = self.sets.len().checked_sub(1)?;
        self.set(last)
    }
}

fn failed(error: &DriverError, state: EditorSessionState, error_base: usize) -> EntryKind {
    let mut message = crate::ui::error_text::driver_message(error);
    if state == EditorSessionState::Lost {
        // An editor session is never reopened behind the user's back:
        // its open transaction and temporary tables went with it.
        message = crate::i18n::gettext_f(
            "{error} This tab's connection was lost; the next run opens a new one.",
            &[("error", &message)],
        );
    }
    let error_char = match error {
        DriverError::Server(diagnostics) => diagnostics
            .position
            .and_then(|position| usize::try_from(position).ok())
            .filter(|position| *position > 0)
            .map(|position| error_base + position - 1),
        _ => None,
    };
    EntryKind::Failed { message, error_char }
}

/// The results list of one run, built as the batches report.
#[derive(Debug, Default)]
pub struct RunLog {
    previews: Vec<String>,
    entries: Vec<RunLogEntry>,
    /// The first batch no report has arrived for yet.
    next_batch: usize,
    transaction: Option<TransactionState>,
    lost: bool,
    elapsed_ms: u128,
}

impl RunLog {
    pub fn new(previews: Vec<String>, warnings: Vec<String>) -> Self {
        let entries = warnings
            .into_iter()
            .map(|message| RunLogEntry {
                kind: EntryKind::ClientWarning { message },
                batch: None,
                preview: String::new(),
            })
            .collect();
        Self {
            previews,
            entries,
            ..Self::default()
        }
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

    pub fn was_stopped(&self) -> bool {
        self.entries
            .iter()
            .any(|entry| matches!(entry.kind, EntryKind::Cancelled))
    }

    pub fn timed_out(&self) -> bool {
        self.entries
            .iter()
            .any(|entry| matches!(entry.kind, EntryKind::TimedOut { .. }))
    }

    /// What the run changed or returned, for the history entry: the
    /// rows statements reported changing, else the rows that came back.
    pub fn rows_for_history(&self) -> Option<i64> {
        let mut affected: Option<u64> = None;
        let mut returned: u64 = 0;
        for entry in &self.entries {
            match &entry.kind {
                EntryKind::Command {
                    rows_affected: Some(rows),
                } => affected = Some(affected.unwrap_or(0).saturating_add(*rows)),
                EntryKind::ResultSet { result, .. } => {
                    returned = returned.saturating_add(result.rows.len() as u64);
                }
                _ => {}
            }
        }
        let rows = affected.unwrap_or(returned);
        (affected.is_some() || returned > 0).then(|| i64::try_from(rows).unwrap_or(i64::MAX))
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
            u32::try_from(shown).unwrap_or(u32::MAX),
            &[("n", &shown.to_string()), ("ms", &ms)],
        );
        if failures == 0 {
            return results;
        }
        let failed = crate::i18n::ngettext_f(
            "{n} failed",
            "{n} failed",
            u32::try_from(failures).unwrap_or(u32::MAX),
            &[("n", &failures.to_string())],
        );
        format!("{results} · {failed}")
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;
    use std::time::Duration;

    use tablepro_core::column::{ColumnType, ResultColumn};
    use tablepro_core::{ServerCode, ServerDiagnostics, ServerNotice, Value};

    use super::*;

    fn columns(names: &[&str]) -> Arc<[ResultColumn]> {
        names
            .iter()
            .map(|name| ResultColumn::new(*name, ColumnType::untyped_text("text")))
            .collect()
    }

    fn summary(end: RunEnd) -> Result<RunSummary, DriverError> {
        Ok(RunSummary {
            elapsed: Duration::from_millis(3),
            end,
            transaction_state: TransactionState::Idle,
        })
    }

    fn collect(events: Vec<ResultEvent>, end: RunEnd) -> (Vec<EntryKind>, Verdict) {
        let mut collector = BatchCollector::default();
        for event in events {
            collector.record(event);
        }
        let (entries, verdict, _) = collector.finish(summary(end), EditorSessionState::Ready, 0);
        (entries, verdict)
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
    fn run_log_maps_events() {
        let (entries, verdict) = collect(
            vec![
                ResultEvent::ResultSetStarted {
                    columns: columns(&["a"]),
                },
                ResultEvent::Rows(vec![vec![Value::Int(1)], vec![Value::Int(2)]]),
                ResultEvent::RowLimitReached { retained: 2 },
                ResultEvent::ResultSetFinished {
                    retained: 2,
                    total_rows: Some(5),
                    truncation: Truncation::ServerStopped,
                },
                ResultEvent::Notice(ServerNotice {
                    severity: "NOTICE".to_owned(),
                    message: "vacuumed".to_owned(),
                    code: None,
                }),
                ResultEvent::CommandCompleted { rows_affected: Some(4) },
            ],
            RunEnd::Completed,
        );

        assert_eq!(verdict, Verdict::Completed);
        assert_eq!(entries.len(), 3, "{entries:?}");
        let EntryKind::ResultSet { result, total_rows } = &entries[0] else {
            panic!("expected rows: {entries:?}");
        };
        assert_eq!(result.row_count(), 2);
        assert!(result.truncated);
        assert_eq!(*total_rows, Some(5));
        assert!(matches!(&entries[1], EntryKind::Notice { message } if message.contains("vacuumed")));
        assert!(matches!(entries[2], EntryKind::Command { rows_affected: Some(4) }));
    }

    #[test]
    fn a_statement_with_nothing_to_say_still_gets_a_line() {
        let (entries, _) = collect(Vec::new(), RunEnd::Completed);

        assert!(matches!(
            entries.as_slice(),
            [EntryKind::Command { rows_affected: None }]
        ));
    }

    #[test]
    fn a_server_error_position_becomes_a_buffer_position() {
        let diagnostics = ServerDiagnostics {
            position: Some(8),
            ..ServerDiagnostics::new(Some(ServerCode::SqlState("42601".to_owned())), "syntax error")
        };
        let collector = BatchCollector::default();

        let (entries, verdict, _) = collector.finish(
            summary(RunEnd::Failed(DriverError::reported(diagnostics))),
            EditorSessionState::Ready,
            100,
        );

        assert_eq!(verdict, Verdict::Failed);
        assert!(
            matches!(
                entries.as_slice(),
                [EntryKind::Failed {
                    error_char: Some(107),
                    ..
                }]
            ),
            "{entries:?}"
        );
    }

    #[test]
    fn run_log_stop_policy_marks_rest_not_run() {
        let failed = vec![EntryKind::Failed {
            message: "boom".to_owned(),
            error_char: None,
        }];
        assert!(!continues(Verdict::Failed, BatchErrorPolicy::StopScript));
        let mut log = RunLog::new(
            vec![
                "SELECT 1".into(),
                "SELECT boom".into(),
                "SELECT 3".into(),
                "SELECT 4".into(),
            ],
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
        let mut log = RunLog::new(vec!["SELECT 1".into()], vec!["Unterminated string".into()]);

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
