use std::collections::VecDeque;

use crate::sql_syntax::script::{ScriptToken, ScriptTokenKind};

use super::script_reader::{RefusedUnit, ScriptUnit, ScriptUnitKind};

/// Rows one INSERT made from COPY data carries, as a dump's INSERTs do.
const ROWS_PER_INSERT: usize = 1_000;
const BYTES_PER_INSERT: usize = 1_046_528;

/// The rows of a `COPY table (columns) FROM stdin` block as INSERTs.
///
/// A driver sends no COPY data, so the rows go in as statements instead:
/// each field of the text format as a string the server casts to its
/// column, as it casts COPY's own text. pg_dump writes this form.
#[derive(Debug)]
pub(super) struct CopyRows {
    start: String,
    refused: Option<RefusedUnit>,
    tuples: String,
    rows: usize,
    first_line: u64,
    line: u64,
}

impl CopyRows {
    /// The block a statement opens, when it is a COPY from stdin.
    pub(super) fn starting(text: &str, tokens: &[ScriptToken], overriding: Option<&str>) -> Option<Self> {
        let code: Vec<&ScriptToken> = tokens
            .iter()
            .filter(|token| !token.kind.is_trivia() && token.kind != ScriptTokenKind::Semicolon)
            .collect();
        let word = |token: &ScriptToken, wanted: &str| {
            token.kind == ScriptTokenKind::Word
                && text
                    .get(token.range.clone())
                    .is_some_and(|word| word.eq_ignore_ascii_case(wanted))
        };
        let copy = code.first()?;
        if !word(copy, "COPY") {
            return None;
        }
        let mut depth = 0i32;
        let mut from = None;
        for (index, token) in code.iter().enumerate() {
            match token.kind {
                ScriptTokenKind::OpenParen => depth += 1,
                ScriptTokenKind::CloseParen => depth -= 1,
                _ if depth == 0 && word(token, "FROM") => {
                    from = Some(index);
                    break;
                }
                _ => {}
            }
        }
        let from = from?;
        let source = code.get(from + 1)?;
        if !word(source, "STDIN") {
            return None;
        }
        let target = text.get(copy.range.end..code[from].range.start)?.trim();
        let mut start = format!("INSERT INTO {target} ");
        if let Some(clause) = overriding {
            start.push_str(clause);
            start.push(' ');
        }
        start.push_str("VALUES\n");
        let refused = (code.len() > from + 2).then_some(RefusedUnit::CopyFormat);
        Some(Self {
            start,
            refused,
            tuples: String::new(),
            rows: 0,
            first_line: 0,
            line: 0,
        })
    }

    pub(super) fn refusal(&self) -> Option<RefusedUnit> {
        self.refused.clone()
    }

    /// The data's first line.
    pub(super) fn at_line(mut self, line: u64) -> Self {
        self.line = line;
        self.first_line = line;
        self
    }

    pub(super) fn row(&mut self, line: &str, units: &mut VecDeque<ScriptUnit>) {
        let number = self.line;
        self.line += 1;
        if self.refused.is_some() {
            return;
        }
        let Some(tuple) = tuple(line) else {
            self.flush(units);
            units.push_back(ScriptUnit {
                text: line.to_owned(),
                line: number,
                repeat: 1,
                kind: ScriptUnitKind::Refused(RefusedUnit::CopyNotText),
            });
            return;
        };
        if self.rows > 0 && self.tuples.len() + tuple.len() + self.start.len() > BYTES_PER_INSERT {
            self.flush(units);
        }
        if self.rows == 0 {
            self.first_line = number;
        } else {
            self.tuples.push_str(",\n");
        }
        self.tuples.push_str(&tuple);
        self.rows += 1;
        if self.rows >= ROWS_PER_INSERT {
            self.flush(units);
        }
    }

    pub(super) fn finish(&mut self, units: &mut VecDeque<ScriptUnit>) {
        self.flush(units);
    }

    fn flush(&mut self, units: &mut VecDeque<ScriptUnit>) {
        if self.rows == 0 {
            return;
        }
        let mut text = String::with_capacity(self.start.len() + self.tuples.len());
        text.push_str(&self.start);
        text.push_str(&self.tuples);
        units.push_back(ScriptUnit {
            text,
            line: self.first_line,
            repeat: 1,
            kind: ScriptUnitKind::Run,
        });
        self.tuples.clear();
        self.rows = 0;
    }
}

/// One line of COPY's text format as a parenthesised list of literals:
/// fields split at tabs, `\N` as NULL, backslash escapes read. `None` when
/// the escapes make bytes that are not UTF-8.
fn tuple(line: &str) -> Option<String> {
    let mut out = String::from("(");
    for (index, field) in line.split('\t').enumerate() {
        if index > 0 {
            out.push_str(", ");
        }
        if field == "\\N" {
            out.push_str("NULL");
            continue;
        }
        let value = String::from_utf8(unescape(field)).ok()?;
        // An E'' string reads the same whatever standard_conforming_strings is.
        out.push_str("E'");
        for character in value.chars() {
            match character {
                '\'' => out.push_str("''"),
                '\\' => out.push_str("\\\\"),
                other => out.push(other),
            }
        }
        out.push('\'');
    }
    out.push(')');
    Some(out)
}

/// COPY's backslash sequences: `\b \f \n \r \t \v`, up to three octal
/// digits, `\x` and up to two hex digits, and a backslash before any other
/// character standing for that character.
fn unescape(field: &str) -> Vec<u8> {
    let bytes = field.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while let Some(&byte) = bytes.get(index) {
        if byte != b'\\' {
            out.push(byte);
            index += 1;
            continue;
        }
        let Some(&next) = bytes.get(index + 1) else {
            out.push(b'\\');
            break;
        };
        index += 2;
        match next {
            b'b' => out.push(0x08),
            b'f' => out.push(0x0c),
            b'n' => out.push(b'\n'),
            b'r' => out.push(b'\r'),
            b't' => out.push(b'\t'),
            b'v' => out.push(0x0b),
            b'0'..=b'7' => {
                let mut value = u32::from(next - b'0');
                for _ in 0..2 {
                    match bytes.get(index) {
                        Some(digit @ b'0'..=b'7') => {
                            value = value * 8 + u32::from(digit - b'0');
                            index += 1;
                        }
                        _ => break,
                    }
                }
                out.push((value & 0xff) as u8);
            }
            b'x' => {
                let mut value = 0u32;
                let mut digits = 0;
                while digits < 2 {
                    match bytes.get(index).and_then(|digit| char::from(*digit).to_digit(16)) {
                        Some(digit) => {
                            value = value * 16 + digit;
                            index += 1;
                            digits += 1;
                        }
                        None => break,
                    }
                }
                match digits {
                    0 => out.push(b'x'),
                    _ => out.push((value & 0xff) as u8),
                }
            }
            other => out.push(other),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_text_format_line_becomes_literals() {
        assert_eq!(
            tuple("1\tit's\t\\N\ta\\tb\\nc\\\\d\t\\\\x00ff").as_deref(),
            Some("(E'1', E'it''s', NULL, E'a\tb\nc\\\\d', E'\\\\x00ff')")
        );
    }

    #[test]
    fn octal_and_hex_escapes_read_as_bytes() {
        assert_eq!(unescape("\\101\\x42\\x4"), b"AB\x04");
        assert_eq!(tuple("\\377"), None, "a lone 0xFF byte is not UTF-8");
    }

    #[test]
    fn an_empty_field_is_an_empty_string() {
        assert_eq!(tuple("").as_deref(), Some("(E'')"));
    }
}
