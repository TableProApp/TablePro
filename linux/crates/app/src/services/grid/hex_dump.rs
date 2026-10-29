use std::fmt::Write;

use super::EDIT_MAX_BYTES;
use super::display_text::more_bytes;

const PER_LINE: usize = 16;
const DIGITS: &[u8; 16] = b"0123456789abcdef";
// The offset and its gap, three columns a byte and the middle gap, then " |", the text and "|\n".
const LINE_LEN: usize = 10 + PER_LINE * 3 + 1 + 2 + PER_LINE + 2;
// The pane lays the dump out whole on the GTK thread, as it does a value it opens for an edit.
const HEX_DUMP_MAX_BYTES: usize = EDIT_MAX_BYTES / LINE_LEN * PER_LINE;

pub fn hex_dump(bytes: &[u8]) -> String {
    let shown = bytes.get(..HEX_DUMP_MAX_BYTES).unwrap_or(bytes);
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
    if shown.len() < bytes.len() {
        dump.push('\n');
        dump.push_str(&more_bytes(bytes.len() - shown.len()));
    }
    dump
}

#[cfg(test)]
mod tests {
    use super::{EDIT_MAX_BYTES, HEX_DUMP_MAX_BYTES, LINE_LEN, PER_LINE, hex_dump};

    #[test]
    fn a_dump_lays_out_offset_hex_and_text() {
        assert_eq!(
            hex_dump(b"Hello, TablePro!\x00\x01\xff \x7f~"),
            "00000000  48 65 6c 6c 6f 2c 20 54  61 62 6c 65 50 72 6f 21  |Hello, TablePro!|\n\
             00000010  00 01 ff 20 7f 7e                                 |... .~|"
        );
    }

    #[test]
    fn a_full_line_is_as_long_as_the_budget_counts() {
        let dump = hex_dump(&[0x41; PER_LINE * 2]);

        assert_eq!(dump.len() + 1, 2 * LINE_LEN, "{dump}");
    }

    #[test]
    fn a_dump_past_its_cap_stays_within_the_editor_budget_and_says_what_it_left_out() {
        let dump = hex_dump(&vec![0u8; HEX_DUMP_MAX_BYTES + 5]);
        let note = "\n… (5 more bytes)";

        assert!(
            dump.ends_with(&format!("|................|{note}")),
            "{}",
            &dump[dump.len() - 120..]
        );
        assert!(dump.len() - note.len() <= EDIT_MAX_BYTES, "{} bytes", dump.len());
        assert_eq!(dump.lines().count(), HEX_DUMP_MAX_BYTES / PER_LINE + 1);
    }

    #[test]
    fn a_value_at_the_cap_is_whole() {
        let dump = hex_dump(&vec![0u8; HEX_DUMP_MAX_BYTES]);

        assert!(dump.ends_with('|'), "{}", &dump[dump.len() - 80..]);
    }

    #[test]
    fn an_empty_value_dumps_to_nothing() {
        assert_eq!(hex_dump(&[]), "");
    }
}
