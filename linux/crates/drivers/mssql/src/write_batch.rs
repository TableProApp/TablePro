use std::sync::Arc;

use tablepro_core::statement::{RowGuard, Statement};
use tablepro_core::{DriverError, ReadOnlyRefusal, SessionFate, StopRequest, WriteBatch, WriteLedger, WriteReport};
use tokio::time::Instant;

use crate::cancel::{MssqlStop, StopProgress, acknowledged_stop, unconfirmed_stop};
use crate::encode::{as_sql, encode_params};
use crate::errors::{ends_connection, map_error};
use crate::in_band_request::{Answer, Halt, Interrupt, StopPolicy, Watch, attention, roll_back_open};
use crate::mssql_pooled::MssqlPooled;
use crate::physical::MssqlClient;
use crate::workspace_call::{catalogue_rows, exact_count};

/// Refuse a batch before anything is sent: a read-only connection never
/// writes, and SQL Server cannot suspend foreign keys for one batch.
pub(crate) fn precheck(batch: &WriteBatch, read_only: bool) -> Result<(), DriverError> {
    if read_only {
        return Err(DriverError::ReadOnly(ReadOnlyRefusal::ClientGuard));
    }
    batch.foreign_keys.require_enforced()
}

/// Everything one write needs once its task holds a connection.
pub(crate) struct WritePlan {
    pub(crate) batch: WriteBatch,
    pub(crate) ledger: Arc<WriteLedger>,
    pub(crate) policy: StopPolicy,
}

/// Run the batch in one transaction, recording each step in the ledger
/// so a lost connection reports what is really in the database.
pub(crate) async fn perform(
    pooled: &mut MssqlPooled,
    plan: &WritePlan,
    request: &StopRequest,
    stop: &MssqlStop,
) -> Result<WriteReport, DriverError> {
    let link = pooled.link()?;
    let watch = Watch::new(request.clone(), link.tally(), plan.policy);
    let mut write = Write {
        client: &mut link.client,
        watch: &watch,
        stop,
        ledger: &plan.ledger,
        clean: true,
    };
    let outcome = write.run(&plan.batch).await;
    if !write.clean || watch.spoiled() {
        pooled.taint();
    }
    outcome
}

struct Write<'a> {
    client: &'a mut MssqlClient,
    watch: &'a Watch,
    stop: &'a MssqlStop,
    ledger: &'a WriteLedger,
    clean: bool,
}

impl Write<'_> {
    async fn run(&mut self, batch: &WriteBatch) -> Result<WriteReport, DriverError> {
        if let Err(interrupt) = self.batch("BEGIN TRANSACTION").await {
            return Err(self.failed(0, interrupt).await);
        }
        let mut report = Vec::with_capacity(batch.steps.len());
        for (index, step) in batch.steps.iter().enumerate() {
            if let Some((probe, expected)) = step.guard.probe() {
                match self.count(probe).await {
                    Ok(actual) if actual == expected => {}
                    Ok(actual) => {
                        let fate = self.roll_back().await;
                        return Err(self.ledger.guard_failed(index, expected, actual, fate));
                    }
                    Err(interrupt) => return Err(self.failed(index, interrupt).await),
                }
            }
            self.ledger.statement_sending(index);
            let affected = match self.execute(&step.statement).await {
                Ok(affected) => affected,
                Err(interrupt) => return Err(self.failed(index, interrupt).await),
            };
            self.ledger.statement_confirmed(index);
            if let RowGuard::AffectedExactly(expected) = step.guard
                && affected != expected
            {
                let fate = self.roll_back().await;
                return Err(self.ledger.guard_failed(index, expected, affected, fate));
            }
            report.push(Some(affected));
        }
        self.commit(batch.steps.len()).await?;
        Ok(WriteReport::new(report))
    }

    async fn batch(&mut self, sql: &str) -> Result<(), Interrupt> {
        let client = &mut *self.client;
        let running = async move {
            let stream = client.simple_query(sql).await?;
            stream.into_results().await.map(|_| ())
        };
        self.watch.finish(running).await
    }

    async fn count(&mut self, probe: &Statement) -> Result<u64, Interrupt> {
        let params = encode_params(probe.params())?;
        let rows = catalogue_rows(self.client, self.watch, probe.sql(), &params).await?;
        exact_count(&rows).map_err(Interrupt::Failed)
    }

    /// The rows the statement reported. The count includes rows a
    /// trigger touched, which is why a SQL Server save proves itself with
    /// a probe rather than with this number.
    async fn execute(&mut self, statement: &Statement) -> Result<u64, Interrupt> {
        let params = encode_params(statement.params())?;
        let refs = as_sql(&params);
        let executed = self.watch.finish(self.client.execute(statement.sql(), &refs)).await?;
        Ok(executed.total())
    }

    /// COMMIT is sent with no regard for a stop: one that races the
    /// commit turns a knowable outcome into an unknown one.
    async fn commit(&mut self, steps: usize) -> Result<(), DriverError> {
        self.ledger.commit_sending(None);
        let committing = async {
            let stream = self.client.simple_query("COMMIT TRANSACTION").await?;
            stream.into_results().await.map(|_| ())
        };
        match committing.await.map_err(map_error) {
            Ok(()) => Ok(()),
            Err(error) if ends_connection(&error) => {
                self.clean = false;
                Err(DriverError::CommitOutcomeUnknown {
                    token: None,
                    source: Box::new(error),
                })
            }
            // The server answered, so nothing was committed.
            Err(error) => {
                self.roll_back().await;
                Err(DriverError::RolledBack {
                    statement_index: steps,
                    source: Box::new(error),
                })
            }
        }
    }

    /// A statement the server refused, the connection failing, or a stop.
    /// The transaction is rolled back in every case, and the outcome comes
    /// from what the ledger saw go out.
    async fn failed(&mut self, index: usize, interrupt: Interrupt) -> DriverError {
        match interrupt {
            Interrupt::Failed(error) if ends_connection(&error) => {
                self.clean = false;
                self.ledger.interrupted(error, SessionFate::Discarded)
            }
            Interrupt::Failed(error) => {
                let fate = self.roll_back().await;
                self.ledger.failed(index, error, fate)
            }
            Interrupt::Stopped(halt) => {
                let (cause, fate) = self.stopped(halt).await;
                self.ledger.interrupted(cause, fate)
            }
        }
    }

    /// Stop the statement in flight, then end the transaction.
    async fn stopped(&mut self, halt: Halt) -> (DriverError, SessionFate) {
        let request = self.watch.request();
        let until = Instant::now() + self.watch.policy().budget;
        let answer = match halt {
            Halt::Unsent | Halt::Finished => Answer::Acknowledged,
            Halt::Boundary | Halt::MidToken => {
                let answer = attention(self.client, until).await;
                self.stop.record(match answer {
                    Answer::Unanswered => StopProgress::Failed,
                    Answer::Acknowledged | Answer::Garbled => StopProgress::Delivered,
                });
                answer
            }
        };
        let rolled_back =
            answer == Answer::Acknowledged && halt != Halt::MidToken && roll_back_open(self.client, until).await;
        if !rolled_back {
            self.clean = false;
        }
        let cause = match answer {
            Answer::Acknowledged => acknowledged_stop(request),
            Answer::Garbled | Answer::Unanswered => unconfirmed_stop(request),
        };
        // No COMMIT was written, so a connection that cannot roll back
        // ends with the transaction undone all the same.
        let fate = match rolled_back {
            true => SessionFate::RolledBack,
            false => SessionFate::Discarded,
        };
        (cause, fate)
    }

    async fn roll_back(&mut self) -> SessionFate {
        let until = Instant::now() + self.watch.policy().budget;
        match roll_back_open(self.client, until).await {
            true => SessionFate::RolledBack,
            false => {
                self.clean = false;
                SessionFate::Discarded
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use tablepro_core::meta::TableRef;
    use tablepro_core::{ForeignKeyCheck, ForeignKeyMode, WriteKind};

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
