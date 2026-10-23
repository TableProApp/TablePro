//! A save, as one DuckDB transaction.
//!
//! DuckDB checks conflicts with other connections at COMMIT, and a
//! statement that fails ends the transaction's usefulness: everything
//! after it is refused until it is rolled back. So the batch stops at
//! the first failure and rolls back; a COMMIT DuckDB refuses has rolled
//! back too.

use tablepro_core::statement::{GuardedStatement, RowGuard};
use tablepro_core::{
    DriverError, LossPhase, SessionFate, StopReason, StopRequest, TimeoutPhase, TransactionState, WriteBatch,
    WriteLedger, WriteReport,
};

use crate::errors::is_interrupt;
use crate::instance::Link;
use crate::result_stream::{batch, changes_rows, count, execute};
use crate::transaction_state::transaction_state;

/// Run `write` on the held connection, recording each step in `ledger`,
/// and say whether the connection is still fit for the pool: one whose
/// rollback failed may hold the transaction still.
pub(crate) fn run(
    link: &Link,
    write: &WriteBatch,
    ledger: &WriteLedger,
    request: &StopRequest,
) -> (Result<WriteReport, DriverError>, bool) {
    let result = transaction(link, write, ledger, request);
    let reusable = transaction_state(link) == TransactionState::Idle;
    (result, reusable)
}

fn transaction(
    link: &Link,
    write: &WriteBatch,
    ledger: &WriteLedger,
    request: &StopRequest,
) -> Result<WriteReport, DriverError> {
    if let Err(error) = batch(link, "BEGIN TRANSACTION") {
        return Err(match stopped(&error, request) {
            Some(cause) => ledger.interrupted(cause, SessionFate::RolledBack),
            None => error,
        });
    }
    let mut rows_affected = Vec::with_capacity(write.steps.len());
    for (index, step) in write.steps.iter().enumerate() {
        if let Some(cause) = request.reason().map(stop_cause) {
            return Err(ledger.interrupted(cause, rollback(link)));
        }
        match run_step(link, ledger, index, step) {
            Ok(affected) => rows_affected.push(affected),
            Err(StepFailure::Guard { expected, actual }) => {
                return Err(ledger.guard_failed(index, expected, actual, rollback(link)));
            }
            Err(StepFailure::Error(error)) => {
                let fate = rollback(link);
                return Err(match stopped(&error, request) {
                    Some(cause) => ledger.interrupted(cause, fate),
                    None => ledger.failed(index, error, fate),
                });
            }
        }
    }
    if let Some(cause) = request.reason().map(stop_cause) {
        return Err(ledger.interrupted(cause, rollback(link)));
    }
    link.hold_stops();
    ledger.commit_sending(None);
    match batch(link, "COMMIT") {
        Ok(()) => Ok(WriteReport::new(rows_affected)),
        // A COMMIT DuckDB refuses, a conflict with another connection's
        // write among them, rolled the transaction back.
        Err(error) => {
            let _ = batch(link, "ROLLBACK");
            Err(ledger.failed(write.steps.len(), error, SessionFate::RolledBack))
        }
    }
}

enum StepFailure {
    Guard { expected: u64, actual: u64 },
    Error(DriverError),
}

/// Probe, send and check one step.
fn run_step(
    link: &Link,
    ledger: &WriteLedger,
    index: usize,
    step: &GuardedStatement,
) -> Result<Option<u64>, StepFailure> {
    if let Some((probe, expected)) = step.guard.probe() {
        let actual = count(link, probe).map_err(StepFailure::Error)?;
        if actual != expected {
            return Err(StepFailure::Guard { expected, actual });
        }
    }
    ledger.statement_sending(index);
    let affected = execute(link, &step.statement).map_err(StepFailure::Error)?;
    ledger.statement_confirmed(index);
    if let RowGuard::AffectedExactly(expected) = step.guard
        && affected != expected
    {
        return Err(StepFailure::Guard {
            expected,
            actual: affected,
        });
    }
    Ok(changes_rows(step.statement.sql()).then_some(affected))
}

/// End the transaction. A transaction DuckDB already ended leaves
/// nothing to roll back, which is the same answer.
fn rollback(link: &Link) -> SessionFate {
    link.hold_stops();
    match batch(link, "ROLLBACK") {
        Ok(()) => SessionFate::RolledBack,
        Err(DriverError::Server(diagnostics)) if diagnostics.message.contains("no transaction is active") => {
            SessionFate::RolledBack
        }
        Err(error) => {
            tracing::warn!(%error, "a rollback failed");
            SessionFate::Discarded
        }
    }
}

/// What the caller is told when `error` is DuckDB giving way to a stop.
fn stopped(error: &DriverError, request: &StopRequest) -> Option<DriverError> {
    match is_interrupt(error) {
        true => request.reason().map(stop_cause),
        false => None,
    }
}

pub(crate) fn stop_cause(reason: StopReason) -> DriverError {
    match reason {
        StopReason::Cancelled => DriverError::Cancelled,
        StopReason::DeadlineElapsed => DriverError::Timeout {
            phase: TimeoutPhase::Statement,
            server_cancelled: true,
        },
        StopReason::Shutdown => DriverError::ConnectionLost {
            during: LossPhase::Statement,
        },
    }
}
