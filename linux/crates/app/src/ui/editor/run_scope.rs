use std::ops::Range;

use tablepro_core::sql_syntax::script::text_offsets;

/// The SQL one run sends, and where it starts in the buffer.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ScopedText {
    pub text: String,
    /// The buffer offset, in characters, of `text`'s first character,
    /// so a server's error position can be found in the buffer.
    pub base_char: usize,
}

/// Run sends the selection when there is one, and the whole buffer
/// when there is not, so a highlighted statement is the only one sent.
pub fn for_run(buffer_text: &str, selection: Option<Range<usize>>) -> Option<ScopedText> {
    let scoped = match selection.filter(|range| range.start < range.end) {
        Some(range) => ScopedText {
            text: char_slice(buffer_text, range.clone()).to_owned(),
            base_char: range.start,
        },
        None => ScopedText {
            text: buffer_text.to_owned(),
            base_char: 0,
        },
    };
    (!scoped.text.trim().is_empty()).then_some(scoped)
}

fn char_slice(text: &str, range: Range<usize>) -> &str {
    let start = text_offsets::char_to_byte(text, range.start);
    let end = text_offsets::char_to_byte(text, range.end);
    text.get(start..end).unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn run_scope_prefers_selection() {
        let buffer = "SELECT 1;\nSELECT 2;\nSELECT 3;";

        let selected = for_run(buffer, Some(10..18)).expect("a selection");
        assert_eq!(selected.text, "SELECT 2");
        assert_eq!(selected.base_char, 10);

        let whole = for_run(buffer, Some(4..4)).expect("an empty selection runs everything");
        assert_eq!(whole.text, buffer);
        assert_eq!(whole.base_char, 0);

        assert_eq!(for_run("  \n ", None), None);
    }

    #[test]
    fn a_selection_is_cut_by_characters_not_bytes() {
        let buffer = "SELECT 'tên'; SELECT 2";

        let selected = for_run(buffer, Some(14..22)).expect("a selection");

        assert_eq!(selected.text, "SELECT 2");
    }
}
