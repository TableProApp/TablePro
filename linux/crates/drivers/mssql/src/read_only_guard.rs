//! Keeping reads on a read-only connection from writing.
//!
//! SQL Server has no read-only session or transaction, so the login's
//! own permissions are the guarantee the connect dialog states. These
//! are defence in depth against accidents: a write that reaches a
//! guarded read is rolled back, and an export refuses SQL that is not a
//! plain read before sending it.

use tablepro_core::sql_syntax::SqlGrammar;
use tablepro_core::sql_syntax::script::{LexicalSettings, ScriptPlan, ScriptTokenKind};
use tablepro_core::{DriverError, ReadOnlyRefusal};

use crate::errors::tds_number;

/// The words that make a statement a write, or let it run one.
const WRITE_WORDS: [&str; 18] = [
    "INSERT", "UPDATE", "DELETE", "MERGE", "INTO", "EXEC", "EXECUTE", "CREATE", "ALTER", "DROP", "TRUNCATE", "GRANT",
    "REVOKE", "DENY", "BEGIN", "COMMIT", "ROLLBACK", "SAVE",
];

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

/// Refuse user SQL that is anything but a read, before it is sent.
pub(crate) fn refuse_writes(sql: &str) -> Result<(), DriverError> {
    let refused = || DriverError::ReadOnly(ReadOnlyRefusal::ClientGuard);
    let plan = ScriptPlan::build(sql, SqlGrammar::MsSql, LexicalSettings::default_for(SqlGrammar::MsSql));
    if !plan.diagnostics().is_empty() || plan.batches().len() > 1 {
        return Err(refused());
    }
    for statement in plan.statements() {
        let mut words = plan
            .tokens(statement.range.clone())
            .filter(|token| !token.kind.is_trivia() && token.kind != ScriptTokenKind::Semicolon);
        let opens_as_read = words.next().is_some_and(|token| match token.kind {
            ScriptTokenKind::OpenParen => true,
            ScriptTokenKind::Word => sql
                .get(token.range)
                .is_some_and(|word| word.eq_ignore_ascii_case("SELECT") || word.eq_ignore_ascii_case("WITH")),
            _ => false,
        });
        let writes = plan.tokens(statement.range.clone()).any(|token| {
            token.kind == ScriptTokenKind::Word
                && sql
                    .get(token.range)
                    .is_some_and(|word| WRITE_WORDS.iter().any(|write| word.eq_ignore_ascii_case(write)))
        });
        if !opens_as_read || writes {
            return Err(refused());
        }
    }
    Ok(())
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
        ] {
            assert_eq!(
                refuse_writes(write),
                Err(DriverError::ReadOnly(ReadOnlyRefusal::ClientGuard)),
                "{write}"
            );
        }
    }
}
