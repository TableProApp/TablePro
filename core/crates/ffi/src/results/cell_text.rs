use super::ValueKind;

const HEX: &[u8; 16] = b"0123456789abcdef";

// An unreadable value has no text of its own: its bytes name its type, which only the grid's window carries.
pub(super) fn full(kind: ValueKind, bytes: &[u8]) -> String {
    match kind {
        ValueKind::Bytes => {
            let mut out = Vec::with_capacity(2 + bytes.len() * 2);
            push_hex(bytes, bytes.len(), &mut out);
            String::from_utf8_lossy(&out).into_owned()
        }
        ValueKind::Undecodable => String::new(),
        _ => String::from_utf8_lossy(bytes).into_owned(),
    }
}

// The value's start as `full` gives it, control characters kept, and whether anything was cut.
pub(super) fn head(kind: ValueKind, bytes: &[u8], max_chars: usize) -> (String, bool) {
    match kind {
        ValueKind::Bytes => {
            let mut out = Vec::new();
            let cut = push_hex(bytes, max_chars.saturating_sub(2) / 2, &mut out);
            (String::from_utf8_lossy(&out).into_owned(), cut)
        }
        ValueKind::Undecodable => (String::new(), false),
        _ => {
            let end = char_boundary_after(bytes, max_chars);
            (String::from_utf8_lossy(&bytes[..end]).into_owned(), end < bytes.len())
        }
    }
}

// Returns whether anything was cut.
pub(super) fn display(kind: ValueKind, bytes: &[u8], max_chars: usize, out: &mut Vec<u8>) -> bool {
    match kind {
        ValueKind::Bytes => push_hex(bytes, max_chars.saturating_sub(2) / 2, out),
        _ => push_line(bytes, max_chars, out),
    }
}

// As `display`, with each line break kept as one `\n`, for a grid that wraps its cells.
pub(super) fn display_lines(kind: ValueKind, bytes: &[u8], max_chars: usize, out: &mut Vec<u8>) -> bool {
    match kind {
        ValueKind::Bytes => push_hex(bytes, max_chars.saturating_sub(2) / 2, out),
        _ => push_lines(bytes, max_chars, out),
    }
}

fn push_hex(bytes: &[u8], max_bytes: usize, out: &mut Vec<u8>) -> bool {
    let shown = &bytes[..bytes.len().min(max_bytes)];
    out.extend_from_slice(b"0x");
    for byte in shown {
        out.push(HEX[usize::from(byte >> 4)]);
        out.push(HEX[usize::from(byte & 0x0f)]);
    }
    shown.len() < bytes.len()
}

// Control characters and line breaks become spaces, so neither can make a row taller or shift a column.
fn push_line(text: &[u8], max_chars: usize, out: &mut Vec<u8>) -> bool {
    let end = char_boundary_after(text, max_chars);
    push_shown(&text[..end], false, out);
    end < text.len()
}

// A line break of any form becomes one `\n`, so no grid depends on which forms its text engine breaks at.
fn push_lines(text: &[u8], max_chars: usize, out: &mut Vec<u8>) -> bool {
    let end = char_boundary_after(text, max_chars);
    push_shown(&text[..end], true, out);
    end < text.len()
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Shown {
    Plain,
    Space,
    Break,
}

// The bytes one character takes at the start of `rest`, and how a cell shows it.
fn classify(rest: &[u8]) -> (usize, Shown) {
    match rest {
        // LF, VT, FF and CR.
        [0x0a..=0x0d, ..] => (1, Shown::Break),
        [byte, ..] if *byte < 0x20 || *byte == 0x7f => (1, Shown::Space),
        // NEL, U+0085.
        [0xc2, 0x85, ..] => (2, Shown::Break),
        // The other C1 controls, U+0080 to U+009F.
        [0xc2, 0x80..=0x9f, ..] => (2, Shown::Space),
        // The line and paragraph separators, U+2028 and U+2029.
        [0xe2, 0x80, 0xa8 | 0xa9, ..] => (3, Shown::Break),
        _ => (1, Shown::Plain),
    }
}

fn push_shown(text: &[u8], keep_breaks: bool, out: &mut Vec<u8>) {
    out.reserve(text.len());
    let mut plain = 0;
    let mut index = 0;
    while index < text.len() {
        let (length, shown) = classify(&text[index..]);
        if shown == Shown::Plain {
            index += length;
            continue;
        }
        out.extend_from_slice(&text[plain..index]);
        // CR LF is one break; flattened, each of the two stays a space as before.
        let crlf = keep_breaks && text[index..].starts_with(b"\r\n");
        out.push(if keep_breaks && shown == Shown::Break {
            b'\n'
        } else {
            b' '
        });
        index += if crlf { 2 } else { length };
        plain = index;
    }
    out.extend_from_slice(&text[plain..]);
}

fn char_boundary_after(text: &[u8], chars: usize) -> usize {
    if text.len() <= chars {
        return text.len();
    }
    let mut seen = 0;
    for (index, byte) in text.iter().enumerate() {
        // A byte that is not a continuation byte starts a character.
        if byte & 0xc0 != 0x80 {
            if seen == chars {
                return index;
            }
            seen += 1;
        }
    }
    text.len()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn shown(kind: ValueKind, bytes: &[u8], max_chars: usize) -> (String, bool) {
        let mut out = Vec::new();
        let cut = display(kind, bytes, max_chars, &mut out);
        (String::from_utf8(out).unwrap(), cut)
    }

    #[test]
    fn an_unreadable_value_shows_its_type_to_the_grid_and_has_no_text() {
        assert_eq!(
            shown(ValueKind::Undecodable, b"money", 100),
            ("money".to_owned(), false)
        );
        assert_eq!(full(ValueKind::Undecodable, b"money"), "");
        assert_eq!(head(ValueKind::Undecodable, b"money", 100), (String::new(), false));
    }

    #[test]
    fn text_is_cut_at_a_character_and_kept_on_one_line() {
        assert_eq!(
            shown(ValueKind::Text, "ab\ncd\té".as_bytes(), 6),
            ("ab cd ".to_owned(), true)
        );
        assert_eq!(
            shown(ValueKind::Text, "日本語".as_bytes(), 3),
            ("日本語".to_owned(), false)
        );
        assert_eq!(
            shown(ValueKind::Text, "日本語".as_bytes(), 2),
            ("日本".to_owned(), true)
        );
        assert_eq!(shown(ValueKind::Text, "👋👋".as_bytes(), 1), ("👋".to_owned(), true));
    }

    fn lines(kind: ValueKind, bytes: &[u8], max_chars: usize) -> (String, bool) {
        let mut out = Vec::new();
        let cut = display_lines(kind, bytes, max_chars, &mut out);
        (String::from_utf8(out).unwrap(), cut)
    }

    #[test]
    fn every_line_break_form_is_one_space_on_one_line() {
        assert_eq!(
            shown(
                ValueKind::Text,
                "a\nb\u{b}c\u{c}d\re\u{85}f\u{2028}g\u{2029}h".as_bytes(),
                100
            ),
            ("a b c d e f g h".to_owned(), false)
        );
        assert_eq!(shown(ValueKind::Text, b"a\r\nb", 100), ("a  b".to_owned(), false));
        assert_eq!(
            shown(ValueKind::Text, "a\u{80}b\u{9f}c\u{7f}d".as_bytes(), 100),
            ("a b c d".to_owned(), false)
        );
        assert_eq!(
            shown(ValueKind::Text, "é\u{a0}\u{2027}\u{202a}".as_bytes(), 100),
            ("é\u{a0}\u{2027}\u{202a}".to_owned(), false)
        );
    }

    #[test]
    fn kept_line_breaks_are_one_newline_whatever_their_form() {
        assert_eq!(
            lines(
                ValueKind::Text,
                "a\nb\u{b}c\u{c}d\re\u{85}f\u{2028}g\u{2029}h".as_bytes(),
                100
            ),
            ("a\nb\nc\nd\ne\nf\ng\nh".to_owned(), false)
        );
        assert_eq!(
            lines(ValueKind::Text, b"a\r\nb\r\rc\n\rd", 100),
            ("a\nb\n\nc\n\nd".to_owned(), false)
        );
        assert_eq!(
            lines(ValueKind::Text, b"a\tb\0c\x1bd", 100),
            ("a b c d".to_owned(), false)
        );
        assert_eq!(lines(ValueKind::Text, b"last\r\n", 100), ("last\n".to_owned(), false));
    }

    #[test]
    fn kept_line_breaks_count_toward_the_cut_as_the_value_holds_them() {
        assert_eq!(lines(ValueKind::Text, b"ab\r\ncd", 3), ("ab\n".to_owned(), true));
        assert_eq!(lines(ValueKind::Text, b"ab\r\ncd", 4), ("ab\n".to_owned(), true));
        assert_eq!(
            lines(ValueKind::Text, "日\u{2028}本語".as_bytes(), 3),
            ("日\n本".to_owned(), true)
        );
        assert_eq!(
            lines(ValueKind::Bytes, &[0x0a, 0x0d, 0xbe, 0xef], 6),
            ("0x0a0d".to_owned(), true)
        );
        assert_eq!(
            lines(ValueKind::Undecodable, b"money", 100),
            ("money".to_owned(), false)
        );
    }

    #[test]
    fn a_head_keeps_line_breaks_and_cuts_at_a_character() {
        assert_eq!(
            head(ValueKind::Text, "a\nb👋c".as_bytes(), 3),
            ("a\nb".to_owned(), true)
        );
        assert_eq!(head(ValueKind::Json, b"{}", 10), ("{}".to_owned(), false));
        assert_eq!(
            head(ValueKind::Bytes, &[0xde, 0xad, 0xbe], 6),
            ("0xdead".to_owned(), true)
        );
    }

    #[test]
    fn binary_shows_its_leading_bytes_in_hex() {
        assert_eq!(
            shown(ValueKind::Bytes, &[0xde, 0xad, 0xbe, 0xef], 6),
            ("0xdead".to_owned(), true)
        );
        assert_eq!(shown(ValueKind::Bytes, &[0x01], 100), ("0x01".to_owned(), false));
        assert_eq!(full(ValueKind::Bytes, &[0xde, 0xad, 0xbe, 0xef]), "0xdeadbeef");
    }
}
