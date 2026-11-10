use std::borrow::Cow;
use std::fmt::Write as _;

// A cell goes to a terminal, so a stored escape sequence is shown, never run.
pub(crate) fn escape_cell(text: &str) -> Cow<'_, str> {
    if !text.chars().any(char::is_control) {
        return Cow::Borrowed(text);
    }
    let mut escaped = String::with_capacity(text.len() + 8);
    for character in text.chars() {
        match character {
            '\\' => escaped.push_str("\\\\"),
            '\t' => escaped.push_str("\\t"),
            '\n' => escaped.push_str("\\n"),
            '\r' => escaped.push_str("\\r"),
            other if other.is_control() => push_hex(&mut escaped, other),
            other => escaped.push(other),
        }
    }
    Cow::Owned(escaped)
}

// Line breaks and tabs stay, so a database's message keeps the caret under the column it points at.
pub(crate) fn escape_lines(text: &str) -> Cow<'_, str> {
    if !text.chars().any(runs_in_a_terminal) {
        return Cow::Borrowed(text);
    }
    let mut escaped = String::with_capacity(text.len() + 8);
    for character in text.chars() {
        match character {
            '\r' => escaped.push_str("\\r"),
            other if runs_in_a_terminal(other) => push_hex(&mut escaped, other),
            other => escaped.push(other),
        }
    }
    Cow::Owned(escaped)
}

fn runs_in_a_terminal(character: char) -> bool {
    character.is_control() && character != '\n' && character != '\t'
}

fn push_hex(into: &mut String, character: char) {
    let _ = write!(into, "\\x{:02X}", u32::from(character));
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_cell_shows_its_control_characters_as_escapes() {
        assert_eq!(escape_cell("plain \\ text"), "plain \\ text");
        assert_eq!(escape_cell("a\tb\nc\r\u{1b}[2J\\"), "a\\tb\\nc\\r\\x1B[2J\\\\");
        assert_eq!(escape_cell("\u{9b}31m"), "\\x9B31m");
    }

    #[test]
    fn a_message_keeps_its_lines_and_loses_its_sequences() {
        assert_eq!(
            escape_lines("syntax error\nLINE 1: SELEC\n\t^"),
            "syntax error\nLINE 1: SELEC\n\t^"
        );
        assert_eq!(
            escape_lines("bad value \u{1b}]52;c;eA==\u{7}\r"),
            "bad value \\x1B]52;c;eA==\\x07\\r"
        );
    }
}
