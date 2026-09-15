use tablepro_core::sql_syntax::SqlGrammar;
use tablepro_core::sql_syntax::script::{LexicalSettings, ScriptPlan, ScriptTokenKind};

/// What a statement says, with the spacing taken out.
///
/// Two texts with the same list are the same statement written
/// differently, which is the only thing a formatter is allowed to do.
pub fn significant_tokens(
    text: &str,
    grammar: SqlGrammar,
    settings: LexicalSettings,
) -> Vec<(ScriptTokenKind, String)> {
    let plan = ScriptPlan::build(text, grammar, settings);
    plan.tokens(0..text.len())
        .filter(|token| token.kind != ScriptTokenKind::Whitespace)
        .map(|token| {
            let slice = text.get(token.range.clone()).unwrap_or_default();
            let body = match token.kind {
                // A formatter may move the spaces at the end of a
                // comment without changing what the comment says.
                ScriptTokenKind::LineComment | ScriptTokenKind::BlockComment => slice.trim_end(),
                _ => slice,
            };
            (token.kind, body.to_owned())
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tokens(text: &str) -> Vec<(ScriptTokenKind, String)> {
        significant_tokens(
            text,
            SqlGrammar::PostgreSql,
            LexicalSettings::default_for(SqlGrammar::PostgreSql),
        )
    }

    #[test]
    fn spacing_alone_does_not_change_a_statement() {
        assert_eq!(tokens("select  a ,b from t"), tokens("select a, b\nfrom t"));
    }

    #[test]
    fn a_changed_word_changes_the_statement() {
        assert_ne!(tokens("select a from t"), tokens("SELECT a from t"));
    }

    #[test]
    fn a_comment_keeps_its_text_but_not_its_trailing_spaces() {
        assert_eq!(tokens("select 1 -- note  "), tokens("select 1 -- note"));
        assert_ne!(tokens("select 1 -- note"), tokens("select 1 -- other"));
    }
}
