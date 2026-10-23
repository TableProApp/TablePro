use std::cell::RefCell;
use std::collections::VecDeque;

use gtk4 as gtk;
use gtk4::prelude::*;

/// A cursor besides GTK's own. Marks, so every edit moves it as it moves
/// GTK's. Text another caret inserts where this one ends stays outside it:
/// a selection's start keeps right gravity and its end left, and an empty
/// caret left, so two carets that meet once their selections go keep
/// their order.
#[derive(Debug)]
pub(super) struct Caret {
    marks: RefCell<[gtk::TextMark; 2]>,
    /// Text the edits at GTK's cursor take around this caret too, marked
    /// before each edit moved anything, in the order the edits came.
    reserved: RefCell<VecDeque<[gtk::TextMark; 2]>>,
}

impl Caret {
    pub(super) fn new(buffer: &gtk::TextBuffer, insert: &gtk::TextIter, anchor: &gtk::TextIter) -> Self {
        Self {
            marks: RefCell::new(marks(buffer, insert, anchor)),
            reserved: RefCell::default(),
        }
    }

    /// Text outside the range stays outside it, as a selection's does.
    pub(super) fn reserve(&self, buffer: &gtk::TextBuffer, from: &gtk::TextIter, to: &gtk::TextIter) {
        let marks = [
            buffer.create_mark(None, from, false),
            buffer.create_mark(None, to, true),
        ];
        self.reserved.borrow_mut().push_back(marks);
    }

    pub(super) fn take_reserved(&self, buffer: &gtk::TextBuffer) -> Option<(gtk::TextIter, gtk::TextIter)> {
        let marks = self.reserved.borrow_mut().pop_front()?;
        let range = (buffer.iter_at_mark(&marks[0]), buffer.iter_at_mark(&marks[1]));
        delete(&marks);
        Some(range)
    }

    pub(super) fn clear_reserved(&self) {
        for marks in self.reserved.take() {
            delete(&marks);
        }
    }

    pub(super) fn at_selection(buffer: &gtk::TextBuffer) -> Self {
        let (insert, anchor) = selection(buffer);
        Self::new(buffer, &insert, &anchor)
    }

    pub(super) fn insert(&self, buffer: &gtk::TextBuffer) -> gtk::TextIter {
        buffer.iter_at_mark(&self.marks.borrow()[0])
    }

    pub(super) fn anchor(&self, buffer: &gtk::TextBuffer) -> gtk::TextIter {
        buffer.iter_at_mark(&self.marks.borrow()[1])
    }

    pub(super) fn range(&self, buffer: &gtk::TextBuffer) -> (gtk::TextIter, gtk::TextIter) {
        let (mut start, mut end) = (self.insert(buffer), self.anchor(buffer));
        start.order(&mut end);
        (start, end)
    }

    pub(super) fn span(&self, buffer: &gtk::TextBuffer, primary: bool) -> Span {
        Span::of(self.insert(buffer).offset(), self.anchor(buffer).offset(), primary)
    }

    /// New marks, since a mark's gravity is fixed and an end can become a
    /// start.
    pub(super) fn set(&self, buffer: &gtk::TextBuffer, insert: &gtk::TextIter, anchor: &gtk::TextIter) {
        let old = self.marks.replace(marks(buffer, insert, anchor));
        delete(&old);
    }

    pub(super) fn follow_selection(&self, buffer: &gtk::TextBuffer) {
        let (insert, anchor) = selection(buffer);
        self.set(buffer, &insert, &anchor);
    }

    pub(super) fn select(&self, buffer: &gtk::TextBuffer) {
        buffer.select_range(&self.insert(buffer), &self.anchor(buffer));
    }
}

impl Drop for Caret {
    fn drop(&mut self) {
        delete(&self.marks.borrow());
        self.clear_reserved();
    }
}

fn marks(buffer: &gtk::TextBuffer, insert: &gtk::TextIter, anchor: &gtk::TextIter) -> [gtk::TextMark; 2] {
    let empty = insert == anchor;
    [
        buffer.create_mark(None, insert, empty || insert > anchor),
        buffer.create_mark(None, anchor, empty || anchor > insert),
    ]
}

fn delete(marks: &[gtk::TextMark; 2]) {
    for mark in marks {
        if let Some(buffer) = mark.buffer() {
            buffer.delete_mark(mark);
        }
    }
}

pub(super) fn selection(buffer: &gtk::TextBuffer) -> (gtk::TextIter, gtk::TextIter) {
    (
        buffer.iter_at_mark(&buffer.get_insert()),
        buffer.iter_at_mark(&buffer.selection_bound()),
    )
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) struct Span {
    pub(super) start: i32,
    pub(super) end: i32,
    pub(super) insert_at_end: bool,
    pub(super) primary: bool,
}

impl Span {
    pub(super) fn of(insert: i32, anchor: i32, primary: bool) -> Self {
        Self {
            start: insert.min(anchor),
            end: insert.max(anchor),
            insert_at_end: insert >= anchor,
            primary,
        }
    }

    /// Where the insertion point and the other end are.
    pub(super) fn ends(self) -> (i32, i32) {
        if self.insert_at_end {
            (self.end, self.start)
        } else {
            (self.start, self.end)
        }
    }

    fn is_empty(self) -> bool {
        self.start == self.end
    }

    /// Carets that would edit the same text: overlapping, or one empty
    /// where the other is or ends.
    fn joins(self, next: Self) -> bool {
        next.start < self.end || (next.start == self.end && (self.is_empty() || next.is_empty()))
    }
}

pub(super) fn merged(mut spans: Vec<Span>) -> Vec<Span> {
    spans.sort_by_key(|span| (span.start, span.end));
    let mut out: Vec<Span> = Vec::with_capacity(spans.len());
    for span in spans {
        match out.last_mut() {
            Some(last) if last.joins(span) => {
                if span.end > last.end {
                    last.end = span.end;
                    last.insert_at_end = span.insert_at_end || span.is_empty();
                }
                last.primary |= span.primary;
            }
            _ => out.push(span),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn span(start: i32, end: i32) -> Span {
        Span {
            start,
            end,
            insert_at_end: true,
            primary: false,
        }
    }

    fn primary(start: i32, end: i32) -> Span {
        Span {
            primary: true,
            ..span(start, end)
        }
    }

    #[test]
    fn carets_apart_stay_apart_in_document_order() {
        assert_eq!(
            merged(vec![span(9, 9), primary(0, 3), span(4, 6)]),
            vec![primary(0, 3), span(4, 6), span(9, 9)]
        );
    }

    #[test]
    fn carets_at_one_place_are_one_and_the_primary_wins() {
        assert_eq!(merged(vec![span(5, 5), primary(5, 5), span(5, 5)]), vec![primary(5, 5)]);
    }

    #[test]
    fn overlapping_selections_join() {
        assert_eq!(merged(vec![span(0, 4), primary(2, 8)]), vec![primary(0, 8)]);
        assert_eq!(merged(vec![span(0, 8), span(2, 4)]), vec![span(0, 8)]);
    }

    #[test]
    fn a_caret_at_the_end_of_a_selection_joins_it() {
        assert_eq!(merged(vec![span(0, 4), span(4, 4)]), vec![span(0, 4)]);
        assert_eq!(merged(vec![span(4, 4), span(4, 9)]), vec![span(4, 9)]);
    }

    #[gtk4::test]
    fn text_another_caret_types_where_this_one_ends_stays_outside_it() {
        let buffer = gtk::TextBuffer::new(None);
        buffer.set_text("foofoo");
        let first = Caret::new(&buffer, &buffer.iter_at_offset(3), &buffer.iter_at_offset(0));
        let empty = Caret::new(&buffer, &buffer.iter_at_offset(6), &buffer.iter_at_offset(6));

        buffer.insert(&mut buffer.iter_at_offset(3), "bar");
        buffer.insert(&mut buffer.iter_at_offset(9), "!");

        assert_eq!(first.span(&buffer, false), Span::of(3, 0, false));
        assert_eq!(empty.span(&buffer, false), Span::of(9, 9, false));
    }

    #[test]
    fn selections_that_only_touch_stay_two() {
        assert_eq!(merged(vec![span(0, 4), span(4, 9)]), vec![span(0, 4), span(4, 9)]);
    }
}
