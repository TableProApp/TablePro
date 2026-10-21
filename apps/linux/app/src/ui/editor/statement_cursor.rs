use tablepro_core::sql_syntax::SqlGrammar;
use tablepro_core::sql_syntax::script::{BatchErrorPolicy, LexicalSettings, ScriptPlan};

pub fn grammar_for(driver: &str) -> Option<SqlGrammar> {
    match driver {
        "postgres" => Some(SqlGrammar::PostgreSql),
        "mysql" => Some(SqlGrammar::MySql),
        "sqlite" => Some(SqlGrammar::Sqlite),
        "mssql" => Some(SqlGrammar::MsSql),
        "clickhouse" => Some(SqlGrammar::ClickHouse),
        "duckdb" => Some(SqlGrammar::PostgreSql),
        _ => None,
    }
}

#[derive(Debug, Clone, Copy)]
pub struct Lexing<'a> {
    pub driver: &'a str,
    pub settings: Option<LexicalSettings>,
}

impl<'a> From<&'a str> for Lexing<'a> {
    fn from(driver: &'a str) -> Self {
        Self { driver, settings: None }
    }
}

impl Lexing<'_> {
    pub fn settings_for(&self, grammar: SqlGrammar) -> LexicalSettings {
        self.settings.unwrap_or_else(|| LexicalSettings::default_for(grammar))
    }

    fn plan(&self, text: &str) -> Option<ScriptPlan> {
        let grammar = grammar_for(self.driver)?;
        Some(ScriptPlan::build(text, grammar, self.settings_for(grammar)))
    }
}

pub fn cursor_byte_offset(text: &str, character_offset: usize) -> usize {
    text.chars().take(character_offset).map(char::len_utf8).sum()
}

#[derive(Debug, Clone)]
pub struct PlannedStatements {
    pub statements: Vec<String>,
    pub error_policy: BatchErrorPolicy,
    pub settings_check: Option<LexicalSettings>,
}

pub fn script_statements<'a>(text: &str, lexing: impl Into<Lexing<'a>>) -> Result<PlannedStatements, String> {
    let lexing = lexing.into();
    let Some(grammar) = grammar_for(lexing.driver) else {
        return Ok(PlannedStatements {
            statements: tablepro_core::sql_lex::split_statements(text, lexing.driver),
            error_policy: BatchErrorPolicy::StopScript,
            settings_check: None,
        });
    };
    let settings = lexing.settings_for(grammar);
    let plan = ScriptPlan::build(text, grammar, settings);
    if !plan.diagnostics().is_empty() {
        return Err(crate::tr!("The script contains an unterminated quote or comment."));
    }
    if plan.batches().iter().any(|batch| batch.repeat.get() != 1) {
        return Err(crate::tr!(
            "GO repetition is not supported. Expand repeated batches explicitly before running."
        ));
    }
    let statements: Vec<String> = plan
        .statements()
        .iter()
        .map(|statement| statement.text(text).trim().to_owned())
        .filter(|statement| !statement.is_empty())
        .collect();
    let settings_dependent = statements.len() > 1
        && LexicalSettings::ALL
            .iter()
            .any(|other| ScriptPlan::build(text, grammar, *other).statements() != plan.statements());
    Ok(PlannedStatements {
        statements,
        error_policy: plan.batch_error_policy(),
        settings_check: settings_dependent.then_some(settings),
    })
}

pub fn statement_at_cursor<'a>(text: &str, lexing: impl Into<Lexing<'a>>, byte: usize) -> Option<String> {
    let lexing = lexing.into();
    let Some(plan) = lexing.plan(text) else {
        return tablepro_core::sql_lex::statement_at_cursor(text, lexing.driver, byte);
    };
    let statement = plan.statement_at(byte)?;
    let affected = plan.diagnostics().iter().any(|diagnostic| {
        let tablepro_core::sql_syntax::script::ScriptDiagnostic::Unterminated { start, .. } = diagnostic;
        statement.range.contains(start)
    });
    if affected {
        return None;
    }
    Some(statement.text(text).trim().to_owned())
}

pub fn statement_range_at<'a>(
    text: &str,
    lexing: impl Into<Lexing<'a>>,
    byte: usize,
) -> Option<std::ops::Range<usize>> {
    let plan = lexing.into().plan(text)?;
    let statement = plan.statement_at(byte)?;
    let unterminated = plan.diagnostics().iter().any(|diagnostic| {
        let tablepro_core::sql_syntax::script::ScriptDiagnostic::Unterminated { start, .. } = diagnostic;
        statement.range.contains(start)
    });
    if unterminated {
        return None;
    }
    let body = statement.text(text);
    let leading = body.len() - body.trim_start().len();
    let trimmed = body.trim();
    (!trimmed.is_empty()).then(|| statement.range.start + leading..statement.range.start + leading + trimmed.len())
}

pub fn adjacent_statement_start<'a>(
    text: &str,
    lexing: impl Into<Lexing<'a>>,
    byte: usize,
    forward: bool,
) -> Option<usize> {
    let plan = lexing.into().plan(text)?;
    let mut starts = plan.statements().iter().filter_map(|statement| {
        let body = statement.text(text);
        let trimmed = body.trim_start();
        (!trimmed.trim_end().is_empty()).then(|| statement.range.start + body.len() - trimmed.len())
    });
    if forward {
        starts.find(|start| *start > byte)
    } else {
        starts.rfind(|start| *start < byte)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn plan_for(text: &str, grammar: SqlGrammar) -> ScriptPlan {
        ScriptPlan::build(text, grammar, LexicalSettings::default_for(grammar))
    }

    fn postgres_without_standard_strings() -> Lexing<'static> {
        Lexing {
            driver: "postgres",
            settings: LexicalSettings::from_postgres_standard_conforming_strings("off"),
        }
    }

    #[test]
    fn run_all_splits_with_the_session_settings_instead_of_the_grammar_defaults() {
        let sql = r"SELECT 'path\'; SELECT 2;";
        assert!(script_statements(sql, "mysql").is_err());
        let planned = script_statements(
            sql,
            Lexing {
                driver: "mysql",
                settings: Some(LexicalSettings::from_mysql_sql_mode("NO_BACKSLASH_ESCAPES")),
            },
        )
        .unwrap();
        assert_eq!(planned.statements, [r"SELECT 'path\'", "SELECT 2"]);
        assert_eq!(
            planned.settings_check,
            Some(LexicalSettings::from_mysql_sql_mode("NO_BACKSLASH_ESCAPES"))
        );

        let planned = script_statements(r"SELECT '東京\'s'; SELECT 2", postgres_without_standard_strings()).unwrap();
        assert_eq!(planned.statements, [r"SELECT '東京\'s'", "SELECT 2"]);
    }

    #[test]
    fn a_script_that_splits_the_same_under_every_setting_needs_no_check() {
        let planned = script_statements("SELECT 'plain'; SELECT \"name\"", "mysql").unwrap();
        assert_eq!(planned.settings_check, None);
        assert_eq!(script_statements("SELECT 1", "mysql").unwrap().settings_check, None);
    }

    #[test]
    fn run_current_statement_uses_the_session_settings_at_a_unicode_cursor() {
        let sql = r"SELECT '東京\'s'; SELECT 'ü' AS second";
        let lexing = postgres_without_standard_strings();
        let second = sql.find("'ü'").unwrap() + "'ü".len();
        assert_eq!(
            statement_at_cursor(sql, lexing, second).as_deref(),
            Some("SELECT 'ü' AS second")
        );
        assert_eq!(
            statement_at_cursor(sql, lexing, sql.find("京").unwrap()).as_deref(),
            Some(r"SELECT '東京\'s'")
        );
        assert_eq!(statement_at_cursor(sql, "postgres", second), None);
        let character_offset = sql[..second].chars().count();
        assert_eq!(
            statement_range_at(sql, lexing, cursor_byte_offset(sql, character_offset)).map(|range| &sql[range]),
            Some("SELECT 'ü' AS second")
        );
    }

    #[test]
    fn formatting_with_the_session_settings_keeps_each_statement() {
        let sql = r"select '東京\'s' from t; select 2";
        let lexing = postgres_without_standard_strings();
        let settings = lexing.settings_for(SqlGrammar::PostgreSql);
        let formatted = tablepro_core::sql_format::format_script(sql, SqlGrammar::PostgreSql, settings);
        let planned = script_statements(&formatted, lexing).unwrap();
        assert_eq!(planned.statements.len(), 2, "{formatted}");
        assert!(formatted.contains(r"'東京\'s'"), "{formatted}");
    }

    #[test]
    fn a_mysql_double_dash_without_a_space_is_subtraction_not_a_comment() {
        let planned = script_statements("SELECT 5--2; SELECT 1", "mysql").unwrap();
        assert_eq!(planned.statements, ["SELECT 5--2", "SELECT 1"]);
        let commented = script_statements("SELECT 5-- 2; SELECT 1\nSELECT 3", "mysql").unwrap();
        assert_eq!(commented.statements, ["SELECT 5-- 2; SELECT 1\nSELECT 3"]);
    }

    #[test]
    fn jumping_moves_to_the_start_of_the_next_and_previous_statement() {
        let sql = "SELECT 1;
  SELECT 2;

SELECT 3";
        let second = sql.find("SELECT 2").unwrap();
        let third = sql.find("SELECT 3").unwrap();
        assert_eq!(adjacent_statement_start(sql, "postgres", 0, true), Some(second));
        assert_eq!(adjacent_statement_start(sql, "postgres", second, true), Some(third));
        assert_eq!(adjacent_statement_start(sql, "postgres", third, true), None);
        assert_eq!(adjacent_statement_start(sql, "postgres", third, false), Some(second));
        assert_eq!(
            adjacent_statement_start(sql, "postgres", second + 3, false),
            Some(second)
        );
        assert_eq!(adjacent_statement_start(sql, "postgres", 0, false), None);
    }

    #[test]
    fn the_statement_range_covers_the_trimmed_statement_under_the_cursor() {
        let sql = "SELECT 1;\n  SELECT '東京' ;\nSELECT 3";
        let start = sql.find("SELECT '東京'").unwrap();
        let range = statement_range_at(sql, "postgres", start + 4).unwrap();
        assert_eq!(&sql[range], "SELECT '東京'");
        assert_eq!(statement_range_at("SELECT 'open", "postgres", 3), None);
        assert_eq!(statement_range_at("SELECT 1", "redis", 1), None);
    }

    #[test]
    fn jumping_ignores_empty_statements_and_engines_without_a_grammar() {
        let sql = "SELECT 1;;;
SELECT 2";
        let second = sql.find("SELECT 2").unwrap();
        assert_eq!(adjacent_statement_start(sql, "postgres", 0, true), Some(second));
        assert_eq!(adjacent_statement_start(sql, "redis", 0, true), None);
    }

    #[test]
    fn dialect_boundaries_and_unicode_cursor_are_preserved() {
        let sql = "CREATE FUNCTION f() RETURNS int AS $$ SELECT 1; SELECT 2; $$ LANGUAGE sql; SELECT '東京'";
        let planned = script_statements(sql, "postgres").unwrap();
        assert_eq!(planned.statements.len(), 2);
        assert_eq!(planned.error_policy, BatchErrorPolicy::StopScript);
        assert_eq!(
            statement_at_cursor(sql, "postgres", sql.find("東京").unwrap()),
            Some("SELECT '東京'".into())
        );
        let mssql_planned = script_statements("SELECT 1; SELECT 2\nGO\nSELECT 3", "mssql").unwrap();
        assert_eq!(mssql_planned.statements, vec!["SELECT 1; SELECT 2", "SELECT 3"]);
        assert_eq!(mssql_planned.error_policy, BatchErrorPolicy::ContinueNextBatch);
        assert_eq!(
            script_statements(
                "DELIMITER $$\nCREATE PROCEDURE p() BEGIN SELECT 1; END$$\nDELIMITER ;",
                "mysql"
            )
            .unwrap()
            .statements,
            vec!["CREATE PROCEDURE p() BEGIN SELECT 1; END"]
        );
        assert!(script_statements("SELECT 1\nGO 2", "mssql").is_err());
        assert!(script_statements("SELECT 'unfinished", "postgres").is_err());
    }

    #[test]
    fn gtk_character_offset_after_multibyte_text_selects_the_following_statement() {
        let sql = "SELECT '東京'; SELECT 2";
        let expected_byte = sql.find("SELECT 2").unwrap();
        let character_offset = sql[..expected_byte].chars().count();
        let cursor_byte = cursor_byte_offset(sql, character_offset);

        assert_eq!(cursor_byte, expected_byte);
        assert!(cursor_byte > character_offset);
        assert_eq!(
            statement_at_cursor(sql, "postgres", character_offset),
            Some("SELECT '東京'".into())
        );
        assert_eq!(
            statement_at_cursor(sql, "postgres", cursor_byte),
            Some("SELECT 2".into())
        );
    }

    #[test]
    fn only_mssql_go_batches_continue_after_an_error() {
        for driver in ["postgres", "mysql", "sqlite", "clickhouse"] {
            assert_eq!(
                script_statements("SELECT 1", driver).unwrap().error_policy,
                BatchErrorPolicy::StopScript,
                "{driver}"
            );
        }
        assert_eq!(
            script_statements("SELECT 1", "mssql").unwrap().error_policy,
            BatchErrorPolicy::ContinueNextBatch
        );
        assert_eq!(
            script_statements("SELECT 1", "an-unknown-driver").unwrap().error_policy,
            BatchErrorPolicy::StopScript
        );
    }

    #[test]
    fn an_unterminated_construct_elsewhere_does_not_block_a_clean_statement_at_the_cursor() {
        let sql = "SELECT 1; SELECT 'unfinished";
        assert_eq!(
            statement_at_cursor(sql, "postgres", sql.find("SELECT 1").unwrap()),
            Some("SELECT 1".into())
        );
        assert_eq!(
            statement_at_cursor(sql, "postgres", sql.find("'unfinished").unwrap()),
            None
        );
    }

    #[test]
    fn malformed_tail_is_not_accepted_as_a_valid_script_prefix() {
        let sql = "SELECT :safe; SELECT 'unfinished :tail";
        let grammar = SqlGrammar::PostgreSql;
        let plan = plan_for(sql, grammar);

        assert!(!plan.diagnostics().is_empty());
        assert_eq!(plan.statements().len(), 2);
        assert!(script_statements(sql, "postgres").is_err());

        let parameters = tablepro_core::extract_named_parameters(sql, "postgres");
        assert_eq!(parameters.names, ["safe"]);
        assert!(parameters.sql.ends_with("SELECT 'unfinished :tail"));

        let formatted = tablepro_core::sql_format::format_script(sql, grammar, LexicalSettings::default_for(grammar));
        assert!(formatted.ends_with("SELECT 'unfinished :tail"));
        assert!(!plan_for(&formatted, grammar).diagnostics().is_empty());

        let facts = tablepro_policy::classify(sql, "postgres");
        assert_eq!(facts.class, tablepro_policy::StatementClass::Unparseable);
        assert!(facts.writes());
    }

    #[test]
    fn value_contract_postgres_malformed_dollar_quote_blocks_every_script_consumer() {
        let sql = "SELECT :safe AS value; SELECT $tag$unfinished :tail; SELECT :after AS value";
        let grammar = SqlGrammar::PostgreSql;
        let plan = plan_for(sql, grammar);

        assert!(!plan.diagnostics().is_empty());
        assert_eq!(plan.statements().len(), 2);
        assert!(script_statements(sql, "postgres").is_err());
        assert_eq!(
            statement_at_cursor(sql, "postgres", sql.find(":safe").unwrap()),
            Some("SELECT :safe AS value".into())
        );
        assert_eq!(statement_at_cursor(sql, "postgres", sql.find("$tag$").unwrap()), None);

        let parameters = tablepro_core::extract_named_parameters(sql, "postgres");
        assert_eq!(parameters.names, ["safe"]);
        assert!(
            parameters
                .sql
                .ends_with("SELECT $tag$unfinished :tail; SELECT :after AS value")
        );

        let formatted = tablepro_core::sql_format::format_script(sql, grammar, LexicalSettings::default_for(grammar));
        assert!(formatted.ends_with("$tag$unfinished :tail; SELECT :after AS value"));
        assert!(!plan_for(&formatted, grammar).diagnostics().is_empty());

        let facts = tablepro_policy::classify(sql, "postgres");
        assert_eq!(facts.class, tablepro_policy::StatementClass::Unparseable);
        assert!(facts.writes());
        let decision = tablepro_policy::evaluate(
            &tablepro_policy::Principal::Agent {
                token: "test".into(),
                client: None,
                model: None,
            },
            tablepro_core::Environment::Local,
            &facts,
            false,
            &tablepro_policy::PolicyConfig::default().for_environment(tablepro_core::Environment::Local),
            None,
        );
        assert!(matches!(
            decision,
            tablepro_policy::Decision::Deny { ref rule, .. } if rule == "fail_closed_unparseable"
        ));
    }

    #[test]
    fn value_contract_sqlite_malformed_tail_blocks_all_script_consumers() {
        let sql = "SELECT :safe AS value; SELECT 'unfinished :tail; SELECT :after AS value";
        let grammar = SqlGrammar::Sqlite;
        let plan = plan_for(sql, grammar);

        assert!(!plan.diagnostics().is_empty());
        assert!(script_statements(sql, "sqlite").is_err());
        assert_eq!(
            statement_at_cursor(sql, "sqlite", sql.find(":safe").unwrap()),
            Some("SELECT :safe AS value".into())
        );
        assert_eq!(
            statement_at_cursor(sql, "sqlite", sql.find("'unfinished").unwrap()),
            None
        );

        let parameters = tablepro_core::extract_named_parameters(sql, "sqlite");
        assert_eq!(parameters.names, ["safe"]);
        assert!(
            parameters
                .sql
                .ends_with("SELECT 'unfinished :tail; SELECT :after AS value")
        );

        let formatted = tablepro_core::sql_format::format_script(sql, grammar, LexicalSettings::default_for(grammar));
        assert!(formatted.contains("SELECT 'unfinished :tail"));
        assert!(!plan_for(&formatted, grammar).diagnostics().is_empty());

        let facts = tablepro_policy::classify(sql, "sqlite");
        assert_eq!(facts.class, tablepro_policy::StatementClass::Unparseable);
        assert!(facts.writes());
        let config = tablepro_policy::PolicyConfig::default().for_environment(tablepro_core::Environment::Local);
        let decision = tablepro_policy::evaluate(
            &tablepro_policy::Principal::Agent {
                token: "test".into(),
                client: None,
                model: None,
            },
            tablepro_core::Environment::Local,
            &facts,
            false,
            &config,
            None,
        );
        assert!(matches!(
            decision,
            tablepro_policy::Decision::Deny { ref rule, .. } if rule == "fail_closed_unparseable"
        ));
    }

    #[test]
    fn value_contract_clickhouse_malformed_heredoc_blocks_full_script_consumers() {
        let sql = "SELECT :safe AS value; SELECT $tag$unfinished :tail";
        let grammar = SqlGrammar::ClickHouse;
        let plan = plan_for(sql, grammar);

        assert!(!plan.diagnostics().is_empty());
        assert_eq!(plan.statements().len(), 2);
        assert!(script_statements(sql, "clickhouse").is_err());

        let parameters = tablepro_core::extract_named_parameters(sql, "clickhouse");
        assert_eq!(parameters.names, ["safe"]);
        assert!(parameters.sql.ends_with("SELECT $tag$unfinished :tail"));

        let formatted = tablepro_core::sql_format::format_script(sql, grammar, LexicalSettings::default_for(grammar));
        assert!(formatted.ends_with("$tag$unfinished :tail"));
        assert!(!plan_for(&formatted, grammar).diagnostics().is_empty());

        let facts = tablepro_policy::classify(sql, "clickhouse");
        assert_eq!(facts.class, tablepro_policy::StatementClass::Unparseable);
        assert!(facts.writes());
        let config = tablepro_policy::PolicyConfig::default().for_environment(tablepro_core::Environment::Local);
        let decision = tablepro_policy::evaluate(
            &tablepro_policy::Principal::Agent {
                token: "test".into(),
                client: None,
                model: None,
            },
            tablepro_core::Environment::Local,
            &facts,
            false,
            &config,
            None,
        );
        assert!(matches!(
            decision,
            tablepro_policy::Decision::Deny { ref rule, .. } if rule == "fail_closed_unparseable"
        ));
    }

    #[test]
    fn value_contract_duckdb_malformed_tail_blocks_all_script_consumers() {
        let sql = "SELECT :safe AS value; SELECT 'unfinished :tail; SELECT :after AS value";
        let grammar = grammar_for("duckdb").unwrap();
        let plan = plan_for(sql, grammar);

        assert!(!plan.diagnostics().is_empty());
        assert!(script_statements(sql, "duckdb").is_err());
        assert_eq!(
            statement_at_cursor(sql, "duckdb", sql.find(":safe").unwrap()),
            Some("SELECT :safe AS value".into())
        );
        assert_eq!(
            statement_at_cursor(sql, "duckdb", sql.find("'unfinished").unwrap()),
            None
        );

        let parameters = tablepro_core::extract_named_parameters(sql, "duckdb");
        assert_eq!(parameters.names, ["safe"]);
        assert!(
            parameters
                .sql
                .ends_with("SELECT 'unfinished :tail; SELECT :after AS value")
        );

        let formatted = tablepro_core::sql_format::format_script(sql, grammar, LexicalSettings::default_for(grammar));
        assert!(formatted.contains("SELECT 'unfinished :tail"));
        assert!(!plan_for(&formatted, grammar).diagnostics().is_empty());

        let facts = tablepro_policy::classify(sql, "duckdb");
        assert_eq!(facts.class, tablepro_policy::StatementClass::Unparseable);
        assert!(facts.writes());
        let config = tablepro_policy::PolicyConfig::default().for_environment(tablepro_core::Environment::Local);
        let decision = tablepro_policy::evaluate(
            &tablepro_policy::Principal::Agent {
                token: "test".into(),
                client: None,
                model: None,
            },
            tablepro_core::Environment::Local,
            &facts,
            false,
            &config,
            None,
        );
        assert!(matches!(
            decision,
            tablepro_policy::Decision::Deny { ref rule, .. } if rule == "fail_closed_unparseable"
        ));
    }

    #[test]
    fn value_contract_mssql_malformed_tail_blocks_the_whole_go_script() {
        let sql = "SELECT :before AS value\r\nGO\r\nSELECT 'unfinished :inside\r\nGO\r\nSELECT :after AS value";
        let grammar = SqlGrammar::MsSql;
        let plan = plan_for(sql, grammar);

        assert!(!plan.diagnostics().is_empty());
        assert!(script_statements(sql, "mssql").is_err());
        let parameters = tablepro_core::extract_named_parameters(sql, "mssql");
        assert_eq!(parameters.names, ["before"]);
        assert!(parameters.sql.contains("SELECT 'unfinished :inside"));

        let formatted = tablepro_core::sql_format::format_script(sql, grammar, LexicalSettings::default_for(grammar));
        assert!(formatted.contains("SELECT 'unfinished :inside"));
        assert!(formatted.contains("GO"));
        assert!(!plan_for(&formatted, grammar).diagnostics().is_empty());

        let facts = tablepro_policy::classify(sql, "mssql");
        assert_eq!(facts.class, tablepro_policy::StatementClass::Unparseable);
        assert!(facts.writes());
        let config = tablepro_policy::PolicyConfig::default().for_environment(tablepro_core::Environment::Local);
        let decision = tablepro_policy::evaluate(
            &tablepro_policy::Principal::Agent {
                token: "test".into(),
                client: None,
                model: None,
            },
            tablepro_core::Environment::Local,
            &facts,
            false,
            &config,
            None,
        );
        assert!(matches!(
            decision,
            tablepro_policy::Decision::Deny { ref rule, .. } if rule == "fail_closed_unparseable"
        ));
    }

    #[test]
    fn mssql_go_batches_keep_consumer_order_and_ignore_delimiter_comments() {
        let sql = "SELECT :read AS value\r\nGO -- :go_comment ;\r\nUPDATE dbo.items SET name = :name WHERE id = :id\r\nGO -- :next_comment ;\r\nSELECT :last AS value";
        let grammar = SqlGrammar::MsSql;
        let plan = plan_for(sql, grammar);

        assert!(plan.diagnostics().is_empty());
        assert_eq!(plan.statements().len(), 3);
        assert_eq!(plan.batches().len(), 3);
        assert_eq!(plan.batch_error_policy(), BatchErrorPolicy::ContinueNextBatch);

        let extracted = tablepro_core::extract_named_parameters(sql, "mssql");
        assert_eq!(extracted.names, ["read", "name", "id", "last"]);
        let planned = script_statements(sql, "mssql").unwrap();
        assert_eq!(planned.statements.len(), 3);
        assert_eq!(planned.error_policy, BatchErrorPolicy::ContinueNextBatch);

        let formatted = tablepro_core::sql_format::format_script(sql, grammar, LexicalSettings::default_for(grammar));
        assert!(formatted.contains("GO -- :go_comment ;"));
        assert!(formatted.contains("GO -- :next_comment ;"));
        let reformatted = plan_for(&formatted, grammar);
        assert!(reformatted.diagnostics().is_empty());
        assert_eq!(reformatted.statements().len(), 3);

        let expected_classes = [
            tablepro_policy::StatementClass::Select,
            tablepro_policy::StatementClass::Update,
            tablepro_policy::StatementClass::Select,
        ];
        for (index, statement) in reformatted.statements().iter().enumerate() {
            let sql = statement.text(&formatted);
            let parameters = tablepro_core::extract_named_parameters(sql, "mssql");
            let facts = tablepro_policy::classify(&parameters.sql, "mssql");
            assert_eq!(facts.class, expected_classes[index]);
            if expected_classes[index] == tablepro_policy::StatementClass::Update {
                assert!(facts.has_where);
            }
        }
    }

    #[test]
    fn mssql_go_repetition_is_preserved_and_refused_by_script_execution() {
        let sql = "SELECT :id AS value\nGO 2 -- :repeat_comment";
        let grammar = SqlGrammar::MsSql;
        let plan = plan_for(sql, grammar);

        assert!(plan.diagnostics().is_empty());
        assert_eq!(plan.batches().len(), 1);
        assert_eq!(plan.batches()[0].repeat.get(), 2);
        assert!(script_statements(sql, "mssql").is_err());

        let formatted = tablepro_core::sql_format::format_script(sql, grammar, LexicalSettings::default_for(grammar));
        assert!(formatted.contains("GO 2 -- :repeat_comment"), "{formatted}");
        let reformatted = plan_for(&formatted, grammar);
        assert_eq!(reformatted.batches()[0].repeat.get(), 2);

        let parameters = tablepro_core::extract_named_parameters(&formatted, "mssql");
        assert_eq!(parameters.names, ["id"]);
        let facts = tablepro_policy::classify(&parameters.sql, "mssql");
        assert_eq!(facts.class, tablepro_policy::StatementClass::Unparseable);
        assert!(facts.writes());
    }

    #[test]
    fn mysql_delimiter_directives_agree_across_script_consumers() {
        let sql = "DELIMITER $$ -- :directive\r\nCREATE PROCEDURE p() BEGIN SELECT 'inside; :literal'; END$$\r\nDELIMITER ; -- :reset\r\nSELECT :after AS value";
        let grammar = SqlGrammar::MySql;
        let plan = plan_for(sql, grammar);

        assert!(plan.diagnostics().is_empty());
        assert_eq!(plan.statements().len(), 2);
        let planned = script_statements(sql, "mysql").unwrap();
        assert_eq!(planned.statements.len(), 2);
        assert!(planned.statements[0].starts_with("CREATE PROCEDURE p()"));
        assert_eq!(planned.statements[1], "SELECT :after AS value");

        let extracted = tablepro_core::extract_named_parameters(sql, "mysql");
        assert_eq!(extracted.names, ["after"]);

        let formatted = tablepro_core::sql_format::format_script(sql, grammar, LexicalSettings::default_for(grammar));
        assert!(formatted.contains("DELIMITER $$ -- :directive"));
        assert!(formatted.contains("DELIMITER ; -- :reset"));
        let reformatted = plan_for(&formatted, grammar);
        assert!(reformatted.diagnostics().is_empty());
        assert_eq!(reformatted.statements().len(), 2);
        assert_eq!(script_statements(&formatted, "mysql").unwrap().statements.len(), 2);

        let facts = reformatted
            .statements()
            .iter()
            .map(|statement| {
                let parameters = tablepro_core::extract_named_parameters(statement.text(&formatted), "mysql");
                tablepro_policy::classify(&parameters.sql, "mysql")
            })
            .collect::<Vec<_>>();
        assert_eq!(facts[0].class, tablepro_policy::StatementClass::Unparseable);
        assert!(facts[0].writes());
        assert_eq!(facts[1].class, tablepro_policy::StatementClass::Select);
        let decision = tablepro_policy::evaluate(
            &tablepro_policy::Principal::Agent {
                token: "test".into(),
                client: None,
                model: None,
            },
            tablepro_core::Environment::Local,
            &facts[0],
            false,
            &tablepro_policy::PolicyConfig::default().for_environment(tablepro_core::Environment::Local),
            None,
        );
        assert!(matches!(
            decision,
            tablepro_policy::Decision::Deny { ref rule, .. } if rule == "fail_closed_unparseable"
        ));
    }

    #[test]
    fn mysql_slash_delimiter_is_preserved_across_planner_editor_and_parameters() {
        let sql = "DELIMITER //\r\nCREATE PROCEDURE q() BEGIN SELECT 'inside; // :literal'; END//\r\nDELIMITER ;\r\nSELECT :after AS value";
        let grammar = SqlGrammar::MySql;
        let plan = plan_for(sql, grammar);
        assert!(plan.diagnostics().is_empty());
        assert_eq!(plan.statements().len(), 2);

        let planned = script_statements(sql, "mysql").unwrap();
        assert_eq!(planned.statements.len(), 2);
        assert!(planned.statements[0].starts_with("CREATE PROCEDURE q()"));
        assert_eq!(planned.statements[1], "SELECT :after AS value");
        assert_eq!(tablepro_core::extract_named_parameters(sql, "mysql").names, ["after"]);

        let formatted = tablepro_core::sql_format::format_script(sql, grammar, LexicalSettings::default_for(grammar));
        assert!(formatted.contains("DELIMITER //"));
        assert!(formatted.contains("DELIMITER ;"));
        let reformatted = plan_for(&formatted, grammar);
        assert!(reformatted.diagnostics().is_empty());
        assert_eq!(reformatted.statements().len(), 2);
        assert_eq!(script_statements(&formatted, "mysql").unwrap().statements.len(), 2);
    }

    #[test]
    fn mysql_slash_delimiter_inside_comments_does_not_end_routine() {
        let sql = "DELIMITER //\r\nCREATE PROCEDURE p() BEGIN SELECT 1 /* // :block */; -- // :line\r\nSELECT '// :literal'; END//\r\nDELIMITER ;\r\nSELECT :after AS value";
        let grammar = SqlGrammar::MySql;
        let plan = plan_for(sql, grammar);

        assert!(plan.diagnostics().is_empty());
        assert_eq!(plan.statements().len(), 2);
        let planned = script_statements(sql, "mysql").unwrap();
        assert_eq!(planned.statements.len(), 2);
        assert!(planned.statements[0].contains("/* // :block */"));
        assert!(planned.statements[0].contains("-- // :line"));
        assert!(planned.statements[0].contains("'// :literal'"));
        assert!(planned.statements[0].ends_with("END"));
        assert_eq!(planned.statements[1], "SELECT :after AS value");
        assert_eq!(tablepro_core::extract_named_parameters(sql, "mysql").names, ["after"]);

        let formatted = tablepro_core::sql_format::format_script(sql, grammar, LexicalSettings::default_for(grammar));
        let reformatted = plan_for(&formatted, grammar);
        assert!(reformatted.diagnostics().is_empty());
        let reformatted = script_statements(&formatted, "mysql").unwrap();
        assert_eq!(reformatted.statements.len(), 2);
        assert!(reformatted.statements[0].contains("/* // :block */"));
        assert!(reformatted.statements[0].contains("-- // :line"));
        assert!(reformatted.statements[1].contains("SELECT"));
        assert!(reformatted.statements[1].contains(":after AS value"));
        assert_eq!(
            tablepro_core::extract_named_parameters(&formatted, "mysql").names,
            ["after"]
        );
    }

    #[test]
    fn value_contract_mysql_short_delimiter_directive_keeps_routine_and_query_identity() {
        let sql = "\\d //\r\nCREATE PROCEDURE p() BEGIN SELECT 'inside // :literal'; END//\r\n\\d ;\r\nSELECT :after AS value";
        let grammar = SqlGrammar::MySql;
        let plan = plan_for(sql, grammar);

        assert!(plan.diagnostics().is_empty());
        assert_eq!(plan.statements().len(), 2);
        let planned = script_statements(sql, "mysql").unwrap();
        assert_eq!(planned.statements.len(), 2);
        assert!(planned.statements[0].starts_with("CREATE PROCEDURE p()"));
        assert_eq!(planned.statements[1], "SELECT :after AS value");
        assert_eq!(tablepro_core::extract_named_parameters(sql, "mysql").names, ["after"]);

        let formatted = tablepro_core::sql_format::format_script(sql, grammar, LexicalSettings::default_for(grammar));
        assert!(formatted.contains("\\d //"));
        assert!(formatted.contains("\\d ;"));
        let reformatted = plan_for(&formatted, grammar);
        assert!(reformatted.diagnostics().is_empty());
        assert_eq!(reformatted.statements().len(), 2);
        let reformatted_script = script_statements(&formatted, "mysql").unwrap();
        assert_eq!(reformatted_script.statements.len(), 2);
        assert!(reformatted_script.statements[0].starts_with("CREATE PROCEDURE p()"));
        assert!(reformatted_script.statements[0].contains("'inside // :literal'"));
        assert!(reformatted_script.statements[1].starts_with("SELECT"));
        assert!(reformatted_script.statements[1].contains(":after AS value"));
        assert_eq!(
            tablepro_core::extract_named_parameters(&formatted, "mysql").names,
            ["after"]
        );

        let facts = tablepro_policy::classify(&reformatted_script.statements[0], "mysql");
        assert_eq!(facts.class, tablepro_policy::StatementClass::Unparseable);
        assert!(facts.writes());
        assert_eq!(
            tablepro_policy::classify(&reformatted_script.statements[1], "mysql").class,
            tablepro_policy::StatementClass::Select
        );
    }

    #[test]
    fn mysql_colon_delimiter_does_not_leak_into_named_parameters() {
        let sql = "DELIMITER :\r\nCREATE PROCEDURE p() BEGIN SELECT ':inside' AS literal; SELECT 2 AS second; END:\r\nDELIMITER ;\r\nSELECT :after AS value";
        let grammar = SqlGrammar::MySql;
        let plan = plan_for(sql, grammar);

        assert!(plan.diagnostics().is_empty());
        assert_eq!(plan.statements().len(), 2);
        let planned = script_statements(sql, "mysql").unwrap();
        assert_eq!(planned.statements.len(), 2);
        assert!(planned.statements[0].ends_with("END"), "{:?}", planned.statements[0]);
        assert!(planned.statements[0].contains("':inside'"));
        assert_eq!(planned.statements[1], "SELECT :after AS value");
        assert_eq!(tablepro_core::extract_named_parameters(sql, "mysql").names, ["after"]);

        let formatted = tablepro_core::sql_format::format_script(sql, grammar, LexicalSettings::default_for(grammar));
        assert!(formatted.contains("DELIMITER :"), "{formatted}");
        let reformatted = plan_for(&formatted, grammar);
        assert!(reformatted.diagnostics().is_empty());
        let reformatted_script = script_statements(&formatted, "mysql").unwrap();
        assert_eq!(reformatted_script.statements.len(), 2);
        assert!(reformatted_script.statements[0].ends_with("END"));
        assert!(reformatted_script.statements[1].contains(":after AS value"));
        assert_eq!(
            tablepro_core::extract_named_parameters(&formatted, "mysql").names,
            ["after"]
        );
    }

    #[test]
    fn mysql_repeated_semicolon_delimiter_keeps_body_statements_together() {
        let sql = "DELIMITER ;;\r\nCREATE PROCEDURE p() BEGIN SELECT ':inside' AS first; SELECT 2 AS second; END;;\r\nDELIMITER ;\r\nSELECT :after AS value";
        let grammar = SqlGrammar::MySql;
        let plan = plan_for(sql, grammar);

        assert!(plan.diagnostics().is_empty());
        assert_eq!(plan.statements().len(), 2);
        let planned = script_statements(sql, "mysql").unwrap();
        assert_eq!(planned.statements.len(), 2);
        assert!(planned.statements[0].starts_with("CREATE PROCEDURE p()"));
        assert!(planned.statements[0].contains("SELECT 2 AS second;"));
        assert_eq!(planned.statements[1], "SELECT :after AS value");
        assert_eq!(tablepro_core::extract_named_parameters(sql, "mysql").names, ["after"]);

        let formatted = tablepro_core::sql_format::format_script(sql, grammar, LexicalSettings::default_for(grammar));
        assert!(formatted.contains("DELIMITER ;;"));
        assert!(formatted.contains("DELIMITER ;"));
        let reformatted = plan_for(&formatted, grammar);
        assert!(reformatted.diagnostics().is_empty());
        assert_eq!(reformatted.statements().len(), 2);
        assert_eq!(script_statements(&formatted, "mysql").unwrap().statements.len(), 2);
    }

    #[test]
    fn mysql_word_character_delimiter_stops_at_keyword_boundary() {
        let sql = "DELIMITER xyz\r\nCREATE PROCEDURE p() BEGIN SELECT 'inside xyz; :literal'; SELECT prefixxyzsuffix AS embedded; ENDxyz\r\nDELIMITER ;\r\nSELECT :after AS value";
        let grammar = SqlGrammar::MySql;
        let plan = plan_for(sql, grammar);

        assert!(plan.diagnostics().is_empty());
        assert_eq!(plan.statements().len(), 2);
        let planned = script_statements(sql, "mysql").unwrap();
        assert_eq!(planned.statements.len(), 2);
        assert!(planned.statements[0].starts_with("CREATE PROCEDURE p()"));
        assert!(planned.statements[0].contains("prefixxyzsuffix AS embedded"));
        assert!(planned.statements[0].ends_with("END"), "{:?}", planned.statements[0]);
        assert_eq!(planned.statements[1], "SELECT :after AS value");
        assert_eq!(tablepro_core::extract_named_parameters(sql, "mysql").names, ["after"]);

        let formatted = tablepro_core::sql_format::format_script(sql, grammar, LexicalSettings::default_for(grammar));
        assert!(formatted.contains("DELIMITER xyz"), "{formatted}");
        let reformatted = plan_for(&formatted, grammar);
        assert!(reformatted.diagnostics().is_empty());
        assert_eq!(reformatted.statements().len(), 2);
        let reformatted_script = script_statements(&formatted, "mysql").unwrap();
        assert_eq!(reformatted_script.statements.len(), 2);
        assert!(reformatted_script.statements[0].contains("prefixxyzsuffix AS embedded"));
        assert_eq!(
            tablepro_core::extract_named_parameters(&formatted, "mysql").names,
            ["after"]
        );
    }

    #[test]
    fn mysql_quoted_delimiter_agrees_across_script_consumers() {
        let sql = "DELIMITER '_finish'\r\nCREATE PROCEDURE p() BEGIN SELECT 'inside _finish; :literal'; END_finish\r\nDELIMITER ';'\r\nSELECT :after AS value";
        let grammar = SqlGrammar::MySql;
        let plan = plan_for(sql, grammar);

        assert!(plan.diagnostics().is_empty());
        assert_eq!(plan.statements().len(), 2);
        let planned = script_statements(sql, "mysql").unwrap();
        assert_eq!(planned.statements.len(), 2);
        assert!(planned.statements[0].starts_with("CREATE PROCEDURE p()"));
        assert!(planned.statements[0].ends_with("END"), "{:?}", planned.statements[0]);
        assert_eq!(planned.statements[1], "SELECT :after AS value");
        assert_eq!(tablepro_core::extract_named_parameters(sql, "mysql").names, ["after"]);

        let formatted = tablepro_core::sql_format::format_script(sql, grammar, LexicalSettings::default_for(grammar));
        assert!(formatted.contains("DELIMITER '_finish'"), "{formatted}");
        assert!(formatted.contains("DELIMITER ';'"), "{formatted}");
        let reformatted = plan_for(&formatted, grammar);
        assert!(reformatted.diagnostics().is_empty());
        assert_eq!(reformatted.statements().len(), 2);
        assert_eq!(script_statements(&formatted, "mysql").unwrap().statements.len(), 2);
        assert_eq!(
            tablepro_core::extract_named_parameters(&formatted, "mysql").names,
            ["after"]
        );
    }

    #[test]
    fn mysql_punctuation_delimiter_preserves_hash_comments() {
        let sql = "DELIMITER #!\r\nCREATE PROCEDURE p() BEGIN # comment with :hidden\r\nSELECT 'inside #! :literal'; END#!\r\nDELIMITER ;\r\nSELECT :after AS value";
        let grammar = SqlGrammar::MySql;
        let plan = plan_for(sql, grammar);

        assert!(plan.diagnostics().is_empty());
        assert_eq!(plan.statements().len(), 2);
        let planned = script_statements(sql, "mysql").unwrap();
        assert_eq!(planned.statements.len(), 2);
        assert!(planned.statements[0].contains("# comment with :hidden"));
        assert!(planned.statements[0].contains("'inside #! :literal'"));
        assert!(planned.statements[0].ends_with("END"));
        assert_eq!(planned.statements[1], "SELECT :after AS value");
        assert_eq!(tablepro_core::extract_named_parameters(sql, "mysql").names, ["after"]);

        let formatted = tablepro_core::sql_format::format_script(sql, grammar, LexicalSettings::default_for(grammar));
        assert!(formatted.contains("DELIMITER #!"), "{formatted}");
        let reformatted = plan_for(&formatted, grammar);
        assert!(reformatted.diagnostics().is_empty());
        let reformatted_script = script_statements(&formatted, "mysql").unwrap();
        assert_eq!(reformatted_script.statements.len(), 2);
        assert!(reformatted_script.statements[0].contains("# comment with :hidden"));
        assert!(reformatted_script.statements[1].starts_with("SELECT"));
        assert!(reformatted_script.statements[1].contains(":after AS value"));
        assert_eq!(
            tablepro_core::extract_named_parameters(&formatted, "mysql").names,
            ["after"]
        );
    }

    #[test]
    fn malformed_mysql_delimited_routine_blocks_the_whole_script() {
        let sql = "DELIMITER $$\r\nCREATE PROCEDURE p() BEGIN SELECT 'unfinished :inside\r\nEND$$\r\nDELIMITER ;\r\nSELECT :after AS value";
        let grammar = SqlGrammar::MySql;
        let plan = plan_for(sql, grammar);

        assert!(!plan.diagnostics().is_empty());
        assert!(script_statements(sql, "mysql").is_err());
        let parameters = tablepro_core::extract_named_parameters(sql, "mysql");
        assert!(
            parameters.names.is_empty(),
            "malformed tail parameters are not executable"
        );

        let formatted = tablepro_core::sql_format::format_script(sql, grammar, LexicalSettings::default_for(grammar));
        assert!(formatted.contains("'unfinished :inside"));
        assert!(!plan_for(&formatted, grammar).diagnostics().is_empty());
        let facts = tablepro_policy::classify(sql, "mysql");
        assert_eq!(facts.class, tablepro_policy::StatementClass::Unparseable);
        assert!(facts.writes());
        let decision = tablepro_policy::evaluate(
            &tablepro_policy::Principal::Agent {
                token: "test".into(),
                client: None,
                model: None,
            },
            tablepro_core::Environment::Local,
            &facts,
            false,
            &tablepro_policy::PolicyConfig::default().for_environment(tablepro_core::Environment::Local),
            None,
        );
        assert!(matches!(
            decision,
            tablepro_policy::Decision::Deny { ref rule, .. } if rule == "fail_closed_unparseable"
        ));

        let mut human_policy =
            tablepro_policy::PolicyConfig::default().for_environment(tablepro_core::Environment::Local);
        assert!(human_policy.human_approve_unparseable);
        let human_decision = tablepro_policy::evaluate(
            &tablepro_policy::Principal::human_gui(),
            tablepro_core::Environment::Local,
            &facts,
            false,
            &human_policy,
            None,
        );
        assert!(matches!(
            human_decision,
            tablepro_policy::Decision::RequireApproval { ref rule, .. }
                if rule == "fail_closed_unparseable"
        ));

        human_policy.human_approve_unparseable = false;
        let configured_human_decision = tablepro_policy::evaluate(
            &tablepro_policy::Principal::human_gui(),
            tablepro_core::Environment::Local,
            &facts,
            false,
            &human_policy,
            None,
        );
        assert!(
            matches!(
                configured_human_decision,
                tablepro_policy::Decision::RequireApproval { ref rule, .. }
                    if rule == "human_dangerous_effect_approval"
            ),
            "{configured_human_decision:?}"
        );
    }
}
