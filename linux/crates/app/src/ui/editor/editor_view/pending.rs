use gtk4 as gtk;
use gtk4::prelude::*;

use super::caret::Caret;

/// An edit at GTK's cursor that no command of the view's made, such as
/// text an input method committed. Kept until the user action ends and
/// then made at every other caret.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum Pending {
    DeleteSelection,
    /// Characters before and after the cursor, as an input method takes
    /// back what it typed before it commits the final text.
    DeleteAround {
        before: i32,
        after: i32,
    },
    Insert(String),
}

impl Pending {
    pub(super) fn of_insert(buffer: &gtk::TextBuffer, location: &gtk::TextIter, text: &str) -> Option<Self> {
        let cursor = buffer.iter_at_mark(&buffer.get_insert());
        (location.offset() == cursor.offset()).then(|| Self::Insert(text.to_owned()))
    }

    pub(super) fn of_delete(buffer: &gtk::TextBuffer, start: &gtk::TextIter, end: &gtk::TextIter) -> Option<Self> {
        let (start, end) = (start.offset().min(end.offset()), start.offset().max(end.offset()));
        if let Some((from, to)) = buffer.selection_bounds() {
            return (from.offset() == start && to.offset() == end).then_some(Self::DeleteSelection);
        }
        let cursor = buffer.iter_at_mark(&buffer.get_insert()).offset();
        (start <= cursor && cursor <= end).then_some(Self::DeleteAround {
            before: cursor - start,
            after: end - cursor,
        })
    }

    /// The same edit at `caret`, which a selection there takes the place
    /// of, as at GTK's cursor. Around the cursor is what `reserve` marked
    /// before GTK's edit, or else what is around it now.
    pub(super) fn apply(&self, buffer: &gtk::TextBuffer, caret: &Caret) {
        let reserved = match self {
            Self::DeleteAround { .. } => caret.take_reserved(buffer),
            _ => None,
        };
        let (mut start, mut end) = caret.range(buffer);
        if start != end {
            buffer.delete(&mut start, &mut end);
        } else if let Self::DeleteAround { before, after } = *self {
            let (mut from, mut to) = reserved.unwrap_or_else(|| around(buffer, &caret.insert(buffer), before, after));
            if from < to {
                buffer.delete(&mut from, &mut to);
            }
        }
        let mut at = caret.insert(buffer);
        if let Self::Insert(text) = self {
            buffer.insert(&mut at, text);
        }
        caret.set(buffer, &at, &at);
    }

    /// Marks at each of `carets` what this edit takes there, while the
    /// text is as GTK's edit found it: a caret it moves closer would
    /// otherwise reach past what it would have taken alone.
    pub(super) fn reserve(&self, buffer: &gtk::TextBuffer, carets: &[Caret]) {
        if let Self::DeleteAround { before, after } = *self {
            for caret in carets {
                let (from, to) = around(buffer, &caret.insert(buffer), before, after);
                caret.reserve(buffer, &from, &to);
            }
        }
    }
}

/// `before` and `after` characters around `at`, on its line.
fn around(buffer: &gtk::TextBuffer, at: &gtk::TextIter, before: i32, after: i32) -> (gtk::TextIter, gtk::TextIter) {
    let mut line_end = *at;
    if !line_end.ends_line() {
        line_end.forward_to_line_end();
    }
    (
        buffer.iter_at_offset(at.offset() - before.min(at.line_offset())),
        buffer.iter_at_offset(at.offset() + after.min(line_end.offset() - at.offset())),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn buffer(text: &str) -> gtk::TextBuffer {
        let buffer = gtk::TextBuffer::new(None);
        buffer.set_text(text);
        buffer
    }

    fn text(buffer: &gtk::TextBuffer) -> String {
        let (start, end) = buffer.bounds();
        buffer.text(&start, &end, false).to_string()
    }

    #[gtk4::test]
    fn an_insert_counts_only_at_the_cursor() {
        let buffer = buffer("select 1");
        buffer.place_cursor(&buffer.iter_at_offset(3));

        assert_eq!(
            Pending::of_insert(&buffer, &buffer.iter_at_offset(3), "x"),
            Some(Pending::Insert("x".to_owned()))
        );
        assert_eq!(Pending::of_insert(&buffer, &buffer.iter_at_offset(0), "x"), None);
    }

    #[gtk4::test]
    fn a_delete_is_the_selection_or_around_the_cursor() {
        let buffer = buffer("select 1");
        buffer.select_range(&buffer.iter_at_offset(2), &buffer.iter_at_offset(5));
        let at = |offset| buffer.iter_at_offset(offset);

        assert_eq!(
            Pending::of_delete(&buffer, &at(2), &at(5)),
            Some(Pending::DeleteSelection)
        );
        assert_eq!(Pending::of_delete(&buffer, &at(2), &at(4)), None);

        buffer.place_cursor(&at(5));
        assert_eq!(
            Pending::of_delete(&buffer, &at(3), &at(5)),
            Some(Pending::DeleteAround { before: 2, after: 0 })
        );
        assert_eq!(
            Pending::of_delete(&buffer, &at(3), &at(7)),
            Some(Pending::DeleteAround { before: 2, after: 2 }),
            "a delete over the cursor takes both sides"
        );
        assert_eq!(Pending::of_delete(&buffer, &at(0), &at(1)), None);
    }

    #[gtk4::test]
    fn an_edit_around_a_caret_stays_on_its_line() {
        let buffer = buffer("ab\ncd\nef");
        let caret = Caret::new(&buffer, &buffer.iter_at_offset(4), &buffer.iter_at_offset(4));

        Pending::DeleteAround { before: 3, after: 5 }.apply(&buffer, &caret);

        assert_eq!(text(&buffer), "ab\n\nef");
        assert_eq!(caret.insert(&buffer).offset(), 3);
    }

    #[gtk4::test]
    fn typing_replaces_a_carets_selection_and_leaves_it_after_the_text() {
        let buffer = buffer("one two");
        let caret = Caret::new(&buffer, &buffer.iter_at_offset(7), &buffer.iter_at_offset(4));

        Pending::Insert("2".to_owned()).apply(&buffer, &caret);

        assert_eq!(text(&buffer), "one 2");
        assert_eq!(caret.range(&buffer).0.offset(), 5);
        assert_eq!(caret.range(&buffer).1.offset(), 5);
    }
}
