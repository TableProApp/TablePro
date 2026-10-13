use std::sync::Arc;

use futures_util::TryStreamExt;
use postgres_types::{ToSql, Type};
use tablepro_core::statement::{RowGuard, Statement};
use tablepro_core::{
    CommitToken, DriverError, ReadOnlyRefusal, SessionFate, StopRequest, WorkspaceSettings, WriteBatch, WriteKind,
    WriteLedger, WriteReport,
};
use tokio::time::Instant;
use tokio_postgres::Client;

use crate::cancel::{PgStop, acknowledges_stop};
use crate::codec::{RawCell, typed};
use crate::errors::map_error;
use crate::pg_call::PgCall;
use crate::workspace_call::{Access, Preamble};

/// Refuse a batch before anything is sent: a read-only connection never
/// writes, and PostgreSQL has no way to suspend foreign keys.
pub(crate) fn precheck(batch: &WriteBatch, read_only: bool) -> Result<(), DriverError> {
    if read_only {
        return Err(DriverError::ReadOnly(ReadOnlyRefusal::ClientGuard));
    }
    batch.foreign_keys.require_enforced()
}

/// Everything one write needs once its task holds a connection.
pub(crate) struct WritePlan {
    pub(crate) batch: WriteBatch,
    pub(crate) settings: WorkspaceSettings,
    pub(crate) ledger: Arc<WriteLedger>,
    /// `txid_current` stands in for `pg_current_xact_id` before 13.
    pub(crate) legacy_txid: bool,
}

/// Run the batch in one transaction, recording each step in the ledger
/// so a lost connection reports what is really in the database.
pub(crate) async fn perform(
    call: &PgCall,
    plan: &WritePlan,
    request: &StopRequest,
    stop: &PgStop,
) -> Result<WriteReport, DriverError> {
    let client = call.client()?;
    let ledger = &plan.ledger;
    // A schema change may legitimately run long; the call's deadline and
    // cancel still bound it.
    let statement_timeout = match plan.batch.kind {
        WriteKind::RowChanges => Some(plan.settings.statement_timeout),
        WriteKind::SchemaChanges => None,
    };
    let begin = Preamble::new(Access::ReadWrite, statement_timeout, plan.settings.lock_timeout);
    let started = Instant::now();
    if let Err(error) = client.batch_execute(begin.sql()).await {
        let error = map_error(&error);
        let fate = rollback(call, client).await;
        return Err(ledger.failed(0, error, fate));
    }
    let mut report = Vec::with_capacity(plan.batch.steps.len());
    for (index, step) in plan.batch.steps.iter().enumerate() {
        if request.is_requested() {
            let fate = rollback(call, client).await;
            return Err(ledger.interrupted(stop.interrupted(request), fate));
        }
        if let Some((probe, expected)) = step.guard.probe() {
            match count(client, probe).await {
                Ok(actual) if actual == expected => {}
                Ok(actual) => {
                    let fate = rollback(call, client).await;
                    return Err(ledger.guard_failed(index, expected, actual, fate));
                }
                Err(error) => {
                    let error = begin.explain(error, started);
                    return Err(step_failed(call, client, plan, index, error, request, stop).await);
                }
            }
        }
        ledger.statement_sending(index);
        let params = typed(step.statement.params());
        let borrowed: Vec<(&(dyn ToSql + Sync), Type)> = params
            .iter()
            .map(|(param, ty)| (param as &(dyn ToSql + Sync), ty.clone()))
            .collect();
        let affected = match client.execute_typed(step.statement.sql(), &borrowed).await {
            Ok(affected) => affected,
            Err(error) => {
                let error = begin.explain(map_error(&error), started);
                return Err(step_failed(call, client, plan, index, error, request, stop).await);
            }
        };
        ledger.statement_confirmed(index);
        if let RowGuard::AffectedExactly(expected) = step.guard
            && affected != expected
        {
            let fate = rollback(call, client).await;
            return Err(ledger.guard_failed(index, expected, affected, fate));
        }
        report.push(Some(affected));
    }
    let token = match transaction_id(client, plan.legacy_txid).await {
        Ok(token) => token,
        Err(error) => {
            let index = plan.batch.steps.len();
            return Err(step_failed(call, client, plan, index, error, request, stop).await);
        }
    };
    ledger.commit_sending(Some(token.clone()));
    match client.batch_execute("COMMIT").await {
        Ok(()) => Ok(WriteReport::new(report)),
        // The server answered, so the outcome is known: a deferred
        // constraint or a serialization failure rolled it all back.
        Err(error) if error.as_db_error().is_some() => Err(DriverError::RolledBack {
            statement_index: plan.batch.steps.len(),
            source: Box::new(begin.explain(map_error(&error), started)),
        }),
        Err(error) => {
            call.taint();
            Err(DriverError::CommitOutcomeUnknown {
                token: Some(token),
                source: Box::new(map_error(&error)),
            })
        }
    }
}

/// A statement the server refused, or one a stop interrupted. The
/// transaction is rolled back either way, and the stop reads as what
/// asked for it.
async fn step_failed(
    call: &PgCall,
    client: &Client,
    plan: &WritePlan,
    index: usize,
    error: DriverError,
    request: &StopRequest,
    stop: &PgStop,
) -> DriverError {
    let fate = rollback(call, client).await;
    if request.is_requested() && acknowledges_stop(&error) {
        return plan.ledger.interrupted(acknowledged_stop(request, stop), fate);
    }
    plan.ledger.failed(index, error, fate)
}

fn acknowledged_stop(request: &StopRequest, stop: &PgStop) -> DriverError {
    match stop.interrupted(request) {
        DriverError::Timeout { phase, .. } => DriverError::Timeout {
            phase,
            server_cancelled: true,
        },
        other => other,
    }
}

/// End the transaction. A ROLLBACK that cannot be sent leaves the
/// connection unusable, and since no COMMIT was written the session's
/// end rolls the work back all the same.
async fn rollback(call: &PgCall, client: &Client) -> SessionFate {
    match client.batch_execute("ROLLBACK").await {
        Ok(()) => SessionFate::RolledBack,
        Err(_) => {
            call.taint();
            SessionFate::Discarded
        }
    }
}

async fn count(client: &Client, probe: &Statement) -> Result<u64, DriverError> {
    let rows: Vec<tokio_postgres::Row> = client
        .query_typed_raw(probe.sql(), typed(probe.params()))
        .await
        .map_err(|error| map_error(&error))?
        .try_collect()
        .await
        .map_err(|error| map_error(&error))?;
    let row = rows
        .first()
        .ok_or_else(|| DriverError::Protocol("the key probe returned no row".to_owned()))?;
    let RawCell(value) = row.try_get(0).map_err(|error| map_error(&error))?;
    value
        .as_exact_u64()
        .ok_or_else(|| DriverError::Protocol(format!("the key probe returned {value:?}")))
}

/// The transaction's id, taken before COMMIT so a commit whose answer is
/// lost can be asked about afterwards.
async fn transaction_id(client: &Client, legacy: bool) -> Result<CommitToken, DriverError> {
    let sql = if legacy {
        "SELECT txid_current()::text"
    } else {
        "SELECT pg_current_xact_id()::text"
    };
    let messages = client.simple_query(sql).await.map_err(|error| map_error(&error))?;
    let xid = messages
        .iter()
        .find_map(|message| match message {
            tokio_postgres::SimpleQueryMessage::Row(row) => row.get(0),
            _ => None,
        })
        .and_then(|text| text.parse::<u64>().ok())
        .ok_or_else(|| DriverError::Protocol("the server returned no transaction id".to_owned()))?;
    Ok(CommitToken::PostgresXid {
        xid,
        legacy_txid: legacy,
    })
}

#[cfg(test)]
mod tests {
    use tablepro_core::meta::TableRef;
    use tablepro_core::{ForeignKeyCheck, ForeignKeyMode};

    use super::*;

    fn batch(foreign_keys: ForeignKeyMode) -> WriteBatch {
        WriteBatch::new(
            WriteKind::RowChanges,
            TableRef::unqualified("t"),
            Vec::new(),
            foreign_keys,
        )
    }

    #[test]
    fn non_sqlite_drivers_reject_suspension() {
        let suspended = ForeignKeyMode::SuspendedThenVerified {
            checks: vec![ForeignKeyCheck::same_table(TableRef::unqualified("t"))],
        };

        assert!(matches!(
            precheck(&batch(suspended), false),
            Err(DriverError::Unsupported {
                feature: "foreign key suspension"
            })
        ));
        assert!(precheck(&batch(ForeignKeyMode::Enforced), false).is_ok());
    }

    #[test]
    fn write_batch_client_guard() {
        assert!(matches!(
            precheck(&batch(ForeignKeyMode::Enforced), true),
            Err(DriverError::ReadOnly(ReadOnlyRefusal::ClientGuard))
        ));
    }
}
