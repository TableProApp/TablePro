use super::ValueKind;

const HEX: &[u8; 16] = b"0123456789abcdef";

pub(super) fn full(kind: ValueKind, bytes: &[u8]) -> String {
    match kind {
        ValueKind::Bytes => {
            let mut out = Vec::with_capacity(2 + bytes.len() * 2);
            push_hex(bytes, bytes.len(), &mut out);
            String::from_utf8_lossy(&out).into_owned()
        }
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

fn push_hex(bytes: &[u8], max_bytes: usize, out: &mut Vec<u8>) -> bool {
    let shown = &bytes[..bytes.len().min(max_bytes)];
    out.extend_from_slice(b"0x");
    for byte in shown {
        out.push(HEX[usize::from(byte >> 4)]);
        out.push(HEX[usize::from(byte & 0x0f)]);
    }
    shown.len() < bytes.len()
}

// Control characters become spaces, so a line break or a tab cannot make a row taller or shift a column.
fn push_line(text: &[u8], max_chars: usize, out: &mut Vec<u8>) -> bool {
    let end = char_boundary_after(text, max_chars);
    let start = out.len();
    out.extend_from_slice(&text[..end]);
    for byte in &mut out[start..] {
        if *byte < 0x20 || *byte == 0x7f {
            *byte = b' ';
        }
    }
    end < text.len()
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
