use std::num::NonZeroU32;

use proptest::prelude::*;
use sqlparser::dialect::{ClickHouseDialect, Dialect, MsSqlDialect, MySqlDialect, PostgreSqlDialect, SQLiteDialect};
use sqlparser::tokenizer::{Token, Tokenizer, TokenizerError};
use tablepro_core::sql_syntax::SqlGrammar;
use tablepro_core::sql_syntax::script::{
    BatchErrorPolicy, LexicalSettings, OpenConstruct, ScriptDiagnostic, ScriptPlan, ScriptTokenKind, text_offsets,
};

fn plan(grammar: SqlGrammar, text: &str) -> ScriptPlan {
    ScriptPlan::build(text, grammar, LexicalSettings::default_for(grammar))
}

fn statements(grammar: SqlGrammar, text: &str) -> Vec<&str> {
    plan(grammar, text)
        .statements()
        .iter()
        .map(|statement| statement.text(text))
        .collect()
}

fn batch_texts<'a>(plan: &ScriptPlan, text: &'a str) -> Vec<&'a str> {
    plan.batches()
        .iter()
        .map(|batch| text.get(batch.range.clone()).unwrap_or_default())
        .collect()
}

#[test]
fn dollar_quoted_body_hides_semicolons() {
    let text = "CREATE FUNCTION f() RETURNS int AS $$ SELECT 1; SELECT 2; $$ LANGUAGE sql;\nSELECT 3;";
    let plan = plan(SqlGrammar::PostgreSql, text);
    let first = &plan.statements()[0];
    assert_eq!(first.range, 0..73);
    assert_eq!(first.extent, 0..74);
    assert_eq!(
        statements(SqlGrammar::PostgreSql, text),
        [
            "CREATE FUNCTION f() RETURNS int AS $$ SELECT 1; SELECT 2; $$ LANGUAGE sql",
            "SELECT 3"
        ]
    );
}

#[test]
fn tagged_dollar_quote_with_inner_double_dollar() {
    let text = "DO $body$ BEGIN RAISE NOTICE '$$;'; END $body$;\nSELECT 1;";
    assert_eq!(
        statements(SqlGrammar::PostgreSql, text),
        ["DO $body$ BEGIN RAISE NOTICE '$$;'; END $body$", "SELECT 1"]
    );
}

#[test]
fn identifier_with_dollar_is_not_a_quote() {
    let text = "SELECT a$b$c FROM t; SELECT $1;";
    assert_eq!(
        statements(SqlGrammar::PostgreSql, text),
        ["SELECT a$b$c FROM t", "SELECT $1"]
    );
}

#[test]
fn escape_string_backslash_quote() {
    let text = r"SELECT E'it\'s; fine'; SELECT 2;";
    assert_eq!(
        statements(SqlGrammar::PostgreSql, text),
        [r"SELECT E'it\'s; fine'", "SELECT 2"]
    );
}

#[test]
fn backslash_plain_string_when_enabled_vs_disabled() {
    let text = r"SELECT 'a\'; SELECT 'b';";
    assert_eq!(statements(SqlGrammar::PostgreSql, text), [r"SELECT 'a\'", "SELECT 'b'"]);

    let enabled = ScriptPlan::build(
        text,
        SqlGrammar::PostgreSql,
        LexicalSettings {
            backslash_escapes: true,
        },
    );
    assert_eq!(enabled.statements().len(), 1);
    assert_eq!(
        enabled.diagnostics(),
        [ScriptDiagnostic::Unterminated {
            construct: OpenConstruct::StringLiteral,
            start: 22,
        }]
    );
}

#[test]
fn nested_block_comment() {
    let text = "SELECT /* outer /* inner; */ still; */ 1; SELECT 2;";
    assert_eq!(
        statements(SqlGrammar::PostgreSql, text),
        ["SELECT /* outer /* inner; */ still; */ 1", "SELECT 2"]
    );
}

#[test]
fn routine_begin_atomic_block_is_one_statement() {
    let text = "CREATE FUNCTION add(a int, b int) RETURNS int LANGUAGE sql\nBEGIN ATOMIC\n  SELECT 1;\n  SELECT a + b;\nEND;\nSELECT 2;";
    assert_eq!(
        statements(SqlGrammar::PostgreSql, text),
        [
            "CREATE FUNCTION add(a int, b int) RETURNS int LANGUAGE sql\nBEGIN ATOMIC\n  SELECT 1;\n  SELECT a + b;\nEND",
            "SELECT 2"
        ]
    );
}

#[test]
fn routine_case_end_inside_body() {
    let text = "CREATE OR REPLACE PROCEDURE p() LANGUAGE sql BEGIN ATOMIC SELECT CASE WHEN true THEN 1 ELSE 2 END; END; SELECT 3;";
    assert_eq!(
        statements(SqlGrammar::PostgreSql, text),
        [
            "CREATE OR REPLACE PROCEDURE p() LANGUAGE sql BEGIN ATOMIC SELECT CASE WHEN true THEN 1 ELSE 2 END; END",
            "SELECT 3"
        ]
    );
}

#[test]
fn begin_column_outside_routine_is_identifier() {
    let text = "SELECT begin, end FROM spans; SELECT 2;";
    assert_eq!(
        statements(SqlGrammar::PostgreSql, text),
        ["SELECT begin, end FROM spans", "SELECT 2"]
    );
}

#[test]
fn transaction_begin_is_not_a_block() {
    let text = "BEGIN; UPDATE t SET x = 1; COMMIT;";
    assert_eq!(
        statements(SqlGrammar::PostgreSql, text),
        ["BEGIN", "UPDATE t SET x = 1", "COMMIT"]
    );
}

#[test]
fn parenthesised_rule_actions_are_one_statement() {
    let text =
        "CREATE RULE r AS ON INSERT TO t DO ALSO (INSERT INTO a VALUES (1); INSERT INTO b VALUES (2)); SELECT 3;";
    assert_eq!(
        statements(SqlGrammar::PostgreSql, text),
        [
            "CREATE RULE r AS ON INSERT TO t DO ALSO (INSERT INTO a VALUES (1); INSERT INTO b VALUES (2))",
            "SELECT 3"
        ]
    );
}

#[test]
fn procedure_with_delimiter_dollar_dollar_plans_three_batches() {
    let text =
        "DELIMITER $$\nCREATE PROCEDURE p()\nBEGIN\n  SELECT 1;\n  SELECT 2;\nEND$$\nDELIMITER ;\nCALL p();\nSELECT 3;";
    let plan = plan(SqlGrammar::MySql, text);
    assert_eq!(
        batch_texts(&plan, text),
        [
            "CREATE PROCEDURE p()\nBEGIN\n  SELECT 1;\n  SELECT 2;\nEND",
            "CALL p()",
            "SELECT 3"
        ]
    );
    let directives = plan
        .tokens(0..text.len())
        .filter(|token| token.kind == ScriptTokenKind::Directive)
        .count();
    assert_eq!(directives, 2);
}

#[test]
fn delimiter_double_slash() {
    let text = "DELIMITER //\nSELECT 1; SELECT 2//\nDELIMITER ;\n";
    assert_eq!(statements(SqlGrammar::MySql, text), ["SELECT 1; SELECT 2"]);
}

#[test]
fn procedure_without_delimiter_splits_like_mysql_client() {
    let text = "CREATE PROCEDURE p() BEGIN SELECT 1; END; SELECT 2;";
    assert_eq!(
        statements(SqlGrammar::MySql, text),
        ["CREATE PROCEDURE p() BEGIN SELECT 1", "END", "SELECT 2"]
    );
}

#[test]
fn hash_comment_hides_semicolon() {
    let text = "SELECT 1 # not; a split\n, 2;\nSELECT 3;";
    assert_eq!(
        statements(SqlGrammar::MySql, text),
        ["SELECT 1 # not; a split\n, 2", "SELECT 3"]
    );
}

#[test]
fn double_dash_needs_whitespace() {
    let text = "SELECT 1--1;\nSELECT 2 -- comment; x\n;";
    assert_eq!(statements(SqlGrammar::MySql, text), ["SELECT 1--1", "SELECT 2"]);
}

#[test]
fn backtick_identifier_with_semicolon() {
    let text = "SELECT `a;b` FROM t; SELECT 2;";
    assert_eq!(statements(SqlGrammar::MySql, text), ["SELECT `a;b` FROM t", "SELECT 2"]);
}

#[test]
fn backslash_escaped_quote() {
    let text = r"SELECT 'it\'s; fine'; SELECT 2;";
    assert_eq!(
        statements(SqlGrammar::MySql, text),
        [r"SELECT 'it\'s; fine'", "SELECT 2"]
    );
}

#[test]
fn trigger_body_ends_at_semicolon_end_semicolon() {
    let text = "CREATE TRIGGER t AFTER INSERT ON a BEGIN\n  INSERT INTO log VALUES (1);\n  UPDATE a SET n = n + 1;\nEND;\nSELECT 1;";
    assert_eq!(
        statements(SqlGrammar::Sqlite, text),
        [
            "CREATE TRIGGER t AFTER INSERT ON a BEGIN\n  INSERT INTO log VALUES (1);\n  UPDATE a SET n = n + 1;\nEND",
            "SELECT 1"
        ]
    );
}

#[test]
fn trigger_case_end_inside_body() {
    let text = "CREATE TEMP TRIGGER t AFTER INSERT ON a BEGIN SELECT CASE WHEN 1 THEN 2 END; END; SELECT 3;";
    assert_eq!(
        statements(SqlGrammar::Sqlite, text),
        [
            "CREATE TEMP TRIGGER t AFTER INSERT ON a BEGIN SELECT CASE WHEN 1 THEN 2 END; END",
            "SELECT 3"
        ]
    );
}

#[test]
fn bracket_identifier_without_doubling() {
    let text = "SELECT [a;b] FROM t; SELECT [x]]; SELECT 2;";
    assert_eq!(
        statements(SqlGrammar::Sqlite, text),
        ["SELECT [a;b] FROM t", "SELECT [x]]", "SELECT 2"]
    );
}

#[test]
fn go_count_repeats_batch() {
    let text = "INSERT INTO t VALUES (1)\nGO 3\nSELECT COUNT(*) FROM t\ngo\n";
    let plan = plan(SqlGrammar::MsSql, text);
    assert_eq!(
        batch_texts(&plan, text),
        ["INSERT INTO t VALUES (1)", "SELECT COUNT(*) FROM t"]
    );
    let repeats: Vec<u32> = plan.batches().iter().map(|batch| batch.repeat.get()).collect();
    assert_eq!(repeats, [3, 1]);
    assert_eq!(plan.batches()[1].repeat, NonZeroU32::MIN);
    assert_eq!(plan.batch_error_policy(), BatchErrorPolicy::ContinueNextBatch);
}

#[test]
fn go_semicolon_is_not_separator() {
    let text = "SELECT 1\nGO;\nSELECT 2";
    assert_eq!(statements(SqlGrammar::MsSql, text), ["SELECT 1\nGO;\nSELECT 2"]);
}

#[test]
fn go_inside_string_is_not_separator() {
    let text = "SELECT 'a\nGO\nb'\nGO\nSELECT 2";
    assert_eq!(statements(SqlGrammar::MsSql, text), ["SELECT 'a\nGO\nb'", "SELECT 2"]);
}

#[test]
fn bracket_identifier_with_doubling() {
    let text = "SELECT [a]]\nGO\nb] FROM t\nGO\nSELECT 2";
    assert_eq!(
        statements(SqlGrammar::MsSql, text),
        ["SELECT [a]]\nGO\nb] FROM t", "SELECT 2"]
    );
}

#[test]
fn heredoc_hides_semicolon() {
    let text = "SELECT $doc$a; b$doc$; SELECT 2;";
    assert_eq!(
        statements(SqlGrammar::ClickHouse, text),
        ["SELECT $doc$a; b$doc$", "SELECT 2"]
    );
}

#[test]
fn slash_slash_comment_hides_semicolon() {
    let text = "SELECT 1 // it's; a comment\n, 2; SELECT 3;";
    assert_eq!(
        statements(SqlGrammar::ClickHouse, text),
        ["SELECT 1 // it's; a comment\n, 2", "SELECT 3"]
    );
}

#[test]
fn hash_space_comment() {
    let text = "#!/usr/bin/env clickhouse-client\nSELECT 1 # it's; hidden\n; SELECT 2;";
    assert_eq!(statements(SqlGrammar::ClickHouse, text), ["SELECT 1", "SELECT 2"]);
}

#[test]
fn hash_word_is_not_comment() {
    let text = "SELECT #word; SELECT 2;";
    assert_eq!(statements(SqlGrammar::ClickHouse, text), ["SELECT #word", "SELECT 2"]);
}

#[test]
fn backslash_always_escapes() {
    let text = r"SELECT 'a\'; b'; SELECT 2;";
    assert_eq!(
        statements(SqlGrammar::ClickHouse, text),
        [r"SELECT 'a\'; b'", "SELECT 2"]
    );
}

#[test]
fn statement_at_on_terminator_takes_preceding() {
    let text = "SELECT 1;SELECT 2;";
    let plan = plan(SqlGrammar::PostgreSql, text);
    let text_at = |byte| plan.statement_at(byte).map(|statement| statement.text(text));
    assert_eq!(text_at(8), Some("SELECT 1"));
    assert_eq!(text_at(9), Some("SELECT 2"));
    assert_eq!(text_at(18), Some("SELECT 2"));
}

#[test]
fn statement_at_in_trailing_whitespace_line() {
    let text = "SELECT 1; -- one\n   \nSELECT 2;";
    let plan = plan(SqlGrammar::PostgreSql, text);
    assert_eq!(plan.statements()[0].extent, 0..16);
    assert_eq!(
        plan.statement_at(18).map(|statement| statement.text(text)),
        Some("SELECT 1")
    );
}

#[test]
fn unterminated_dollar_quote_reports_diagnostic_and_keeps_prior_statements() {
    let text = "SELECT 1; SELECT $$abc; SELECT 2;";
    let plan = plan(SqlGrammar::PostgreSql, text);
    assert_eq!(
        statements(SqlGrammar::PostgreSql, text),
        ["SELECT 1", "SELECT $$abc; SELECT 2;"]
    );
    assert_eq!(
        plan.diagnostics(),
        [ScriptDiagnostic::Unterminated {
            construct: OpenConstruct::DollarQuoted,
            start: 17,
        }]
    );
}

#[test]
fn char_byte_roundtrip_multibyte() {
    let text = "SELECT 'é😀'; SELECT 2;";
    let chars = text.chars().count();
    for index in 0..=chars {
        assert_eq!(
            text_offsets::byte_to_char(text, text_offsets::char_to_byte(text, index)),
            index
        );
    }
    assert_eq!(text_offsets::char_to_byte(text, 10), 14);
    let plan = plan(SqlGrammar::PostgreSql, text);
    let second = &plan.statements()[1];
    assert_eq!(text_offsets::byte_to_char(text, second.range.start), 13);
}

proptest! {
    #[test]
    fn ranges_on_char_boundaries_and_batches_disjoint(
        text in "[ -~\n\té😀]{0,160}",
        backslash_escapes in any::<bool>(),
    ) {
        for grammar in SqlGrammar::ALL {
            let plan = ScriptPlan::build(&text, grammar, LexicalSettings { backslash_escapes });
            let mut cursor = 0;
            for token in plan.tokens(0..text.len()) {
                prop_assert_eq!(token.range.start, cursor);
                prop_assert!(token.range.end > token.range.start);
                prop_assert!(text.is_char_boundary(token.range.end));
                cursor = token.range.end;
            }
            prop_assert_eq!(cursor, text.len());

            let mut previous_end = 0;
            for batch in plan.batches() {
                prop_assert!(batch.range.start >= previous_end);
                prop_assert!(batch.range.start < batch.range.end);
                prop_assert!(text.is_char_boundary(batch.range.start) && text.is_char_boundary(batch.range.end));
                previous_end = batch.range.end;
            }
            for statement in plan.statements() {
                prop_assert!(statement.range.start < statement.range.end);
                prop_assert!(statement.range.end <= statement.extent.end);
                prop_assert!(statement.extent.end <= text.len());
                prop_assert!(text.is_char_boundary(statement.extent.end));
            }
        }
    }
}

const AGREED_CASES: &[(SqlGrammar, &str)] = &[
    (
        SqlGrammar::PostgreSql,
        "CREATE FUNCTION f() RETURNS int AS $$ SELECT 1; $$ LANGUAGE sql; SELECT 3;",
    ),
    (
        SqlGrammar::PostgreSql,
        "DO $body$ BEGIN RAISE NOTICE '$$;'; END $body$;\nSELECT 1;",
    ),
    (SqlGrammar::PostgreSql, "SELECT a$b$c FROM t; SELECT $1;"),
    (SqlGrammar::PostgreSql, r"SELECT E'it\'s; fine'; SELECT 'x''y;';"),
    (
        SqlGrammar::PostgreSql,
        "SELECT /* outer /* inner; */ still; */ 1; SELECT \"a;b\";",
    ),
    (SqlGrammar::PostgreSql, "BEGIN; UPDATE t SET x = 1; -- done;\nCOMMIT;"),
    (SqlGrammar::MySql, "SELECT 1--1;\nSELECT 2 -- comment; x\n;"),
    (SqlGrammar::MySql, "SELECT `a;b` FROM t; SELECT 1 # not; a split\n;"),
    (SqlGrammar::MySql, r"SELECT 'it\'s; fine', 'a;b'; SELECT 2;"),
    (SqlGrammar::Sqlite, "SELECT [a;b], \"c;d\", `e;f` FROM t; SELECT 'g;h';"),
    (
        SqlGrammar::Sqlite,
        "CREATE TRIGGER t AFTER INSERT ON a BEGIN SELECT 1; END; SELECT 2;",
    ),
    (
        SqlGrammar::MsSql,
        "SELECT [a]]b;c] FROM t; SELECT N'x;y'; /* a /* b; */ c; */ SELECT 2;",
    ),
    (SqlGrammar::ClickHouse, "SELECT $doc$a; b$doc$; SELECT 2;"),
    (SqlGrammar::ClickHouse, r"SELECT 'a\'; b', `c;d` FROM t; SELECT 2;"),
];

fn byte_offset(text: &str, line: u64, column: u64) -> usize {
    let (mut current_line, mut current_column) = (1, 1);
    for (index, ch) in text.char_indices() {
        if current_line == line && current_column == column {
            return index;
        }
        if ch == '\n' {
            current_line += 1;
            current_column = 1;
        } else {
            current_column += 1;
        }
    }
    text.len()
}

fn sqlparser_semicolons(grammar: SqlGrammar, text: &str) -> Result<Vec<usize>, TokenizerError> {
    let dialect: &dyn Dialect = match grammar {
        SqlGrammar::PostgreSql => &PostgreSqlDialect {},
        SqlGrammar::MySql => &MySqlDialect {},
        SqlGrammar::Sqlite => &SQLiteDialect {},
        SqlGrammar::MsSql => &MsSqlDialect {},
        SqlGrammar::ClickHouse => &ClickHouseDialect {},
    };
    let tokens = Tokenizer::new(dialect, text)
        .with_unescape(false)
        .tokenize_with_location()?;
    Ok(tokens
        .iter()
        .filter(|token| token.token == Token::SemiColon)
        .map(|token| byte_offset(text, token.span.start.line, token.span.start.column))
        .collect())
}

#[test]
fn lexer_matches_sqlparser_where_engines_agree() {
    for (grammar, text) in AGREED_CASES {
        let ours: Vec<usize> = plan(*grammar, text)
            .tokens(0..text.len())
            .filter(|token| token.kind == ScriptTokenKind::Semicolon)
            .map(|token| token.range.start)
            .collect();
        let theirs = sqlparser_semicolons(*grammar, text).unwrap();
        assert_eq!(ours, theirs, "{grammar:?} {text:?}");
    }
}
