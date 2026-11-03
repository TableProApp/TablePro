use std::collections::HashSet;
use std::ops::Range;
use std::sync::OnceLock;

use crate::sql_syntax::SqlGrammar;
use crate::sql_syntax::script::lexer::Lexer;
use crate::sql_syntax::script::script_rules::rules_for;
use crate::sql_syntax::script::server_reading::ServerReading;
use crate::sql_syntax::script::{LexicalSettings, OpenConstruct, ScriptTokenKind};

/// What an editor colors a token as.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum SyntaxKind {
    Identifier,
    Keyword,
    String,
    QuotedIdentifier,
    Number,
    Comment,
    Operator,
    Punctuation,
}

/// A token an editor colors, over a byte range of the text it came from.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SyntaxToken {
    pub kind: SyntaxKind,
    pub range: Range<usize>,
}

/// In order, without white space; an open construct runs to the end. Redis and MongoDB have none.
pub fn syntax_tokens(text: &str, grammar: SqlGrammar, settings: LexicalSettings) -> Vec<SyntaxToken> {
    let Some(rules) = rules_for(grammar) else {
        return Vec::new();
    };
    let keywords = keywords_of(grammar);
    let mut lexer = Lexer::new(text, &rules.syntax, settings, ServerReading::Client);
    let mut tokens = Vec::new();
    while let Some(token) = lexer.next_token(None) {
        if token.range.end <= token.range.start {
            break;
        }
        let kind = match token.kind {
            ScriptTokenKind::Whitespace => continue,
            ScriptTokenKind::LineComment | ScriptTokenKind::BlockComment | ScriptTokenKind::ExecutableMarker => {
                SyntaxKind::Comment
            }
            ScriptTokenKind::StringLiteral | ScriptTokenKind::DollarQuoted => SyntaxKind::String,
            ScriptTokenKind::QuotedIdentifier => SyntaxKind::QuotedIdentifier,
            ScriptTokenKind::Word => word_kind(text.get(token.range.clone()).unwrap_or_default(), keywords),
            ScriptTokenKind::Number => SyntaxKind::Number,
            ScriptTokenKind::Semicolon | ScriptTokenKind::OpenParen | ScriptTokenKind::CloseParen => {
                SyntaxKind::Punctuation
            }
            ScriptTokenKind::Punct => SyntaxKind::Operator,
            ScriptTokenKind::Directive => SyntaxKind::Keyword,
            ScriptTokenKind::Unterminated => match token.open {
                Some(OpenConstruct::BlockComment) => SyntaxKind::Comment,
                Some(OpenConstruct::QuotedIdentifier) => SyntaxKind::QuotedIdentifier,
                Some(OpenConstruct::StringLiteral | OpenConstruct::DollarQuoted) | None => SyntaxKind::String,
            },
        };
        tokens.push(SyntaxToken {
            kind,
            range: token.range,
        });
    }
    tokens
}

// The longest keyword or reserved word any grammar lists, with room to spare.
const LONGEST_KEYWORD: usize = 48;

fn word_kind(word: &str, keywords: &HashSet<String>) -> SyntaxKind {
    if word.len() > LONGEST_KEYWORD || !word.is_ascii() {
        return SyntaxKind::Identifier;
    }
    let mut upper = [0u8; LONGEST_KEYWORD];
    let upper = &mut upper[..word.len()];
    upper.copy_from_slice(word.as_bytes());
    upper.make_ascii_uppercase();
    match std::str::from_utf8(upper) {
        Ok(upper) if keywords.contains(upper) => SyntaxKind::Keyword,
        _ => SyntaxKind::Identifier,
    }
}

fn keywords_of(grammar: SqlGrammar) -> &'static HashSet<String> {
    static SETS: OnceLock<Vec<(SqlGrammar, HashSet<String>)>> = OnceLock::new();
    static EMPTY: OnceLock<HashSet<String>> = OnceLock::new();
    let sets = SETS.get_or_init(|| {
        SqlGrammar::SQL
            .iter()
            .map(|&grammar| {
                let words = grammar
                    .keywords()
                    .map(str::to_owned)
                    .chain(
                        grammar
                            .reserved_words()
                            .split_ascii_whitespace()
                            .map(str::to_ascii_uppercase),
                    )
                    .filter(|word| word.len() <= LONGEST_KEYWORD)
                    .collect();
                (grammar, words)
            })
            .collect()
    });
    sets.iter()
        .find(|(listed, _)| *listed == grammar)
        .map_or_else(|| EMPTY.get_or_init(HashSet::new), |(_, words)| words)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn kinds(text: &str, grammar: SqlGrammar) -> Vec<(SyntaxKind, &str)> {
        syntax_tokens(text, grammar, LexicalSettings::default_for(grammar))
            .into_iter()
            .map(|token| (token.kind, &text[token.range]))
            .collect()
    }

    #[test]
    fn keywords_match_in_any_case() {
        assert_eq!(
            kinds("select Id FrOm orders;", SqlGrammar::PostgreSql),
            vec![
                (SyntaxKind::Keyword, "select"),
                (SyntaxKind::Identifier, "Id"),
                (SyntaxKind::Keyword, "FrOm"),
                (SyntaxKind::Identifier, "orders"),
                (SyntaxKind::Punctuation, ";"),
            ]
        );
    }

    #[test]
    fn reserved_words_count_as_keywords() {
        assert_eq!(kinds("limit", SqlGrammar::Cql), vec![(SyntaxKind::Keyword, "limit")]);
    }

    #[test]
    fn a_block_comment_spans_lines() {
        let text = "a /* one\ntwo\n*/ b";
        assert_eq!(
            kinds(text, SqlGrammar::PostgreSql),
            vec![
                (SyntaxKind::Identifier, "a"),
                (SyntaxKind::Comment, "/* one\ntwo\n*/"),
                (SyntaxKind::Identifier, "b"),
            ]
        );
    }

    #[test]
    fn an_unterminated_string_runs_to_the_end() {
        let text = "select 'abc\nselect 1";
        assert_eq!(
            kinds(text, SqlGrammar::Sqlite),
            vec![(SyntaxKind::Keyword, "select"), (SyntaxKind::String, "'abc\nselect 1")]
        );
    }

    #[test]
    fn an_unterminated_comment_is_a_comment() {
        assert_eq!(
            kinds("/* open", SqlGrammar::MySql),
            vec![(SyntaxKind::Comment, "/* open")]
        );
    }

    #[test]
    fn a_vietnamese_string_keeps_its_byte_range() {
        let text = "insert into t values ('Đơn hàng số 1', 2.5);";
        let tokens = kinds(text, SqlGrammar::MySql);
        assert!(tokens.contains(&(SyntaxKind::String, "'Đơn hàng số 1'")));
        assert!(tokens.contains(&(SyntaxKind::Number, "2.5")));
        assert!(tokens.contains(&(SyntaxKind::Operator, ",")));
    }

    #[test]
    fn mysql_backslash_escapes_follow_the_setting() {
        let text = r"select 'a\'b' x";
        let on = syntax_tokens(
            text,
            SqlGrammar::MySql,
            LexicalSettings {
                backslash_escapes: true,
            },
        );
        assert_eq!(on.get(1).map(|token| &text[token.range.clone()]), Some(r"'a\'b'"));
        assert_eq!(on.get(2).map(|token| token.kind), Some(SyntaxKind::Identifier));

        let off = syntax_tokens(
            text,
            SqlGrammar::MySql,
            LexicalSettings {
                backslash_escapes: false,
            },
        );
        assert_eq!(off.get(1).map(|token| &text[token.range.clone()]), Some(r"'a\'"));
    }

    #[test]
    fn quoted_names_and_numbers() {
        assert_eq!(
            kinds("\"Order\" 1e3 `x`", SqlGrammar::PostgreSql)[..2],
            [(SyntaxKind::QuotedIdentifier, "\"Order\""), (SyntaxKind::Number, "1e3")]
        );
        assert_eq!(
            kinds("`x`", SqlGrammar::MySql),
            vec![(SyntaxKind::QuotedIdentifier, "`x`")]
        );
    }

    #[test]
    fn redis_and_mongo_have_no_tokens() {
        assert!(kinds("GET key", SqlGrammar::Redis).is_empty());
        assert!(kinds("db.users.find()", SqlGrammar::Mongo).is_empty());
    }
}
