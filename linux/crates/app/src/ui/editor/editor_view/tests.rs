use std::time::Duration;

use sourceview5::prelude::*;

use super::*;
use crate::test_support::{KeyInjector, OwnedWindow, after_next_frame, finish_on_main, wait_until};

const WAIT: Duration = Duration::from_secs(5);

/// A view shown in a window that has the keyboard, as the editor's is
/// when the user types: committed text follows the carets only then.
struct Shown {
    view: EditorView,
    _window: OwnedWindow<gtk::Window>,
}

impl Shown {
    fn new(text: &str) -> Self {
        let view = EditorView::default();
        let buffer = sourceview5::Buffer::new(None);
        buffer.set_text(text);
        view.set_buffer(Some(&buffer));
        view.set_monospace(true);
        let window = gtk::Window::builder()
            .default_width(480)
            .default_height(320)
            .child(&view)
            .build();
        KeyInjector::focus_only(&window);
        let window = OwnedWindow::new(window);
        view.grab_focus();
        wait_until(WAIT, || window.is_active() && view.has_focus()).expect("the view to take the focus");
        after_next_frame(&view);
        Self { view, _window: window }
    }

    fn buffer(&self) -> gtk::TextBuffer {
        self.view.buffer()
    }

    fn text(&self) -> String {
        let buffer = self.buffer();
        let (start, end) = buffer.bounds();
        buffer.text(&start, &end, false).to_string()
    }

    fn cursor_at(&self, offset: i32) {
        let buffer = self.buffer();
        buffer.place_cursor(&buffer.iter_at_offset(offset));
    }

    fn ranges(&self) -> Vec<(i32, i32)> {
        self.view
            .caret_ranges()
            .iter()
            .map(|(start, end)| (start.offset(), end.offset()))
            .collect()
    }

    fn at(&self, offset: i32) -> gtk::TextIter {
        self.buffer().iter_at_offset(offset)
    }

    /// What GtkTextView does with text an input method commits
    /// (gtk_text_view_commit_text), the path every typed character takes.
    fn commit(&self, text: &str) {
        let buffer = self.buffer();
        buffer.begin_user_action();
        buffer.delete_selection(true, true);
        buffer.insert_interactive_at_cursor(text, true);
        buffer.end_user_action();
    }

    /// Three carets, each selecting one `a` of `SELECT a, a, a`.
    fn three_selected() -> Self {
        let shown = Self::new("SELECT a, a, a");
        shown.cursor_at(7);
        for _ in 0..3 {
            assert!(shown.view.add_caret_at_next_match());
        }
        assert_eq!(shown.ranges(), [(7, 8), (10, 11), (13, 14)]);
        shown
    }
}

#[gtk4::test]
fn three_carets_type_and_delete_together_and_one_undo_takes_back_each_edit() {
    let shown = Shown::three_selected();
    let buffer = shown.buffer();

    shown.commit("b");
    assert_eq!(shown.text(), "SELECT b, b, b");
    assert_eq!(shown.ranges(), [(8, 8), (11, 11), (14, 14)]);

    shown.commit("c");
    shown.view.emit_by_name::<()>("backspace", &[]);
    assert_eq!(shown.text(), "SELECT b, b, b");
    shown.view.emit_by_name::<()>("backspace", &[]);
    assert_eq!(shown.text(), "SELECT , , ");
    assert_eq!(shown.view.caret_count(), 3);

    buffer.undo();
    assert_eq!(
        shown.text(),
        "SELECT b, b, b",
        "one undo took back one backspace at every caret"
    );
    assert_eq!(shown.view.caret_count(), 1, "an undo returns to one cursor");
    buffer.undo();
    assert_eq!(shown.text(), "SELECT bc, bc, bc");
    buffer.undo();
    assert_eq!(shown.text(), "SELECT b, b, b");
    buffer.undo();
    assert_eq!(shown.text(), "SELECT a, a, a");
    assert!(!buffer.can_undo());
    let (start, end) = buffer
        .selection_bounds()
        .expect("the undo selects GTK's own match again");
    assert_eq!((start.offset(), end.offset()), (13, 14));

    buffer.redo();
    assert_eq!(shown.text(), "SELECT b, b, b");
    assert_eq!(shown.view.caret_count(), 1);
}

#[gtk4::test]
fn selections_side_by_side_each_keep_their_own_text() {
    let shown = Shown::new("foofoo");
    let buffer = shown.buffer();
    buffer.select_range(&shown.at(0), &shown.at(3));
    assert!(shown.view.add_caret_at_next_match());
    assert_eq!(shown.ranges(), [(0, 3), (3, 6)]);

    shown.commit("bar");
    assert_eq!(shown.text(), "barbar");
    assert_eq!(shown.ranges(), [(3, 3), (6, 6)]);

    shown.view.emit_by_name::<()>("backspace", &[]);
    assert_eq!(shown.text(), "baba");
    shown.view.insert_at_carets("x");
    assert_eq!(shown.text(), "baxbax");
}

#[gtk4::test]
fn next_match_selects_the_word_then_each_next_whole_word() {
    let shown = Shown::new("u.id, users.u_id, u");
    shown.cursor_at(0);

    assert!(shown.view.add_caret_at_next_match());
    assert_eq!(shown.ranges(), [(0, 1)], "the first press selects the word");
    assert!(shown.view.add_caret_at_next_match());
    assert_eq!(shown.ranges(), [(0, 1), (18, 19)]);
    assert!(!shown.view.add_caret_at_next_match(), "every match has a caret");
    let buffer = shown.buffer();
    assert_eq!(
        buffer.iter_at_mark(&buffer.get_insert()).offset(),
        19,
        "GTK's cursor went to the new match"
    );
}

#[gtk4::test]
fn a_match_that_overlaps_a_selection_is_no_new_caret() {
    let shown = Shown::new("aaa");
    let buffer = shown.buffer();
    buffer.select_range(&shown.at(2), &shown.at(0));

    assert!(!shown.view.add_caret_at_next_match());

    assert_eq!(shown.ranges(), [(0, 2)]);
}

#[gtk4::test]
fn tab_on_lines_two_carets_share_indents_each_line_once() {
    let shown = Shown::new("abc\ndef\nghi");
    let buffer = shown.buffer();
    buffer.select_range(&shown.at(5), &shown.at(1));
    shown
        .view
        .imp()
        .carets
        .borrow_mut()
        .push(Caret::new(&buffer, &shown.at(9), &shown.at(6)));

    let forwarded = std::cell::Cell::new(0);

    shown
        .view
        .tab_at_every_caret(false, || forwarded.set(forwarded.get() + 1));

    assert_eq!(shown.text(), "\tabc\n\tdef\n\tghi");
    assert_eq!(forwarded.get(), 0, "a caret that indented also typed a tab");
    shown
        .view
        .tab_at_every_caret(true, || forwarded.set(forwarded.get() + 1));
    assert_eq!(shown.text(), "abc\ndef\nghi");
}

#[gtk4::test]
fn unindenting_keeps_a_caret_inside_the_indentation() {
    let shown = Shown::new("        a b");
    shown.view.set_tab_width(4);
    shown.cursor_at(11);
    shown.view.toggle_caret_at(&shown.at(2));

    shown.view.tab_at_every_caret(true, || {});

    assert_eq!(shown.text(), "    a b");
    assert_eq!(shown.view.caret_count(), 2);
}

#[gtk4::test]
fn tab_indents_whole_lines_and_types_at_the_other_carets_as_one_edit() {
    let shown = Shown::new("foo\nfoo\nbar");
    let buffer = shown.buffer();
    buffer.select_range(&shown.at(3), &shown.at(0));
    shown
        .view
        .imp()
        .carets
        .borrow_mut()
        .push(Caret::new(&buffer, &shown.at(7), &shown.at(4)));
    shown
        .view
        .imp()
        .carets
        .borrow_mut()
        .push(Caret::new(&buffer, &shown.at(9), &shown.at(9)));
    let forwarded = std::cell::Cell::new(0);

    // A forwarded Tab where nothing is selected types a tab, as GtkSourceView does.
    shown.view.tab_at_every_caret(false, || {
        forwarded.set(forwarded.get() + 1);
        buffer.insert_at_cursor("\t");
    });

    assert_eq!(shown.text(), "\tfoo\n\tfoo\nb\tar");
    assert_eq!(forwarded.get(), 1);
    buffer.undo();
    assert_eq!(shown.text(), "foo\nfoo\nbar", "one undo took back the whole Tab");
}

#[gtk4::test]
fn a_selection_made_by_hand_finds_any_match() {
    let shown = Shown::new("users u_id u");
    let buffer = shown.buffer();
    buffer.select_range(&shown.at(0), &shown.at(1));

    assert!(shown.view.add_caret_at_next_match());

    assert_eq!(shown.ranges(), [(0, 1), (6, 7)]);
}

#[gtk4::test]
fn all_matches_puts_a_caret_on_each() {
    let shown = Shown::new("SELECT a, a, a FROM t AS a");
    shown.cursor_at(7);

    assert!(shown.view.add_carets_at_all_matches());

    assert_eq!(shown.ranges(), [(7, 8), (10, 11), (13, 14), (25, 26)]);
}

#[gtk4::test]
fn a_column_of_carets_keeps_its_column_past_a_short_line() {
    let shown = Shown::new("abcdef\nab\nabcdef");
    shown.cursor_at(4);

    assert!(shown.view.add_caret_on_next_line(true));
    assert!(shown.view.add_caret_on_next_line(true));

    assert_eq!(shown.ranges(), [(4, 4), (9, 9), (14, 14)]);
    assert!(!shown.view.add_caret_on_next_line(true), "there is no line below");
}

#[gtk4::test]
fn a_move_at_the_carets_starts_the_column_again() {
    let shown = Shown::new("abcd\nabcd\nabcd");
    shown.cursor_at(1);
    assert!(shown.view.add_caret_on_next_line(true));

    shown
        .view
        .emit_by_name::<()>("move-cursor", &[&gtk::MovementStep::LogicalPositions, &1, &false]);
    assert!(shown.view.add_caret_on_next_line(true));

    assert_eq!(shown.ranges(), [(2, 2), (7, 7), (12, 12)]);
}

#[gtk4::test]
fn each_caret_keeps_its_own_column_past_a_short_line() {
    let shown = Shown::new("abcdef\nab\nabcdef\nabcdef");
    shown.cursor_at(4);
    shown.view.toggle_caret_at(&shown.at(8));
    let down = || {
        shown
            .view
            .emit_by_name::<()>("move-cursor", &[&gtk::MovementStep::DisplayLines, &1, &false]);
    };

    down();
    assert_eq!(shown.ranges(), [(9, 9), (11, 11)]);
    down();

    assert_eq!(shown.ranges(), [(14, 14), (18, 18)]);
}

#[gtk4::test]
fn above_the_first_line_adds_nothing() {
    let shown = Shown::new("abc\ndef");
    shown.cursor_at(1);

    assert!(!shown.view.add_caret_on_next_line(false));
    assert_eq!(shown.view.caret_count(), 1);
}

#[gtk4::test]
fn ctrl_click_adds_a_caret_and_takes_one_away() {
    let shown = Shown::new("one two three");
    shown.cursor_at(0);

    shown.view.toggle_caret_at(&shown.at(4));
    assert_eq!(shown.ranges(), [(0, 0), (4, 4)]);
    shown.view.toggle_caret_at(&shown.at(8));
    assert_eq!(shown.ranges(), [(0, 0), (4, 4), (8, 8)]);

    shown.view.toggle_caret_at(&shown.at(0));
    assert_eq!(shown.ranges(), [(4, 4), (8, 8)]);
    shown.view.toggle_caret_at(&shown.at(8));
    assert_eq!(
        shown.ranges(),
        [(4, 4)],
        "taking GTK's cursor away moves it to another caret"
    );
    shown.view.toggle_caret_at(&shown.at(4));
    assert_eq!(shown.ranges(), [(4, 4)], "the last cursor stays");
}

#[gtk4::test]
fn carets_that_meet_become_one() {
    let shown = Shown::new("abcdef");
    shown.cursor_at(3);
    shown.view.toggle_caret_at(&shown.at(5));

    shown
        .view
        .emit_by_name::<()>("move-cursor", &[&gtk::MovementStep::LogicalPositions, &-10, &false]);

    assert_eq!(shown.ranges(), [(0, 0)]);
    assert!(!shown.view.has_extra_carets());
}

#[gtk4::test]
fn moving_and_deleting_by_word_works_on_each_carets_own_word() {
    let shown = Shown::new("alpha one\nbe two");
    shown.cursor_at(0);
    shown.view.toggle_caret_at(&shown.at(10));

    shown
        .view
        .emit_by_name::<()>("move-cursor", &[&gtk::MovementStep::Words, &1, &false]);
    assert_eq!(shown.ranges(), [(5, 5), (12, 12)]);

    shown
        .view
        .emit_by_name::<()>("delete-from-cursor", &[&gtk::DeleteType::WordEnds, &-1]);
    assert_eq!(shown.text(), " one\n two");

    shown.buffer().undo();
    assert_eq!(shown.text(), "alpha one\nbe two");
}

#[gtk4::test]
fn a_caret_inside_text_another_deletes_does_not_delete_again() {
    let shown = Shown::new("hello world");
    shown.cursor_at(7);
    shown.view.toggle_caret_at(&shown.at(9));

    shown
        .view
        .emit_by_name::<()>("delete-from-cursor", &[&gtk::DeleteType::WordEnds, &-1]);

    assert_eq!(shown.text(), "hello ld");
    assert_eq!(shown.ranges(), [(6, 6)]);
}

#[gtk4::test]
fn a_selection_another_caret_deletes_goes_with_it() {
    let shown = Shown::new("one two three");
    let buffer = shown.buffer();
    buffer.select_range(&shown.at(6), &shown.at(4));
    shown.view.toggle_caret_at(&shown.at(7));
    assert!(shown.view.imp().completion_blocked.get());

    shown
        .view
        .emit_by_name::<()>("delete-from-cursor", &[&gtk::DeleteType::WordEnds, &-1]);

    assert_eq!(shown.text(), "one  three");
    assert_eq!(shown.view.caret_count(), 1);
    assert!(
        !shown.view.imp().completion_blocked.get(),
        "the last other caret went without a word"
    );
}

#[gtk4::test]
fn deleting_a_line_takes_each_line_once() {
    let shown = Shown::new("a1 a2\nb\nc");
    shown.cursor_at(0);
    shown.view.toggle_caret_at(&shown.at(3));

    shown
        .view
        .emit_by_name::<()>("delete-from-cursor", &[&gtk::DeleteType::Paragraphs, &1]);

    assert_eq!(shown.text(), "\nb\nc", "the line's text went once");
    assert!(
        !shown.view.imp().completion_blocked.get(),
        "the other caret on the line went without a word"
    );
}

#[gtk4::test]
fn paste_puts_a_line_at_each_caret_when_the_counts_match() {
    let shown = Shown::new("x = ;\ny = ;");
    shown.cursor_at(4);
    shown.view.toggle_caret_at(&shown.at(10));

    shown.view.insert_at_carets("1\n2");
    assert_eq!(shown.text(), "x = 1;\ny = 2;");

    shown.view.insert_at_carets("a\nb\nc");
    assert_eq!(shown.text(), "x = 1a\nb\nc;\ny = 2a\nb\nc;");
}

#[gtk4::test]
fn copy_joins_the_selections_and_cut_takes_them_away() {
    let shown = Shown::three_selected();
    let clipboard = shown.view.clipboard();

    shown.view.emit_by_name::<()>("cut-clipboard", &[]);

    let copied = finish_on_main(WAIT, async move { clipboard.read_text_future().await })
        .expect("the clipboard to answer")
        .expect("text on the clipboard");
    assert_eq!(copied.as_deref(), Some("a\na\na"));
    assert_eq!(shown.text(), "SELECT , , ");
}

#[gtk4::test]
fn a_move_the_carets_did_not_make_leaves_one_cursor() {
    let shown = Shown::new("one two");
    shown.cursor_at(0);
    shown.view.toggle_caret_at(&shown.at(4));
    assert!(shown.view.has_extra_carets());

    shown.cursor_at(2);

    assert!(!shown.view.has_extra_carets());
    assert_eq!(shown.ranges(), [(2, 2)]);
}

#[gtk4::test]
fn back_to_one_cursor_keeps_its_selection() {
    let shown = Shown::three_selected();

    assert!(shown.view.single_caret());
    assert!(!shown.view.single_caret(), "there was nothing left to take away");
    assert_eq!(shown.ranges(), [(13, 14)]);
}

#[gtk4::test]
fn turned_off_there_is_one_cursor_and_no_way_to_add_one() {
    let shown = Shown::three_selected();

    shown.view.set_carets_enabled(false);

    assert_eq!(shown.view.caret_count(), 1);
    assert!(!shown.view.add_caret_at_next_match());
    assert!(!shown.view.add_carets_at_all_matches());
    assert!(!shown.view.add_caret_on_next_line(true));
    shown.view.toggle_caret_at(&shown.at(0));
    assert_eq!(shown.view.caret_count(), 1);
}

#[gtk4::test]
fn a_replacement_before_the_cursor_repeats_at_every_caret() {
    let shown = Shown::new("sel\nsel");
    shown.cursor_at(3);
    shown.view.toggle_caret_at(&shown.at(7));
    let buffer = shown.buffer();

    // As an input method takes back what it typed and commits the text.
    let (mut start, mut end) = (shown.at(4), shown.at(7));
    buffer.begin_user_action();
    buffer.delete(&mut start, &mut end);
    buffer.insert(&mut start, "SELECT");
    buffer.end_user_action();

    assert_eq!(shown.text(), "SELECT\nSELECT");
    buffer.undo();
    assert_eq!(shown.text(), "sel\nsel");
}

#[gtk4::test]
fn a_replacement_over_the_cursor_takes_both_sides_at_every_caret() {
    let shown = Shown::new("sel\nsel");
    shown.cursor_at(2);
    shown.view.toggle_caret_at(&shown.at(6));
    let buffer = shown.buffer();

    let (mut start, mut end) = (shown.at(4), shown.at(7));
    buffer.begin_user_action();
    buffer.delete(&mut start, &mut end);
    buffer.insert(&mut start, "SELECT");
    buffer.end_user_action();

    assert_eq!(shown.text(), "SELECT\nSELECT");
}

#[gtk4::test]
fn a_caret_inside_text_the_cursor_replaces_goes_with_it() {
    let shown = Shown::new("selec");
    shown.cursor_at(2);
    shown.view.toggle_caret_at(&shown.at(5));
    let buffer = shown.buffer();

    let (mut start, mut end) = (shown.at(0), shown.at(5));
    buffer.begin_user_action();
    buffer.delete(&mut start, &mut end);
    buffer.insert(&mut start, "SELECT");
    buffer.end_user_action();

    assert_eq!(shown.text(), "SELECT");
    assert_eq!(shown.view.caret_count(), 1);
}

#[gtk4::test]
fn overwrite_keeps_one_cursor() {
    let shown = Shown::three_selected();

    shown.view.set_overwrite(true);

    assert_eq!(shown.view.caret_count(), 1);
    assert!(!shown.view.add_caret_at_next_match());
    shown.view.set_overwrite(false);
    assert!(shown.view.add_caret_at_next_match());
}

#[gtk4::test]
fn the_completion_list_waits_for_one_cursor() {
    let shown = Shown::new("se se");
    shown.cursor_at(2);

    shown.view.toggle_caret_at(&shown.at(5));
    assert!(shown.view.imp().completion_blocked.get());

    shown.view.single_caret();
    assert!(!shown.view.imp().completion_blocked.get());
}

#[gtk4::test]
fn an_edit_made_once_keeps_every_caret_with_its_code() {
    let shown = Shown::new("a\nb");
    shown.cursor_at(2);
    shown.view.toggle_caret_at(&shown.at(0));
    let buffer = shown.buffer();

    shown.view.edit_once(|| {
        buffer.begin_user_action();
        buffer.insert(&mut buffer.iter_at_offset(2), "-- ");
        buffer.insert(&mut buffer.iter_at_offset(0), "-- ");
        buffer.end_user_action();
    });

    assert_eq!(shown.text(), "-- a\n-- b");
    assert_eq!(shown.ranges(), [(3, 3), (8, 8)]);
    buffer.undo();
    assert_eq!(shown.text(), "a\nb", "one undo took the edit back");
}

#[gtk4::test]
fn an_edit_made_once_stays_where_it_was_made() {
    let shown = Shown::new("a\nb");
    shown.cursor_at(0);
    shown.view.toggle_caret_at(&shown.at(2));
    let buffer = shown.buffer();

    shown.view.edit_once(|| {
        buffer.begin_user_action();
        buffer.insert_at_cursor("-- ");
        buffer.end_user_action();
    });

    assert_eq!(shown.text(), "a\n-- b");
    assert_eq!(shown.view.caret_count(), 2);
}

#[gtk4::test]
fn the_carets_paint() {
    let shown = Shown::three_selected();

    shown.view.queue_draw();
    after_next_frame(&shown.view);
}
