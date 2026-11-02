use tablepro_core::sql_syntax::script::{ScriptToken, ScriptTokenKind};

/// What a statement does to the session's transaction, read from its
/// leading keywords.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum StatementClass {
    /// BEGIN, START TRANSACTION.
    TransactionStart,
    /// COMMIT, END, ROLLBACK, ABORT. `chain` is AND CHAIN, which opens
    /// the next transaction at once.
    TransactionEnd {
        rollback: bool,
        chain: bool,
    },
    /// SAVEPOINT and RELEASE.
    Savepoint,
    RollbackToSavepoint,
    /// PREPARE TRANSACTION, COMMIT PREPARED, ROLLBACK PREPARED.
    TwoPhase,
    CopyFromStdin,
    CopyToStdout,
    /// A statement whose result a cursor can hold: SELECT, VALUES, TABLE,
    /// WITH, or one that opens with a parenthesis.
    RowSource,
    /// CALL and DO can commit or roll back inside, so what they leave is
    /// only known by asking.
    Undetermined,
    Other {
        reports_rows: bool,
    },
}

/// Classify a statement from its tokens. Only words at parenthesis depth
/// zero count, so a keyword inside a subquery or a function body never
/// changes the class.
pub(crate) fn classify(text: &str, tokens: &[ScriptToken]) -> StatementClass {
    let significant: Vec<&ScriptToken> = tokens.iter().filter(|token| !token.kind.is_trivia()).collect();
    if significant
        .first()
        .is_some_and(|token| token.kind == ScriptTokenKind::OpenParen)
    {
        return StatementClass::RowSource;
    }
    let words = top_level_words(text, &significant);
    let word = |index: usize| words.get(index).map(String::as_str).unwrap_or_default();
    match word(0) {
        "BEGIN" => StatementClass::TransactionStart,
        "START" if word(1) == "TRANSACTION" => StatementClass::TransactionStart,
        "COMMIT" | "ROLLBACK" if word(1) == "PREPARED" => StatementClass::TwoPhase,
        "PREPARE" if word(1) == "TRANSACTION" => StatementClass::TwoPhase,
        "ROLLBACK" | "ABORT" if is_rollback_to(&words) => StatementClass::RollbackToSavepoint,
        "COMMIT" | "END" | "ROLLBACK" | "ABORT" => StatementClass::TransactionEnd {
            rollback: matches!(word(0), "ROLLBACK" | "ABORT"),
            chain: has_chain(&words),
        },
        "SAVEPOINT" | "RELEASE" => StatementClass::Savepoint,
        "COPY" => copy_direction(&words),
        "SELECT" | "VALUES" | "TABLE" | "WITH" => StatementClass::RowSource,
        "CALL" | "DO" => StatementClass::Undetermined,
        "INSERT" | "UPDATE" | "DELETE" | "MERGE" | "MOVE" | "FETCH" => StatementClass::Other { reports_rows: true },
        _ => StatementClass::Other { reports_rows: false },
    }
}

impl StatementClass {
    /// Whether the statement controls the transaction itself, so its own
    /// results and notices are not data to show.
    pub(crate) fn is_transaction_control(self) -> bool {
        matches!(
            self,
            Self::TransactionStart
                | Self::TransactionEnd { .. }
                | Self::Savepoint
                | Self::RollbackToSavepoint
                | Self::TwoPhase
        )
    }

    /// Whether a command tag's count is a row count for this statement.
    /// A row source's count is its rows, and DDL's tag has no count.
    pub(crate) fn reports_rows(self) -> bool {
        matches!(
            self,
            Self::RowSource | Self::CopyToStdout | Self::CopyFromStdin | Self::Other { reports_rows: true }
        )
    }
}

fn top_level_words(text: &str, tokens: &[&ScriptToken]) -> Vec<String> {
    let mut depth = 0usize;
    let mut words = Vec::new();
    for token in tokens {
        match token.kind {
            ScriptTokenKind::OpenParen => depth += 1,
            ScriptTokenKind::CloseParen => depth = depth.saturating_sub(1),
            ScriptTokenKind::Word if depth == 0 => {
                if let Some(word) = text.get(token.range.clone()) {
                    words.push(word.to_ascii_uppercase());
                }
            }
            _ => {}
        }
    }
    words
}

/// `ROLLBACK [WORK | TRANSACTION] TO [SAVEPOINT] name`.
fn is_rollback_to(words: &[String]) -> bool {
    words.iter().skip(1).take(2).any(|word| word == "TO")
}

/// `AND CHAIN`, as opposed to `AND NO CHAIN`.
fn has_chain(words: &[String]) -> bool {
    words.windows(2).any(|pair| pair[0] == "AND" && pair[1] == "CHAIN")
}

fn copy_direction(words: &[String]) -> StatementClass {
    let follows = |first: &str, second: &str| words.windows(2).any(|pair| pair[0] == first && pair[1] == second);
    if follows("FROM", "STDIN") {
        StatementClass::CopyFromStdin
    } else if follows("TO", "STDOUT") {
        StatementClass::CopyToStdout
    } else {
        StatementClass::Other { reports_rows: true }
    }
}

#[cfg(test)]
mod tests {
    use tablepro_core::sql_syntax::SqlGrammar;
    use tablepro_core::sql_syntax::script::{LexicalSettings, ScriptPlan};

    use super::*;

    fn class(text: &str) -> StatementClass {
        let plan = ScriptPlan::build(
            text,
            SqlGrammar::PostgreSql,
            LexicalSettings {
                backslash_escapes: false,
            },
        );
        let tokens: Vec<ScriptToken> = plan.tokens(0..text.len()).collect();
        classify(text, &tokens)
    }

    #[test]
    fn leading_keyword_table() {
        let end = |rollback, chain| StatementClass::TransactionEnd { rollback, chain };
        let cases = [
            ("BEGIN", StatementClass::TransactionStart),
            ("begin isolation level serializable", StatementClass::TransactionStart),
            ("START TRANSACTION READ ONLY", StatementClass::TransactionStart),
            ("COMMIT", end(false, false)),
            ("END", end(false, false)),
            ("commit and chain", end(false, true)),
            ("COMMIT AND NO CHAIN", end(false, false)),
            ("ROLLBACK", end(true, false)),
            ("ROLLBACK AND CHAIN", end(true, true)),
            ("ABORT", end(true, false)),
            ("ROLLBACK TO SAVEPOINT a", StatementClass::RollbackToSavepoint),
            ("ROLLBACK TO a", StatementClass::RollbackToSavepoint),
            ("ROLLBACK WORK TO SAVEPOINT a", StatementClass::RollbackToSavepoint),
            ("SAVEPOINT a", StatementClass::Savepoint),
            ("RELEASE SAVEPOINT a", StatementClass::Savepoint),
            ("PREPARE TRANSACTION 'x'", StatementClass::TwoPhase),
            ("COMMIT PREPARED 'x'", StatementClass::TwoPhase),
            ("ROLLBACK PREPARED 'x'", StatementClass::TwoPhase),
            ("COPY t FROM STDIN", StatementClass::CopyFromStdin),
            (
                "copy t (a, b) from stdin with (format csv)",
                StatementClass::CopyFromStdin,
            ),
            ("COPY (SELECT 1) TO STDOUT", StatementClass::CopyToStdout),
            ("COPY t FROM '/tmp/x'", StatementClass::Other { reports_rows: true }),
            ("SELECT 1", StatementClass::RowSource),
            ("  -- why\n  values (1)", StatementClass::RowSource),
            ("TABLE t", StatementClass::RowSource),
            ("WITH x AS (SELECT 1) SELECT * FROM x", StatementClass::RowSource),
            ("(SELECT 1) UNION (SELECT 2)", StatementClass::RowSource),
            ("CALL p()", StatementClass::Undetermined),
            ("DO $$ BEGIN COMMIT; END $$", StatementClass::Undetermined),
            ("INSERT INTO t VALUES (1)", StatementClass::Other { reports_rows: true }),
            (
                "CREATE TABLE t (begin int)",
                StatementClass::Other { reports_rows: false },
            ),
            ("PREPARE q AS SELECT 1", StatementClass::Other { reports_rows: false }),
            ("SELECT * FROM (SELECT 1) AS begin", StatementClass::RowSource),
        ];
        for (text, expected) in cases {
            assert_eq!(class(text), expected, "{text}");
        }
    }

    #[test]
    fn a_keyword_inside_parentheses_does_not_count() {
        assert_eq!(
            class("COPY (SELECT 'FROM STDIN') TO STDOUT"),
            StatementClass::CopyToStdout
        );
        assert!(StatementClass::TransactionStart.is_transaction_control());
        assert!(!StatementClass::RowSource.is_transaction_control());
        assert!(!StatementClass::Other { reports_rows: false }.reports_rows());
    }
}
