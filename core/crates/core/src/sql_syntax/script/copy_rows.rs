use std::collections::VecDeque;

use crate::sql_syntax::script::{ScriptToken, ScriptTokenKind};

use super::script_reader::{RefusedUnit, ScriptUnit, ScriptUnitKind};

/// The most one piece of COPY rows holds: what the file is read by.
pub(super) const COPY_PIECE_BYTES: usize = 256 * 1024;

/// psql's end of the rows, a line of its own. psql 18 never sends it, and
/// PostgreSQL 18 reads it as data in CSV.
const END_MARKER: &str = "\\.";

/// The rows of a `COPY ... FROM stdin` block, passed on as the file holds
/// them. A piece is cut where the rows reach `COPY_PIECE_BYTES`, not where
/// a read of the file ended, so a file splits the same however it is read.
#[derive(Debug)]
pub(super) struct CopyRows {
    binary: bool,
    data: String,
    /// The line `data` starts on.
    data_line: u64,
    /// The line the next byte taken is on.
    line: u64,
    /// Part of the line being read was taken already, so it is a row and
    /// not the end marker.
    in_row: bool,
}

impl CopyRows {
    /// The block a statement opens, when it is a COPY from stdin.
    pub(super) fn starting(text: &str, tokens: &[ScriptToken]) -> Option<Self> {
        let code: Vec<&ScriptToken> = tokens
            .iter()
            .filter(|token| !token.kind.is_trivia() && token.kind != ScriptTokenKind::Semicolon)
            .collect();
        let copy = code.first()?;
        if !is_word(text, copy, "COPY") {
            return None;
        }
        let mut depth = 0i32;
        let mut from = None;
        for (index, token) in code.iter().enumerate() {
            match token.kind {
                ScriptTokenKind::OpenParen => depth += 1,
                ScriptTokenKind::CloseParen => depth -= 1,
                _ if depth == 0 && is_word(text, token, "FROM") => {
                    from = Some(index);
                    break;
                }
                _ => {}
            }
        }
        let source = code.get(from? + 1)?;
        if !is_word(text, source, "STDIN") {
            return None;
        }
        Some(Self {
            binary: reads_binary(text, &code),
            data: String::new(),
            data_line: 0,
            line: 0,
            in_row: false,
        })
    }

    pub(super) fn refusal(&self) -> Option<RefusedUnit> {
        self.binary.then_some(RefusedUnit::CopyBinary)
    }

    /// The data's first line.
    pub(super) fn at_line(mut self, line: u64) -> Self {
        self.line = line;
        self.data_line = line;
        self
    }

    /// Take the rows `pending` holds. Gives how many bytes were taken and
    /// whether the rows ended. A part of a line that could still be the
    /// end marker is left until the rest of the line comes.
    pub(super) fn take(&mut self, pending: &str, end: bool, units: &mut VecDeque<ScriptUnit>) -> (usize, bool) {
        let mut consumed = 0;
        loop {
            let rest = pending.get(consumed..).unwrap_or_default();
            match rest.find('\n') {
                Some(at) => {
                    let line = rest.get(..at).unwrap_or_default();
                    if !self.in_row && is_end_marker(line) {
                        self.finish(units);
                        return (consumed + at + 1, true);
                    }
                    self.push(rest.get(..=at).unwrap_or_default(), units);
                    self.in_row = false;
                    consumed += at + 1;
                }
                None if end => {
                    if self.in_row || !is_end_marker(rest) {
                        self.push(rest, units);
                    }
                    self.finish(units);
                    return (pending.len(), true);
                }
                None => {
                    if !rest.is_empty() && (self.in_row || !may_be_end_marker(rest)) {
                        self.push(rest, units);
                        self.in_row = true;
                        consumed = pending.len();
                    }
                    return (consumed, false);
                }
            }
        }
    }

    fn push(&mut self, rows: &str, units: &mut VecDeque<ScriptUnit>) {
        if self.binary || rows.is_empty() {
            return;
        }
        if self.data.is_empty() {
            self.data_line = self.line;
        }
        self.line += rows.matches('\n').count() as u64;
        self.data.push_str(rows);
        while self.data.len() >= COPY_PIECE_BYTES {
            let mut cut = COPY_PIECE_BYTES;
            while !self.data.is_char_boundary(cut) {
                cut -= 1;
            }
            let rest = self.data.split_off(cut);
            let piece = std::mem::replace(&mut self.data, rest);
            self.emit(piece, units);
        }
    }

    fn finish(&mut self, units: &mut VecDeque<ScriptUnit>) {
        if self.binary {
            return;
        }
        let piece = std::mem::take(&mut self.data);
        if !piece.is_empty() {
            self.emit(piece, units);
        }
        units.push_back(ScriptUnit {
            text: String::new(),
            line: self.line,
            repeat: 1,
            kind: ScriptUnitKind::CopyEnd,
        });
    }

    fn emit(&mut self, piece: String, units: &mut VecDeque<ScriptUnit>) {
        let line = self.data_line;
        self.data_line += piece.matches('\n').count() as u64;
        units.push_back(ScriptUnit {
            text: piece,
            line,
            repeat: 1,
            kind: ScriptUnitKind::CopyData,
        });
    }
}

fn is_end_marker(line: &str) -> bool {
    line.strip_suffix('\r').unwrap_or(line) == END_MARKER
}

/// Whether the start of a line can still turn out to be the end marker.
fn may_be_end_marker(part: &str) -> bool {
    END_MARKER.starts_with(part) || is_end_marker(part)
}

fn is_word(text: &str, token: &ScriptToken, wanted: &str) -> bool {
    token.kind == ScriptTokenKind::Word
        && text
            .get(token.range.clone())
            .is_some_and(|word| word.eq_ignore_ascii_case(wanted))
}

/// Whether the copy reads the binary format, which a script cannot hold:
/// `COPY BINARY t`, the old `WITH BINARY`, or `FORMAT binary` among the
/// options. A WHERE clause ends the options.
fn reads_binary(text: &str, code: &[&ScriptToken]) -> bool {
    let mut depth = 0i32;
    let mut after_format = false;
    for token in code {
        match token.kind {
            ScriptTokenKind::OpenParen => depth += 1,
            ScriptTokenKind::CloseParen => depth -= 1,
            _ if depth == 0 && is_word(text, token, "WHERE") => return false,
            _ if depth == 0 && is_word(text, token, "BINARY") => return true,
            _ if after_format && names_binary(text, token) => return true,
            _ => {}
        }
        after_format = depth == 1 && is_word(text, token, "FORMAT");
    }
    false
}

/// `binary`, `'binary'` or `"binary"`.
fn names_binary(text: &str, token: &ScriptToken) -> bool {
    let quoted = matches!(
        token.kind,
        ScriptTokenKind::Word | ScriptTokenKind::StringLiteral | ScriptTokenKind::QuotedIdentifier
    );
    quoted
        && text
            .get(token.range.clone())
            .map(|name| name.trim_matches(|character| character == '\'' || character == '"'))
            .is_some_and(|name| name.eq_ignore_ascii_case("binary"))
}

#[cfg(test)]
mod tests {
    use crate::sql_syntax::SqlGrammar;
    use crate::sql_syntax::script::{LexicalSettings, ScriptPlan};

    use super::*;

    fn binary(statement: &str) -> Option<bool> {
        let plan = ScriptPlan::build(
            statement,
            SqlGrammar::PostgreSql,
            LexicalSettings {
                backslash_escapes: false,
            },
        );
        let tokens: Vec<ScriptToken> = plan.tokens(0..statement.len()).collect();
        CopyRows::starting(statement, &tokens).map(|copy| copy.binary)
    }

    #[test]
    fn every_spelling_of_the_binary_format_is_found() {
        for statement in [
            "COPY t FROM stdin (FORMAT binary)",
            "copy t from stdin with (format 'binary')",
            "COPY t FROM STDIN WITH (FREEZE, FORMAT \"binary\")",
            "COPY BINARY t FROM stdin",
            "COPY t FROM stdin WITH BINARY",
            "COPY t (a, b) FROM stdin BINARY",
        ] {
            assert_eq!(binary(statement), Some(true), "{statement}");
        }
    }

    #[test]
    fn text_and_csv_with_any_options_are_not_binary() {
        for statement in [
            "COPY t FROM stdin",
            "COPY t (a, b) FROM stdin WITH (FORMAT csv, HEADER true, NULL 'x', DELIMITER ';')",
            "COPY t FROM stdin WITH CSV HEADER QUOTE AS '\"'",
            "COPY t (\"binary\", format) FROM stdin",
            "COPY t FROM stdin (FORMAT text) WHERE (format = 'binary')",
        ] {
            assert_eq!(binary(statement), Some(false), "{statement}");
        }
    }

    #[test]
    fn only_a_copy_from_stdin_opens_a_block() {
        assert_eq!(binary("COPY t FROM '/tmp/rows'"), None);
        assert_eq!(binary("COPY (SELECT 1) TO STDOUT"), None);
        assert_eq!(binary("SELECT 'COPY t FROM stdin'"), None);
    }
}
