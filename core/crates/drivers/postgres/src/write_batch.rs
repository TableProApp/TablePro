use std::sync::Arc;

use futures_util::TryStreamExt;
use postgres_types::{ToSql, Type};
use tablepro_core::statement::{GuardedStatement, RowGuard, Statement};
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
    // A database change goes out as a simple query, which carries no
    // parameters and reports no row count a guard could check.
    let bare = |step: &GuardedStatement| step.statement.params().is_empty() && step.guard == RowGuard::None;
    if batch.kind == WriteKind::DatabaseChanges && !batch.steps.iter().all(bare) {
        return Err(DriverError::Protocol(
            "a database change carries no parameters or row guards".to_owned(),
        ));
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

/// Run the batch in one transaction, or a database change statement by
/// statement, recording each step in the ledger so a lost connection
/// reports what is really in the database.
pub(crate) async fn perform(
    call: &PgCall,
    plan: &WritePlan,
    request: &StopRequest,
    stop: &PgStop,
) -> Result<WriteReport, DriverError> {
    if plan.batch.kind == WriteKind::DatabaseChanges {
        return statement_by_statement(call, plan, request, stop).await;
    }
    let client = call.client()?;
    let ledger = &plan.ledger;
    // A schema change may legitimately run long; the call's deadline and
    // cancel still bound it.
    let statement_timeout = match plan.batch.kind {
        WriteKind::RowChanges => Some(plan.settings.statement_timeout),
        WriteKind::SchemaChanges | WriteKind::DatabaseChanges => None,
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

/// CREATE and DROP DATABASE refuse a transaction block, and statements
/// sent together in one simple query form one, so each goes out alone
/// and lands on its own. No bound is set: SET LOCAL needs a transaction,
/// and a session setting would stay on a server connection a pooler
/// hands to other clients. The call's deadline and cancel still stop it.
async fn statement_by_statement(
    call: &PgCall,
    plan: &WritePlan,
    request: &StopRequest,
    stop: &PgStop,
) -> Result<WriteReport, DriverError> {
    let client = call.client()?;
    let ledger = &plan.ledger;
    let mut report = Vec::with_capacity(plan.batch.steps.len());
    for (index, step) in plan.batch.steps.iter().enumerate() {
        if request.is_requested() {
            return Err(ledger.interrupted(stop.interrupted(request), SessionFate::Discarded));
        }
        ledger.statement_sending(index);
        if let Err(error) = client.batch_execute(step.statement.sql()).await {
            return Err(statement_failed(call, plan, index, &error, request, stop));
        }
        ledger.statement_confirmed(index);
        report.push(None);
    }
    Ok(WriteReport::new(report))
}

/// A statement the server answered with an error did not apply. One
/// whose answer was lost may have, so its outcome is left unknown.
fn statement_failed(
    call: &PgCall,
    plan: &WritePlan,
    index: usize,
    error: &tokio_postgres::Error,
    request: &StopRequest,
    stop: &PgStop,
) -> DriverError {
    let answered = error.as_db_error().is_some();
    let error = map_error(error);
    if !answered {
        call.taint();
        return plan.ledger.interrupted(error, SessionFate::Discarded);
    }
    let error = match request.is_requested() && acknowledges_stop(&error) {
        true => acknowledged_stop(request, stop),
        false => error,
    };
    plan.ledger.failed(index, error, SessionFate::RolledBack)
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
        "SELECT pg_catalog.txid_current()::pg_catalog.text"
    } else {
        "SELECT pg_catalog.pg_current_xact_id()::pg_catalog.text"
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
    use tablepro_core::statement::{BoundParam, ParamType, StatementBuilder};
    use tablepro_core::{ForeignKeyCheck, ForeignKeyMode, UnsupportedFeature, Value};

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
                feature: UnsupportedFeature::ForeignKeySuspension
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

    fn sql(text: &str) -> Statement {
        let mut builder = StatementBuilder::new();
        builder.push_sql(text);
        builder.finish()
    }

    fn database_changes(steps: Vec<GuardedStatement>) -> WriteBatch {
        WriteBatch::new(
            WriteKind::DatabaseChanges,
            TableRef::new(Some("shop".to_owned()), ""),
            steps,
            ForeignKeyMode::Enforced,
        )
    }

    #[test]
    fn a_database_change_goes_out_only_as_plain_statements() {
        let mut bound = StatementBuilder::new();
        bound.push_sql("DROP DATABASE $1");
        bound.push_bound(BoundParam::new(Value::Text("shop".to_owned()), ParamType::Text).expect("a text parameter"));
        let plain = GuardedStatement::unguarded(sql("DROP DATABASE \"shop\""));

        assert!(precheck(&database_changes(vec![plain.clone()]), false).is_ok());
        for refused in [
            GuardedStatement::unguarded(bound.finish()),
            GuardedStatement::affecting_exactly(sql("DROP DATABASE \"shop\""), 1),
        ] {
            assert!(
                matches!(
                    precheck(&database_changes(vec![plain.clone(), refused.clone()]), false),
                    Err(DriverError::Protocol(_))
                ),
                "{refused:?}"
            );
        }
        let mut guarded = batch(ForeignKeyMode::Enforced);
        guarded.steps = vec![GuardedStatement::affecting_exactly(sql("DELETE FROM t"), 1)];
        assert!(precheck(&guarded, false).is_ok());
    }
}
