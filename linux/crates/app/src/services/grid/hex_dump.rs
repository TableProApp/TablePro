use super::EDIT_MAX_BYTES;
use super::display_text::more_bytes;

/// `bytes` as a hex dump, capped at what the pane lays out whole on the GTK
/// thread, with a worded note for anything past the cap.
pub fn hex_dump(bytes: &[u8]) -> String {
    let (mut dump, left_out) = tablepro_core::grid::hex_dump(bytes, EDIT_MAX_BYTES);
    if left_out > 0 {
        dump.push('\n');
        dump.push_str(&more_bytes(left_out));
    }
    dump
}

#[cfg(test)]
mod tests {
    use super::hex_dump;

    #[test]
    fn a_dump_lays_out_offset_hex_and_text() {
        assert_eq!(
            hex_dump(b"Hello, TablePro!\x00\x01\xff \x7f~"),
            "00000000  48 65 6c 6c 6f 2c 20 54  61 62 6c 65 50 72 6f 21  |Hello, TablePro!|\n\
             00000010  00 01 ff 20 7f 7e                                 |... .~|"
        );
    }

    #[test]
    fn a_dump_past_its_cap_says_what_it_left_out() {
        let dump = hex_dump(&vec![0u8; 400_000]);

        assert!(dump.contains("more bytes"), "{}", &dump[dump.len() - 40..]);
    }

    #[test]
    fn an_empty_value_dumps_to_nothing() {
        assert_eq!(hex_dump(&[]), "");
    }
}
