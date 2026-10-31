use std::collections::HashSet;
use std::ops::Range;

use crate::sql_syntax::script::script_rules::{
    BackslashPolicy, BracketIdentifier, DollarQuote, HashComment, QuoteKind, QuoteRule, ScriptSyntax,
};
use crate::sql_syntax::script::server_reading::{CommentRead, NameQuotes, ServerReading, dollar_tag_end, read_at};
use crate::sql_syntax::script::{LexicalSettings, OpenConstruct, ScriptTokenKind};

/// MariaDB's MSSQL mode ends a `[name]` at a `]` that is not doubled.
const MARIADB_BRACKETS: BracketIdentifier = BracketIdentifier::Doubling;

/// U+FEFF as UTF-8.
const BYTE_ORDER_MARK: &[u8] = b"\xEF\xBB\xBF";

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
    reading: ServerReading,
    pos: usize,
    missing_heredoc_closers: HashSet<&'a str>,
    /// Where the executable comment the lexer is inside opened.
    executable: Option<usize>,
}

impl<'a> Lexer<'a> {
    pub fn new(
        text: &'a str,
        syntax: &'static ScriptSyntax,
        settings: LexicalSettings,
        reading: ServerReading,
    ) -> Self {
        Self {
            text,
            bytes: text.as_bytes(),
            syntax,
            settings,
            reading,
            pos: 0,
            missing_heredoc_closers: HashSet::new(),
            executable: None,
        }
    }

    pub fn position(&self) -> usize {
        self.pos
    }

    pub fn open_executable_comment(&self) -> Option<usize> {
        self.executable
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
            // The server ends an executable comment at the first `*/`
            // that stands where a token could start.
            _ if self.executable.is_some() && self.text[start..].starts_with("*/") => {
                self.executable = None;
                self.plain(ScriptTokenKind::ExecutableMarker, start + 2)
            }
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
        if self.syntax.tcl_parameters
            && let Some(end) = self.tcl_parameter_end(start, first)
        {
            return self.plain(ScriptTokenKind::Word, end);
        }
        match first {
            b if is_space(b) => self.plain(ScriptTokenKind::Whitespace, self.whitespace_end(start)),
            0xEF if self.syntax.byte_order_mark_is_space && self.bytes[start..].starts_with(BYTE_ORDER_MARK) => {
                self.plain(ScriptTokenKind::Whitespace, start + BYTE_ORDER_MARK.len())
            }
            b'-' if next == Some(b'-') && self.dash_comment_starts(start) => self.line_comment(start),
            b'#' if self.hash_comment_starts(next) => self.line_comment(start),
            b'/' if next == Some(b'*') => self.comment(start),
            b'/' if next == Some(b'/') && self.syntax.slash_slash_comment => self.line_comment(start),
            b'\'' => self.quoted(start, self.syntax.single_quote),
            b'"' => self.quoted(start, self.double_quote()),
            b'`' => match self.syntax.backtick {
                Some(rule) => self.quoted(start, rule),
                None => self.plain(ScriptTokenKind::Punct, start + 1),
            },
            b'[' => self.bracketed(start),
            b'$' => self.dollar(start, delimiter),
            b';' if delimiter.is_none() => self.plain(ScriptTokenKind::Semicolon, start + 1),
            b'(' => self.plain(ScriptTokenKind::OpenParen, start + 1),
            b')' => self.plain(ScriptTokenKind::CloseParen, start + 1),
            b if b.is_ascii_digit() => self.plain(ScriptTokenKind::Number, self.number_end(start, delimiter)),
            b'.' if next.is_some_and(|b| b.is_ascii_digit()) && !self.follows_dot(start) => {
                self.plain(ScriptTokenKind::Number, self.number_end(start, delimiter))
            }
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
        let ends_at_cr = self.syntax.line_comment_ends_at_cr;
        let end = self
            .bytes
            .get(start..)
            .and_then(|rest| rest.iter().position(|&b| b == b'\n' || (ends_at_cr && b == b'\r')))
            .map_or(self.bytes.len(), |offset| start + offset);
        self.plain(ScriptTokenKind::LineComment, end)
    }

    fn comment(&mut self, start: usize) -> LexedToken {
        let read = match self.syntax.executable_comments {
            true => read_at(&self.bytes[start..], self.reading),
            false => None,
        };
        match read {
            None => self.block_comment(start),
            Some(CommentRead::Runs { content_start }) => {
                self.executable.get_or_insert(start);
                self.plain(ScriptTokenKind::ExecutableMarker, start + content_start)
            }
            Some(CommentRead::Skipped) => self.skipped_comment(start),
        }
    }

    /// A comment a server's version skips, read as its `consume_comment`
    /// reads it: bytes to the first `*/`, past one level of `/* */`.
    fn skipped_comment(&self, start: usize) -> LexedToken {
        let close = |from: usize| {
            self.text
                .get(from..)
                .and_then(|rest| rest.find("*/"))
                .map(|offset| from + offset + 2)
        };
        let mut index = start + 2;
        while let Some(&b) = self.bytes.get(index) {
            let next = self.bytes.get(index + 1).copied();
            if b == b'/' && next == Some(b'*') {
                match close(index + 2) {
                    Some(end) => index = end,
                    None => break,
                }
            } else if b == b'*' && next == Some(b'/') {
                return self.plain(ScriptTokenKind::BlockComment, index + 2);
            } else {
                index += 1;
            }
        }
        self.unterminated(start, OpenConstruct::BlockComment)
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

    /// An `E'...'` string, with every `'...'` that continues it: the
    /// server reads those by the rules of the first piece, so a backslash
    /// escapes in them whatever `standard_conforming_strings` says.
    fn escape_string(&self, start: usize) -> LexedToken {
        let mut from = start + 2;
        loop {
            let Some(end) = self.quote_end(from, b'\'', true) else {
                return self.unterminated(start, OpenConstruct::StringLiteral);
            };
            match self.continuing_quote(end) {
                Some(quote) => from = quote + 1,
                None => return self.plain(ScriptTokenKind::StringLiteral, end),
            }
        }
    }

    /// The quote that carries on the string that closed just before
    /// `from`, as PostgreSQL's `quotecontinue` rule finds it: only blanks
    /// and `--` comments in between, a line break among them. Before the
    /// first line break only a space, tab or form feed counts as a blank.
    fn continuing_quote(&self, from: usize) -> Option<usize> {
        let mut index = from;
        let mut line_broke = false;
        loop {
            match *self.bytes.get(index)? {
                b'\n' | b'\r' => {
                    line_broke = true;
                    index += 1;
                }
                b' ' | b'\t' | 0x0c => index += 1,
                0x0b if line_broke => index += 1,
                b'-' if self.bytes.get(index + 1) == Some(&b'-') => {
                    index += self.bytes[index..].iter().position(|&b| b == b'\n' || b == b'\r')?;
                }
                b'\'' if line_broke => return Some(index),
                _ => return None,
            }
        }
    }

    fn double_quote(&self) -> QuoteRule {
        match self.reading.name_quotes() {
            NameQuotes::Default => self.syntax.double_quote,
            NameQuotes::Ansi | NameQuotes::Brackets => QuoteRule {
                kind: QuoteKind::QuotedIdentifier,
                backslash: BackslashPolicy::Never,
            },
        }
    }

    fn bracketed(&self, start: usize) -> LexedToken {
        let rule = match self.reading.name_quotes() {
            NameQuotes::Brackets => MARIADB_BRACKETS,
            NameQuotes::Default | NameQuotes::Ansi => self.syntax.bracket_identifier,
        };
        let doubling = match rule {
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
        if self.reading.quotes_dollar_tags()
            && let Some(token) = self.mysql_dollar_quote(start)
        {
            return token;
        }
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
            DollarQuote::Untagged if self.bytes.get(start + 1) == Some(&b'$') => {
                return match self.text[start + 2..].find("$$") {
                    Some(offset) => self.plain(ScriptTokenKind::DollarQuoted, start + 2 + offset + 2),
                    None => self.unterminated(start, OpenConstruct::DollarQuoted),
                };
            }
            DollarQuote::Untagged | DollarQuote::None => {}
        }
        if self.is_word_start(b'$') {
            return self.word(start, delimiter);
        }
        self.plain(ScriptTokenKind::Punct, start + 1)
    }

    /// SQLite reads `$space::name(…)` as one token, and the same after `@`,
    /// `:` and `#`, as `sqlite3GetToken` reads it: a parameter whose name
    /// runs from the parenthesis to the next `)` whatever stands between,
    /// a quote or a `;` included. White space or the end of the text ends
    /// it first, as a token SQLite refuses. `None` for a name that is one
    /// word, which needs no rule of its own.
    fn tcl_parameter_end(&self, start: usize, first: u8) -> Option<usize> {
        if !matches!(first, b'$' | b'@' | b':' | b'#') {
            return None;
        }
        let mut named = false;
        let mut qualified = false;
        let mut index = start + 1;
        while let Some(&b) = self.bytes.get(index) {
            match b {
                b if self.is_word_part(b) => {
                    named = true;
                    index += 1;
                }
                b':' if self.bytes.get(index + 1) == Some(&b':') => {
                    qualified = true;
                    index += 2;
                }
                b'(' if named => {
                    let stop = self.bytes[index..]
                        .iter()
                        .position(|&b| matches!(b, b')' | 0) || is_space(b))
                        .map_or(self.bytes.len(), |offset| index + offset);
                    return Some(stop + usize::from(self.bytes.get(stop) == Some(&b')')));
                }
                _ => break,
            }
        }
        qualified.then_some(index)
    }

    /// MySQL 8.1 and later quote text in `$tag$ … $tag$` where a token
    /// starts, as `get_dollar_quoted_text` reads it. A `$` that breaks a
    /// partial match of the closer cannot start the next one.
    fn mysql_dollar_quote(&self, start: usize) -> Option<LexedToken> {
        // After `.` or `@` the server is inside a name.
        if start
            .checked_sub(1)
            .and_then(|before| self.bytes.get(before))
            .is_some_and(|b| matches!(b, b'.' | b'@'))
        {
            return None;
        }
        let opener_end = dollar_tag_end(self.bytes, start)?;
        let closer = &self.bytes[start..opener_end];
        let mut matched = 0;
        for (index, &b) in self.bytes.iter().enumerate().skip(opener_end) {
            if matched > 0 && b == closer[matched] {
                matched += 1;
                if matched == closer.len() {
                    return Some(self.plain(ScriptTokenKind::DollarQuoted, index + 1));
                }
            } else {
                matched = usize::from(matched == 0 && b == b'$');
            }
        }
        Some(self.unterminated(start, OpenConstruct::DollarQuoted))
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

    /// A numeric constant as SQL spells it: digits, an optional fraction
    /// and an optional exponent, so `0.5` and `1.5e-3` stay one token.
    /// Letters and underscores glued on after that (`0x1F`, `1_000`, a
    /// malformed `1abc`) stay part of it, as they did before.
    fn number_end(&self, start: usize, delimiter: Option<&str>) -> usize {
        let digit_at = |at: usize| self.bytes.get(at).is_some_and(u8::is_ascii_digit);
        let digits_end = |mut at: usize| {
            loop {
                while digit_at(at) {
                    at += 1;
                }
                let separator = self.syntax.digit_separators
                    && self.bytes.get(at) == Some(&b'_')
                    && at.checked_sub(1).is_some_and(digit_at)
                    && digit_at(at + 1);
                if !separator {
                    return at;
                }
                at += 1;
            }
        };
        let mut end = digits_end(start);
        if self.bytes.get(end) == Some(&b'.') && self.bytes.get(end + 1) != Some(&b'.') {
            end = digits_end(end + 1);
        }
        if matches!(self.bytes.get(end), Some(b'e' | b'E')) {
            let sign = usize::from(matches!(self.bytes.get(end + 1), Some(b'+' | b'-')));
            if digit_at(end + 1 + sign) {
                end = digits_end(end + 1 + sign);
            }
        }
        self.word_end(end, delimiter)
    }

    /// The second dot of a `1..2` range is punctuation, not the start of `.2`.
    fn follows_dot(&self, at: usize) -> bool {
        at.checked_sub(1).and_then(|before| self.bytes.get(before)) == Some(&b'.')
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
