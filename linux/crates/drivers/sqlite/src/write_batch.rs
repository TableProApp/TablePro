//! A save, as one SQLite write transaction.
//!
//! Every batch starts with BEGIN IMMEDIATE, which takes the write lock
//! before the first probe reads anything. A deferred BEGIN would take
//! it at the first write instead, and a probe that read first could
//! then fail to upgrade its lock. Contention therefore shows up once,
//! as Busy after the lock timeout, before anything has run.

use std::collections::HashMap;
use std::time::Duration;

use sqlx::sqlite::SqliteConnection as SqlxConnection;
use sqlx::{AssertSqlSafe, Connection as _, Row};
use tablepro_core::meta::TableRef;
use tablepro_core::statement::{GuardedStatement, RowGuard};
use tablepro_core::{
    DriverError, ForeignKeyCheck, ForeignKeyMode, LossPhase, SessionFate, StopReason, StopRequest, TimeoutPhase,
    WriteBatch, WriteLedger, WriteReport,
};

use crate::catalog::{FOREIGN_KEY_CHECK_SQL, MAIN_SCHEMA};
use crate::encode::bind_all;
use crate::errors::{SQLITE_IOERR, is_interrupt, map_error, primary_of};
use crate::foreign_key_verification::{Violation, introduced, renamed, violation_error};
use crate::interrupt::InterruptFlag;
use crate::result_stream::{count, reports_changes};
use crate::sqlite_pooled::SqlitePooled;

/// Run `batch` on the held connection, recording each step in `ledger`.
pub(crate) async fn run(
    pooled: &mut SqlitePooled,
    batch: &WriteBatch,
    ledger: &WriteLedger,
    flag: &InterruptFlag,
    request: &StopRequest,
    lock_timeout: Duration,
) -> Result<WriteReport, DriverError> {
    flag.install(pooled.connection(), lock_timeout).await?;
    let checks = match &batch.foreign_keys {
        ForeignKeyMode::Enforced => None,
        ForeignKeyMode::SuspendedThenVerified { checks } => Some(checks.as_slice()),
    };
    // The pragma does nothing inside a transaction, so it is turned off
    // before BEGIN and back on after COMMIT or ROLLBACK.
    let restore = match checks {
        Some(_) => suspend_foreign_keys(pooled.connection()).await?,
        None => false,
    };
    let mut write = Write {
        batch,
        ledger,
        flag,
        request,
        discard: false,
    };
    let outcome = write.transaction(pooled.connection(), checks).await;
    if restore {
        flag.lower();
        if let Err(error) = sqlx::query("PRAGMA foreign_keys = ON")
            .execute(pooled.connection())
            .await
        {
            // A new connection gets foreign keys from its open options.
            tracing::warn!(%error, "foreign keys could not be turned back on; closing the connection");
            write.discard = true;
        }
    }
    if write.discard {
        pooled.discard_on_release();
    }
    outcome
}

/// Turn foreign keys off for the batch, saying whether they were on.
async fn suspend_foreign_keys(connection: &mut SqlxConnection) -> Result<bool, DriverError> {
    let enabled: i64 = sqlx::query_scalar("PRAGMA foreign_keys")
        .fetch_one(&mut *connection)
        .await
        .map_err(map_error)?;
    if enabled == 0 {
        return Ok(false);
    }
    sqlx::query("PRAGMA foreign_keys = OFF")
        .execute(&mut *connection)
        .await
        .map_err(map_error)?;
    Ok(true)
}

struct Write<'a> {
    batch: &'a WriteBatch,
    ledger: &'a WriteLedger,
    flag: &'a InterruptFlag,
    request: &'a StopRequest,
    /// The connection must not go back to the pool: its rollback failed,
    /// or a COMMIT failed and sqlx's own count of open transactions can
    /// no longer be trusted.
    discard: bool,
}

impl Write<'_> {
    async fn transaction(
        &mut self,
        connection: &mut SqlxConnection,
        checks: Option<&[ForeignKeyCheck]>,
    ) -> Result<WriteReport, DriverError> {
        let mut transaction = match connection.begin_with(AssertSqlSafe("BEGIN IMMEDIATE")).await {
            Ok(transaction) => transaction,
            Err(error) => {
                let error = map_error(error);
                return Err(match self.stopped(&error) {
                    Some(cause) => self.ledger.interrupted(cause, SessionFate::RolledBack),
                    None => error,
                });
            }
        };

        let baseline = match checks {
            Some(checks) => match baseline(&mut transaction, checks).await {
                Ok(baseline) => baseline,
                Err(error) => {
                    let fate = self.rollback(transaction).await;
                    return Err(self.failure(0, error, fate));
                }
            },
            None => Vec::new(),
        };

        let mut rows_affected = Vec::with_capacity(self.batch.steps.len());
        for (index, step) in self.batch.steps.iter().enumerate() {
            if let Some(cause) = self.request.reason().map(stop_cause) {
                let fate = self.rollback(transaction).await;
                return Err(self.ledger.interrupted(cause, fate));
            }
            match self.step(&mut transaction, index, step).await {
                Ok(affected) => rows_affected.push(affected),
                Err(StepFailure::Guard { expected, actual }) => {
                    let fate = self.rollback(transaction).await;
                    return Err(self.ledger.guard_failed(index, expected, actual, fate));
                }
                Err(StepFailure::Error(error)) => {
                    let fate = self.rollback(transaction).await;
                    return Err(self.failure(index, error, fate));
                }
            }
        }

        if let Some(checks) = checks {
            let after = match violations_after(&mut transaction, checks).await {
                Ok(after) => after,
                Err(error) => {
                    let fate = self.rollback(transaction).await;
                    return Err(self.failure(self.batch.steps.len(), error, fate));
                }
            };
            let introduced = introduced(&baseline, &after);
            if !introduced.is_empty() {
                self.rollback(transaction).await;
                return Err(DriverError::RolledBack {
                    statement_index: self.batch.steps.len(),
                    source: Box::new(violation_error(&introduced)),
                });
            }
        }

        if let Some(cause) = self.request.reason().map(stop_cause) {
            let fate = self.rollback(transaction).await;
            return Err(self.ledger.interrupted(cause, fate));
        }
        self.ledger.commit_sending(None);
        // Past this point a stop would turn a known outcome into an
        // unknown one, so the COMMIT runs whatever was asked.
        self.flag.lower();
        match transaction.commit().await {
            Ok(()) => Ok(WriteReport::new(rows_affected)),
            Err(error) => {
                let error = map_error(error);
                self.discard = true;
                // An I/O error during COMMIT may have left the journal
                // either side of the commit point.
                match primary_of(&error) {
                    Some(SQLITE_IOERR) => Err(self.ledger.interrupted(error, SessionFate::Discarded)),
                    _ => Err(self
                        .ledger
                        .failed(self.batch.steps.len(), error, SessionFate::RolledBack)),
                }
            }
        }
    }

    /// Probe, send and check one step.
    async fn step(
        &self,
        connection: &mut SqlxConnection,
        index: usize,
        step: &GuardedStatement,
    ) -> Result<Option<u64>, StepFailure> {
        if let Some((probe, expected)) = step.guard.probe() {
            let actual = count(connection, probe).await.map_err(StepFailure::Error)?;
            if actual != expected {
                return Err(StepFailure::Guard { expected, actual });
            }
        }
        let sql = step.statement.sql();
        let query = bind_all(sqlx::query(AssertSqlSafe(sql.to_owned())), step.statement.params())
            .map_err(StepFailure::Error)?;
        self.ledger.statement_sending(index);
        let done = query
            .execute(&mut *connection)
            .await
            .map_err(|error| StepFailure::Error(map_error(error)))?;
        self.ledger.statement_confirmed(index);
        let affected = done.rows_affected();
        if let (Some(false), RowGuard::AffectedExactly(expected)) = (step.guard.accepts_affected(affected), &step.guard)
        {
            return Err(StepFailure::Guard {
                expected: *expected,
                actual: affected,
            });
        }
        Ok(reports_changes(sql).then_some(affected))
    }

    async fn rollback(&mut self, transaction: sqlx::Transaction<'_, sqlx::Sqlite>) -> SessionFate {
        self.flag.lower();
        match transaction.rollback().await {
            Ok(()) => SessionFate::RolledBack,
            Err(error) => {
                // Closing the connection rolls back what is still open.
                tracing::warn!(error = %map_error(error), "a rollback failed; closing the connection");
                self.discard = true;
                SessionFate::Discarded
            }
        }
    }

    /// The outcome of a step the server refused, or that a stop cut off.
    fn failure(&self, index: usize, error: DriverError, fate: SessionFate) -> DriverError {
        match self.stopped(&error) {
            Some(cause) => self.ledger.interrupted(cause, fate),
            None => self.ledger.failed(index, error, fate),
        }
    }

    /// What the caller is told when `error` is how SQLite gave way to a
    /// stop: an interrupt, or a lock wait given up as busy. The flag is
    /// lowered for the rollback by then, so the request says whether a
    /// stop came.
    fn stopped(&self, error: &DriverError) -> Option<DriverError> {
        match is_interrupt(error) || *error == DriverError::Busy {
            true => self.request.reason().map(stop_cause),
            false => None,
        }
    }
}

enum StepFailure {
    Guard { expected: u64, actual: u64 },
    Error(DriverError),
}

fn stop_cause(reason: StopReason) -> DriverError {
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

/// The violations already there, named as they will be after the batch.
async fn baseline(connection: &mut SqlxConnection, checks: &[ForeignKeyCheck]) -> Result<Vec<Violation>, DriverError> {
    let mut found = Vec::new();
    let mut renames = HashMap::new();
    for check in checks {
        let Some(before) = &check.before else {
            continue;
        };
        found.extend(violations(connection, before).await?);
        renames.insert(before.name.to_lowercase(), check.after.name.clone());
    }
    Ok(renamed(found, &renames))
}

async fn violations_after(
    connection: &mut SqlxConnection,
    checks: &[ForeignKeyCheck],
) -> Result<Vec<Violation>, DriverError> {
    let mut found = Vec::new();
    for check in checks {
        found.extend(violations(connection, &check.after).await?);
    }
    Ok(found)
}

/// `foreign_key_check` for one child table: the rows whose parent row
/// is missing.
async fn violations(connection: &mut SqlxConnection, table: &TableRef) -> Result<Vec<Violation>, DriverError> {
    let schema = table
        .schema
        .as_deref()
        .filter(|schema| !schema.is_empty())
        .unwrap_or(MAIN_SCHEMA);
    let rows = sqlx::query(FOREIGN_KEY_CHECK_SQL)
        .bind(table.name.as_str())
        .bind(schema)
        .fetch_all(&mut *connection)
        .await
        .map_err(map_error)?;
    rows.iter()
        .map(|row| {
            Ok(Violation {
                table: row.try_get("table").map_err(map_error)?,
                rowid: row.try_get("rowid").map_err(map_error)?,
                parent: row.try_get("parent").map_err(map_error)?,
            })
        })
        .collect()
}
