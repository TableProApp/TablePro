use std::sync::Arc;

use mongodb::{Client, ClientSession};
use tablepro_core::statement::{GuardedStatement, RowGuard};
use tablepro_core::{DriverError, ReadOnlyRefusal, SessionFate, StopRequest, WriteBatch, WriteLedger, WriteReport};

use crate::call::generated;
use crate::endpoint::MongoEndpoint;
use crate::execute::{Source, start};

/// Refuse a batch before anything is sent: a read-only connection never
/// writes, and MongoDB has no foreign keys to suspend.
pub(crate) fn precheck(batch: &WriteBatch, read_only: bool) -> Result<(), DriverError> {
    if read_only {
        return Err(DriverError::ReadOnly(ReadOnlyRefusal::ClientGuard));
    }
    batch.foreign_keys.require_enforced()?;
    Ok(())
}

/// Everything one save needs once its task runs.
pub(crate) struct WritePlan {
    pub(crate) batch: WriteBatch,
    pub(crate) ledger: Arc<WriteLedger>,
    pub(crate) endpoint: Arc<MongoEndpoint>,
    pub(crate) client: Client,
    pub(crate) database: String,
}

/// Apply the batch a statement at a time, each a single-document write
/// MongoDB applies whole or not at all. A step whose document is gone, or
/// is not the one loaded, matches no document, and the save stops there
/// with what the steps before it applied.
pub(crate) async fn perform(
    plan: &WritePlan,
    session: &mut ClientSession,
    request: &StopRequest,
) -> Result<WriteReport, DriverError> {
    let ledger = &plan.ledger;
    let mut report = Vec::with_capacity(plan.batch.steps.len());
    for (index, step) in plan.batch.steps.iter().enumerate() {
        if request.is_requested() {
            return Err(ledger.interrupted(DriverError::Cancelled, SessionFate::RolledBack));
        }
        prove(plan, session, index, step).await?;
        let (_, planned) = generated(&step.statement, &plan.database)
            .map_err(|error| ledger.failed(index, error, SessionFate::RolledBack))?;
        ledger.statement_sending(index);
        let affected = match start(&plan.endpoint, &plan.client, session, planned).await {
            // Applied where it ran, with its fate open: as a write whose
            // answer never came.
            Ok(Source::Write {
                unconfirmed: Some(error),
                ..
            }) => return Err(ledger.interrupted(error, SessionFate::Discarded)),
            Ok(Source::Write { affected, .. }) => Some(affected),
            Ok(Source::Count(count)) => Some(count),
            Ok(_) => None,
            Err(error) => return Err(failure(ledger, index, error)),
        };
        // A single-document write that matched no document changed
        // nothing, so the step is not counted as applied.
        if let (Some(expected), Some(actual)) = (expected_rows(&step.guard), affected)
            && expected != actual
        {
            return Err(ledger.guard_failed(index, expected, actual, SessionFate::RolledBack));
        }
        ledger.statement_confirmed(index);
        report.push(affected);
    }
    Ok(WriteReport::new(report))
}

/// A probe guard counts the documents its key names before the step.
async fn prove(
    plan: &WritePlan,
    session: &mut ClientSession,
    index: usize,
    step: &GuardedStatement,
) -> Result<(), DriverError> {
    let Some((probe, expected)) = step.guard.probe() else {
        return Ok(());
    };
    let ledger = &plan.ledger;
    let (_, planned) =
        generated(probe, &plan.database).map_err(|error| ledger.failed(index, error, SessionFate::RolledBack))?;
    match start(&plan.endpoint, &plan.client, session, planned).await {
        Ok(Source::Count(actual)) if actual == expected => Ok(()),
        Ok(Source::Count(actual)) => Err(ledger.guard_failed(index, expected, actual, SessionFate::RolledBack)),
        Ok(_) => Err(ledger.failed(
            index,
            DriverError::Protocol("the key probe returned no count".to_owned()),
            SessionFate::RolledBack,
        )),
        Err(error) => Err(ledger.failed(index, error, SessionFate::RolledBack)),
    }
}

fn expected_rows(guard: &RowGuard) -> Option<u64> {
    match guard {
        RowGuard::AffectedExactly(rows) => Some(*rows),
        RowGuard::None | RowGuard::ProbeExactly { .. } => None,
    }
}

/// A refusal from the server applied nothing of its statement; a lost
/// connection may have applied it.
fn failure(ledger: &WriteLedger, index: usize, error: DriverError) -> DriverError {
    match error {
        DriverError::ConnectionLost { .. } | DriverError::Transport(_) | DriverError::Timeout { .. } => {
            ledger.interrupted(error, SessionFate::Discarded)
        }
        other => ledger.failed(index, other, SessionFate::RolledBack),
    }
}
