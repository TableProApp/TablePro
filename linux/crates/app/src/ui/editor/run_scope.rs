use std::ops::Range;

use tablepro_core::sql_syntax::script::{ScriptPlan, text_offsets};

/// The SQL one run sends, and where it starts in the buffer.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ScopedText {
    pub text: String,
    /// The buffer offset, in characters, of `text`'s first character,
    /// so a server's error position can be found in the buffer.
    pub base_char: usize,
}

/// Run sends the selection when there is one, and the whole buffer
/// when there is not, so a highlighted statement is the only one sent.
pub fn for_run(buffer_text: &str, selection: Option<Range<usize>>) -> Option<ScopedText> {
    let scoped = match selection.filter(|range| range.start < range.end) {
        Some(range) => ScopedText {
            text: char_slice(buffer_text, range.clone()).to_owned(),
            base_char: range.start,
        },
        None => ScopedText {
            text: buffer_text.to_owned(),
            base_char: 0,
        },
    };
    (!scoped.text.trim().is_empty()).then_some(scoped)
}

/// The statement the cursor is in, as the engine's script rules read
/// it, with its character range in the buffer.
pub fn at_cursor(buffer_text: &str, plan: &ScriptPlan, cursor_char: usize) -> Option<(ScopedText, Range<usize>)> {
    let byte = text_offsets::char_to_byte(buffer_text, cursor_char);
    let statement = plan.statement_at(byte)?;
    let start = text_offsets::byte_to_char(buffer_text, statement.range.start);
    let end = text_offsets::byte_to_char(buffer_text, statement.range.end);
    let text = statement.text(buffer_text);
    if text.trim().is_empty() {
        return None;
    }
    Some((
        ScopedText {
            text: text.to_owned(),
            base_char: start,
        },
        start..end,
    ))
}

fn char_slice(text: &str, range: Range<usize>) -> &str {
    let start = text_offsets::char_to_byte(text, range.start);
    let end = text_offsets::char_to_byte(text, range.end);
    text.get(start..end).unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use tablepro_core::sql_syntax::SqlGrammar;
    use tablepro_core::sql_syntax::script::LexicalSettings;

    use super::*;

    #[test]
    fn run_scope_prefers_selection() {
        let buffer = "SELECT 1;\nSELECT 2;\nSELECT 3;";

        let selected = for_run(buffer, Some(10..18)).expect("a selection");
        assert_eq!(selected.text, "SELECT 2");
        assert_eq!(selected.base_char, 10);

        let whole = for_run(buffer, Some(4..4)).expect("an empty selection runs everything");
        assert_eq!(whole.text, buffer);
        assert_eq!(whole.base_char, 0);

        assert_eq!(for_run("  \n ", None), None);
    }

    #[test]
    fn a_selection_is_cut_by_characters_not_bytes() {
        let buffer = "SELECT 'tên'; SELECT 2";

        let selected = for_run(buffer, Some(14..22)).expect("a selection");

        assert_eq!(selected.text, "SELECT 2");
    }

    #[test]
    fn run_scope_statement_at_cursor_uses_plan() {
        let buffer = "CREATE FUNCTION f() RETURNS int AS $$ SELECT 1; $$ LANGUAGE sql;\nSELECT 2;";
        let plan = ScriptPlan::build(
            buffer,
            SqlGrammar::PostgreSql,
            LexicalSettings::default_for(SqlGrammar::PostgreSql),
        );

        let (inside_body, range) = at_cursor(buffer, &plan, 40).expect("a statement");
        assert!(inside_body.text.starts_with("CREATE FUNCTION"), "{}", inside_body.text);
        assert!(inside_body.text.ends_with("LANGUAGE sql"), "{}", inside_body.text);
        assert_eq!(range.start, 0);

        let (second, _) = at_cursor(buffer, &plan, buffer.chars().count()).expect("the last statement");
        assert_eq!(second.text, "SELECT 2");
        assert_eq!(second.base_char, buffer.find("SELECT 2").unwrap_or_default());
    }
}
