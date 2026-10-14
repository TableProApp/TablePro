use std::ops::Range;

use crate::sql_syntax::SqlGrammar;
use crate::sql_syntax::script::{LexicalSettings, ScriptPlan, ScriptTokenKind};

/// One token of a statement, with comments, whitespace and client
/// directives gone.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum StatementToken<'a> {
    /// A keyword or a bare name.
    Word(&'a str),
    /// A quoted name, without its quotes.
    QuotedName(&'a str),
    /// What a dollar quote holds, which is usually a routine body.
    DollarBody(&'a str),
    OpenParen,
    Punct(char),
    /// A string, a number or a closing parenthesis.
    Other,
}

impl<'a> StatementToken<'a> {
    pub(crate) fn is_word(&self, word: &str) -> bool {
        matches!(self, Self::Word(text) if text.eq_ignore_ascii_case(word))
    }

    pub(crate) fn is_punct(&self, punct: char) -> bool {
        *self == Self::Punct(punct)
    }

    /// The name it spells, quoted or not.
    pub(crate) fn name(&self) -> Option<&'a str> {
        match self {
            Self::Word(text) | Self::QuotedName(text) => Some(text),
            _ => None,
        }
    }
}

/// A script split into statements the way the editor runs it.
#[derive(Debug)]
pub(crate) struct LexedScript<'a> {
    pub statements: Vec<Vec<StatementToken<'a>>>,
    /// A string, quoted name or comment runs to the end of the text, so
    /// where the statements end is a guess.
    pub unterminated: bool,
}

pub(crate) fn lex_statements(sql: &str, grammar: SqlGrammar) -> LexedScript<'_> {
    let plan = ScriptPlan::build(sql, grammar, LexicalSettings::default_for(grammar));
    let statements = plan
        .statements()
        .iter()
        .map(|statement| {
            plan.tokens(statement.range.clone())
                .filter_map(|token| significant(sql, token.kind, token.range))
                .collect()
        })
        .collect();
    LexedScript {
        statements,
        unterminated: !plan.diagnostics().is_empty(),
    }
}

fn significant(sql: &str, kind: ScriptTokenKind, range: Range<usize>) -> Option<StatementToken<'_>> {
    let text = sql.get(range).unwrap_or_default();
    let token = match kind {
        ScriptTokenKind::Whitespace
        | ScriptTokenKind::LineComment
        | ScriptTokenKind::BlockComment
        | ScriptTokenKind::Directive => return None,
        ScriptTokenKind::Word => StatementToken::Word(text),
        ScriptTokenKind::QuotedIdentifier => StatementToken::QuotedName(unquoted(text)),
        ScriptTokenKind::DollarQuoted => StatementToken::DollarBody(dollar_body(text)),
        ScriptTokenKind::OpenParen => StatementToken::OpenParen,
        ScriptTokenKind::Punct => text.chars().next().map_or(StatementToken::Other, StatementToken::Punct),
        ScriptTokenKind::StringLiteral
        | ScriptTokenKind::Number
        | ScriptTokenKind::Semicolon
        | ScriptTokenKind::CloseParen
        | ScriptTokenKind::Unterminated => StatementToken::Other,
    };
    Some(token)
}

/// Every quote the lexer accepts for a name (`"`, `` ` ``, `[` and `]`)
/// is one byte, so dropping the first and last byte leaves the name.
fn unquoted(text: &str) -> &str {
    text.get(1..text.len().saturating_sub(1)).unwrap_or_default()
}

/// `$tag$body$tag$` gives `body`.
fn dollar_body(text: &str) -> &str {
    let Some(opener) = text.get(1..).and_then(|rest| rest.find('$')).map(|close| close + 2) else {
        return "";
    };
    text.get(opener..text.len().saturating_sub(opener)).unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn comments_whitespace_and_strings_carry_no_words() {
        let script = lex_statements("SELECT /* CREATE */ 'USER' -- ROLE\n FROM t", SqlGrammar::PostgreSql);

        assert_eq!(
            script.statements,
            vec![vec![
                StatementToken::Word("SELECT"),
                StatementToken::Other,
                StatementToken::Word("FROM"),
                StatementToken::Word("t"),
            ]]
        );
        assert!(!script.unterminated);
    }

    #[test]
    fn quoted_names_lose_their_quotes() {
        let script = lex_statements("EXEC [dbo].[sp_who]", SqlGrammar::MsSql);

        assert_eq!(
            script.statements,
            vec![vec![
                StatementToken::Word("EXEC"),
                StatementToken::QuotedName("dbo"),
                StatementToken::Punct('.'),
                StatementToken::QuotedName("sp_who"),
            ]]
        );
    }

    #[test]
    fn a_dollar_quote_gives_its_body() {
        let script = lex_statements("DO $body$ SELECT 1 $body$", SqlGrammar::PostgreSql);

        assert_eq!(
            script.statements,
            vec![vec![
                StatementToken::Word("DO"),
                StatementToken::DollarBody(" SELECT 1 ")
            ]]
        );
    }

    #[test]
    fn statements_split_as_the_editor_splits_them() {
        let script = lex_statements("SELECT 1\nGO\nSELECT 2", SqlGrammar::MsSql);

        assert_eq!(script.statements.len(), 2);
    }

    #[test]
    fn an_open_string_is_reported() {
        assert!(lex_statements("SELECT 'abc", SqlGrammar::PostgreSql).unterminated);
        assert!(lex_statements("SELECT 1 /* note", SqlGrammar::MySql).unterminated);
    }
}
