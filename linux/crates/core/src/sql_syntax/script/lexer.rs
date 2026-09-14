use std::collections::HashSet;
use std::ops::Range;

use crate::sql_syntax::script::script_rules::{
    BackslashPolicy, BracketIdentifier, DollarQuote, HashComment, QuoteKind, QuoteRule, ScriptSyntax,
};
use crate::sql_syntax::script::{LexicalSettings, OpenConstruct, ScriptTokenKind};

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct LexedToken {
    pub kind: ScriptTokenKind,
    pub range: Range<usize>,
    pub open: Option<OpenConstruct>,
}

pub(crate) struct Lexer<'a> {
    text: &'a str,
    bytes: &'a [u8],
    syntax: &'static ScriptSyntax,
    settings: LexicalSettings,
    pos: usize,
    missing_heredoc_closers: HashSet<&'a str>,
}

impl<'a> Lexer<'a> {
    pub fn new(text: &'a str, syntax: &'static ScriptSyntax, settings: LexicalSettings) -> Self {
        Self {
            text,
            bytes: text.as_bytes(),
            syntax,
            settings,
            pos: 0,
            missing_heredoc_closers: HashSet::new(),
        }
    }

    pub fn position(&self) -> usize {
        self.pos
    }

    pub fn at_line_start(&self) -> bool {
        self.pos == 0 || self.bytes.get(self.pos - 1) == Some(&b'\n')
    }

    pub fn skip_to(&mut self, end: usize) {
        self.pos = end.min(self.bytes.len());
    }

    pub fn next_token(&mut self, delimiter: Option<&str>) -> Option<LexedToken> {
        let start = self.pos;
        let first = *self.bytes.get(start)?;
        let token = match delimiter {
            Some(delimiter) if !delimiter.is_empty() && self.text[start..].starts_with(delimiter) => {
                self.plain(ScriptTokenKind::Semicolon, start + delimiter.len())
            }
            _ => self.lex_at(start, first, delimiter),
        };
        self.pos = token.range.end;
        Some(token)
    }

    fn lex_at(&mut self, start: usize, first: u8, delimiter: Option<&str>) -> LexedToken {
        let next = self.bytes.get(start + 1).copied();
        match first {
            b if is_space(b) => self.plain(ScriptTokenKind::Whitespace, self.whitespace_end(start)),
            b'-' if next == Some(b'-') && self.dash_comment_starts(start) => self.line_comment(start),
            b'#' if self.hash_comment_starts(next) => self.line_comment(start),
            b'/' if next == Some(b'*') => self.block_comment(start),
            b'/' if next == Some(b'/') && self.syntax.slash_slash_comment => self.line_comment(start),
            b'\'' => self.quoted(start, self.syntax.single_quote),
            b'"' => self.quoted(start, self.syntax.double_quote),
            b'`' => match self.syntax.backtick {
                Some(rule) => self.quoted(start, rule),
                None => self.plain(ScriptTokenKind::Punct, start + 1),
            },
            b'[' => self.bracketed(start),
            b'$' => self.dollar(start, delimiter),
            b';' if delimiter.is_none() => self.plain(ScriptTokenKind::Semicolon, start + 1),
            b'(' => self.plain(ScriptTokenKind::OpenParen, start + 1),
            b')' => self.plain(ScriptTokenKind::CloseParen, start + 1),
            b if b.is_ascii_digit() => self.plain(ScriptTokenKind::Number, self.word_end(start + 1, delimiter)),
            b if self.is_word_start(b) => self.word(start, delimiter),
            _ => self.plain(ScriptTokenKind::Punct, start + 1),
        }
    }

    fn plain(&self, kind: ScriptTokenKind, end: usize) -> LexedToken {
        LexedToken {
            kind,
            range: self.pos..end,
            open: None,
        }
    }

    fn unterminated(&self, start: usize, construct: OpenConstruct) -> LexedToken {
        LexedToken {
            kind: ScriptTokenKind::Unterminated,
            range: start..self.bytes.len(),
            open: Some(construct),
        }
    }

    fn whitespace_end(&self, start: usize) -> usize {
        let mut end = start;
        while let Some(&b) = self.bytes.get(end) {
            if !is_space(b) {
                break;
            }
            end += 1;
            if b == b'\n' {
                break;
            }
        }
        end
    }

    fn dash_comment_starts(&self, start: usize) -> bool {
        !self.syntax.dash_comment_needs_space
            || self
                .bytes
                .get(start + 2)
                .is_none_or(|b| b.is_ascii_whitespace() || b.is_ascii_control())
    }

    fn hash_comment_starts(&self, next: Option<u8>) -> bool {
        match self.syntax.hash_comment {
            HashComment::None => false,
            HashComment::Always => true,
            HashComment::SpaceOrBang => matches!(next, Some(b' ' | b'!')),
        }
    }

    fn line_comment(&self, start: usize) -> LexedToken {
        let end = find_byte(self.bytes, start, b'\n').unwrap_or(self.bytes.len());
        self.plain(ScriptTokenKind::LineComment, end)
    }

    fn block_comment(&self, start: usize) -> LexedToken {
        let mut depth = 1u32;
        let mut index = start + 2;
        while let Some(&b) = self.bytes.get(index) {
            let next = self.bytes.get(index + 1).copied();
            if b == b'*' && next == Some(b'/') {
                depth -= 1;
                index += 2;
                if depth == 0 {
                    return self.plain(ScriptTokenKind::BlockComment, index);
                }
            } else if b == b'/' && next == Some(b'*') && self.syntax.nested_block_comments {
                depth += 1;
                index += 2;
            } else {
                index += 1;
            }
        }
        self.unterminated(start, OpenConstruct::BlockComment)
    }

    fn quoted(&self, start: usize, rule: QuoteRule) -> LexedToken {
        let backslash = match rule.backslash {
            BackslashPolicy::Never => false,
            BackslashPolicy::Always => true,
            BackslashPolicy::WhenEnabled => self.settings.backslash_escapes,
        };
        let (kind, construct) = match rule.kind {
            QuoteKind::StringLiteral => (ScriptTokenKind::StringLiteral, OpenConstruct::StringLiteral),
            QuoteKind::QuotedIdentifier => (ScriptTokenKind::QuotedIdentifier, OpenConstruct::QuotedIdentifier),
        };
        let quote = self.bytes[start];
        match self.quote_end(start + 1, quote, backslash) {
            Some(end) => self.plain(kind, end),
            None => self.unterminated(start, construct),
        }
    }

    fn quote_end(&self, from: usize, quote: u8, backslash: bool) -> Option<usize> {
        let mut index = from;
        while let Some(&b) = self.bytes.get(index) {
            if backslash && b == b'\\' {
                index += 2;
            } else if b == quote {
                if self.bytes.get(index + 1) == Some(&quote) {
                    index += 2;
                } else {
                    return Some(index + 1);
                }
            } else {
                index += 1;
            }
        }
        None
    }

    fn escape_string(&self, start: usize) -> LexedToken {
        match self.quote_end(start + 2, b'\'', true) {
            Some(end) => self.plain(ScriptTokenKind::StringLiteral, end),
            None => self.unterminated(start, OpenConstruct::StringLiteral),
        }
    }

    fn bracketed(&self, start: usize) -> LexedToken {
        let doubling = match self.syntax.bracket_identifier {
            BracketIdentifier::None => return self.plain(ScriptTokenKind::Punct, start + 1),
            BracketIdentifier::NoDoubling => false,
            BracketIdentifier::Doubling => true,
        };
        let mut index = start + 1;
        while let Some(close) = find_byte(self.bytes, index, b']') {
            if doubling && self.bytes.get(close + 1) == Some(&b']') {
                index = close + 2;
            } else {
                return self.plain(ScriptTokenKind::QuotedIdentifier, close + 1);
            }
        }
        self.unterminated(start, OpenConstruct::QuotedIdentifier)
    }

    fn dollar(&mut self, start: usize, delimiter: Option<&str>) -> LexedToken {
        match self.syntax.dollar_quote {
            DollarQuote::Tagged => {
                if let Some(opener_end) = self.tagged_opener_end(start) {
                    let opener = &self.text[start..opener_end];
                    return match self.text[opener_end..].find(opener) {
                        Some(offset) => self.plain(ScriptTokenKind::DollarQuoted, opener_end + offset + opener.len()),
                        None => self.unterminated(start, OpenConstruct::DollarQuoted),
                    };
                }
            }
            DollarQuote::Heredoc => {
                if let Some(end) = self.heredoc_end(start) {
                    return self.plain(ScriptTokenKind::DollarQuoted, end);
                }
            }
            DollarQuote::None => {}
        }
        if self.is_word_start(b'$') {
            return self.word(start, delimiter);
        }
        self.plain(ScriptTokenKind::Punct, start + 1)
    }

    fn tagged_opener_end(&self, start: usize) -> Option<usize> {
        let mut index = start + 1;
        let first = *self.bytes.get(index)?;
        if first != b'$' {
            if !(first.is_ascii_alphabetic() || first == b'_' || first >= 0x80) {
                return None;
            }
            while self
                .bytes
                .get(index)
                .is_some_and(|b| b.is_ascii_alphanumeric() || *b == b'_' || *b >= 0x80)
            {
                index += 1;
            }
            if self.bytes.get(index) != Some(&b'$') {
                return None;
            }
        }
        Some(index + 1)
    }

    fn heredoc_end(&mut self, start: usize) -> Option<usize> {
        let close = find_byte(self.bytes, start + 1, b'$')?;
        let opener = &self.text[start..=close];
        if self.missing_heredoc_closers.contains(opener) {
            return None;
        }
        match self.text[close + 1..].find(opener) {
            Some(offset) => Some(close + 1 + offset + opener.len()),
            None => {
                self.missing_heredoc_closers.insert(opener);
                None
            }
        }
    }

    fn word(&self, start: usize, delimiter: Option<&str>) -> LexedToken {
        let end = self.word_end(start + 1, delimiter);
        let is_escape_prefix = self.syntax.escape_string_prefix
            && end == start + 1
            && matches!(self.bytes[start], b'e' | b'E')
            && self.bytes.get(end) == Some(&b'\'');
        if is_escape_prefix {
            return self.escape_string(start);
        }
        self.plain(ScriptTokenKind::Word, end)
    }

    fn word_end(&self, from: usize, delimiter: Option<&str>) -> usize {
        let delimiter = delimiter.filter(|d| d.bytes().next().is_some_and(|b| self.is_word_part(b)));
        let mut end = from;
        while let Some(&b) = self.bytes.get(end) {
            if !self.is_word_part(b) || delimiter.is_some_and(|d| self.bytes[end..].starts_with(d.as_bytes())) {
                break;
            }
            end += 1;
        }
        end
    }

    fn is_word_start(&self, b: u8) -> bool {
        b.is_ascii_alphabetic() || b == b'_' || b >= 0x80 || self.syntax.word_start_extra.contains(&b)
    }

    fn is_word_part(&self, b: u8) -> bool {
        b.is_ascii_alphanumeric() || b == b'_' || b >= 0x80 || self.syntax.word_part_extra.contains(&b)
    }
}

fn is_space(b: u8) -> bool {
    matches!(b, b' ' | b'\t' | b'\n' | b'\r' | 0x0b | 0x0c)
}

fn find_byte(bytes: &[u8], from: usize, needle: u8) -> Option<usize> {
    bytes
        .get(from..)?
        .iter()
        .position(|&b| b == needle)
        .map(|offset| from + offset)
}
