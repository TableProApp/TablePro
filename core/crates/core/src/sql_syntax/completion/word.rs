// The byte where the word ending at byte `cursor` starts: what a proposal replaces and what the list ranks for.
pub fn word_start(text: &str, cursor: usize) -> usize {
    let mut cursor = cursor.min(text.len());
    while !text.is_char_boundary(cursor) {
        cursor -= 1;
    }
    text.get(..cursor)
        .unwrap_or_default()
        .char_indices()
        .rev()
        .take_while(|(_, c)| is_word_char(*c))
        .last()
        .map_or(cursor, |(at, _)| at)
}

// A combining mark belongs to the letter before it, so a decomposed "café" is one word.
pub fn is_word_char(c: char) -> bool {
    c.is_alphanumeric() || c == '_' || unicode_normalization::char::is_combining_mark(c)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_word_keeps_combining_marks_with_their_base() {
        let text = "SELECT * FROM cafe\u{301}";

        assert_eq!(word_start(text, text.len()), 14);
        assert!(is_word_char('\u{903}'));
        assert!(is_word_char('\u{20dd}'));
    }

    #[test]
    fn a_word_runs_back_over_letters_digits_and_underscores() {
        assert_eq!(word_start("SELECT * FROM us", 16), 14);
        assert_eq!(word_start("SELECT u.user_id2", 17), 9);
        assert_eq!(word_start("SELECT ", 7), 7);
        assert_eq!(word_start("", 0), 0);
    }

    #[test]
    fn a_word_holds_whole_characters_outside_ascii() {
        let text = "SELECT * FROM đơn";

        assert_eq!(word_start(text, text.len()), 14);
        assert_eq!(word_start(text, text.len() - 2), 14, "a cursor inside a character");
    }
}
