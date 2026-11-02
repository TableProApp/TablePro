//! The expression keys and the WHERE clause of an index, read from the
//! CREATE INDEX that SQLite stored for it.
//!
//! sqlparser parses the statement, which settles how many keys there
//! are and whether one has a sort order or the index a predicate. The
//! text of each comes from sqlparser's own token stream rather than
//! from the AST's spans: in sqlparser 0.63 a function call's span stops
//! before its closing parenthesis and a parenthesised expression's
//! span skips its parentheses, so a span slice would cut keys short.
//! The tokens carry exact positions, and quotes, brackets and comments
//! are already single tokens there, so the top-level commas are the
//! only places a key list can split. Where the tokens and the AST do
//! not line up, the AST's own rendering of the expression is used.

use std::ops::Range;

use sqlparser::ast::{CreateIndex, OrderBySort, Statement};
use sqlparser::dialect::SQLiteDialect;
use sqlparser::keywords::Keyword;
use sqlparser::parser::Parser;
use sqlparser::tokenizer::{Location, Token, Tokenizer};

/// What an index's stored SQL says beyond the pragmas.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct IndexSql {
    /// One entry per key, in key order: the key as written, without its
    /// ASC or DESC.
    pub keys: Vec<String>,
    pub predicate: Option<String>,
}

/// Read a CREATE INDEX. `None` when it does not parse as exactly one.
pub(crate) fn read_index_sql(sql: &str) -> Option<IndexSql> {
    let dialect = SQLiteDialect {};
    let mut statements = Parser::parse_sql(&dialect, sql).ok()?;
    let Some(Statement::CreateIndex(index)) = statements.pop() else {
        return None;
    };
    if !statements.is_empty() {
        return None;
    }
    let tokens = SourceTokens::read(&dialect, sql);
    let cut = tokens.as_ref().and_then(|tokens| tokens.cut(&index));
    Some(texts(&index, cut))
}

fn texts(index: &CreateIndex, cut: Option<Cut>) -> IndexSql {
    let Cut { keys, predicate } = cut.unwrap_or_default();
    let aligned = keys.len() == index.columns.len();
    IndexSql {
        keys: index
            .columns
            .iter()
            .enumerate()
            .map(|(position, column)| match keys.get(position) {
                Some(text) if aligned => text.clone(),
                _ => column.column.expr.to_string(),
            })
            .collect(),
        predicate: index
            .predicate
            .as_ref()
            .map(|expression| predicate.unwrap_or_else(|| expression.to_string())),
    }
}

/// The key texts and the predicate text the tokens gave.
#[derive(Debug, Default)]
struct Cut {
    keys: Vec<String>,
    predicate: Option<String>,
}

/// The statement's tokens, each with the bytes of the text it came
/// from.
struct SourceTokens<'a> {
    sql: &'a str,
    tokens: Vec<(Token, Range<usize>)>,
}

impl<'a> SourceTokens<'a> {
    fn read(dialect: &SQLiteDialect, sql: &'a str) -> Option<Self> {
        let lines = LineStarts::new(sql);
        let tokens = Tokenizer::new(dialect, sql)
            .tokenize_with_location()
            .ok()?
            .into_iter()
            .map(|token| {
                let start = lines.byte(token.span.start)?;
                let end = lines.byte(token.span.end)?;
                Some((token.token, start..end))
            })
            .collect::<Option<Vec<_>>>()?;
        Some(Self { sql, tokens })
    }

    fn cut(&self, index: &CreateIndex) -> Option<Cut> {
        let open = self.key_list_open()?;
        let (segments, close) = self.segments(open)?;
        let keys = segments
            .into_iter()
            .zip(&index.columns)
            .map(|(segment, column)| {
                let sorted = matches!(column.column.options.sort, Some(OrderBySort::Asc | OrderBySort::Desc));
                self.key_text(segment, sorted)
            })
            .collect::<Option<Vec<_>>>()?;
        Some(Cut {
            keys,
            predicate: self.predicate(close),
        })
    }

    /// The parenthesis after ON that opens the key list.
    fn key_list_open(&self) -> Option<usize> {
        let mut after_on = false;
        let mut depth = 0usize;
        for (position, (token, _)) in self.tokens.iter().enumerate() {
            match token {
                Token::Word(word) if depth == 0 && word.keyword == Keyword::ON => after_on = true,
                Token::LParen if depth == 0 && after_on => return Some(position),
                Token::LParen => depth += 1,
                Token::RParen => depth = depth.saturating_sub(1),
                _ => {}
            }
        }
        None
    }

    /// The token ranges between the key list's top-level commas, and the
    /// position of the parenthesis that closes it.
    fn segments(&self, open: usize) -> Option<(Vec<Range<usize>>, usize)> {
        let mut segments = Vec::new();
        let mut start = open + 1;
        let mut depth = 0usize;
        for (position, (token, _)) in self.tokens.iter().enumerate().skip(open + 1) {
            match token {
                Token::LParen => depth += 1,
                Token::RParen if depth == 0 => {
                    segments.push(start..position);
                    return Some((segments, position));
                }
                Token::RParen => depth -= 1,
                Token::Comma if depth == 0 => {
                    segments.push(start..position);
                    start = position + 1;
                }
                _ => {}
            }
        }
        None
    }

    fn key_text(&self, segment: Range<usize>, sorted: bool) -> Option<String> {
        let mut segment = self.trimmed(segment);
        if sorted {
            let last = segment.end.checked_sub(1)?;
            let ordering = matches!(
                self.tokens.get(last),
                Some((Token::Word(word), _)) if matches!(word.keyword, Keyword::ASC | Keyword::DESC)
            );
            if ordering {
                segment = self.trimmed(segment.start..last);
            }
        }
        self.text(segment)
    }

    /// Everything after a top-level WHERE that follows the key list, up
    /// to a closing semicolon.
    fn predicate(&self, close: usize) -> Option<String> {
        let start = self
            .tokens
            .iter()
            .enumerate()
            .skip(close + 1)
            .find_map(|(position, (token, _))| {
                matches!(token, Token::Word(word) if word.keyword == Keyword::WHERE).then_some(position + 1)
            })?;
        let end = self
            .tokens
            .iter()
            .enumerate()
            .skip(start)
            .find_map(|(position, (token, _))| matches!(token, Token::SemiColon).then_some(position))
            .unwrap_or(self.tokens.len());
        self.text(self.trimmed(start..end))
    }

    /// The range without the whitespace and comments at either end.
    fn trimmed(&self, mut range: Range<usize>) -> Range<usize> {
        while range.start < range.end && self.is_trivia(range.start) {
            range.start += 1;
        }
        while range.end > range.start && self.is_trivia(range.end - 1) {
            range.end -= 1;
        }
        range
    }

    fn is_trivia(&self, position: usize) -> bool {
        matches!(self.tokens.get(position), Some((Token::Whitespace(_), _)))
    }

    fn text(&self, range: Range<usize>) -> Option<String> {
        if range.is_empty() {
            return None;
        }
        let start = self.tokens.get(range.start)?.1.start;
        let end = self.tokens.get(range.end - 1)?.1.end;
        self.sql.get(start..end).map(str::to_owned)
    }
}

/// Byte offsets for the tokenizer's line and column locations, which
/// count characters from 1.
struct LineStarts<'a> {
    text: &'a str,
    starts: Vec<usize>,
}

impl<'a> LineStarts<'a> {
    fn new(text: &'a str) -> Self {
        let starts = std::iter::once(0)
            .chain(text.match_indices('\n').map(|(newline, _)| newline + 1))
            .collect();
        Self { text, starts }
    }

    fn byte(&self, location: Location) -> Option<usize> {
        let line = usize::try_from(location.line).ok()?.checked_sub(1)?;
        let column = usize::try_from(location.column).ok()?.checked_sub(1)?;
        let start = *self.starts.get(line)?;
        let rest = self.text.get(start..)?;
        match rest.char_indices().nth(column) {
            Some((offset, _)) => Some(start + offset),
            None if rest.chars().count() == column => Some(self.text.len()),
            None => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn key_list_keeps_quotes_brackets_and_comments_inside_keys() {
        let sql = "CREATE INDEX i ON t (lower(\"a,b\"), [c,d] DESC, f(x /* , */, 'y,z'), (g + 1) * 2 ASC)";

        let read = read_index_sql(sql).unwrap();

        assert_eq!(
            read.keys,
            ["lower(\"a,b\")", "[c,d]", "f(x /* , */, 'y,z')", "(g + 1) * 2"]
        );
        assert_eq!(read.predicate, None);
    }

    #[test]
    fn where_tail_is_predicate() {
        let sql = "CREATE INDEX i ON t (substr(a, 1, 3), \"b,c\" DESC) WHERE a <> 'x,y' AND (b > 0)";

        let read = read_index_sql(sql).unwrap();

        assert_eq!(read.keys, ["substr(a, 1, 3)", "\"b,c\""]);
        assert_eq!(read.predicate.as_deref(), Some("a <> 'x,y' AND (b > 0)"));
    }

    #[test]
    fn keys_on_later_lines_keep_their_text() {
        let sql = "CREATE UNIQUE INDEX IF NOT EXISTS \"é\" ON \"t\"(\n  upper(name),\n  id\n)\nWHERE id > 0";

        let read = read_index_sql(sql).unwrap();

        assert_eq!(read.keys, ["upper(name)", "id"]);
        assert_eq!(read.predicate.as_deref(), Some("id > 0"));
    }

    #[test]
    fn keys_fall_back_to_the_parsed_expression_when_the_tokens_do_not_line_up() {
        let parsed = Parser::parse_sql(&SQLiteDialect {}, "CREATE INDEX i ON t (lower( a ), b) WHERE b > 1").unwrap();
        let Some(Statement::CreateIndex(index)) = parsed.into_iter().next() else {
            panic!("not a CREATE INDEX");
        };
        let short = Cut {
            keys: vec!["only one".to_owned()],
            predicate: None,
        };

        let read = texts(&index, Some(short));

        assert_eq!(read.keys, ["lower(a)", "b"]);
        assert_eq!(read.predicate.as_deref(), Some("b > 1"));
    }

    #[test]
    fn something_other_than_create_index_is_not_read() {
        assert_eq!(read_index_sql("CREATE TABLE t (a)"), None);
        assert_eq!(read_index_sql("not sql at all"), None);
    }
}
