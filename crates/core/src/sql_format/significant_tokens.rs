use crate::sql_syntax::SqlGrammar;
use crate::sql_syntax::script::{LexicalSettings, ScriptPlan, ScriptTokenKind};

/// What a statement says, with the spacing taken out.
///
/// Preserve token adjacency and newlines where SQL gives them meaning.
/// This is a conservative guard, not a proof of semantic equivalence;
/// real-server regressions provide an independent oracle.
pub fn significant_tokens(
    text: &str,
    grammar: SqlGrammar,
    settings: LexicalSettings,
) -> Vec<(ScriptTokenKind, String, u8)> {
    let plan = ScriptPlan::build(text, grammar, settings);
    let mut previous: Option<(ScriptTokenKind, &str, usize)> = None;
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
            let significant_gap = previous.map_or(0, |(kind, body, end)| {
                let gap = &text[end..token.range.start];
                if kind == ScriptTokenKind::StringLiteral && token.kind == ScriptTokenKind::StringLiteral {
                    // PostgreSQL concatenates only when the gap contains a newline.
                    u8::from(!gap.is_empty()) + u8::from(gap.contains('\n'))
                } else if (kind == ScriptTokenKind::Word && token.kind == ScriptTokenKind::StringLiteral)
                    || (body.eq_ignore_ascii_case("u") && slice == "&")
                    || (body == "&"
                        && matches!(
                            token.kind,
                            ScriptTokenKind::StringLiteral | ScriptTokenKind::QuotedIdentifier
                        ))
                    || (kind == ScriptTokenKind::Punct && token.kind == ScriptTokenKind::Punct)
                {
                    u8::from(!gap.is_empty())
                } else {
                    0
                }
            });
            previous = Some((token.kind, slice, token.range.end));
            (token.kind, body.to_owned(), significant_gap)
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tokens(text: &str) -> Vec<(ScriptTokenKind, String, u8)> {
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
