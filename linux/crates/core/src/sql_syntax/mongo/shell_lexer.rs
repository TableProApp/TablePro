use std::ops::Range;

/// What a piece of shell text is.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ShellTokenKind {
    Whitespace {
        newline: bool,
    },
    LineComment,
    BlockComment {
        closed: bool,
    },
    /// A string in single, double or back quotes.
    String {
        closed: bool,
    },
    /// A regular expression literal, `/pattern/flags`.
    Regex {
        closed: bool,
    },
    Number,
    /// A name, `$` and `_` included, so `$gt` and `$1` are one each.
    Identifier,
    Punct,
}

impl ShellTokenKind {
    pub fn is_trivia(self) -> bool {
        matches!(
            self,
            Self::Whitespace { .. } | Self::LineComment | Self::BlockComment { .. }
        )
    }

    /// Whether the text ends inside this token: a quote, a regular
    /// expression or a block comment that never closes.
    pub fn is_open(self) -> bool {
        matches!(
            self,
            Self::String { closed: false } | Self::Regex { closed: false } | Self::BlockComment { closed: false }
        )
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct ShellToken {
    pub kind: ShellTokenKind,
    pub range: Range<usize>,
}

impl ShellToken {
    pub fn text<'a>(&self, source: &'a str) -> &'a str {
        source.get(self.range.clone()).unwrap_or_default()
    }

    /// The one character of a punctuation token.
    pub fn punct(&self, source: &str) -> Option<char> {
        match self.kind {
            ShellTokenKind::Punct => self.text(source).chars().next(),
            _ => None,
        }
    }
}

/// The tokens of `text`, covering every byte of it. The shell has no
/// division, so a `/` where a value may start opens a regular expression,
/// as it does in mongosh.
pub fn lex_shell(text: &str) -> Vec<ShellToken> {
    let mut tokens: Vec<ShellToken> = Vec::new();
    let mut at = 0;
    while let Some(c) = text[at..].chars().next() {
        let start = at;
        let rest = &text[at..];
        let kind = if c.is_whitespace() {
            let length = rest.find(|c: char| !c.is_whitespace()).unwrap_or(rest.len());
            at += length;
            ShellTokenKind::Whitespace {
                newline: rest[..length].contains(['\n', '\r']),
            }
        } else if rest.starts_with("//") {
            at += rest.find(['\n', '\r']).unwrap_or(rest.len());
            ShellTokenKind::LineComment
        } else if let Some(body) = rest.strip_prefix("/*") {
            match body.find("*/") {
                Some(end) => {
                    at += end + 4;
                    ShellTokenKind::BlockComment { closed: true }
                }
                None => {
                    at = text.len();
                    ShellTokenKind::BlockComment { closed: false }
                }
            }
        } else if matches!(c, '\'' | '"' | '`') {
            let (length, closed) = string_length(rest, c);
            at += length;
            ShellTokenKind::String { closed }
        } else if c == '/' && value_may_start(&tokens, text) {
            let (length, closed) = regex_length(rest);
            at += length;
            ShellTokenKind::Regex { closed }
        } else if c.is_ascii_digit() {
            at += number_length(rest);
            ShellTokenKind::Number
        } else if is_name_start(c) {
            at += rest.find(|c: char| !is_name_part(c)).unwrap_or(rest.len());
            ShellTokenKind::Identifier
        } else {
            at += c.len_utf8();
            ShellTokenKind::Punct
        };
        tokens.push(ShellToken { kind, range: start..at });
    }
    tokens
}

pub(crate) fn is_name_start(c: char) -> bool {
    c.is_alphabetic() || c == '_' || c == '$'
}

pub(crate) fn is_name_part(c: char) -> bool {
    c.is_alphanumeric() || c == '_' || c == '$'
}

/// Whether the last significant token leaves room for a value, so a `/`
/// there starts a regular expression rather than standing alone.
fn value_may_start(tokens: &[ShellToken], text: &str) -> bool {
    let Some(last) = tokens.iter().rev().find(|token| !token.kind.is_trivia()) else {
        return true;
    };
    match last.kind {
        ShellTokenKind::Punct => !matches!(last.punct(text), Some(')' | ']' | '}')),
        ShellTokenKind::Identifier => matches!(last.text(text), "return" | "typeof" | "in" | "of"),
        _ => false,
    }
}

/// The length of a string opened by `quote` at the start of `rest`, and
/// whether it closes. A single or double quoted string ends at a line
/// break, as in JavaScript, unless a backslash continues the line.
fn string_length(rest: &str, quote: char) -> (usize, bool) {
    let mut chars = rest.char_indices().skip(1);
    while let Some((index, c)) = chars.next() {
        match c {
            '\\' => {
                chars.next();
            }
            '\n' | '\r' if quote != '`' => return (index, false),
            c if c == quote => return (index + c.len_utf8(), true),
            _ => {}
        }
    }
    (rest.len(), false)
}

/// A regular expression runs to the first `/` that is neither escaped nor
/// inside a `[...]` class, then takes its flags. A line break ends it
/// unclosed.
fn regex_length(rest: &str) -> (usize, bool) {
    let mut in_class = false;
    let mut chars = rest.char_indices().skip(1);
    while let Some((index, c)) = chars.next() {
        match c {
            '\\' => {
                chars.next();
            }
            '\n' | '\r' => return (index, false),
            '[' => in_class = true,
            ']' => in_class = false,
            '/' if !in_class => {
                let after = index + 1;
                let flags = rest[after..]
                    .find(|c: char| !c.is_ascii_alphabetic())
                    .unwrap_or(rest.len() - after);
                return (after + flags, true);
            }
            _ => {}
        }
    }
    (rest.len(), false)
}

/// A decimal number with an optional fraction and exponent, or a hex,
/// octal or binary integer.
fn number_length(rest: &str) -> usize {
    let bytes = rest.as_bytes();
    if bytes.len() > 1 && bytes[0] == b'0' && matches!(bytes[1], b'x' | b'X' | b'o' | b'O' | b'b' | b'B') {
        return 2 + rest[2..]
            .find(|c: char| !c.is_ascii_alphanumeric())
            .unwrap_or(rest.len() - 2);
    }
    let mut at = digits(bytes, 0);
    if bytes.get(at) == Some(&b'.') && bytes.get(at + 1).is_some_and(u8::is_ascii_digit) {
        at = digits(bytes, at + 1);
    }
    if matches!(bytes.get(at), Some(b'e' | b'E')) {
        let sign = usize::from(matches!(bytes.get(at + 1), Some(b'+' | b'-')));
        if bytes.get(at + 1 + sign).is_some_and(u8::is_ascii_digit) {
            at = digits(bytes, at + 1 + sign);
        }
    }
    at
}

fn digits(bytes: &[u8], from: usize) -> usize {
    let mut at = from;
    while bytes.get(at).is_some_and(u8::is_ascii_digit) {
        at += 1;
    }
    at
}

#[cfg(test)]
mod tests {
    use super::*;

    fn kinds(text: &str) -> Vec<(ShellTokenKind, &str)> {
        lex_shell(text)
            .into_iter()
            .map(|token| (token.kind, &text[token.range]))
            .collect()
    }

    fn significant(text: &str) -> Vec<&str> {
        lex_shell(text)
            .into_iter()
            .filter(|token| !token.kind.is_trivia())
            .map(|token| &text[token.range])
            .collect()
    }

    #[test]
    fn the_tokens_cover_the_text() {
        let text = "db.users.find({ age: { $gt: 30 } }) // adults\n";
        let tokens = lex_shell(text);

        let mut at = 0;
        for token in &tokens {
            assert_eq!(token.range.start, at, "{tokens:?}");
            at = token.range.end;
        }
        assert_eq!(at, text.len());
        assert_eq!(
            significant(text),
            [
                "db", ".", "users", ".", "find", "(", "{", "age", ":", "{", "$gt", ":", "30", "}", "}", ")"
            ]
        );
    }

    #[test]
    fn a_slash_where_a_value_starts_is_a_regular_expression() {
        assert_eq!(
            kinds("{a: /x\\/y[/]z/i}")[4],
            (ShellTokenKind::Regex { closed: true }, "/x\\/y[/]z/i")
        );
        assert_eq!(kinds("find(/a/)")[2], (ShellTokenKind::Regex { closed: true }, "/a/"));
        assert_eq!(kinds("x) /a/")[3].0, ShellTokenKind::Punct, "a slash after a value");
        assert_eq!(kinds("/open\n")[0], (ShellTokenKind::Regex { closed: false }, "/open"));
    }

    #[test]
    fn strings_take_their_escapes_and_stop_open_at_a_line_break() {
        assert_eq!(
            kinds(r#""a\"b""#)[0],
            (ShellTokenKind::String { closed: true }, r#""a\"b""#)
        );
        assert_eq!(
            kinds("'it\\'s'")[0],
            (ShellTokenKind::String { closed: true }, "'it\\'s'")
        );
        assert_eq!(
            kinds("'open\nx'")[0],
            (ShellTokenKind::String { closed: false }, "'open")
        );
        assert_eq!(
            kinds("`two\nlines`")[0],
            (ShellTokenKind::String { closed: true }, "`two\nlines`")
        );
    }

    #[test]
    fn comments_and_numbers() {
        assert_eq!(
            kinds("/* a */1")[0],
            (ShellTokenKind::BlockComment { closed: true }, "/* a */")
        );
        assert_eq!(
            kinds("/* open")[0],
            (ShellTokenKind::BlockComment { closed: false }, "/* open")
        );
        for number in ["7", "1.5", "2e10", "3.25E-4", "0x1F", "0b101"] {
            assert_eq!(kinds(number), [(ShellTokenKind::Number, number)], "{number}");
        }
        assert_eq!(significant("1.x"), ["1", ".", "x"]);
        assert_eq!(significant("$1 $gt _id"), ["$1", "$gt", "_id"]);
    }

    #[test]
    fn whitespace_says_whether_it_breaks_a_line() {
        assert_eq!(kinds("a  b")[1].0, ShellTokenKind::Whitespace { newline: false });
        assert_eq!(kinds("a \r\n b")[1].0, ShellTokenKind::Whitespace { newline: true });
    }
}
