//! Keeping reads on a read-only connection from writing.
//!
//! SQL Server has no read-only session or transaction, so the login's
//! own permissions are the guarantee the connect dialog states. These
//! are defence in depth against accidents: a write that reaches a
//! guarded read is rolled back, and an export refuses SQL that is not a
//! plain read before sending it.

use tablepro_core::sql_syntax::script::{LexicalSettings, ScriptPlan};
use tablepro_core::sql_syntax::{SqlGrammar, StatementAccess, statement_access};
use tablepro_core::{DriverError, ReadOnlyRefusal};

use crate::errors::tds_number;

/// Run `sql` inside a transaction that is always rolled back. The line
/// breaks keep a trailing line comment from swallowing the ROLLBACK.
pub(crate) fn wrap(sql: &str) -> String {
    format!("BEGIN TRANSACTION;\n{sql}\n;\nROLLBACK TRANSACTION;")
}

/// What a guarded read's failure means. A ROLLBACK or COMMIT with no
/// transaction to end, or a transaction count that changed, means the
/// statement ended the guard's transaction itself.
pub(crate) fn guarded_error(error: DriverError) -> DriverError {
    match tds_number(&error) {
        Some(266 | 3902 | 3903) => DriverError::ReadOnly(ReadOnlyRefusal::ClientGuard),
        _ => error,
    }
}

/// Refuse user SQL that is anything but a read, before it is sent. A
/// second `GO` batch would run outside the guard's transaction.
pub(crate) fn refuse_writes(sql: &str) -> Result<(), DriverError> {
    let plan = ScriptPlan::build(sql, SqlGrammar::MsSql, LexicalSettings::default_for(SqlGrammar::MsSql));
    let reads = plan.batches().len() <= 1 && statement_access(sql, SqlGrammar::MsSql) == StatementAccess::Read;
    match reads {
        true => Ok(()),
        false => Err(DriverError::ReadOnly(ReadOnlyRefusal::ClientGuard)),
    }
}

#[cfg(test)]
mod tests {
    use tablepro_core::{ServerCode, ServerDiagnostics};

    use super::*;

    #[test]
    fn wraps_statement_in_begin_rollback() {
        assert_eq!(
            wrap("SELECT * FROM t -- trailing"),
            "BEGIN TRANSACTION;\nSELECT * FROM t -- trailing\n;\nROLLBACK TRANSACTION;"
        );
    }

    #[test]
    fn an_escaped_guard_is_the_client_guard() {
        let tds = |number| {
            DriverError::reported(ServerDiagnostics::new(
                Some(ServerCode::Tds {
                    number,
                    state: 1,
                    class: 16,
                }),
                "transaction mismatch",
            ))
        };

        assert_eq!(
            guarded_error(tds(3903)),
            DriverError::ReadOnly(ReadOnlyRefusal::ClientGuard)
        );
        assert_eq!(
            guarded_error(tds(266)),
            DriverError::ReadOnly(ReadOnlyRefusal::ClientGuard)
        );
        assert!(matches!(guarded_error(tds(208)), DriverError::Server(_)));
    }

    #[test]
    fn only_plain_reads_pass_the_export_guard() {
        for read in [
            "SELECT * FROM t",
            "  with c AS (SELECT 1 AS a) SELECT a FROM c;",
            "SELECT [update], 'DELETE' AS word FROM t; SELECT 2",
            "(SELECT 1) UNION (SELECT 2)",
        ] {
            assert_eq!(refuse_writes(read), Ok(()), "{read}");
        }
        for write in [
            "DELETE FROM t",
            "SELECT * INTO copy FROM t",
            "SELECT 1; UPDATE t SET a = 1",
            "EXEC sp_who",
            "WITH c AS (SELECT 1 AS a) DELETE FROM c",
            "SELECT 1\nGO\nSELECT 2",
            "SELECT 'unterminated",
            "SET NOCOUNT ON",
            "SELECT 1\nDELETE FROM t",
            "SELECT * FROM OPENQUERY(remote, 'DELETE FROM t')",
        ] {
            assert_eq!(
                refuse_writes(write),
                Err(DriverError::ReadOnly(ReadOnlyRefusal::ClientGuard)),
                "{write}"
            );
        }
    }
}
