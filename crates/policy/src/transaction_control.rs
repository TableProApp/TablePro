use sqlparser::ast::{Statement, TransactionAccessMode, TransactionIsolationLevel, TransactionMode};
use sqlparser::parser::Parser;
use sqlparser::tokenizer::{Token, Tokenizer};

use crate::classify::dialect_for;
use crate::tsql_transaction::{self, TsqlPhrase};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TransactionControl {
    Begin,
    BeginReadWrite,
    BeginReadOnly,
    BeginReadOnlySnapshot,
    Commit { chain: bool },
    Rollback { chain: bool },
}

/// Detect transaction modes that leave a pooled connection inside a
/// transaction without an explicit BEGIN.
pub(crate) fn has_implicit_transaction_starter(sql: &str, driver_id: &str) -> bool {
    if !matches!(driver_id, "mysql" | "mssql") {
        return false;
    }
    let dialect = dialect_for(driver_id);
    let Ok(tokens) = Tokenizer::new(dialect.as_ref(), sql).tokenize() else {
        return false;
    };
    let tokens = tokens
        .into_iter()
        .filter(|token| !matches!(token, Token::Whitespace(_)))
        .collect::<Vec<_>>();

    tokens
        .split(|token| matches!(token, Token::SemiColon))
        .any(|statement| match driver_id {
            "mssql" => {
                is_word(statement.first(), "SET")
                    && is_word(statement.get(1), "IMPLICIT_TRANSACTIONS")
                    && is_word(statement.get(2), "ON")
            }
            "mysql" => mysql_implicit_transaction_statement(statement),
            _ => false,
        })
}

fn mysql_implicit_transaction_statement(tokens: &[Token]) -> bool {
    if is_word(tokens.first(), "XA") && (is_word(tokens.get(1), "START") || is_word(tokens.get(1), "BEGIN")) {
        return true;
    }
    if !is_word(tokens.first(), "SET") {
        return false;
    }
    tokens.iter().enumerate().any(|(index, token)| {
        let is_autocommit = matches!(token, Token::Word(word)
            if word.value.eq_ignore_ascii_case("autocommit")
                || word.value.eq_ignore_ascii_case("@@autocommit"));
        if !is_autocommit || !matches!(tokens.get(index + 1), Some(Token::Eq | Token::Assignment)) {
            return false;
        }
        let enabled = matches!(tokens.get(index + 2), Some(Token::Number(value, _)) if value == "1")
            || is_word(tokens.get(index + 2), "ON")
            || is_word(tokens.get(index + 2), "TRUE");
        let complete_value = tokens.get(index + 3).is_none_or(|next| matches!(next, Token::Comma));
        !enabled || !complete_value
    })
}

fn is_word(token: Option<&Token>, expected: &str) -> bool {
    matches!(token, Some(Token::Word(word)) if word.value.eq_ignore_ascii_case(expected))
}

pub fn transaction_control(sql: &str, driver_id: &str) -> Option<TransactionControl> {
    if driver_id == "mssql" {
        return tsql_transaction_control(sql);
    }
    parsed_transaction_control(sql, driver_id)
}

fn parsed_transaction_control(sql: &str, driver_id: &str) -> Option<TransactionControl> {
    let dialect = dialect_for(driver_id);
    let statements = Parser::parse_sql(dialect.as_ref(), sql.trim()).ok()?;
    let [statement] = statements.as_slice() else {
        return None;
    };
    control_of(statement)
}

fn tsql_transaction_control(sql: &str) -> Option<TransactionControl> {
    let Some(phrase) = tsql_transaction::scan(sql).only_phrase() else {
        return parsed_transaction_control(sql, "mssql");
    };
    match phrase {
        TsqlPhrase::Begin => parsed_transaction_control(sql, "mssql").or(Some(TransactionControl::Begin)),
        TsqlPhrase::Commit => Some(TransactionControl::Commit { chain: false }),
        TsqlPhrase::Rollback => Some(TransactionControl::Rollback { chain: false }),
        TsqlPhrase::NamedRollback | TsqlPhrase::Save => None,
    }
}

pub(crate) fn hides_transaction_control(sql: &str, driver_id: &str) -> bool {
    if driver_id == "mssql" && tsql_transaction::scan(sql).hides_control() {
        return true;
    }
    let dialect = dialect_for(driver_id);
    let Ok(statements) = Parser::parse_sql(dialect.as_ref(), sql.trim()) else {
        return false;
    };
    statements.len() > 1 && statements.iter().any(|statement| control_of(statement).is_some())
}

pub(crate) fn leaves_tsql_transaction_unclosed(sql: &str, driver_id: &str) -> bool {
    driver_id == "mssql" && tsql_transaction::scan(sql).leaves_shared_transaction_unclosed()
}

fn control_of(statement: &Statement) -> Option<TransactionControl> {
    match statement {
        Statement::StartTransaction { modes, statements, .. } if statements.is_empty() => transaction_start(modes),
        Statement::Commit { chain, .. } => Some(TransactionControl::Commit { chain: *chain }),
        Statement::Rollback { chain, savepoint: None } => Some(TransactionControl::Rollback { chain: *chain }),
        _ => None,
    }
}

fn transaction_start(modes: &[TransactionMode]) -> Option<TransactionControl> {
    if modes.contains(&TransactionMode::AccessMode(TransactionAccessMode::ReadWrite)) {
        return Some(TransactionControl::BeginReadWrite);
    }
    if !modes.contains(&TransactionMode::AccessMode(TransactionAccessMode::ReadOnly)) {
        return Some(TransactionControl::Begin);
    }
    if modes.iter().any(|mode| {
        matches!(
            mode,
            TransactionMode::IsolationLevel(
                TransactionIsolationLevel::RepeatableRead | TransactionIsolationLevel::Serializable
            )
        )
    }) {
        Some(TransactionControl::BeginReadOnlySnapshot)
    } else {
        Some(TransactionControl::BeginReadOnly)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn each_transaction_statement_is_recognised_per_dialect() {
        let cases = [
            ("BEGIN", "postgres", Some(TransactionControl::Begin)),
            ("BEGIN READ WRITE", "postgres", Some(TransactionControl::BeginReadWrite)),
            (
                "START TRANSACTION READ WRITE",
                "postgres",
                Some(TransactionControl::BeginReadWrite),
            ),
            ("BEGIN READ ONLY", "postgres", Some(TransactionControl::BeginReadOnly)),
            (
                "BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY",
                "postgres",
                Some(TransactionControl::BeginReadOnlySnapshot),
            ),
            (
                "START TRANSACTION READ ONLY",
                "mysql",
                Some(TransactionControl::BeginReadOnly),
            ),
            ("START TRANSACTION", "mysql", Some(TransactionControl::Begin)),
            ("BEGIN TRANSACTION", "mssql", Some(TransactionControl::Begin)),
            ("COMMIT", "sqlite", Some(TransactionControl::Commit { chain: false })),
            ("END", "postgres", Some(TransactionControl::Commit { chain: false })),
            (
                "COMMIT AND CHAIN",
                "postgres",
                Some(TransactionControl::Commit { chain: true }),
            ),
            ("ROLLBACK", "mysql", Some(TransactionControl::Rollback { chain: false })),
            ("ROLLBACK TO SAVEPOINT s", "postgres", None),
            ("SAVEPOINT s", "postgres", None),
            ("SELECT 1", "postgres", None),
            ("BEGIN; COMMIT", "postgres", None),
            ("not sql at all", "postgres", None),
        ];
        for (sql, driver, expected) in cases {
            assert_eq!(transaction_control(sql, driver), expected, "{driver}: {sql}");
        }
    }

    #[test]
    fn sql_server_tran_spellings_are_transaction_control() {
        let begin = Some(TransactionControl::Begin);
        let commit = Some(TransactionControl::Commit { chain: false });
        let rollback = Some(TransactionControl::Rollback { chain: false });
        for (sql, expected) in [
            ("BEGIN TRAN", begin),
            ("begin tran", begin),
            ("BEGIN TRAN t1", begin),
            ("BEGIN TRANSACTION t1", begin),
            ("BEGIN TRAN @name", begin),
            ("BEGIN DISTRIBUTED TRANSACTION", begin),
            ("COMMIT TRAN", commit),
            ("COMMIT TRANSACTION t1", commit),
            ("COMMIT WORK", commit),
            ("ROLLBACK TRAN", rollback),
            ("ROLLBACK WORK", rollback),
            ("ROLLBACK TRANSACTION t1", None),
            ("SAVE TRAN s1", None),
        ] {
            assert_eq!(transaction_control(sql, "mssql"), expected, "{sql}");
        }
        assert!(hides_transaction_control("ROLLBACK TRAN s1", "mssql"));
        assert!(hides_transaction_control("SAVE TRAN s1", "mssql"));
    }

    #[test]
    fn sql_server_tran_inside_a_batch_is_hidden_transaction_control() {
        for sql in [
            "BEGIN TRAN UPDATE t SET a = 1 WHERE id = 1",
            "BEGIN TRAN; UPDATE t SET a = 1 WHERE id = 1",
            "UPDATE t SET a = 1 WHERE id = 1 COMMIT TRAN",
            "UPDATE t SET a = 1 WHERE id = 1; ROLLBACK TRAN",
            "SAVE TRAN s1; UPDATE t SET a = 1",
        ] {
            assert!(hides_transaction_control(sql, "mssql"), "{sql}");
        }
        for sql in [
            "SELECT 'BEGIN TRAN' AS x",
            "SELECT 1 /* COMMIT TRAN */",
            "UPDATE tran SET a = 1",
        ] {
            assert!(!hides_transaction_control(sql, "mssql"), "{sql}");
            assert_eq!(transaction_control(sql, "mssql"), None, "{sql}");
        }
    }

    #[test]
    fn implicit_transaction_starters_are_dialect_aware_and_ignore_literals_and_comments() {
        for (sql, driver) in [
            ("SET autocommit = 0", "mysql"),
            ("set /* connection scope */ session autocommit := OFF", "mysql"),
            ("SET @@autocommit = 0", "mysql"),
            ("SET @@session.autocommit = 0", "mysql"),
            ("SELECT 1; XA START 'branch-1'", "mysql"),
            ("XA BEGIN 'branch-2'", "mysql"),
            ("SET autocommit = FALSE", "mysql"),
            ("SET autocommit = 1 - 1", "mysql"),
            ("SET autocommit = ON - 1", "mysql"),
            ("SET sql_mode = 'STRICT_ALL_TABLES', autocommit = 0", "mysql"),
            ("SET autocommit = @wanted", "mysql"),
            ("SET IMPLICIT_TRANSACTIONS ON", "mssql"),
        ] {
            assert!(has_implicit_transaction_starter(sql, driver), "{driver}: {sql}");
        }
        for (sql, driver) in [
            ("SELECT 'SET autocommit = 0'", "mysql"),
            ("SELECT 1 /* SET IMPLICIT_TRANSACTIONS ON */", "mssql"),
            ("SET @autocommit = 0", "mysql"),
            ("SET sql_mode = 'STRICT_ALL_TABLES'", "mysql"),
            ("SET autocommit = 1", "mysql"),
            ("SET SESSION autocommit = ON", "mysql"),
            ("SET IMPLICIT_TRANSACTIONS OFF", "mssql"),
            ("SET autocommit = 0", "postgres"),
        ] {
            assert!(!has_implicit_transaction_starter(sql, driver), "{driver}: {sql}");
        }
    }
}
