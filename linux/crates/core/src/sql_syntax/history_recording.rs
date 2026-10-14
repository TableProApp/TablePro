use super::SqlGrammar;
use super::credential_rules::CredentialRules;
use super::statement_tokens::{StatementToken, lex_statements};

/// Whether what the user ran may go into the query history.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HistoryRecording {
    Record,
    Withhold(WithholdReason),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WithholdReason {
    /// A statement sets a password, a key or a link to another server.
    CredentialStatement,
    /// A string, quoted name or comment never closes, so where the
    /// statements are, and what is inside a literal, is a guess.
    Untokenizable,
}

/// Dollar-quoted bodies are read for the statements inside them this
/// many levels deep: a DO block in a function body is as far as real
/// scripts nest.
const MAX_BODY_DEPTH: u8 = 4;

/// Whether `sql` may be kept, split the way the editor splits it for
/// `grammar`. The text is never rewritten: an entry is kept whole or not
/// at all, so History can neither show nor run a statement with a secret
/// cut out of it.
pub fn classify_for_history(grammar: SqlGrammar, rules: &CredentialRules, sql: &str) -> HistoryRecording {
    let script = lex_statements(sql, grammar);
    if script.unterminated {
        return HistoryRecording::Withhold(WithholdReason::Untokenizable);
    }
    match carries_credentials(grammar, rules, &script.statements, 0) {
        true => HistoryRecording::Withhold(WithholdReason::CredentialStatement),
        false => HistoryRecording::Record,
    }
}

fn carries_credentials(
    grammar: SqlGrammar,
    rules: &CredentialRules,
    statements: &[Vec<StatementToken<'_>>],
    depth: u8,
) -> bool {
    statements.iter().any(|tokens| {
        rules.matches(tokens)
            || tokens.iter().any(|token| match token {
                // A body that does not lex cleanly is text in a literal,
                // not a routine, so only the statements it does hold count.
                StatementToken::DollarBody(body) if depth < MAX_BODY_DEPTH => {
                    carries_credentials(grammar, rules, &lex_statements(body, grammar).statements, depth + 1)
                }
                _ => false,
            })
    })
}

#[cfg(test)]
mod tests {
    use proptest::prelude::*;

    use super::*;

    const RULES: CredentialRules = CredentialRules {
        statement_prefixes: &[
            &["CREATE", "USER"],
            &["ALTER", "USER"],
            &["CREATE", "NAMED", "COLLECTION"],
        ],
        conditional_prefixes: &[(&["GRANT"], &["IDENTIFIED"])],
        carriers: &["dblink_connect", "sp_addlogin", "s3"],
    };

    const WITHHELD: HistoryRecording = HistoryRecording::Withhold(WithholdReason::CredentialStatement);

    fn classify(grammar: SqlGrammar, sql: &str) -> HistoryRecording {
        classify_for_history(grammar, &RULES, sql)
    }

    #[test]
    fn plain_statements_are_recorded_in_every_grammar() {
        let plain = [
            "SELECT id FROM users WHERE password IS NULL AND email = 'a@b'",
            "UPDATE accounts SET secret = NULL WHERE name = 'x'",
            "DELETE FROM creds WHERE password = 'p'",
            "SELECT 'password' AS label",
            "CREATE TABLE s3 (id int)",
            "SELECT s3 FROM t",
            "-- only a note\n/* and another */",
            "",
        ];
        for grammar in SqlGrammar::ALL {
            for sql in plain {
                assert_eq!(classify(grammar, sql), HistoryRecording::Record, "{grammar:?}: {sql}");
            }
        }
    }

    #[test]
    fn one_credential_statement_withholds_the_whole_script() {
        assert_eq!(
            classify(SqlGrammar::PostgreSql, "SELECT 1; CREATE USER u PASSWORD 'p'"),
            WITHHELD
        );
    }

    #[test]
    fn or_replace_does_not_hide_a_prefix() {
        assert_eq!(
            classify(SqlGrammar::ClickHouse, "CREATE OR REPLACE USER u IDENTIFIED BY 'p'"),
            WITHHELD
        );
    }

    #[test]
    fn an_open_literal_or_comment_cannot_be_read() {
        let untokenizable = HistoryRecording::Withhold(WithholdReason::Untokenizable);

        assert_eq!(classify(SqlGrammar::PostgreSql, "SELECT 'abc"), untokenizable);
        assert_eq!(classify(SqlGrammar::MySql, "SELECT 1 /* note"), untokenizable);
        assert_eq!(classify(SqlGrammar::MsSql, "SELECT [abc"), untokenizable);
    }

    #[test]
    fn words_in_strings_comments_and_names_do_not_count() {
        for sql in [
            "SELECT 'CREATE USER u' AS text",
            "SELECT 1 -- CREATE USER u\n",
            "SELECT create_user FROM t",
            "SELECT \"CREATE\", \"USER\" FROM t",
            "SELECT 'sp_addlogin x'",
        ] {
            assert_eq!(classify(SqlGrammar::PostgreSql, sql), HistoryRecording::Record, "{sql}");
        }
    }

    #[test]
    fn a_conditional_prefix_needs_its_word_in_the_same_statement() {
        assert_eq!(
            classify(SqlGrammar::MySql, "GRANT SELECT ON t TO u"),
            HistoryRecording::Record
        );
        assert_eq!(
            classify(SqlGrammar::MySql, "GRANT SELECT ON t TO u; SELECT identified FROM t"),
            HistoryRecording::Record
        );
        assert_eq!(
            classify(SqlGrammar::MySql, "GRANT ALL ON *.* TO u IDENTIFIED BY 'p'"),
            WITHHELD
        );
    }

    #[test]
    fn a_prefix_counts_anywhere_in_a_batch() {
        assert_eq!(
            classify(SqlGrammar::MsSql, "SELECT 1\nCREATE USER u WITH PASSWORD = 'p'"),
            WITHHELD
        );
        assert_eq!(
            classify(
                SqlGrammar::MySql,
                "DELIMITER //\nCREATE PROCEDURE p() BEGIN CREATE USER u IDENTIFIED BY 'p'; END //"
            ),
            WITHHELD
        );
    }

    #[test]
    fn a_dollar_quoted_body_is_read_for_statements() {
        assert_eq!(
            classify(
                SqlGrammar::PostgreSql,
                "DO $$ BEGIN IF NOT EXISTS (SELECT 1) THEN CREATE USER app PASSWORD 'p'; END IF; END $$"
            ),
            WITHHELD
        );
        assert_eq!(
            classify(SqlGrammar::PostgreSql, "SELECT $$it's a note$$"),
            HistoryRecording::Record
        );
    }

    #[test]
    fn a_carrier_counts_as_a_call() {
        for (grammar, sql) in [
            (SqlGrammar::PostgreSql, "SELECT dblink_connect('password=x')"),
            (SqlGrammar::PostgreSql, "SELECT public.dblink_connect('password=x')"),
            (SqlGrammar::PostgreSql, "SELECT \"dblink_connect\"('password=x')"),
            (SqlGrammar::ClickHouse, "SELECT * FROM s3('url', 'key', 'secret')"),
            (
                SqlGrammar::ClickHouse,
                "INSERT INTO FUNCTION s3('url', 'key', 'secret') VALUES (1)",
            ),
            (SqlGrammar::ClickHouse, "DESCRIBE TABLE s3('url', 'key', 'secret')"),
            (
                SqlGrammar::ClickHouse,
                "CREATE TABLE t (id Int32) ENGINE = S3('url', 'key', 'secret')",
            ),
            (SqlGrammar::MsSql, "sp_addlogin 'l', 'p'"),
            (SqlGrammar::MsSql, "EXEC sp_addlogin 'l', 'p'"),
            (SqlGrammar::MsSql, "EXECUTE master.dbo.sp_addlogin 'l', 'p'"),
            (SqlGrammar::MsSql, "EXEC master..sp_addlogin 'l', 'p'"),
            (SqlGrammar::MsSql, "EXEC [dbo].[sp_addlogin] 'l', 'p'"),
            (SqlGrammar::MsSql, "DECLARE @rc int\nEXEC @rc = sp_addlogin 'l', 'p'"),
            (SqlGrammar::MsSql, "SELECT 1\nGO\nsp_addlogin 'l', 'p'"),
        ] {
            assert_eq!(classify(grammar, sql), WITHHELD, "{sql}");
        }
    }

    #[test]
    fn a_carrier_name_that_names_a_table_is_not_a_call() {
        for sql in [
            "CREATE TABLE s3 (id Int32) ENGINE = Memory",
            "CREATE TABLE IF NOT EXISTS db.s3 (id Int32) ENGINE = Memory",
            "INSERT INTO s3 (id) VALUES (1)",
            "CREATE VIEW s3 (id) AS SELECT 1",
            "SELECT s3.id FROM s3",
            "SELECT 1 AS s3",
        ] {
            assert_eq!(classify(SqlGrammar::ClickHouse, sql), HistoryRecording::Record, "{sql}");
        }
    }

    #[test]
    fn a_procedure_mid_batch_needs_exec() {
        assert_eq!(
            classify(SqlGrammar::MsSql, "SELECT 1\nPRINT sp_addlogin"),
            HistoryRecording::Record
        );
    }

    proptest! {
        #[test]
        fn any_text_classifies_without_panicking(sql in "\\PC{0,120}", grammar in 0usize..5) {
            let grammar = SqlGrammar::ALL[grammar];
            let _ = classify(grammar, &sql);
        }

        #[test]
        fn a_credential_statement_is_withheld_whatever_runs_before_it(
            before in "[A-Za-z0-9_ ,=()]{0,60}",
        ) {
            let sql = format!("SELECT {before};\nCREATE USER u PASSWORD 'p'");
            prop_assert_eq!(classify(SqlGrammar::PostgreSql, &sql), WITHHELD);
        }
    }
}
