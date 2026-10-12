use tablepro_core::sql_syntax::SqlGrammar;
use tablepro_core::sql_syntax::script::{LexicalSettings, ScriptPlan};

/// The script the buffer holds, read with the engine's own rules: a
/// dollar-quoted body, a `GO` batch or a procedure between `DELIMITER`
/// lines is one statement, where a split on semicolons would cut it.
pub fn plan_for(text: &str, grammar: SqlGrammar) -> ScriptPlan {
    ScriptPlan::build(text, grammar, LexicalSettings::default_for(grammar))
}

#[cfg(test)]
mod tests {
    use super::super::run_scope::at_cursor;
    use super::*;

    fn statement_at(text: &str, cursor_char: usize) -> Option<String> {
        let plan = plan_for(text, SqlGrammar::PostgreSql);
        at_cursor(text, &plan, cursor_char).map(|(scoped, _)| scoped.text)
    }

    #[test]
    fn the_cursor_picks_the_statement_it_sits_in() {
        let sql = "SELECT 1; SELECT 2";

        assert_eq!(statement_at(sql, 4).as_deref(), Some("SELECT 1"));
        assert_eq!(statement_at(sql, 17).as_deref(), Some("SELECT 2"));
    }

    #[test]
    fn a_cursor_past_the_end_picks_the_last_statement() {
        assert_eq!(statement_at("SELECT 1; SELECT 2", 9999).as_deref(), Some("SELECT 2"));
    }

    #[test]
    fn a_semicolon_inside_a_string_is_not_a_boundary() {
        let sql = "INSERT INTO t VALUES ('a;b'); SELECT 2";

        let statement = statement_at(sql, 24).expect("a statement");

        assert!(statement.starts_with("INSERT INTO t VALUES"), "{statement}");
        assert!(statement.contains("'a;b'"), "{statement}");
    }

    #[test]
    fn a_cursor_in_a_multibyte_identifier_stays_in_its_statement() {
        let sql = "SELECT \"tên\" FROM t; SELECT 2";
        // Character 9 is inside the quoted identifier, which is three
        // bytes further along than it is characters.
        let statement = statement_at(sql, 9).expect("a statement");

        assert!(statement.starts_with("SELECT \"tên\""), "{statement}");
    }
}
