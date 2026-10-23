//! A save, statement by statement: CQL has no transaction to put
//! around them.

use tablepro_core::statement::{GuardedStatement, RowGuard, Statement};
use tablepro_core::{
    DriverError, ReadOnlyRefusal, ServerCode, SessionFate, StopRequest, WriteBatch, WriteLedger, WriteReport,
};

use crate::call::{stoppable, stopped};
use crate::rows::applied;
use crate::session::CqlLink;

/// Refuse a batch before anything is sent: a read-only connection never
/// writes, CQL has no foreign keys to suspend, and only a lightweight
/// transaction says whether it changed its one row.
pub(crate) fn precheck(batch: &WriteBatch, read_only: bool) -> Result<(), DriverError> {
    if read_only {
        return Err(DriverError::ReadOnly(ReadOnlyRefusal::ClientGuard));
    }
    batch.foreign_keys.require_enforced()?;
    let unprovable = batch.steps.iter().position(|step| match step.guard {
        RowGuard::AffectedExactly(rows) => rows > 1 || !reports_applied(&step.statement),
        RowGuard::None | RowGuard::ProbeExactly { .. } => false,
    });
    match unprovable {
        Some(statement_index) => Err(DriverError::GuardUnsupported { statement_index }),
        None => Ok(()),
    }
}

/// `IF EXISTS` and `IF NOT EXISTS` make a write a lightweight
/// transaction, whose answer says whether it applied.
fn reports_applied(statement: &Statement) -> bool {
    let sql = statement.sql().trim_end().to_ascii_uppercase();
    sql.ends_with(" IF EXISTS") || sql.ends_with(" IF NOT EXISTS")
}

/// Apply the batch. A statement on the wire is never dropped, since the
/// server applies it whatever the client does: the stop waits for its
/// answer within the cancel grace, so the ledger can say whether it
/// landed. Between statements a stop ends the save.
pub(crate) async fn perform(
    link: &CqlLink,
    batch: &WriteBatch,
    ledger: &WriteLedger,
    request: &StopRequest,
) -> Result<WriteReport, DriverError> {
    let mut report = Vec::with_capacity(batch.steps.len());
    for (index, step) in batch.steps.iter().enumerate() {
        prove(link, ledger, request, index, step).await?;
        if request.is_requested() {
            return Err(ledger.interrupted(stopped(request), SessionFate::Discarded));
        }
        ledger.statement_sending(index);
        let result = match link.execute(&step.statement).await {
            Ok(result) => result,
            Err(error) => {
                return Err(match may_have_applied(&error) {
                    true => ledger.interrupted(error, SessionFate::Discarded),
                    false => ledger.failed(index, error, SessionFate::RolledBack),
                });
            }
        };
        let affected = applied(result)?.map(u64::from);
        // A transaction that did not apply changed nothing, so it is
        // not counted as landed.
        if let RowGuard::AffectedExactly(expected) = step.guard {
            let actual = affected.unwrap_or(0);
            if actual != expected {
                return Err(ledger.guard_failed(index, expected, actual, SessionFate::RolledBack));
            }
        }
        ledger.statement_confirmed(index);
        report.push(affected);
    }
    Ok(WriteReport::new(report))
}

/// Count the rows a step would change and refuse it unless they are the
/// ones it was written for. Nothing is in flight while a probe runs.
async fn prove(
    link: &CqlLink,
    ledger: &WriteLedger,
    request: &StopRequest,
    index: usize,
    step: &GuardedStatement,
) -> Result<(), DriverError> {
    let Some((probe, expected)) = step.guard.probe() else {
        return Ok(());
    };
    if request.is_requested() {
        return Err(ledger.interrupted(stopped(request), SessionFate::RolledBack));
    }
    match stoppable(request, count(link, probe)).await {
        Ok(actual) if actual == expected => Ok(()),
        Ok(actual) => Err(ledger.guard_failed(index, expected, actual, SessionFate::RolledBack)),
        Err(error) if request.is_requested() => Err(ledger.interrupted(error, SessionFate::RolledBack)),
        Err(error) => Err(ledger.failed(index, error, SessionFate::RolledBack)),
    }
}

async fn count(link: &CqlLink, probe: &Statement) -> Result<u64, DriverError> {
    let rows = link
        .execute(probe)
        .await?
        .into_rows_result()
        .map_err(|error| DriverError::Protocol(error.to_string()))?;
    let (count,): (i64,) = rows
        .single_row()
        .map_err(|error| DriverError::Protocol(error.to_string()))?;
    u64::try_from(count).map_err(|_| DriverError::Protocol(format!("the key probe returned {count}")))
}

/// A write whose outcome the error leaves open. A write timeout means
/// the coordinator stopped waiting for replicas that may still apply
/// it, and a write failure that some did; a lost connection says
/// nothing either way.
fn may_have_applied(error: &DriverError) -> bool {
    match error {
        DriverError::Server(diagnostics) => matches!(diagnostics.code, Some(ServerCode::Cql { code: 0x1100 | 0x1500 })),
        DriverError::ConnectionLost { .. } | DriverError::Timeout { .. } | DriverError::Transport(_) => true,
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use tablepro_core::meta::TableRef;
    use tablepro_core::statement::StatementBuilder;
    use tablepro_core::{ForeignKeyCheck, ForeignKeyMode, LossPhase, ServerDiagnostics, UnsupportedFeature, WriteKind};

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
    fn only_a_lightweight_transaction_can_prove_its_row() {
        let proved = vec![
            GuardedStatement::affecting_exactly(statement("UPDATE t SET a = ? WHERE id = ? IF EXISTS"), 1),
            GuardedStatement::affecting_exactly(statement("INSERT INTO t (id) VALUES (?) IF NOT EXISTS"), 1),
            GuardedStatement::unguarded(statement("TRUNCATE t")),
        ];
        assert_eq!(precheck(&batch(proved, ForeignKeyMode::Enforced), false), Ok(()));

        let blind = vec![GuardedStatement::affecting_exactly(
            statement("DELETE FROM t WHERE id = ?"),
            1,
        )];
        assert_eq!(
            precheck(&batch(blind, ForeignKeyMode::Enforced), false),
            Err(DriverError::GuardUnsupported { statement_index: 0 })
        );
        let several = vec![GuardedStatement::affecting_exactly(
            statement("DELETE FROM t WHERE id = ? IF EXISTS"),
            2,
        )];
        assert_eq!(
            precheck(&batch(several, ForeignKeyMode::Enforced), false),
            Err(DriverError::GuardUnsupported { statement_index: 0 })
        );
    }

    #[test]
    fn a_read_only_connection_and_a_suspension_are_refused_before_sending() {
        assert!(matches!(
            precheck(&batch(Vec::new(), ForeignKeyMode::Enforced), true),
            Err(DriverError::ReadOnly(ReadOnlyRefusal::ClientGuard))
        ));
        let suspended = ForeignKeyMode::SuspendedThenVerified {
            checks: vec![ForeignKeyCheck::same_table(TableRef::unqualified("t"))],
        };
        assert!(matches!(
            precheck(&batch(Vec::new(), suspended), false),
            Err(DriverError::Unsupported {
                feature: UnsupportedFeature::ForeignKeySuspension
            })
        ));
    }

    #[test]
    fn a_write_timeout_leaves_the_outcome_open_and_a_refusal_does_not() {
        let server = |code| DriverError::reported(ServerDiagnostics::new(Some(ServerCode::Cql { code }), "x"));

        assert!(may_have_applied(&server(0x1100)));
        assert!(may_have_applied(&server(0x1500)));
        assert!(!may_have_applied(&server(0x2200)));
        assert!(
            !may_have_applied(&server(0x1000)),
            "an unavailable coordinator sent nothing"
        );
        assert!(may_have_applied(&DriverError::ConnectionLost {
            during: LossPhase::Statement
        }));
    }
}
