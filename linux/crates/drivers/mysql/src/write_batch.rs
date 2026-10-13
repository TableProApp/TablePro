//! A save, written the way the table's storage engine can take it.
//!
//! InnoDB rolls back, so its row changes run in one transaction. MyISAM,
//! MEMORY, Aria and the rest apply each statement as it runs, so their
//! row changes and every schema change run statement by statement, with
//! the ledger recording how far they got.

use std::sync::Arc;

use sqlx::mysql::MySqlConnection;
use sqlx::{AssertSqlSafe, Executor as _};
use tablepro_core::statement::{GuardedStatement, RowGuard, Statement};
use tablepro_core::{
    DriverError, ReadOnlyRefusal, SessionFate, StopRequest, WorkspaceSettings, WriteAtomicity, WriteBatch, WriteKind,
    WriteLedger, WriteReport,
};

use crate::cancel::{MySqlStop, acknowledges_stop, interrupted};
use crate::decode::decode_row;
use crate::errors::{INCOMPLETE_ROLLBACK, UNSUPPORTED_PS, map_error, reply_lost, server_number};
use crate::flavour::MySqlFlavour;
use crate::mysql_call::Tainter;
use crate::mysql_timestamp_mode::MySqlTimestampMode;
use crate::mysql_wire_format::MySqlWireFormat;
use crate::session_statements::statement_timeout;
use crate::workspace_call::{count, prepared};

/// Refuse a batch before anything is sent: a read-only connection never
/// writes, and MySQL has no way to suspend foreign keys for a batch the
/// way the plan means it.
pub(crate) fn precheck(batch: &WriteBatch, read_only: bool) -> Result<(), DriverError> {
    if read_only {
        return Err(DriverError::ReadOnly(ReadOnlyRefusal::ClientGuard));
    }
    batch.foreign_keys.require_enforced()
}

/// Everything one write needs once its task holds a connection.
pub(crate) struct WritePlan {
    pub batch: WriteBatch,
    pub atomicity: WriteAtomicity,
    pub ledger: Arc<WriteLedger>,
    pub settings: WorkspaceSettings,
}

/// The connection a write runs on, and what it needs at hand.
pub(crate) struct WriteContext<'a> {
    pub connection: &'a mut MySqlConnection,
    pub flavour: MySqlFlavour,
    pub tainter: Tainter,
    pub request: &'a StopRequest,
    pub stop: &'a MySqlStop,
}

pub(crate) async fn perform(context: &mut WriteContext<'_>, plan: &WritePlan) -> Result<WriteReport, DriverError> {
    match (plan.batch.kind, plan.atomicity) {
        (WriteKind::RowChanges, WriteAtomicity::Transactional) => transactional(context, plan).await,
        (WriteKind::RowChanges, WriteAtomicity::StatementByStatement) => stepwise(context, plan).await,
        (WriteKind::SchemaChanges, _) => schema_changes(context, plan).await,
    }
}

async fn transactional(context: &mut WriteContext<'_>, plan: &WritePlan) -> Result<WriteReport, DriverError> {
    let ledger = &plan.ledger;
    let steps = &plan.batch.steps;
    if let Err(error) = run(context, "START TRANSACTION").await {
        let fate = rollback(context, 0).await;
        return Err(ledger.failed(0, error, fate));
    }
    let mut report = Vec::with_capacity(steps.len());
    for (index, step) in steps.iter().enumerate() {
        if context.request.is_requested() {
            return Err(stopped_between_statements(context, plan, report.len()).await);
        }
        if let Some((probe, expected)) = step.guard.probe() {
            match count(context.connection, context.flavour, probe).await {
                Ok(actual) if actual == expected => {}
                Ok(actual) => {
                    let fate = rollback(context, report.len()).await;
                    return Err(ledger.guard_failed(index, expected, actual, fate));
                }
                Err(error) => return Err(transaction_step_failed(context, plan, index, error, report.len()).await),
            }
        }
        ledger.statement_sending(index);
        let affected = match execute(context, &step.statement).await {
            Ok(affected) => affected,
            Err(error) => return Err(transaction_step_failed(context, plan, index, error, report.len()).await),
        };
        ledger.statement_confirmed(index);
        report.push(Some(affected));
        if let RowGuard::AffectedExactly(expected) = step.guard
            && affected != expected
        {
            let fate = rollback(context, report.len()).await;
            return Err(ledger.guard_failed(index, expected, affected, fate));
        }
    }
    if context.request.is_requested() {
        return Err(stopped_between_statements(context, plan, report.len()).await);
    }
    ledger.commit_sending(None);
    match context.connection.execute("COMMIT").await {
        Ok(_) => Ok(WriteReport::new(report)),
        // The server answered, so the outcome is known: it rolled back.
        Err(error @ sqlx::Error::Database(_)) => Err(DriverError::RolledBack {
            statement_index: steps.len(),
            source: Box::new(map_error(&error, context.flavour)),
        }),
        Err(error) => {
            context.tainter.taint();
            Err(DriverError::CommitOutcomeUnknown {
                token: None,
                source: Box::new(map_error(&error, context.flavour)),
            })
        }
    }
}

/// A statement the server refused, or one a KILL interrupted. The
/// transaction is rolled back either way, and the stop reads as what
/// asked for it.
async fn transaction_step_failed(
    context: &mut WriteContext<'_>,
    plan: &WritePlan,
    index: usize,
    error: DriverError,
    executed: usize,
) -> DriverError {
    let fate = rollback(context, executed).await;
    if context.request.is_requested() && acknowledges_stop(&error, context.stop.progress()) {
        return plan.ledger.interrupted(acknowledged(context.request), fate);
    }
    plan.ledger.failed(index, error, fate)
}

/// The call was stopped while no statement was running. Any KILL sent
/// for it found the connection idle and may still be pending there, so
/// the connection does not go back to the pool.
async fn stopped_between_statements(context: &mut WriteContext<'_>, plan: &WritePlan, executed: usize) -> DriverError {
    context.tainter.taint();
    let fate = match plan.atomicity {
        WriteAtomicity::Transactional => rollback(context, executed).await,
        WriteAtomicity::StatementByStatement => SessionFate::Discarded,
    };
    plan.ledger.interrupted(interrupted(context.request), fate)
}

/// End the transaction and learn whether it all came back. Rows a
/// trigger wrote into a table that cannot roll back stay written, and
/// the server says so with warning 1196.
async fn rollback(context: &mut WriteContext<'_>, executed: usize) -> SessionFate {
    if context.connection.execute("ROLLBACK").await.is_err() {
        context.tainter.taint();
        return SessionFate::Discarded;
    }
    match incomplete_rollback(context.connection).await {
        Ok(true) => SessionFate::RollbackIncomplete { executed },
        Ok(false) => SessionFate::RolledBack,
        Err(_) => {
            context.tainter.taint();
            SessionFate::RolledBack
        }
    }
}

async fn incomplete_rollback(connection: &mut MySqlConnection) -> Result<bool, sqlx::Error> {
    let warnings = connection.fetch_all(sqlx::raw_sql("SHOW WARNINGS")).await?;
    Ok(warnings.iter().any(|row| {
        let values = decode_row(row, MySqlWireFormat::Text, MySqlTimestampMode::WorkspaceUtc);
        values
            .get(1)
            .and_then(tablepro_core::Value::as_exact_u64)
            .is_some_and(|code| code == u64::from(INCOMPLETE_ROLLBACK))
    }))
}

/// Row changes on an engine that cannot roll back. Every probe runs
/// before anything is written, so a row that moved is found while
/// nothing has changed yet. CLIENT_FOUND_ROWS makes the affected count
/// the rows matched, so a count other than the guard's means that
/// statement found a different row and changed nothing, and the batch
/// stops there.
async fn stepwise(context: &mut WriteContext<'_>, plan: &WritePlan) -> Result<WriteReport, DriverError> {
    for (index, step) in plan.batch.steps.iter().enumerate() {
        if let Some((probe, expected)) = step.guard.probe() {
            let actual = count(context.connection, context.flavour, probe)
                .await
                .map_err(|error| plan.ledger.failed(index, error, SessionFate::RolledBack))?;
            if actual != expected {
                return Err(plan
                    .ledger
                    .guard_failed(index, expected, actual, SessionFate::RolledBack));
            }
        }
    }
    statement_by_statement(context, plan, &plan.batch.steps).await
}

async fn statement_by_statement(
    context: &mut WriteContext<'_>,
    plan: &WritePlan,
    steps: &[GuardedStatement],
) -> Result<WriteReport, DriverError> {
    let mut report = Vec::with_capacity(steps.len());
    for (index, step) in steps.iter().enumerate() {
        if context.request.is_requested() {
            return Err(stopped_between_statements(context, plan, report.len()).await);
        }
        plan.ledger.statement_sending(index);
        let affected = match execute(context, &step.statement).await {
            Ok(affected) => affected,
            Err(error) => return Err(step_failed(&context.tainter, &plan.ledger, index, error)),
        };
        let guard_failed = matches!(step.guard, RowGuard::AffectedExactly(expected) if affected != expected);
        // A statement that matched no row changed nothing, so it is not
        // one of the applied ones; one that matched more did change them.
        if !(guard_failed && affected == 0) {
            plan.ledger.statement_confirmed(index);
        }
        if let RowGuard::AffectedExactly(expected) = step.guard
            && guard_failed
        {
            return Err(plan
                .ledger
                .guard_failed(index, expected, affected, SessionFate::RolledBack));
        }
        report.push(Some(affected));
    }
    Ok(WriteReport::new(report))
}

/// A statement the server refused did not run. One whose connection
/// dropped may have run before the reply was lost, so on an engine that
/// cannot roll back it is reported as unknown, not as refused.
fn step_failed(tainter: &Tainter, ledger: &WriteLedger, index: usize, error: DriverError) -> DriverError {
    if reply_lost(&error) {
        tainter.taint();
        return ledger.interrupted(error, SessionFate::Discarded);
    }
    ledger.failed(index, error, SessionFate::RolledBack)
}

/// Each DDL statement commits on its own. MariaDB's statement timeout
/// would stop a long ALTER as it stops a SELECT, so it is lifted for the
/// batch and put back after; MySQL's bounds only SELECT.
async fn schema_changes(context: &mut WriteContext<'_>, plan: &WritePlan) -> Result<WriteReport, DriverError> {
    if context.flavour == MySqlFlavour::MySql {
        return statement_by_statement(context, plan, &plan.batch.steps).await;
    }
    let lifted = statement_timeout(MySqlFlavour::MariaDb, None);
    if let Err(error) = run(context, &lifted).await {
        return Err(plan.ledger.failed(0, error, SessionFate::RolledBack));
    }
    let outcome = statement_by_statement(context, plan, &plan.batch.steps).await;
    let restore = statement_timeout(MySqlFlavour::MariaDb, Some(plan.settings.statement_timeout));
    if let Err(error) = run(context, &restore).await {
        tracing::warn!(%error, "the statement timeout could not be put back; closing the connection");
        context.tainter.taint();
    }
    outcome
}

/// One step, prepared even without parameters: a prepare takes exactly
/// one statement, so a stray `;` in generated SQL fails to parse instead
/// of running a second one. Only a statement the server parsed whole
/// and cannot prepare, such as CREATE TRIGGER on MySQL, goes over the
/// text protocol, which runs every statement it is given.
async fn execute(context: &mut WriteContext<'_>, statement: &Statement) -> Result<u64, DriverError> {
    let outcome = prepared(statement)?.execute(&mut *context.connection).await;
    let done = match outcome.map_err(|error| map_error(&error, context.flavour)) {
        Err(error) if statement.params().is_empty() && server_number(&error) == Some(UNSUPPORTED_PS) => context
            .connection
            .execute(sqlx::raw_sql(AssertSqlSafe(statement.sql().to_owned())))
            .await
            .map_err(|error| map_error(&error, context.flavour))?,
        other => other?,
    };
    Ok(done.rows_affected())
}

async fn run(context: &mut WriteContext<'_>, sql: &str) -> Result<(), DriverError> {
    context
        .connection
        .execute(sqlx::raw_sql(AssertSqlSafe(sql.to_owned())))
        .await
        .map(|_| ())
        .map_err(|error| map_error(&error, context.flavour))
}

/// The stop as the server confirmed it.
fn acknowledged(request: &StopRequest) -> DriverError {
    match interrupted(request) {
        DriverError::Timeout { phase, .. } => DriverError::Timeout {
            phase,
            server_cancelled: true,
        },
        other => other,
    }
}

#[cfg(test)]
mod tests {
    use tablepro_core::meta::TableRef;
    use tablepro_core::{ForeignKeyCheck, ForeignKeyMode, StopReason, TimeoutPhase};

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
            checks: vec![ForeignKeyCheck {
                before: None,
                after: TableRef::unqualified("t"),
            }],
        };

        assert_eq!(
            precheck(&batch(suspended), false),
            Err(DriverError::Unsupported {
                feature: "foreign key suspension"
            })
        );
        assert_eq!(
            precheck(&batch(ForeignKeyMode::Enforced), true),
            Err(DriverError::ReadOnly(ReadOnlyRefusal::ClientGuard))
        );
        assert_eq!(precheck(&batch(ForeignKeyMode::Enforced), false), Ok(()));
    }

    #[test]
    fn a_lost_statement_is_unknown_and_a_refused_one_did_not_apply() {
        let tainter = crate::mysql_call::MysqlCall::new().tainter();
        let lost = || DriverError::ConnectionLost {
            during: tablepro_core::LossPhase::Statement,
        };

        let first = WriteLedger::new(WriteAtomicity::StatementByStatement);
        first.statement_sending(0);
        assert!(matches!(
            step_failed(&tainter, &first, 0, lost()),
            DriverError::CommitOutcomeUnknown { .. }
        ));

        let second = WriteLedger::new(WriteAtomicity::StatementByStatement);
        second.statement_sending(0);
        second.statement_confirmed(0);
        second.statement_sending(1);
        assert!(matches!(
            step_failed(&tainter, &second, 1, lost()),
            DriverError::PartiallyApplied {
                applied: 1,
                statement_index: 1,
                failed_outcome: tablepro_core::StatementOutcome::Unknown,
                ..
            }
        ));

        let server_answers = [
            DriverError::server("duplicate key"),
            DriverError::Timeout {
                phase: tablepro_core::TimeoutPhase::Statement,
                server_cancelled: true,
            },
        ];
        for answer in server_answers {
            let refused = WriteLedger::new(WriteAtomicity::StatementByStatement);
            refused.statement_sending(0);
            assert!(
                matches!(
                    step_failed(&tainter, &refused, 0, answer.clone()),
                    DriverError::RolledBack { statement_index: 0, .. }
                ),
                "{answer:?}"
            );
        }
    }

    #[test]
    fn an_acknowledged_deadline_says_the_server_stopped_it() {
        let request = StopRequest::new();
        request.request(StopReason::DeadlineElapsed);

        assert_eq!(
            acknowledged(&request),
            DriverError::Timeout {
                phase: TimeoutPhase::Statement,
                server_cancelled: true
            }
        );
    }
}
