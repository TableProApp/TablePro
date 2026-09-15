use relm4::gtk;
use relm4::gtk::prelude::TextBufferExt;
use tablepro_core::sql_syntax::SqlGrammar;
use tablepro_core::sql_syntax::script::{LexicalSettings, ScriptPlan, text_offsets};

/// The script the buffer holds, read with the engine's own rules.
pub fn plan_for(text: &str, grammar: SqlGrammar) -> ScriptPlan {
    ScriptPlan::build(text, grammar, LexicalSettings::default_for(grammar))
}

/// The statements a run sends, in order.
///
/// The plan knows what a statement is on each engine: a dollar-quoted
/// body, a `GO` batch, a procedure between `DELIMITER` lines. Splitting
/// on semicolons instead would cut a PL/pgSQL function in half.
pub fn script_statements(text: &str, grammar: SqlGrammar) -> Vec<String> {
    plan_for(text, grammar)
        .statements()
        .iter()
        .map(|statement| statement.text(text).trim().to_owned())
        .filter(|statement| !statement.is_empty())
        .collect()
}

/// Where the statement under the cursor starts and ends in the buffer.
///
/// The buffer counts in characters and the plan in bytes, so every
/// mapping between them goes through here: a cursor in a Vietnamese
/// identifier lands mid-character otherwise.
pub fn statement_bounds_at(
    buffer: &gtk::TextBuffer,
    plan: &ScriptPlan,
    text: &str,
    cursor_char: usize,
) -> Option<(gtk::TextIter, gtk::TextIter)> {
    let byte = text_offsets::char_to_byte(text, cursor_char);
    let statement = plan.statement_at(byte)?;
    Some((
        iter_for_byte(buffer, text, statement.range.start),
        iter_for_byte(buffer, text, statement.range.end),
    ))
}

pub fn iter_for_byte(buffer: &gtk::TextBuffer, text: &str, byte: usize) -> gtk::TextIter {
    let chars = i32::try_from(text_offsets::byte_to_char(text, byte)).unwrap_or(i32::MAX);
    buffer.iter_at_offset(chars)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn statement_at(text: &str, cursor_char: usize) -> Option<String> {
        let buffer = gtk::TextBuffer::new(None);
        buffer.set_text(text);
        let plan = plan_for(text, SqlGrammar::PostgreSql);
        let (start, end) = statement_bounds_at(&buffer, &plan, text, cursor_char)?;
        Some(buffer.text(&start, &end, false).to_string().trim().to_owned())
    }

    #[gtk4::test]
    fn the_cursor_picks_the_statement_it_sits_in() {
        let sql = "SELECT 1; SELECT 2";

        assert_eq!(statement_at(sql, 4).as_deref(), Some("SELECT 1"));
        assert_eq!(statement_at(sql, 17).as_deref(), Some("SELECT 2"));
    }

    #[gtk4::test]
    fn a_cursor_past_the_end_picks_the_last_statement() {
        assert_eq!(statement_at("SELECT 1; SELECT 2", 9999).as_deref(), Some("SELECT 2"));
    }

    #[gtk4::test]
    fn a_semicolon_inside_a_string_is_not_a_boundary() {
        let sql = "INSERT INTO t VALUES ('a;b'); SELECT 2";

        let statement = statement_at(sql, 24).expect("a statement");

        assert!(statement.starts_with("INSERT INTO t VALUES"), "{statement}");
        assert!(statement.contains("'a;b'"), "{statement}");
    }

    #[gtk4::test]
    fn a_cursor_in_a_multibyte_identifier_stays_in_its_statement() {
        let sql = "SELECT \"tên\" FROM t; SELECT 2";
        // Character 9 is inside the quoted identifier, which is three
        // bytes further along than it is characters.
        let statement = statement_at(sql, 9).expect("a statement");

        assert!(statement.starts_with("SELECT \"tên\""), "{statement}");
    }

    #[test]
    fn a_script_splits_into_the_statements_the_engine_sees() {
        assert_eq!(
            script_statements("SELECT 1; SELECT 2", SqlGrammar::PostgreSql),
            vec!["SELECT 1", "SELECT 2"]
        );
        assert_eq!(
            script_statements("INSERT INTO t VALUES ('a;b'); SELECT 1", SqlGrammar::PostgreSql),
            vec!["INSERT INTO t VALUES ('a;b')", "SELECT 1"]
        );
        // The comment sits between the statements, so what goes to
        // the server is the statement without it.
        assert_eq!(
            script_statements("SELECT 1 -- comment ; here\n; SELECT 2", SqlGrammar::PostgreSql),
            vec!["SELECT 1", "SELECT 2"]
        );
        assert_eq!(script_statements("SELECT 1;", SqlGrammar::PostgreSql), vec!["SELECT 1"]);
        assert!(script_statements("   \n ", SqlGrammar::PostgreSql).is_empty());
    }

    #[test]
    fn a_dollar_quoted_body_is_one_statement() {
        let sql = "CREATE FUNCTION f() RETURNS int AS $$ SELECT 1; SELECT 2; $$ LANGUAGE sql";

        let statements = script_statements(sql, SqlGrammar::PostgreSql);

        assert_eq!(statements.len(), 1, "the function body was cut up: {statements:?}");
    }
}
