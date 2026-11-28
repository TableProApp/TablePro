use std::fmt::Write;

const PER_LINE: usize = 16;
const DIGITS: &[u8; 16] = b"0123456789abcdef";
// The offset and its gap, three columns a byte and the middle gap, then " |", the text and "|\n".
const LINE_LEN: usize = 10 + PER_LINE * 3 + 1 + 2 + PER_LINE + 2;

/// `bytes` laid out as `xxd` does: an offset, the bytes in hex and their
/// printable text. `edit_budget` caps the dump at what a pane lays out whole;
/// the return is the dump and how many trailing bytes it left out, which the
/// app says in its own words.
pub fn hex_dump(bytes: &[u8], edit_budget: usize) -> (String, usize) {
    let max_bytes = edit_budget / LINE_LEN * PER_LINE;
    let shown = bytes.get(..max_bytes).unwrap_or(bytes);
    let mut dump = String::with_capacity(shown.len().div_ceil(PER_LINE) * LINE_LEN + LINE_LEN);
    for (line, chunk) in shown.chunks(PER_LINE).enumerate() {
        if line > 0 {
            dump.push('\n');
        }
        let _ = write!(dump, "{:08x}  ", line * PER_LINE);
        for at in 0..PER_LINE {
            match chunk.get(at) {
                Some(byte) => {
                    dump.push(char::from(DIGITS[usize::from(byte >> 4)]));
                    dump.push(char::from(DIGITS[usize::from(byte & 0x0f)]));
                    dump.push(' ');
                }
                None => dump.push_str("   "),
            }
            if at == PER_LINE / 2 - 1 {
                dump.push(' ');
            }
        }
        dump.push_str(" |");
        dump.extend(chunk.iter().map(|&byte| match byte {
            0x20..=0x7e => char::from(byte),
            _ => '.',
        }));
        dump.push('|');
    }
    (dump, bytes.len() - shown.len())
}

#[cfg(test)]
mod tests {
    use super::{LINE_LEN, PER_LINE, hex_dump};

    // A generous budget used by the app; the math here mirrors the app's.
    const BUDGET: usize = 1_000_000;
    const MAX_BYTES: usize = BUDGET / LINE_LEN * PER_LINE;

    fn dump(bytes: &[u8]) -> (String, usize) {
        hex_dump(bytes, BUDGET)
    }

    #[test]
    fn a_dump_lays_out_offset_hex_and_text() {
        let (text, left_out) = dump(b"Hello, TablePro!\x00\x01\xff \x7f~");
        assert_eq!(left_out, 0);
        assert_eq!(
            text,
            "00000000  48 65 6c 6c 6f 2c 20 54  61 62 6c 65 50 72 6f 21  |Hello, TablePro!|\n\
             00000010  00 01 ff 20 7f 7e                                 |... .~|"
        );
    }

    #[test]
    fn a_full_line_is_as_long_as_the_budget_counts() {
        let (text, _) = dump(&[0x41; PER_LINE * 2]);

        assert_eq!(text.len() + 1, 2 * LINE_LEN, "{text}");
    }

    #[test]
    fn a_dump_past_its_cap_stays_within_the_budget_and_counts_what_it_left_out() {
        let (text, left_out) = dump(&vec![0u8; MAX_BYTES + 5]);

        assert_eq!(left_out, 5);
        assert!(text.ends_with("|................|"), "{}", &text[text.len() - 40..]);
        assert!(text.len() <= BUDGET, "{} bytes", text.len());
        assert_eq!(text.lines().count(), MAX_BYTES / PER_LINE);
    }

    #[test]
    fn a_value_at_the_cap_is_whole() {
        let (text, left_out) = dump(&vec![0u8; MAX_BYTES]);

        assert_eq!(left_out, 0);
        assert!(text.ends_with('|'), "{}", &text[text.len() - 80..]);
    }

    #[test]
    fn an_empty_value_dumps_to_nothing() {
        assert_eq!(dump(&[]), (String::new(), 0));
    }
}
