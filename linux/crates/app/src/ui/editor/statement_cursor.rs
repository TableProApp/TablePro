use gtk4::prelude::*;
use tablepro_core::sql_syntax::SqlGrammar;
use tablepro_core::sql_syntax::script::{LexicalSettings, ScriptPlan, text_offsets};

/// The script the buffer holds, read with the engine's own rules: a
/// dollar-quoted body, a `GO` batch or a procedure between `DELIMITER`
/// lines is one statement, where a split on semicolons would cut it.
pub fn plan_for(text: &str, grammar: SqlGrammar) -> ScriptPlan {
    ScriptPlan::build(text, grammar, LexicalSettings::default_for(grammar))
}

/// Where the statement under the cursor starts and ends in the buffer.
///
/// The buffer counts characters and the plan counts bytes, so every
/// mapping between the two goes through here: a cursor in a Vietnamese
/// identifier lands mid-character otherwise.
pub fn statement_bounds_at(
    buffer: &gtk4::TextBuffer,
    plan: &ScriptPlan,
    text: &str,
    cursor_char: usize,
) -> Option<(gtk4::TextIter, gtk4::TextIter)> {
    let byte = text_offsets::char_to_byte(text, cursor_char);
    let statement = plan.statement_at(byte)?;
    Some((
        iter_for_byte(buffer, text, statement.range.start),
        iter_for_byte(buffer, text, statement.range.end),
    ))
}

/// The buffer position of a byte offset into `text`, which must be the
/// buffer's text. Past the end is the end.
pub fn iter_for_byte(buffer: &gtk4::TextBuffer, text: &str, byte: usize) -> gtk4::TextIter {
    let chars = i32::try_from(text_offsets::byte_to_char(text, byte)).unwrap_or(i32::MAX);
    buffer.iter_at_offset(chars)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn buffer(text: &str) -> gtk4::TextBuffer {
        let buffer = gtk4::TextBuffer::new(None);
        buffer.set_text(text);
        buffer
    }

    fn bounds_at(text: &str, cursor_char: usize) -> Option<(i32, i32, String)> {
        let buffer = buffer(text);
        let plan = plan_for(text, SqlGrammar::PostgreSql);
        let (start, end) = statement_bounds_at(&buffer, &plan, text, cursor_char)?;
        Some((
            start.offset(),
            end.offset(),
            buffer.text(&start, &end, false).to_string(),
        ))
    }

    #[gtk4::test]
    fn statement_bounds_multibyte_text() {
        let text = "SELECT 'tên'; SELECT \"bảng\" FROM t";

        let (start, end, statement) = bounds_at(text, 30).expect("a statement");

        assert_eq!(statement, "SELECT \"bảng\" FROM t");
        assert_eq!((start, end), (14, 34), "the bounds were not mapped to characters");
    }

    #[gtk4::test]
    fn a_cursor_in_a_multibyte_identifier_stays_in_its_statement() {
        // Character 9 is inside the quoted identifier, which is three
        // bytes further along than it is characters.
        let (_, _, statement) = bounds_at("SELECT \"tên\" FROM t; SELECT 2", 9).expect("a statement");

        assert_eq!(statement, "SELECT \"tên\" FROM t");
    }

    #[gtk4::test]
    fn the_cursor_picks_the_statement_it_sits_in() {
        let text = "SELECT 1; SELECT 2";

        assert_eq!(bounds_at(text, 4).map(|(_, _, sql)| sql).as_deref(), Some("SELECT 1"));
        assert_eq!(bounds_at(text, 17).map(|(_, _, sql)| sql).as_deref(), Some("SELECT 2"));
    }

    #[gtk4::test]
    fn a_cursor_past_the_end_picks_the_last_statement() {
        let statement = bounds_at("SELECT 1; SELECT 2", 9999).map(|(_, _, sql)| sql);

        assert_eq!(statement.as_deref(), Some("SELECT 2"));
    }

    #[gtk4::test]
    fn a_semicolon_inside_a_string_is_not_a_boundary() {
        let (_, _, statement) = bounds_at("INSERT INTO t VALUES ('a;b'); SELECT 2", 24).expect("a statement");

        assert_eq!(statement, "INSERT INTO t VALUES ('a;b')");
    }

    #[gtk4::test]
    fn a_dollar_quoted_body_is_one_statement() {
        let text = "CREATE FUNCTION f() RETURNS int AS $$ SELECT 1; $$ LANGUAGE sql;\nSELECT 2;";

        let (start, _, statement) = bounds_at(text, 40).expect("a statement");

        assert_eq!(start, 0);
        assert!(statement.ends_with("LANGUAGE sql"), "{statement}");
    }

    #[gtk4::test]
    fn an_empty_buffer_has_no_statement() {
        assert_eq!(bounds_at("", 0), None);
        assert_eq!(bounds_at("  \n -- only a comment\n", 3), None);
    }

    #[gtk4::test]
    fn iter_for_byte_at_end() {
        let text = "SELECT 'tên'";
        let buffer = buffer(text);

        assert!(iter_for_byte(&buffer, text, text.len()).is_end());
        assert!(iter_for_byte(&buffer, text, text.len() + 10).is_end());
        assert_eq!(iter_for_byte(&buffer, text, text.len() - 1).offset(), 11);
    }
}
