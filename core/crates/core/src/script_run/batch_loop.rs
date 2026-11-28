use std::future::Future;
use std::pin::Pin;
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::time::Instant;

use tokio_util::sync::CancellationToken;

use crate::editor_session::{EditorSession, EditorSessionState};
use crate::error::DriverError;
use crate::read_only_refusal::ReadOnlyRefusal;
use crate::result_event::ResultEvent;
use crate::result_sink::{ResultSink, SinkFlow};
use crate::run_options::RunOptions;
use crate::transaction_state::TransactionState;
use crate::user_sql::UserSql;

use super::budget::{Kept, ScriptRun, room_after};
use super::collector::BatchCollector;
use super::entry::{AfterRun, ScriptBatchReport, ScriptEntry, Verdict, continues};
use super::store::ScriptResultStore;

/// Whether the caller still wants the rest of the run's reports.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReportFlow {
    Continue,
    /// Nobody is reading any more, so the run stops.
    ConsumerGone,
}

/// Hears one report per batch, in order, as the loop finishes each batch.
/// The FFI posts an event the app drains; the Linux app words it and
/// sends it to the results pane.
pub trait BatchReporter: Send {
    fn report<'a>(&'a mut self, report: ScriptBatchReport) -> Pin<Box<dyn Future<Output = ReportFlow> + Send + 'a>>;
}

/// Send each batch in turn, reporting each one as it ends. `transaction`
/// is where the session's transaction stood before the run. Rows go to
/// `store`; the reports point at each set by its store index. The caller
/// says the run is finished once the tab knows where it left the session.
pub async fn run_batches(
    editor: &Arc<dyn EditorSession>,
    run: &ScriptRun,
    cancel: &CancellationToken,
    store: &Arc<dyn ScriptResultStore>,
    reporter: &mut dyn BatchReporter,
    transaction: Option<TransactionState>,
) -> AfterRun {
    let mut after = AfterRun {
        transaction,
        rollback_told: false,
    };
    let mut kept = Kept::default();
    'batches: for (index, batch) in run.batches.iter().enumerate() {
        if batch.refused {
            if reporter.report(refusal(index)).await == ReportFlow::ConsumerGone {
                return after;
            }
            if !continues(Verdict::Failed, run.policy) {
                break;
            }
            continue;
        }
        for _ in 0..batch.repeat.max(1) {
            if cancel.is_cancelled() {
                break 'batches;
            }
            let sql = UserSql::new(batch.text.as_str());
            let (room, row_limit, byte_limit) = room_after(run, kept.rows, kept.bytes);
            let collector = Arc::new(Mutex::new(BatchCollector::new(store.clone()).within(room)));
            let options = RunOptions::new(cancel.child_token())
                .with_deadline(run.statement_timeout)
                .with_row_limit(row_limit)
                .with_byte_limit(byte_limit);
            let sink = Box::new(CollectingSink {
                collector: collector.clone(),
            });
            let started = Instant::now();
            let ran = editor.run(sql, options, sink).await;
            let elapsed_ms = started.elapsed().as_millis();
            let collected = std::mem::replace(&mut *lock(&collector), BatchCollector::new(store.clone()));
            let state = editor.state();
            let lost = state == EditorSessionState::Lost;
            let in_transaction = transaction_open(after.transaction);
            let outcome = collected.finish(ran, state, in_transaction, batch.error_base);
            // A lost session's last word describes a connection that is
            // gone, not the transaction the user had.
            if !lost && outcome.transaction.is_some() {
                after.transaction = outcome.transaction;
            }
            after.rollback_told |= lost
                && in_transaction
                && outcome
                    .entries
                    .iter()
                    .any(|entry| matches!(entry, ScriptEntry::Failed { .. }));
            kept.rows += outcome.kept_rows;
            kept.bytes = kept.bytes.saturating_add(outcome.kept_bytes);
            let verdict = outcome.verdict;
            let report = ScriptBatchReport {
                batch: index,
                entries: outcome.entries,
                verdict,
                transaction: outcome.transaction,
                lost,
                elapsed_ms,
            };
            if reporter.report(report).await == ReportFlow::ConsumerGone {
                // Nobody is left to show the rest.
                return after;
            }
            if !continues(verdict, run.policy) {
                break 'batches;
            }
        }
    }
    after
}

/// A batch Safe Mode kept from the server, which fails the way a write
/// the server refused would.
pub(super) fn refusal(batch: usize) -> ScriptBatchReport {
    ScriptBatchReport {
        batch,
        entries: vec![ScriptEntry::Failed {
            error: DriverError::ReadOnly(ReadOnlyRefusal::ClientGuard),
            error_char: None,
            lost: false,
            in_transaction: false,
        }],
        verdict: Verdict::Failed,
        transaction: None,
        lost: false,
        elapsed_ms: 0,
    }
}

fn transaction_open(transaction: Option<TransactionState>) -> bool {
    matches!(
        transaction,
        Some(TransactionState::InTransaction | TransactionState::Failed)
    )
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
