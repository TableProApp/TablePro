use gtk4 as gtk;
use gtk4::prelude::*;

/// Case-sensitive, as a rename needs. `whole_word` when the text came
/// from the word at the cursor, so `u` does not find the `u` in `users`.
#[derive(Debug, Clone)]
pub(super) struct Needle {
    pub(super) text: String,
    pub(super) whole_word: bool,
}

/// A word is an SQL identifier, as completion takes it: Pango's word
/// boundaries split `user_id` at the underscore.
fn is_word_char(c: char) -> bool {
    c.is_alphanumeric() || c == '_'
}

fn word_start(iter: &gtk::TextIter) -> gtk::TextIter {
    let mut start = *iter;
    loop {
        let mut before = start;
        if !before.backward_char() || !is_word_char(before.char()) {
            return start;
        }
        start = before;
    }
}

fn word_end(iter: &gtk::TextIter) -> gtk::TextIter {
    let mut end = *iter;
    while is_word_char(end.char()) {
        if !end.forward_char() {
            break;
        }
    }
    end
}

/// The word the cursor is in or at either end of.
pub(super) fn word_at(iter: &gtk::TextIter) -> Option<(gtk::TextIter, gtk::TextIter)> {
    let (start, end) = (word_start(iter), word_end(iter));
    (start < end).then_some((start, end))
}

fn is_whole_word(start: &gtk::TextIter, end: &gtk::TextIter) -> bool {
    let mut before = *start;
    (!before.backward_char() || !is_word_char(before.char())) && !is_word_char(end.char())
}

/// The first match after `after`, going round to the top once. `taken`
/// says which ranges already have a caret.
pub(super) fn next_match(
    buffer: &gtk::TextBuffer,
    needle: &Needle,
    after: &gtk::TextIter,
    taken: impl Fn(i32, i32) -> bool,
) -> Option<(gtk::TextIter, gtk::TextIter)> {
    let stop = after.offset();
    let mut from = *after;
    let mut wrapped = false;
    loop {
        match search(needle, &from) {
            Some((start, _)) if wrapped && start.offset() >= stop => return None,
            Some((start, end)) if taken(start.offset(), end.offset()) => from = past(start),
            Some(found) => return Some(found),
            None if wrapped => return None,
            None => {
                wrapped = true;
                from = buffer.start_iter();
            }
        }
    }
}

pub(super) fn all_matches(buffer: &gtk::TextBuffer, needle: &Needle) -> Vec<(gtk::TextIter, gtk::TextIter)> {
    let mut found = Vec::new();
    let mut from = buffer.start_iter();
    while let Some((start, end)) = search(needle, &from) {
        from = end;
        found.push((start, end));
    }
    found
}

fn search(needle: &Needle, from: &gtk::TextIter) -> Option<(gtk::TextIter, gtk::TextIter)> {
    let mut from = *from;
    loop {
        let (start, end) = from.forward_search(&needle.text, gtk::TextSearchFlags::TEXT_ONLY, None)?;
        if !needle.whole_word || is_whole_word(&start, &end) {
            return Some((start, end));
        }
        from = past(start);
    }
}

fn past(start: gtk::TextIter) -> gtk::TextIter {
    let mut next = start;
    next.forward_char();
    next
}

#[cfg(test)]
mod tests {
    use super::*;

    fn buffer(text: &str) -> gtk::TextBuffer {
        let buffer = gtk::TextBuffer::new(None);
        buffer.set_text(text);
        buffer
    }

    fn offsets(found: Option<(gtk::TextIter, gtk::TextIter)>) -> Option<(i32, i32)> {
        found.map(|(start, end)| (start.offset(), end.offset()))
    }

    fn needle(text: &str, whole_word: bool) -> Needle {
        Needle {
            text: text.to_owned(),
            whole_word,
        }
    }

    #[gtk4::test]
    fn the_word_at_the_cursor_takes_underscores_and_its_end() {
        let buffer = buffer("SELECT user_id FROM t");
        let words = |offset| offsets(word_at(&buffer.iter_at_offset(offset)));

        assert_eq!(words(9), Some((7, 14)));
        assert_eq!(words(7), Some((7, 14)));
        assert_eq!(words(14), Some((7, 14)), "the end of a word");
        assert_eq!(words(6), Some((0, 6)));
        assert_eq!(buffer.iter_at_offset(15).char(), 'F');
        assert_eq!(words(15), Some((15, 19)));
        assert_eq!(words(21), Some((20, 21)), "the end of the text");
    }

    #[gtk4::test]
    fn no_word_between_words() {
        let buffer = buffer("a  =  b");

        assert_eq!(offsets(word_at(&buffer.iter_at_offset(2))), None);
    }

    #[gtk4::test]
    fn a_whole_word_skips_longer_words() {
        let buffer = buffer("u.id, users.u_id, u");
        let after = buffer.iter_at_offset(1);

        assert_eq!(
            offsets(next_match(&buffer, &needle("u", true), &after, |_, _| false)),
            Some((18, 19))
        );
        assert_eq!(
            offsets(next_match(&buffer, &needle("u", false), &after, |_, _| false)),
            Some((6, 7))
        );
    }

    #[gtk4::test]
    fn the_search_goes_round_once_and_skips_taken_matches() {
        let buffer = buffer("a b a c a");
        let after = buffer.iter_at_offset(9);
        let a = needle("a", true);

        assert_eq!(offsets(next_match(&buffer, &a, &after, |_, _| false)), Some((0, 1)));
        assert_eq!(
            offsets(next_match(&buffer, &a, &after, |start, _| start == 0)),
            Some((4, 5))
        );
        assert_eq!(offsets(next_match(&buffer, &a, &after, |_, _| true)), None);
    }

    #[gtk4::test]
    fn the_search_is_case_sensitive() {
        let buffer = buffer("Total total TOTAL");

        assert_eq!(
            all_matches(&buffer, &needle("total", true))
                .into_iter()
                .map(|(start, end)| (start.offset(), end.offset()))
                .collect::<Vec<_>>(),
            vec![(6, 11)]
        );
    }
}
