use std::sync::Arc;

use crate::column::ResultColumn;
use crate::editor_session::EditorSessionState;
use crate::error::DriverError;
use crate::error_category::ErrorCategory;
use crate::result_event::{ResultEvent, RunEnd, RunSummary, Truncation};
use crate::transaction_state::TransactionState;
use crate::value::Value;

use super::budget::RowRoom;
use super::entry::{ResultSetSummary, ScriptEntry, Verdict};
use super::store::ScriptResultStore;

/// What one batch produced: its log, its verdict, where it left the
/// transaction, and the rows and bytes it added to the run's budget.
#[derive(Debug)]
pub struct BatchOutcome {
    pub entries: Vec<ScriptEntry>,
    pub verdict: Verdict,
    pub transaction: Option<TransactionState>,
    pub kept_rows: u64,
    pub kept_bytes: u64,
}

// A batch's result set: where its log entry sits, and the store index its
// rows went to.
#[derive(Clone, Copy)]
struct SetRef {
    entry: usize,
    store: usize,
}

/// Turns one batch's `ResultEvent`s into structured log entries, sending
/// rows on to the run's store and trimming each result to the run's
/// budget. One collector per batch; the run's budget comes in as `room`.
pub struct BatchCollector {
    store: Arc<dyn ScriptResultStore>,
    entries: Vec<ScriptEntry>,
    // The result sets of this batch, in the order they started.
    sets: Vec<SetRef>,
    room: RowRoom,
    kept_rows: u64,
    kept_bytes: u64,
}

impl BatchCollector {
    pub fn new(store: Arc<dyn ScriptResultStore>) -> Self {
        Self {
            store,
            entries: Vec::new(),
            sets: Vec::new(),
            room: RowRoom::UNLIMITED,
            kept_rows: 0,
            kept_bytes: 0,
        }
    }

    /// Rows past `room` are dropped, and the result says why.
    pub fn within(mut self, room: RowRoom) -> Self {
        self.room = room;
        self
    }

    pub fn record(&mut self, event: ResultEvent) {
        match event {
            ResultEvent::ResultSetStarted { columns } => self.start_set(columns),
            ResultEvent::ColumnsResolved { set_index, columns } => {
                if let Some(set) = self.sets.get(set_index).copied() {
                    self.store.resolve_columns(set.store, columns);
                }
            }
            ResultEvent::Rows(rows) => self.rows(rows),
            // Until the set ends and says how far the read went, all that
            // is known is that more rows were left behind.
            ResultEvent::RowLimitReached { .. } => {
                let cut_by = self.room.limits_statement.then_some(self.room.run_limit);
                self.set_summary(|summary| ResultSetSummary {
                    truncation: Truncation::ServerStopped,
                    total_rows: None,
                    run_limit: summary.run_limit.or(cut_by),
                    ..summary
                });
            }
            ResultEvent::ByteLimitReached { .. } => {
                let size = self.room.run_bytes;
                self.set_summary(|summary| ResultSetSummary {
                    truncation: Truncation::ByteLimit,
                    total_rows: None,
                    size_limit: summary.size_limit.or(Some(size)),
                    ..summary
                });
            }
            ResultEvent::ResultSetFinished {
                total_rows, truncation, ..
            } => self.set_finished(total_rows, truncation),
            ResultEvent::CommandCompleted { rows_affected } => {
                self.entries.push(ScriptEntry::Command { rows_affected });
            }
            ResultEvent::Notice(notice) => self.entries.push(ScriptEntry::Notice {
                severity: notice.severity,
                message: notice.message,
                code: notice.code,
            }),
            ResultEvent::NoticeLimitReached { retained } => {
                self.entries.push(ScriptEntry::NoticeLimitReached { retained });
            }
        }
    }

    fn start_set(&mut self, columns: Arc<[ResultColumn]>) {
        let store = self.store.start_set(columns);
        let entry = self.entries.len();
        self.entries.push(ScriptEntry::ResultSet {
            set_index: store,
            summary: ResultSetSummary::complete(0),
        });
        self.sets.push(SetRef { entry, store });
    }

    fn rows(&mut self, rows: Vec<Vec<Value>>) {
        let Some(set) = self.sets.last().copied() else {
            // Rows before a result set would have no columns to name their
            // cells, so there is nowhere to keep them.
            return;
        };
        // The session keeps the row that crosses its limit, so a statement
        // with no bytes left still brings one.
        let full = self.room.bytes_left == 0;
        let room = if full { 0 } else { self.room.left };
        let keep = usize::try_from(room).unwrap_or(usize::MAX).min(rows.len());
        self.room.left -= keep as u64;
        let cut = keep < rows.len();
        let cut_by = (cut && !full).then_some(self.room.run_limit);
        let cut_for_size = (cut && full).then_some(self.room.run_bytes);
        let kept: Vec<Vec<Value>> = rows.into_iter().take(keep).collect();
        self.kept_rows += kept.len() as u64;
        self.kept_bytes = kept
            .iter()
            .flat_map(|row| row.iter())
            .map(|value| value.retained_bytes() as u64)
            .fold(self.kept_bytes, u64::saturating_add);
        self.store.append(set.store, kept);
        if let Some(summary) = self.summary_mut(set) {
            summary.retained += keep as u64;
            summary.run_limit = summary.run_limit.or(cut_by);
            summary.size_limit = summary.size_limit.or(cut_for_size);
        }
    }

    fn set_finished(&mut self, total_rows: Option<u64>, truncation: Truncation) {
        let cut_by =
            (self.room.limits_statement && truncation == Truncation::ReadPastLimit).then_some(self.room.run_limit);
        let cut_for_size = (truncation == Truncation::ByteLimit).then_some(self.room.run_bytes);
        let Some((set, old)) = self.last_summary() else {
            return;
        };
        let summary = ResultSetSummary {
            total_rows,
            truncation,
            run_limit: old.run_limit.or(cut_by),
            size_limit: old.size_limit.or(cut_for_size),
            ..old
        };
        let cut = truncation != Truncation::Complete || summary.run_limit.is_some() || summary.size_limit.is_some();
        self.store.finish_set(set.store, total_rows, cut);
        self.entries[set.entry] = ScriptEntry::ResultSet {
            set_index: set.store,
            summary,
        };
    }

    // Replace the last set's summary with one built from its current one.
    fn set_summary(&mut self, build: impl FnOnce(ResultSetSummary) -> ResultSetSummary) {
        if let Some((set, old)) = self.last_summary() {
            self.entries[set.entry] = ScriptEntry::ResultSet {
                set_index: set.store,
                summary: build(old),
            };
        }
    }

    /// Close the batch with how it ended. `in_transaction` says a
    /// transaction was open when the batch was sent. `error_base` is where
    /// the batch starts in the buffer, so a server's error position
    /// becomes a buffer position.
    pub fn finish(
        mut self,
        outcome: Result<RunSummary, DriverError>,
        state: EditorSessionState,
        in_transaction: bool,
        error_base: usize,
    ) -> BatchOutcome {
        let lost = state == EditorSessionState::Lost;
        let (verdict, transaction) = match outcome {
            Ok(summary) => {
                let verdict = match summary.end {
                    RunEnd::Completed => {
                        if self.entries.is_empty() {
                            // Every statement shows up, even one that
                            // neither returned rows nor counted any.
                            self.entries.push(ScriptEntry::Command { rows_affected: None });
                        }
                        Verdict::Completed
                    }
                    RunEnd::Failed(error) => {
                        self.entries.push(failed(error, lost, in_transaction, error_base));
                        Verdict::Failed
                    }
                    RunEnd::Cancelled => {
                        self.entries.push(ScriptEntry::Cancelled);
                        Verdict::Stopped
                    }
                    RunEnd::TimedOut { server_cancelled } => {
                        self.entries.push(ScriptEntry::TimedOut { server_cancelled });
                        Verdict::Stopped
                    }
                };
                (verdict, Some(summary.transaction_state))
            }
            Err(error) if error.category() == ErrorCategory::Interrupted => {
                self.entries.push(ScriptEntry::Cancelled);
                (Verdict::Stopped, None)
            }
            Err(error) => {
                self.entries.push(failed(error, lost, in_transaction, error_base));
                (Verdict::Stopped, None)
            }
        };
        BatchOutcome {
            entries: self.entries,
            verdict,
            transaction,
            kept_rows: self.kept_rows,
            kept_bytes: self.kept_bytes,
        }
    }

    // The summary of the set `set.entry` points at.
    fn summary_mut(&mut self, set: SetRef) -> Option<&mut ResultSetSummary> {
        match self.entries.get_mut(set.entry)? {
            ScriptEntry::ResultSet { summary, .. } => Some(summary),
            _ => None,
        }
    }

    // The last started set and a copy of its summary, for the events that
    // replace the whole summary once the set ends.
    fn last_summary(&self) -> Option<(SetRef, ResultSetSummary)> {
        let set = self.sets.last().copied()?;
        match self.entries.get(set.entry)? {
            ScriptEntry::ResultSet { summary, .. } => Some((set, *summary)),
            _ => None,
        }
    }
}

fn failed(error: DriverError, lost: bool, in_transaction: bool, error_base: usize) -> ScriptEntry {
    let error_char = match &error {
        DriverError::Server(diagnostics) => diagnostics
            .position
            .and_then(|position| usize::try_from(position).ok())
            .filter(|position| *position > 0)
            .map(|position| error_base + position - 1),
        _ => None,
    };
    ScriptEntry::Failed {
        error,
        error_char,
        lost,
        in_transaction,
    }
}
