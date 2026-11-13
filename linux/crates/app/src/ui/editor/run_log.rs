use tablepro_core::sql_syntax::script::BatchErrorPolicy;
use tablepro_core::{
    ByteLimit, DriverError, EditorSessionState, ErrorCategory, ResultEvent, RunEnd, RunSummary, TransactionState,
    Truncation, UserSql,
};

use tablepro_core::masking::{MaskingPolicy, SharedMaskingPolicy};

use super::script_runner::sql_preview;
use crate::services::grid::{GridMasks, MaskSource, remask_rows};
use crate::ui::result_pane::{ResultSetView, ResultSummary};
use crate::workspace::WorkOutcome;

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
        // Set when the message holds the server's own words, which can repeat a value the statement read.
        server: Option<ServerWords>,
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

// What a failure keeps of the server's error for a Fix that cannot send its words.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ServerWords {
    pub code: Option<String>,
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

/// The rows a batch may still keep under its run's limit.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RowRoom {
    /// The run's limit, which a result it cuts short names.
    pub run_limit: u64,
    pub left: u64,
    /// The statement was sent with `left` as its row limit, below its
    /// own, so a result the driver cut short was cut by the run's limit.
    pub limits_statement: bool,
    // The run's byte limit, which a result it cuts short names, and the bytes of rows the run can still keep.
    pub run_bytes: u64,
    pub bytes_left: u64,
}

impl RowRoom {
    // A result the session cut for size without a room from the run names the editor's own limit.
    pub const UNLIMITED: Self = Self {
        run_limit: u64::MAX,
        left: u64::MAX,
        limits_statement: false,
        run_bytes: ByteLimit::EDITOR_DEFAULT.get(),
        bytes_left: u64::MAX,
    };
}

/// Turns the events of one run into results list lines, on the runtime,
/// so only finished lines cross to the GTK thread.
#[derive(Debug)]
pub struct BatchCollector {
    /// The batch's text, which each of its result sets keeps.
    statement: UserSql,
    entries: Vec<EntryKind>,
    /// Where each result set of this run sits in `entries`.
    sets: Vec<usize>,
    room: RowRoom,
    masking: Option<StatementMasking>,
    // The rules as last read, with the generation they were read at.
    read: Option<(u64, MaskingPolicy)>,
}

// How one statement's rows meet the connection's masking rules as they arrive, so no value a rule hides is ever held.
#[derive(Debug, Clone)]
pub struct StatementMasking {
    // The session's live rules: a save during the run reaches the rows that arrive after it.
    pub rules: SharedMaskingPolicy,
    pub source: MaskSource,
    // The tab shows its values unmasked.
    pub revealed: bool,
}

impl BatchCollector {
    pub fn new(statement: UserSql) -> Self {
        Self {
            statement,
            entries: Vec::new(),
            sets: Vec::new(),
            room: RowRoom::UNLIMITED,
            masking: None,
            read: None,
        }
    }

    /// Rows past `room` are dropped, and the result says why.
    pub fn within(self, room: RowRoom) -> Self {
        Self { room, ..self }
    }

    pub fn masked(self, masking: Option<StatementMasking>) -> Self {
        Self { masking, ..self }
    }

    pub fn record(&mut self, event: ResultEvent) {
        match event {
            ResultEvent::ResultSetStarted { columns } => self.start_set(columns),
            ResultEvent::ColumnsResolved { set_index, columns } => self.resolve_columns(set_index, columns),
            ResultEvent::Rows(rows) => {
                if self.rules_moved()
                    && let Some(last) = self.sets.len().checked_sub(1)
                {
                    self.refresh_masks(last);
                }
                if self.sets.is_empty() {
                    // Rows with no columns would draw a grid that cannot
                    // say what any cell is.
                    tracing::warn!(rows = rows.len(), "rows arrived before their result set");
                    return;
                }
                // The session keeps the row that crosses its limit, so a statement with no bytes left still brings one.
                let full = self.room.bytes_left == 0;
                let room = if full { 0 } else { self.room.left };
                let kept = usize::try_from(room).unwrap_or(usize::MAX).min(rows.len());
                self.room.left -= kept as u64;
                let cut = kept < rows.len();
                let cut_by = (cut && !full).then_some(self.room.run_limit);
                let cut_for_size = (cut && full).then_some(self.room.run_bytes);
                if let Some(result) = self.last_set() {
                    let (shown, columns) = (result.masks.shown.clone(), result.columns.clone());
                    result.rows.extend(rows.into_iter().take(kept).map(|mut row| {
                        shown.apply(&columns, &mut row);
                        row.into()
                    }));
                    result.summary.retained = result.rows.len() as u64;
                    result.summary.run_limit = result.summary.run_limit.or(cut_by);
                    result.summary.size_limit = result.summary.size_limit.or(cut_for_size);
                }
            }
            // Until the set ends and says how far the read went, all
            // that is known is that more rows were left behind.
            ResultEvent::RowLimitReached { .. } => {
                let cut_by = self.room.limits_statement.then_some(self.room.run_limit);
                if let Some(result) = self.last_set() {
                    result.summary = ResultSummary {
                        retained: result.rows.len() as u64,
                        total_rows: None,
                        truncation: Truncation::ServerStopped,
                        run_limit: result.summary.run_limit.or(cut_by),
                        size_limit: result.summary.size_limit,
                    };
                }
            }
            ResultEvent::ByteLimitReached { .. } => {
                let size = self.room.run_bytes;
                if let Some(result) = self.last_set() {
                    result.summary = ResultSummary {
                        retained: result.rows.len() as u64,
                        total_rows: None,
                        truncation: Truncation::ByteLimit,
                        run_limit: result.summary.run_limit,
                        size_limit: result.summary.size_limit.or(Some(size)),
                    };
                }
            }
            ResultEvent::ResultSetFinished {
                total_rows, truncation, ..
            } => {
                let cut_by = (self.room.limits_statement && truncation == Truncation::ReadPastLimit)
                    .then_some(self.room.run_limit);
                let cut_for_size = (truncation == Truncation::ByteLimit).then_some(self.room.run_bytes);
                if let Some(result) = self.last_set() {
                    result.summary = ResultSummary {
                        retained: result.rows.len() as u64,
                        total_rows,
                        truncation,
                        run_limit: result.summary.run_limit.or(cut_by),
                        size_limit: result.summary.size_limit.or(cut_for_size),
                    };
                }
            }
            ResultEvent::CommandCompleted { rows_affected } => {
                self.entries.push(EntryKind::Command { rows_affected });
            }
            ResultEvent::Notice(notice) => self.entries.push(EntryKind::Notice {
                message: format!("{}: {}", notice.severity, notice.message),
            }),
            ResultEvent::NoticeLimitReached { retained } => self.entries.push(EntryKind::Notice {
                message: crate::i18n::ngettext_f(
                    "Only the first {n} notice is shown. The server sent more.",
                    "Only the first {n} notices are shown. The server sent more.",
                    u32::try_from(retained).unwrap_or(u32::MAX),
                    &[("n", &retained.to_string())],
                ),
            }),
        }
    }

    /// Close the run with how it ended. `in_transaction` says a
    /// transaction was open when the batch was sent. `error_base` is
    /// where the batch starts in the buffer, so a server's error position
    /// becomes a buffer position.
    pub fn finish(
        mut self,
        outcome: Result<RunSummary, DriverError>,
        state: EditorSessionState,
        in_transaction: bool,
        error_base: usize,
    ) -> (Vec<EntryKind>, Verdict, Option<TransactionState>) {
        let lost = SessionLoss {
            lost: state == EditorSessionState::Lost,
            in_transaction,
        };
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
                        self.entries.push(failed(&error, lost, error_base));
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
                self.entries.push(failed(&error, lost, error_base));
                (Verdict::Stopped, None)
            }
        };
        (self.entries, verdict, transaction)
    }

    // The generation first, so rules set between the two reads are read again on the next check.
    fn policy(&mut self) -> Option<MaskingPolicy> {
        let rules = &self.masking.as_ref()?.rules;
        let generation = rules.generation();
        match &self.read {
            Some((read, policy)) if *read == generation => Some(policy.clone()),
            _ => {
                let policy = rules.get();
                self.read = Some((generation, policy.clone()));
                Some(policy)
            }
        }
    }

    fn rules_moved(&self) -> bool {
        match (&self.masking, &self.read) {
            (Some(masking), Some((read, _))) => masking.rules.generation() != *read,
            _ => false,
        }
    }

    fn start_set(&mut self, columns: std::sync::Arc<[tablepro_core::column::ResultColumn]>) {
        self.sets.push(self.entries.len());
        let mut view = ResultSetView::new(columns, self.statement.clone());
        if let Some(policy) = self.policy()
            && let Some(masking) = &self.masking
        {
            view.masks = masking.source.masks(&policy, &view.columns, masking.revealed);
            view.mask_source = masking.source.clone();
        }
        self.entries.push(EntryKind::ResultSet(view));
    }

    // Types the driver resolved late can bring a type rule into play, also for rows already held.
    fn resolve_columns(&mut self, set_index: usize, columns: std::sync::Arc<[tablepro_core::column::ResultColumn]>) {
        let Some(result) = self.set(set_index) else {
            return;
        };
        result.columns = columns;
        self.refresh_masks(set_index);
    }

    // Masks the set's held rows of every column the rules now mask, as when its columns resolved or a save landed.
    fn refresh_masks(&mut self, set_index: usize) {
        let Some(policy) = self.policy() else {
            return;
        };
        let Some(masking) = self.masking.clone() else {
            return;
        };
        let Some(result) = self.set(set_index) else {
            return;
        };
        let fresh = masking.source.masks(&policy, &result.columns, masking.revealed);
        let shown = match result.rows.is_empty() {
            true => fresh.shown.clone(),
            false => match remask_rows(&result.columns, &result.masks.shown, &fresh.shown, &result.rows) {
                Some((shown, rows)) => {
                    result.rows = rows;
                    shown
                }
                None => result.masks.shown.clone(),
            },
        };
        result.masks = GridMasks { shown, ..fresh };
    }

    fn set(&mut self, set_index: usize) -> Option<&mut ResultSetView> {
        let index = *self.sets.get(set_index)?;
        match self.entries.get_mut(index) {
            Some(EntryKind::ResultSet(result)) => Some(result),
            _ => None,
        }
    }

    fn last_set(&mut self) -> Option<&mut ResultSetView> {
        let last = self.sets.len().checked_sub(1)?;
        self.set(last)
    }
}

/// Whether the session's connection went with this batch, and whether
/// a transaction was open on it.
#[derive(Debug, Clone, Copy)]
struct SessionLoss {
    lost: bool,
    in_transaction: bool,
}

fn failed(error: &DriverError, lost: SessionLoss, error_base: usize) -> EntryKind {
    let mut message = crate::ui::error_text::driver_message(error);
    // An editor session is never reopened behind the user's back: its
    // open transaction and temporary tables went with it. With a
    // transaction open, the next run is refused rather than reopening.
    if lost.lost && lost.in_transaction {
        message = crate::i18n::gettext_f(
            "{error} This tab's connection was lost, so the server rolled back its open transaction.",
            &[("error", &message)],
        );
    } else if lost.lost {
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
    let server = tablepro_core::masking::may_repeat_a_value(error).then(|| ServerWords {
        code: tablepro_core::masking::server_code(error),
    });
    EntryKind::Failed {
        message,
        error_char,
        server,
    }
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
        let mut collector = BatchCollector::new(UserSql::new("SELECT a FROM t"));
        for event in events {
            collector.record(event);
        }
        let (entries, verdict, _) = collector.finish(summary(end), EditorSessionState::Ready, false, 0);
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
        let EntryKind::ResultSet(result) = &entries[0] else {
            panic!("expected rows: {entries:?}");
        };
        assert_eq!(result.row_count(), 2);
        assert_eq!(
            result.summary,
            ResultSummary {
                retained: 2,
                total_rows: Some(5),
                truncation: Truncation::ServerStopped,
                run_limit: None,
                size_limit: None,
            }
        );
        assert_eq!(result.statement.as_str(), "SELECT a FROM t");
        assert!(matches!(&entries[1], EntryKind::Notice { message } if message.contains("vacuumed")));
        assert!(matches!(entries[2], EntryKind::Command { rows_affected: Some(4) }));
    }

    #[test]
    fn notices_past_the_runs_limit_end_in_one_line_that_says_so() {
        let notice = |message: &str| {
            ResultEvent::Notice(ServerNotice {
                severity: "NOTICE".to_owned(),
                message: message.to_owned(),
                code: None,
            })
        };

        let (entries, _) = collect(
            vec![
                notice("row 1"),
                notice("row 2"),
                ResultEvent::NoticeLimitReached { retained: 2 },
                ResultEvent::CommandCompleted { rows_affected: None },
            ],
            RunEnd::Completed,
        );

        let messages: Vec<&str> = entries
            .iter()
            .filter_map(|entry| match entry {
                EntryKind::Notice { message } => Some(message.as_str()),
                _ => None,
            })
            .collect();
        assert_eq!(
            messages,
            [
                "NOTICE: row 1",
                "NOTICE: row 2",
                "Only the first 2 notices are shown. The server sent more."
            ]
        );
        assert!(matches!(
            entries.last(),
            Some(EntryKind::Command { rows_affected: None })
        ));
    }

    #[test]
    fn a_set_the_driver_cut_at_the_runs_room_names_the_run_limit() {
        let room = RowRoom {
            run_limit: 100,
            left: 1,
            limits_statement: true,
            ..RowRoom::UNLIMITED
        };
        let mut collector = BatchCollector::new(UserSql::new("SELECT a FROM t")).within(room);
        for event in [
            ResultEvent::ResultSetStarted {
                columns: columns(&["a"]),
            },
            ResultEvent::Rows(vec![vec![Value::Int(1)]]),
            ResultEvent::RowLimitReached { retained: 1 },
            ResultEvent::ResultSetFinished {
                retained: 1,
                total_rows: None,
                truncation: Truncation::ReadPastLimit,
            },
        ] {
            collector.record(event);
        }
        let (entries, _, _) = collector.finish(summary(RunEnd::Completed), EditorSessionState::Ready, false, 0);

        let EntryKind::ResultSet(result) = &entries[0] else {
            panic!("expected rows: {entries:?}");
        };
        assert_eq!(result.row_count(), 1);
        assert_eq!(result.summary.run_limit, Some(100));
    }

    fn first_summary(entries: &[EntryKind]) -> ResultSummary {
        match entries.first() {
            Some(EntryKind::ResultSet(result)) => result.summary,
            other => panic!("expected rows: {other:?}"),
        }
    }

    #[test]
    fn a_set_cut_for_size_says_so_before_and_after_it_ends() {
        let cut = || {
            vec![
                ResultEvent::ResultSetStarted {
                    columns: columns(&["a"]),
                },
                ResultEvent::Rows(vec![vec![Value::Int(1)], vec![Value::Int(2)]]),
                ResultEvent::ByteLimitReached { retained: 2 },
            ]
        };
        let mut finished = cut();
        finished.push(ResultEvent::ResultSetFinished {
            retained: 2,
            total_rows: Some(9),
            truncation: Truncation::ByteLimit,
        });

        let (stopped, _) = collect(cut(), RunEnd::Cancelled);
        let (ended, _) = collect(finished, RunEnd::Completed);

        let size_limit = Some(ByteLimit::EDITOR_DEFAULT.get());
        assert_eq!(
            first_summary(&stopped),
            ResultSummary {
                retained: 2,
                total_rows: None,
                truncation: Truncation::ByteLimit,
                run_limit: None,
                size_limit,
            }
        );
        assert_eq!(
            first_summary(&ended),
            ResultSummary {
                retained: 2,
                total_rows: Some(9),
                truncation: Truncation::ByteLimit,
                run_limit: None,
                size_limit,
            }
        );
    }

    #[test]
    fn a_batch_with_no_bytes_left_keeps_no_rows_and_says_why() {
        let room = RowRoom {
            run_bytes: 1_000,
            bytes_left: 0,
            ..RowRoom::UNLIMITED
        };
        let mut collector = BatchCollector::new(UserSql::new("SELECT a FROM t")).within(room);
        for event in [
            ResultEvent::ResultSetStarted {
                columns: columns(&["a"]),
            },
            ResultEvent::Rows(vec![vec![Value::Int(1)]]),
            ResultEvent::ByteLimitReached { retained: 1 },
            ResultEvent::ResultSetFinished {
                retained: 1,
                total_rows: Some(3),
                truncation: Truncation::ByteLimit,
            },
        ] {
            collector.record(event);
        }
        let (entries, _, _) = collector.finish(summary(RunEnd::Completed), EditorSessionState::Ready, false, 0);

        let kept = first_summary(&entries);
        assert_eq!((kept.retained, kept.size_limit, kept.run_limit), (0, Some(1_000), None));
    }

    #[test]
    fn a_set_cut_by_the_limit_and_then_stopped_stays_truncated() {
        let (entries, _) = collect(
            vec![
                ResultEvent::ResultSetStarted {
                    columns: columns(&["a"]),
                },
                ResultEvent::Rows(vec![vec![Value::Int(1)]]),
                ResultEvent::RowLimitReached { retained: 1 },
            ],
            RunEnd::Cancelled,
        );

        let EntryKind::ResultSet(result) = &entries[0] else {
            panic!("expected rows: {entries:?}");
        };
        assert!(result.summary.is_truncated());
        assert_eq!(result.summary.total_rows, None);
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
                    server: None,
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
    fn a_statement_with_nothing_to_say_still_gets_a_line() {
        let (entries, _) = collect(Vec::new(), RunEnd::Completed);

        assert!(matches!(
            entries.as_slice(),
            [EntryKind::Command { rows_affected: None }]
        ));
    }

    fn masked_by(policy: MaskingPolicy, revealed: bool) -> BatchCollector {
        BatchCollector::new(UserSql::new("SELECT id, email FROM users")).masked(Some(StatementMasking {
            rules: SharedMaskingPolicy::new(policy),
            source: MaskSource::Query {
                table: Some("users".to_owned()),
            },
            revealed,
        }))
    }

    fn email_rule() -> MaskingPolicy {
        use tablepro_core::masking::{MaskingRule, MaskingStyle, MaskingTarget};
        MaskingPolicy::new([MaskingRule::new(
            "users.email",
            MaskingTarget::Column,
            MaskingStyle::Email,
        )])
    }

    fn first_result(collector: BatchCollector) -> ResultSetView {
        let (entries, _, _) = collector.finish(summary(RunEnd::Completed), EditorSessionState::Ready, false, 0);
        match entries.into_iter().next() {
            Some(EntryKind::ResultSet(result)) => result,
            other => panic!("no result: {other:?}"),
        }
    }

    #[test]
    fn rows_are_masked_as_they_arrive_and_a_revealed_tab_keeps_them() {
        let events = || {
            vec![
                ResultEvent::ResultSetStarted {
                    columns: columns(&["id", "email"]),
                },
                ResultEvent::Rows(vec![vec![Value::Int(1), Value::Text("ann@example.com".to_owned())]]),
            ]
        };
        let mut masked = masked_by(email_rule(), false);
        let mut revealed = masked_by(email_rule(), true);
        for event in events() {
            masked.record(event);
        }
        for event in events() {
            revealed.record(event);
        }

        let masked = first_result(masked);
        let revealed = first_result(revealed);

        assert_eq!(masked.rows[0][1], Value::Text("a•••@example.com".to_owned()));
        assert!(masked.masks.is_masked(1));
        assert_eq!(revealed.rows[0][1], Value::Text("ann@example.com".to_owned()));
        assert!(revealed.masks.revealed);
        assert!(
            revealed.masks.external.is_masked(1),
            "a revealed result still masks on the way out"
        );
    }

    #[test]
    fn a_rule_saved_during_the_run_masks_the_rows_held_and_those_after_it() {
        let rules = SharedMaskingPolicy::default();
        let mut collector =
            BatchCollector::new(UserSql::new("SELECT id, email FROM users")).masked(Some(StatementMasking {
                rules: rules.clone(),
                source: MaskSource::Query {
                    table: Some("users".to_owned()),
                },
                revealed: false,
            }));
        let row = |id: i64, email: &str| vec![Value::Int(id), Value::Text(email.to_owned())];
        collector.record(ResultEvent::ResultSetStarted {
            columns: columns(&["id", "email"]),
        });
        collector.record(ResultEvent::Rows(vec![row(1, "ann@example.com")]));

        rules.set(email_rule());
        collector.record(ResultEvent::Rows(vec![row(2, "bo@example.com")]));

        let result = first_result(collector);
        assert_eq!(result.rows[0][1], Value::Text("a•••@example.com".to_owned()));
        assert_eq!(result.rows[1][1], Value::Text("b•••@example.com".to_owned()));
        assert!(result.masks.is_masked(1));
    }

    #[test]
    fn a_type_resolved_late_masks_the_rows_already_held() {
        use tablepro_core::masking::{MaskingRule, MaskingStyle, MaskingTarget};
        let policy = MaskingPolicy::new([MaskingRule::new("uuid", MaskingTarget::Type, MaskingStyle::Full)]);
        let mut collector = masked_by(policy, false);
        collector.record(ResultEvent::ResultSetStarted {
            columns: columns(&["token"]),
        });
        collector.record(ResultEvent::Rows(vec![vec![Value::Text("a1".to_owned())]]));
        collector.record(ResultEvent::ColumnsResolved {
            set_index: 0,
            columns: vec![ResultColumn::new("token", ColumnType::untyped_text("uuid"))].into(),
        });
        collector.record(ResultEvent::Rows(vec![vec![Value::Text("b2".to_owned())]]));

        let result = first_result(collector);

        assert_eq!(
            result.rows.iter().map(|row| row[0].clone()).collect::<Vec<_>>(),
            [Value::Text("••••".to_owned()), Value::Text("••••".to_owned())]
        );
    }

    #[test]
    fn a_server_error_position_becomes_a_buffer_position() {
        let diagnostics = ServerDiagnostics {
            position: Some(8),
            ..ServerDiagnostics::new(Some(ServerCode::SqlState("42601".to_owned())), "syntax error")
        };
        let collector = BatchCollector::new(UserSql::new("SELECT"));

        let (entries, verdict, _) = collector.finish(
            summary(RunEnd::Failed(DriverError::reported(diagnostics))),
            EditorSessionState::Ready,
            false,
            100,
        );

        assert_eq!(verdict, Verdict::Failed);
        assert!(
            matches!(
                entries.as_slice(),
                [EntryKind::Failed {
                    error_char: Some(107),
                    server: Some(ServerWords { code: Some(_) }),
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
            server: None,
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
