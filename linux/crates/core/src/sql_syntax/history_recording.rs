use super::SqlGrammar;
use super::credential_rules::CredentialRules;
use super::script::ScriptPlan;
use super::statement_access::CLIENT_SPLITS;
use super::statement_tokens::{StatementToken, lex_statements, statements_of};

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

/// Routine bodies are read for the statements inside them this many
/// levels deep: a DO block in a function body is as far as real scripts
/// nest.
const MAX_BODY_DEPTH: u8 = 4;

/// Whether `sql` may be kept, read every way a server of `grammar` may
/// read it. The text is never rewritten: an entry is kept whole or not
/// at all, so History can neither show nor run a statement with a secret
/// cut out of it.
pub fn classify_for_history(grammar: SqlGrammar, rules: &CredentialRules, sql: &str) -> HistoryRecording {
    classify_as_sent(grammar, rules, sql, CLIENT_SPLITS)
}

/// The whole text, then each piece a `DELIMITER` line cuts it into, which
/// a client sends apart.
fn classify_as_sent(grammar: SqlGrammar, rules: &CredentialRules, sql: &str, splits: u8) -> HistoryRecording {
    let whole = classify_every_way(grammar, rules, sql);
    if whole != HistoryRecording::Record || splits == 0 {
        return whole;
    }
    ScriptPlan::client_pieces(sql, grammar)
        .into_iter()
        .map(|piece| classify_as_sent(grammar, rules, piece, splits - 1))
        .find(|recording| *recording != HistoryRecording::Record)
        .unwrap_or(HistoryRecording::Record)
}

fn classify_every_way(grammar: SqlGrammar, rules: &CredentialRules, sql: &str) -> HistoryRecording {
    let Some(plans) = ScriptPlan::server_readings(sql, grammar) else {
        return HistoryRecording::Withhold(WithholdReason::Untokenizable);
    };
    let mut unterminated = false;
    for plan in plans {
        let script = statements_of(sql, &plan);
        if script.unterminated {
            unterminated = true;
        } else if carries_credentials(grammar, rules, &script.statements, 0) {
            return HistoryRecording::Withhold(WithholdReason::CredentialStatement);
        }
    }
    match unterminated {
        true => HistoryRecording::Withhold(WithholdReason::Untokenizable),
        false => HistoryRecording::Record,
    }
}

fn carries_credentials(
    grammar: SqlGrammar,
    rules: &CredentialRules,
    statements: &[Vec<StatementToken<'_>>],
    depth: u8,
) -> bool {
    // A body that does not lex cleanly is text in a literal, not a
    // routine, so only the statements it does hold count.
    let body_carries = |body: &str| {
        depth < MAX_BODY_DEPTH
            && carries_credentials(grammar, rules, &lex_statements(body, grammar).statements, depth + 1)
    };
    statements.iter().any(|tokens| {
        rules.matches(grammar, tokens)
            || tokens.iter().enumerate().any(|(at, token)| match token {
                StatementToken::DollarBody(body) => body_carries(body),
                StatementToken::StringLiteral(text) if quoted_routine_body(grammar, tokens, at) => {
                    body_carries(&string_value(text))
                }
                _ => false,
            })
    })
}

/// PostgreSQL also takes a DO block or a function body as a plain
/// string: `DO 'BEGIN ... END'`, `CREATE FUNCTION f() ... AS 'SELECT 1'`.
fn quoted_routine_body(grammar: SqlGrammar, tokens: &[StatementToken<'_>], at: usize) -> bool {
    if grammar != SqlGrammar::PostgreSql {
        return false;
    }
    let before = |back: usize| at.checked_sub(back).and_then(|index| tokens.get(index));
    let is_word = |back: usize, word: &str| before(back).is_some_and(|token| token.is_word(word));
    if is_word(1, "DO") || (is_word(3, "DO") && is_word(2, "LANGUAGE")) {
        return true;
    }
    is_word(1, "AS") && defines_routine(tokens.get(..at).unwrap_or_default())
}

fn defines_routine(tokens: &[StatementToken<'_>]) -> bool {
    tokens.windows(2).any(|pair| {
        let creates = pair[0].is_word("CREATE") || pair[0].is_word("REPLACE");
        creates && (pair[1].is_word("FUNCTION") || pair[1].is_word("PROCEDURE"))
    })
}

/// The text a PostgreSQL string literal stands for: `'it''s'` and
/// `E'it\'s'` both give `it's`.
fn string_value(text: &str) -> String {
    let (escapes, quoted) = match text.strip_prefix(['E', 'e']) {
        Some(rest) => (true, rest),
        None => (false, text),
    };
    let inner = quoted
        .strip_prefix('\'')
        .and_then(|rest| rest.strip_suffix('\''))
        .unwrap_or_default();
    let mut value = String::with_capacity(inner.len());
    let mut chars = inner.chars();
    while let Some(c) = chars.next() {
        match c {
            '\'' => {
                chars.next();
                value.push('\'');
            }
            '\\' if escapes => match chars.next() {
                Some('n') => value.push('\n'),
                Some('t') => value.push('\t'),
                Some('r') => value.push('\r'),
                Some(escaped) => value.push(escaped),
                None => {}
            },
            _ => value.push(c),
        }
    }
    value
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
        carriers: &["dblink_connect", "sp_addlogin", "s3", "OPENROWSET"],
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
            "CREATE INDEX i ON s3 (id) TYPE minmax",
            "CREATE INDEX IF NOT EXISTS i ON db.s3 (id) TYPE minmax",
        ] {
            assert_eq!(classify(SqlGrammar::ClickHouse, sql), HistoryRecording::Record, "{sql}");
        }
        for (grammar, sql) in [
            (SqlGrammar::PostgreSql, "CREATE UNIQUE INDEX CONCURRENTLY i ON s3 (id)"),
            (SqlGrammar::PostgreSql, "CREATE INDEX ON s3 (id)"),
            (SqlGrammar::MySql, "CREATE UNIQUE INDEX i USING BTREE ON s3 (id)"),
            (SqlGrammar::MsSql, "CREATE UNIQUE NONCLUSTERED INDEX i ON dbo.s3 (id)"),
            (SqlGrammar::MsSql, "CREATE STATISTICS st ON s3 (id)"),
            (SqlGrammar::Sqlite, "CREATE INDEX IF NOT EXISTS main.i ON s3 (id)"),
            (SqlGrammar::Sqlite, "CREATE TABLE t (id int REFERENCES s3 (id))"),
        ] {
            assert_eq!(classify(grammar, sql), HistoryRecording::Record, "{grammar:?}: {sql}");
        }
    }

    #[test]
    fn a_carrier_in_a_condition_is_a_call() {
        for grammar in SqlGrammar::ALL {
            for sql in [
                "SELECT u.id FROM users u JOIN logins l ON dblink_connect('password=x') = l.v",
                "SELECT a.id FROM a JOIN b ON a.id = b.id AND dblink_connect('password=x') = 'OK'",
                "CREATE VIEW v AS SELECT a.id FROM a JOIN b ON dblink_connect('password=x') = b.v",
                "SELECT 1 WHERE EXISTS dblink_connect('password=x')",
                "SELECT 1 WHERE NOT EXISTS dblink_connect('password=x')",
                "CREATE TABLE t AS SELECT 1 FROM a WHERE EXISTS dblink_connect('password=x')",
                "SELECT * FROM a JOIN b ON s3('url', 'key', 'secret') = b.v",
            ] {
                assert_eq!(classify(grammar, sql), WITHHELD, "{grammar:?}: {sql}");
            }
        }
    }

    #[test]
    fn a_procedure_named_mid_batch_without_arguments_is_not_a_call() {
        assert_eq!(
            classify(SqlGrammar::MsSql, "SELECT 1\nPRINT sp_addlogin"),
            HistoryRecording::Record
        );
    }

    #[test]
    fn a_procedure_mid_batch_with_its_arguments_is_a_call() {
        for sql in [
            "SELECT 1;\nsp_addlogin 'l', 'p'",
            "SELECT 1;\nsp_addlogin",
            "SELECT 1\nsp_addlogin 'l', 'p'",
            "SELECT 1\nsp_addlogin N'l', N'p'",
            "SELECT 1\nsp_addlogin @loginame = 'l', @passwd = 'p'",
        ] {
            assert_eq!(classify(SqlGrammar::MsSql, sql), WITHHELD, "{sql}");
        }
    }

    #[test]
    fn a_reserved_carrier_is_a_call_where_a_table_name_would_go() {
        assert_eq!(
            classify(
                SqlGrammar::MsSql,
                "INSERT INTO OPENROWSET('SQLNCLI', 'Server=s;Uid=sa;Pwd=secret;', 'SELECT * FROM t') SELECT * FROM t"
            ),
            WITHHELD
        );
        assert_eq!(
            classify(SqlGrammar::MsSql, "INSERT INTO [OPENROWSET] (c) VALUES (1)"),
            HistoryRecording::Record
        );
        assert_eq!(
            classify(SqlGrammar::ClickHouse, "INSERT INTO s3 (id) VALUES (1)"),
            HistoryRecording::Record
        );
    }

    #[test]
    fn a_quoted_postgres_routine_body_is_read_for_statements() {
        for sql in [
            "DO 'BEGIN CREATE USER u PASSWORD ''p''; END'",
            "DO LANGUAGE plpgsql 'BEGIN CREATE USER u PASSWORD ''p''; END'",
            "CREATE FUNCTION f() RETURNS void AS 'SELECT dblink_connect(''password=x'')' LANGUAGE sql",
            r"CREATE OR REPLACE PROCEDURE p() LANGUAGE sql AS E'SELECT dblink_connect(\'password=x\')'",
        ] {
            assert_eq!(classify(SqlGrammar::PostgreSql, sql), WITHHELD, "{sql}");
        }
        assert_eq!(
            classify(
                SqlGrammar::PostgreSql,
                "CREATE FUNCTION f() RETURNS text AS 'SELECT ''CREATE USER u''' LANGUAGE sql"
            ),
            HistoryRecording::Record
        );
        assert_eq!(
            classify(SqlGrammar::MySql, "DO 'CREATE USER u'"),
            HistoryRecording::Record
        );
    }

    #[test]
    fn a_mysql_executable_comment_is_read() {
        for sql in [
            "/*!80000 CREATE USER u IDENTIFIED BY 'p' */",
            "SELECT 1;\n/*!80000 CREATE USER u IDENTIFIED BY 'p' */;",
            "GRANT ALL ON *.* TO u /*!50000 IDENTIFIED BY 'p' */",
            "/*M!100100 CREATE USER u IDENTIFIED BY 'p' */",
        ] {
            assert_eq!(classify(SqlGrammar::MySql, sql), WITHHELD, "{sql}");
        }
        assert_eq!(
            classify(SqlGrammar::MySql, "SELECT 1 /* CREATE USER u */"),
            HistoryRecording::Record
        );
        assert_eq!(
            classify(SqlGrammar::PostgreSql, "SELECT 1 /*! CREATE USER u */"),
            HistoryRecording::Record
        );
    }

    #[test]
    fn a_credential_any_server_reading_runs_is_withheld() {
        for sql in [
            "SELECT 1 /*!, '*/'; CREATE USER u IDENTIFIED BY 'p'; SELECT ' */",
            "SELECT 1 /*!50000 # */ '\n; CREATE USER u IDENTIFIED BY 'p'; -- '\n*/",
            // A server older than 99999 skips the comment past its nested
            // `/* */`, so the CREATE USER after it runs.
            "SELECT 1 /*!99999 /* */ ' */ ; CREATE USER u IDENTIFIED BY 'p'; -- ' */",
            // Split again at its DELIMITER line, the last line goes alone.
            "SELECT 1;\nDELIMITER ; /*!99999 '*/ `' */\nSELECT 1 /*!99999 ' */ ; CREATE USER u IDENTIFIED BY 'p'; -- ` ' */",
            // Under NO_BACKSLASH_ESCAPES the first string ends at `\'`.
            r"INSERT INTO paths VALUES ('C:\temp\'); CREATE USER u IDENTIFIED BY 'p'; -- it's done",
        ] {
            assert_ne!(classify(SqlGrammar::MySql, sql), HistoryRecording::Record, "{sql}");
        }
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
