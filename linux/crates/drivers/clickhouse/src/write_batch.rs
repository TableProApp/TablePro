use std::sync::Arc;

use clickhouse::error::Error as ClickHouseError;
use tablepro_core::meta::TableRef;
use tablepro_core::statement::{RowGuard, Statement};
use tablepro_core::{
    CommitToken, DriverError, ReadOnlyRefusal, SessionFate, StopRequest, WriteBatch, WriteLedger, WriteReport,
};
use uuid::Uuid;

use crate::call_client::CallClient;
use crate::cancel::{ClickHouseStop, acknowledges_stop};
use crate::errors::map_error;
use crate::param_value::bind_params;
use crate::result_reader::{RESULT_FORMAT, read_table};
use crate::write_error_class::{WriteErrorClass, classify};

/// Refuse a batch before anything is sent: a read-only connection never
/// writes, ClickHouse cannot suspend foreign keys it does not have, and
/// a mutation reports no row count for an exact guard to check.
pub(crate) fn precheck(batch: &WriteBatch, read_only: bool) -> Result<(), DriverError> {
    if read_only {
        return Err(DriverError::ReadOnly(ReadOnlyRefusal::ClientGuard));
    }
    batch.foreign_keys.require_enforced()?;
    match batch
        .steps
        .iter()
        .position(|step| matches!(step.guard, RowGuard::AffectedExactly(_)))
    {
        Some(statement_index) => Err(DriverError::GuardUnsupported { statement_index }),
        None => Ok(()),
    }
}

/// Everything one write needs once its task runs.
pub(crate) struct WritePlan {
    pub(crate) batch: WriteBatch,
    /// The batch's table, qualified, for the commit token.
    pub(crate) table: TableRef,
    pub(crate) ledger: Arc<WriteLedger>,
    /// Reads that may be stopped, for the probes.
    pub(crate) probes: clickhouse::Client,
    /// Waits for each statement to finish, and never bounds it: a
    /// mutation the server gives up waiting on keeps running anyway.
    pub(crate) writes: clickhouse::Client,
}

/// Apply the batch statement by statement.
///
/// Every probe runs first, so a row that moved stops the save before
/// any mutation is sent. Each statement then carries a query id of its
/// own, kept in the ledger's token, so a statement whose answer never
/// arrived can be looked up in `system.query_log` afterwards. A
/// statement in flight is never stopped: a KILL does not undo a
/// mutation, it only hides what it did.
pub(crate) async fn perform(
    plan: &WritePlan,
    request: &StopRequest,
    stop: &Arc<ClickHouseStop>,
) -> Result<WriteReport, DriverError> {
    let ledger = &plan.ledger;
    let probes = CallClient::new(plan.probes.clone(), stop.clone(), request.clone());
    for (index, step) in plan.batch.steps.iter().enumerate() {
        let Some((probe, expected)) = step.guard.probe() else {
            continue;
        };
        if request.is_requested() {
            return Err(ledger.interrupted(stop.interrupted(request), SessionFate::RolledBack));
        }
        match count(&probes, probe).await {
            Ok(actual) if actual == expected => {}
            Ok(actual) => return Err(ledger.guard_failed(index, expected, actual, SessionFate::RolledBack)),
            Err(error) if request.is_requested() && acknowledges_stop(&error) => {
                return Err(ledger.interrupted(acknowledged(stop.interrupted(request)), SessionFate::RolledBack));
            }
            Err(error) => return Err(ledger.failed(index, error, SessionFate::RolledBack)),
        }
    }
    stop.clear();
    let query_ids: Vec<Uuid> = plan.batch.steps.iter().map(|_| Uuid::new_v4()).collect();
    let mut report = Vec::with_capacity(plan.batch.steps.len());
    for (index, (step, query_id)) in plan.batch.steps.iter().zip(&query_ids).enumerate() {
        if request.is_requested() {
            return Err(ledger.interrupted(stop.interrupted(request), SessionFate::Discarded));
        }
        ledger.attach_token(CommitToken::ClickHouseQuery {
            query_ids: query_ids.clone(),
            first_unconfirmed: index,
            table: plan.table.clone(),
        });
        ledger.statement_sending(index);
        match execute(&plan.writes, &step.statement, *query_id).await {
            Ok(written) => {
                ledger.statement_confirmed(index);
                report.push(written);
            }
            Err(error) => {
                let mapped = map_error(&error);
                return Err(match classify(&error) {
                    WriteErrorClass::MayHaveApplied => ledger.interrupted(mapped, SessionFate::Discarded),
                    WriteErrorClass::Refused => ledger.failed(index, mapped, SessionFate::RolledBack),
                });
            }
        }
    }
    Ok(WriteReport::new(report))
}

/// A stop the server acknowledged reads as a timeout it enforced.
fn acknowledged(interrupted: DriverError) -> DriverError {
    match interrupted {
        DriverError::Timeout { phase, .. } => DriverError::Timeout {
            phase,
            server_cancelled: true,
        },
        other => other,
    }
}

/// Run one statement to its end and give back the rows it wrote.
///
/// An INSERT reports its rows in the summary; a mutation reports none,
/// which is not the same as zero rows, so a zero becomes "not known".
async fn execute(
    client: &clickhouse::Client,
    statement: &Statement,
    query_id: Uuid,
) -> Result<Option<u64>, ClickHouseError> {
    let query = bind_params(client.query_raw(statement.sql()), statement.params())
        .with_setting("query_id", query_id.to_string());
    let mut cursor = query.fetch_bytes(RESULT_FORMAT)?;
    while cursor.next().await?.is_some() {}
    let written = cursor.summary().and_then(clickhouse::QuerySummary::written_rows);
    Ok(written.filter(|rows| *rows > 0))
}

async fn count(calls: &CallClient, probe: &Statement) -> Result<u64, DriverError> {
    let result = read_table(calls.statement(probe)?, None).await?;
    let value = result
        .rows
        .first()
        .and_then(|row| row.first())
        .ok_or_else(|| DriverError::Protocol("the key probe returned no row".to_owned()))?;
    value
        .as_exact_u64()
        .ok_or_else(|| DriverError::Protocol(format!("the key probe returned {value:?}")))
}

#[cfg(test)]
mod tests {
    use tablepro_core::meta::TableRef;
    use tablepro_core::statement::{GuardedStatement, StatementBuilder};
    use tablepro_core::{ForeignKeyCheck, ForeignKeyMode, WriteKind};

    use super::*;

    fn statement(sql: &str) -> Statement {
        let mut builder = StatementBuilder::new();
        builder.push_sql(sql);
        builder.finish()
    }

    fn batch(steps: Vec<GuardedStatement>, foreign_keys: ForeignKeyMode) -> WriteBatch {
        WriteBatch::new(WriteKind::RowChanges, TableRef::unqualified("t"), steps, foreign_keys)
    }

    #[test]
    fn affected_exactly_is_guard_unsupported_without_network() {
        let steps = vec![
            GuardedStatement::unguarded(statement("INSERT INTO t VALUES (1)")),
            GuardedStatement::affecting_exactly(statement("ALTER TABLE t DELETE WHERE id = 1"), 1),
        ];

        assert_eq!(
            precheck(&batch(steps, ForeignKeyMode::Enforced), false),
            Err(DriverError::GuardUnsupported { statement_index: 1 })
        );
    }

    #[test]
    fn non_sqlite_drivers_reject_suspension() {
        let suspended = ForeignKeyMode::SuspendedThenVerified {
            checks: vec![ForeignKeyCheck::same_table(TableRef::unqualified("t"))],
        };

        assert!(matches!(
            precheck(&batch(Vec::new(), suspended), false),
            Err(DriverError::Unsupported {
                feature: "foreign key suspension"
            })
        ));
        assert!(precheck(&batch(Vec::new(), ForeignKeyMode::Enforced), false).is_ok());
    }

    #[test]
    fn a_read_only_connection_refuses_before_anything_is_sent() {
        assert!(matches!(
            precheck(&batch(Vec::new(), ForeignKeyMode::Enforced), true),
            Err(DriverError::ReadOnly(ReadOnlyRefusal::ClientGuard))
        ));
    }
}
