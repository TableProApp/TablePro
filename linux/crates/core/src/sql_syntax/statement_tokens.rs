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
    /// A string as written, quotes and any `E` prefix included.
    StringLiteral(&'a str),
    OpenParen,
    /// Punctuation, and `;` wherever a statement keeps one, as a T-SQL
    /// batch does.
    Punct(char),
    /// A number or a closing parenthesis.
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
    // Split at the terminators rather than taken statement by statement,
    // so a comment the plan leaves outside every statement still counts:
    // MySQL runs a `/*!` comment with whatever stands between the same
    // two terminators, and the history keeps the whole text.
    let mut statements = Vec::new();
    let mut current = Vec::new();
    for token in plan.tokens(0..sql.len()) {
        let ends_statement = match token.kind {
            ScriptTokenKind::Directive => true,
            ScriptTokenKind::Semicolon => !plan
                .statement_at(token.range.start)
                .is_some_and(|statement| statement.range.contains(&token.range.start)),
            _ => false,
        };
        if ends_statement {
            if !current.is_empty() {
                statements.push(std::mem::take(&mut current));
            }
            continue;
        }
        push_significant(sql, grammar, token.kind, token.range, &mut current);
    }
    if !current.is_empty() {
        statements.push(current);
    }
    LexedScript {
        statements,
        unterminated: !plan.diagnostics().is_empty(),
    }
}

fn push_significant<'a>(
    sql: &'a str,
    grammar: SqlGrammar,
    kind: ScriptTokenKind,
    range: Range<usize>,
    tokens: &mut Vec<StatementToken<'a>>,
) {
    let text = sql.get(range).unwrap_or_default();
    let token = match kind {
        ScriptTokenKind::BlockComment => {
            // MySQL and MariaDB run what a `/*!` comment holds as part of
            // the statement around it.
            if let Some(inner) = executable_comment(grammar, text) {
                tokens.extend(lex_statements(inner, grammar).statements.into_iter().flatten());
            }
            return;
        }
        ScriptTokenKind::Whitespace | ScriptTokenKind::LineComment | ScriptTokenKind::Directive => return,
        ScriptTokenKind::Word => StatementToken::Word(text),
        ScriptTokenKind::QuotedIdentifier => StatementToken::QuotedName(unquoted(text)),
        ScriptTokenKind::DollarQuoted => StatementToken::DollarBody(dollar_body(text)),
        ScriptTokenKind::StringLiteral => StatementToken::StringLiteral(text),
        ScriptTokenKind::OpenParen => StatementToken::OpenParen,
        ScriptTokenKind::Semicolon => StatementToken::Punct(';'),
        ScriptTokenKind::Punct => text.chars().next().map_or(StatementToken::Other, StatementToken::Punct),
        ScriptTokenKind::Number | ScriptTokenKind::CloseParen | ScriptTokenKind::Unterminated => StatementToken::Other,
    };
    tokens.push(token);
}

/// `/*!50100 text */` or MariaDB's `/*M!100100 text */` gives `text`.
fn executable_comment(grammar: SqlGrammar, text: &str) -> Option<&str> {
    if grammar != SqlGrammar::MySql {
        return None;
    }
    let body = text.strip_prefix("/*!").or_else(|| text.strip_prefix("/*M!"))?;
    let body = body.strip_suffix("*/")?;
    Some(body.trim_start_matches(|c: char| c.is_ascii_digit()))
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
                StatementToken::StringLiteral("'USER'"),
                StatementToken::Word("FROM"),
                StatementToken::Word("t"),
            ]]
        );
        assert!(!script.unterminated);
    }

    #[test]
    fn a_mysql_executable_comment_is_part_of_its_statement() {
        assert_eq!(
            lex_statements("CREATE /*!50100 TEMPORARY */ TABLE t", SqlGrammar::MySql).statements,
            vec![vec![
                StatementToken::Word("CREATE"),
                StatementToken::Word("TEMPORARY"),
                StatementToken::Word("TABLE"),
                StatementToken::Word("t"),
            ]]
        );
        assert_eq!(
            lex_statements("SELECT /*M!100100 1 */ x", SqlGrammar::MySql).statements,
            vec![vec![
                StatementToken::Word("SELECT"),
                StatementToken::Other,
                StatementToken::Word("x"),
            ]]
        );
        assert_eq!(
            lex_statements("SELECT /*! TEMPORARY */ x", SqlGrammar::PostgreSql).statements,
            vec![vec![StatementToken::Word("SELECT"), StatementToken::Word("x")]]
        );
    }

    #[test]
    fn a_mysql_executable_comment_between_statements_is_a_statement() {
        let script = lex_statements("SELECT 1;\n/*!40101 SET NAMES utf8 */;", SqlGrammar::MySql);

        assert_eq!(
            script.statements,
            vec![
                vec![StatementToken::Word("SELECT"), StatementToken::Other],
                vec![
                    StatementToken::Word("SET"),
                    StatementToken::Word("NAMES"),
                    StatementToken::Word("utf8"),
                ],
            ]
        );
    }

    #[test]
    fn a_batch_keeps_its_semicolons() {
        let script = lex_statements("SELECT 1; SELECT 2", SqlGrammar::MsSql);

        assert_eq!(
            script.statements,
            vec![vec![
                StatementToken::Word("SELECT"),
                StatementToken::Other,
                StatementToken::Punct(';'),
                StatementToken::Word("SELECT"),
                StatementToken::Other,
            ]]
        );
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
