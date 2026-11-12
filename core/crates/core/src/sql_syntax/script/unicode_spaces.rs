//! DuckDB's pass that turns non-ASCII spaces into spaces before its lexer
//! runs.

use std::ops::Range;

/// DuckDB 2.0.0's `Parser::StripUnicodeSpaces` (`src/parser/parser.cpp`),
/// run only as far as the lexer asks. It turns U+00A0, U+2000 to U+200B,
/// U+202F, U+205F, U+2060, U+3000 and U+FEFF into spaces wherever it is
/// outside what it reads as a `'` or `"` quote, a `$tag$` quote or a `--`
/// comment. It reads no block comment, backslash or backtick, so it can be
/// inside a quote where the lexer is not, and there the space stays a name
/// character. The loops, their bounds and their order are DuckDB's.
#[derive(Debug)]
pub(crate) struct UnicodeSpaces {
    state: State,
    pos: usize,
    /// Where each space it turns into a space starts, in order.
    blanked: Vec<usize>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum State {
    Regular,
    Quote(u8),
    /// After a `$` that may open a quote, reading its tag.
    Tag {
        start: usize,
    },
    Dollar {
        start: usize,
        len: usize,
    },
    Comment,
    Done,
}

impl UnicodeSpaces {
    pub(crate) fn new(from: usize) -> Self {
        Self {
            state: State::Regular,
            pos: from,
            blanked: Vec::new(),
        }
    }

    /// Whether the space that starts at `at` becomes a space. `at` is not
    /// before where the pass started.
    pub(crate) fn blanks(&mut self, bytes: &[u8], at: usize) -> bool {
        while self.pos <= at && self.state != State::Done {
            self.step(bytes);
        }
        self.blanked.binary_search(&at).is_ok()
    }

    /// One turn of the loop DuckDB is in.
    fn step(&mut self, q: &[u8]) {
        let size = q.len();
        let pos = self.pos;
        match self.state {
            State::Done => {}
            State::Regular if pos + 2 >= size => self.state = State::Done,
            State::Regular => {
                if space_len(q, pos).is_some() {
                    self.blanked.push(pos);
                }
                match q[pos] {
                    b'"' | b'\'' => {
                        self.state = State::Quote(q[pos]);
                        self.pos += 1;
                        return;
                    }
                    b'$' if q[pos + 1] == b'$' || is_tag_start(q[pos + 1]) => {
                        self.pos += 1;
                        self.state = State::Tag { start: self.pos };
                        return;
                    }
                    b'-' if q[pos + 1] == b'-' => {
                        self.state = State::Comment;
                        return;
                    }
                    _ => {}
                }
                self.pos += 1;
            }
            State::Tag { .. } if pos + 2 >= size => self.state = State::Done,
            State::Tag { start } => match q[pos] {
                b'$' => {
                    self.state = State::Dollar {
                        start,
                        len: pos - start,
                    }
                }
                b if !is_tag_part(b) => self.state = State::Regular,
                _ => self.pos += 1,
            },
            State::Dollar { .. } if pos + 2 >= size => self.state = State::Done,
            State::Dollar { start, len } => {
                let closes = q[pos] == b'$'
                    && size - (pos + 1) > len
                    && q[pos + len + 1] == b'$'
                    && q[pos + 1..pos + 1 + len] == q[start..start + len];
                if closes {
                    self.pos += len + 1;
                    self.state = State::Regular;
                } else {
                    self.pos += 1;
                }
            }
            State::Quote(_) if pos + 1 >= size => self.state = State::Done,
            State::Quote(quote) => {
                if q[pos] != quote {
                    self.pos += 1;
                } else if q[pos + 1] == quote {
                    self.pos += 2;
                } else {
                    self.pos += 1;
                    self.state = State::Regular;
                }
            }
            State::Comment if pos >= size => self.state = State::Done,
            State::Comment => match q[pos] {
                b'\n' | b'\r' => self.state = State::Regular,
                _ => self.pos += 1,
            },
        }
    }
}

/// How many bytes the space that starts at `at` takes, when one of the
/// spaces DuckDB turns into a space starts there.
pub(crate) fn space_len(bytes: &[u8], at: usize) -> Option<usize> {
    match bytes.get(at..)? {
        [0xC2, 0xA0, ..] => Some(2),
        [0xE2, 0x80, 0x80..=0x8B | 0xAF, ..] | [0xE2, 0x81, 0x9F | 0xA0, ..] | [0xE3, 0x80, 0x80, ..] => Some(3),
        [0xEF, 0xBB, 0xBF, ..] => Some(3),
        _ => None,
    }
}

/// The spaces DuckDB turns into spaces in `text`, sent to it whole.
pub fn blanked_spaces(text: &str) -> Vec<Range<usize>> {
    let bytes = text.as_bytes();
    let mut pass = UnicodeSpaces::new(0);
    (0..bytes.len())
        .filter_map(|at| space_len(bytes, at).map(|len| at..at + len))
        .filter(|space| pass.blanks(bytes, space.start))
        .collect()
}

/// Whether `bytes` hold any of the spaces, so the pass can change them.
pub(crate) fn any(bytes: &[u8]) -> bool {
    (0..bytes.len()).any(|at| space_len(bytes, at).is_some())
}

fn is_tag_start(b: u8) -> bool {
    b.is_ascii_alphabetic() || b == b'_' || b >= 0x80
}

fn is_tag_part(b: u8) -> bool {
    is_tag_start(b) || b.is_ascii_digit()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn blanked(text: &str) -> Vec<usize> {
        blanked_spaces(text).into_iter().map(|space| space.start).collect()
    }

    #[test]
    fn every_space_it_lists_is_turned_into_a_space_and_no_other() {
        for space in [
            '\u{a0}', '\u{2000}', '\u{2005}', '\u{200a}', '\u{200b}', '\u{202f}', '\u{205f}', '\u{2060}', '\u{3000}',
            '\u{feff}',
        ] {
            assert_eq!(blanked(&format!("a{space}b c")), [1], "{space:?}");
        }
        for other in [
            '\u{85}', '\u{1680}', '\u{200c}', '\u{2028}', '\u{2061}', '\u{2019}', '\u{fffe}',
        ] {
            assert!(blanked(&format!("a{other}b c")).is_empty(), "{other:?}");
        }
    }

    #[test]
    fn a_space_inside_what_it_reads_as_a_quote_or_a_comment_stays() {
        assert!(blanked("'a\u{200b}b' x").is_empty());
        assert!(blanked("\"a\u{200b}b\" x").is_empty());
        assert!(blanked("-- a\u{200b}b\nx").is_empty());
        assert!(blanked("$$a\u{200b}b$$ x").is_empty());
        assert!(blanked("$t$a\u{200b}$t$ x").is_empty());
        assert_eq!(blanked("'it''s' \u{200b} x"), [8]);
        assert_eq!(blanked("-- a\n\u{200b} x"), [5]);
        assert_eq!(blanked("$t$a$t$ \u{200b} x"), [8]);
    }

    #[test]
    fn it_reads_quotes_its_own_way() {
        // No block comment and no backslash: the quote opens in the comment and closes at E'.
        assert!(blanked("/* ' */ a\u{200b}E'x").is_empty());
        assert!(blanked("/* ' */ 'a' \u{200b}x").is_empty());
        // `a$$` opens a `$$` quote to it, as a tag of the next `$`.
        assert_eq!(blanked("a$$ b\u{200b}$$ c\u{200b}d x"), [12]);
        // A tag's space is read as part of the tag, and a bad tag byte goes back to the regular loop.
        assert_eq!(blanked("$a\u{200b}$x$a\u{200b}$ \u{200b} x"), [14]);
        assert_eq!(blanked("$a- \u{200b} x"), [4]);
    }

    #[test]
    fn the_last_two_bytes_are_never_read() {
        assert!(blanked("a\u{a0}").is_empty());
        assert_eq!(blanked("a\u{a0}b"), [1]);
        assert_eq!(blanked("a\u{200b}"), [1]);
    }

    #[test]
    fn it_reads_on_from_where_it_starts() {
        let text = "' a; \u{200b} x";
        let mut pass = UnicodeSpaces::new(4);
        assert!(pass.blanks(text.as_bytes(), 5));
        assert!(!blanked(text).contains(&5));
    }
}
