use gtk4::prelude::*;

/// Replace everything in the buffer as one step Ctrl+Z can take back.
///
/// `TextBuffer::set_text` is recorded as irreversible, so Format, a
/// query picked from history or a loaded file would wipe what the user
/// had with no way back. A delete and an insert inside one user action
/// are a single undo step instead.
pub fn replace_all_undoable(buffer: &impl IsA<gtk4::TextBuffer>, text: &str) {
    let buffer = buffer.as_ref();
    buffer.begin_user_action();
    let (mut start, mut end) = buffer.bounds();
    buffer.delete(&mut start, &mut end);
    let mut at = buffer.start_iter();
    buffer.insert(&mut at, text);
    buffer.end_user_action();
}

/// Where the cursor was, by line and column, so it can be put back near
/// the same place after the text around it was rewritten.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CursorAnchor {
    line: i32,
    line_offset: i32,
}

impl CursorAnchor {
    pub fn capture(buffer: &impl IsA<gtk4::TextBuffer>) -> Self {
        let buffer = buffer.as_ref();
        let iter = buffer.iter_at_mark(&buffer.get_insert());
        Self {
            line: iter.line(),
            line_offset: iter.line_offset(),
        }
    }

    /// Put the cursor back, clamped to the text that is there now: a
    /// shorter line or fewer lines move it to the nearest end.
    pub fn restore(self, buffer: &impl IsA<gtk4::TextBuffer>) {
        let buffer = buffer.as_ref();
        let last_line = (buffer.line_count() - 1).max(0);
        let line = self.line.clamp(0, last_line);
        let Some(mut iter) = buffer.iter_at_line(line) else {
            buffer.place_cursor(&buffer.end_iter());
            return;
        };
        let mut line_end = iter;
        if !line_end.ends_line() {
            line_end.forward_to_line_end();
        }
        iter.set_line_offset(self.line_offset.clamp(0, line_end.line_offset()));
        buffer.place_cursor(&iter);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn buffer(text: &str) -> gtk4::TextBuffer {
        let buffer = gtk4::TextBuffer::new(None);
        buffer.set_text(text);
        buffer
    }

    fn text(buffer: &gtk4::TextBuffer) -> String {
        let (start, end) = buffer.bounds();
        buffer.text(&start, &end, false).to_string()
    }

    #[gtk4::test]
    fn format_is_one_undo_step() {
        let buffer = buffer("select 1;select 2");
        assert!(!buffer.can_undo(), "set_text left something to undo");

        replace_all_undoable(&buffer, "SELECT\n    1;\n\nSELECT\n    2");
        assert!(buffer.can_undo());

        buffer.undo();

        assert_eq!(text(&buffer), "select 1;select 2");
        assert!(!buffer.can_undo(), "the replace took more than one undo step");
    }

    #[gtk4::test]
    fn cursor_anchor_clamps_to_shorter_text() {
        let buffer = buffer("SELECT 1\nFROM a_long_table_name\nWHERE x = 1");
        let mut iter = buffer.iter_at_line(2).expect("a third line");
        iter.set_line_offset(9);
        buffer.place_cursor(&iter);
        let anchor = CursorAnchor::capture(&buffer);

        buffer.set_text("SELECT 1\nFROM t");
        anchor.restore(&buffer);

        let cursor = buffer.iter_at_mark(&buffer.get_insert());
        assert_eq!((cursor.line(), cursor.line_offset()), (1, 6));
    }

    #[gtk4::test]
    fn cursor_anchor_keeps_a_position_that_still_exists() {
        let buffer = buffer("SELECT 1\nFROM t");
        let mut iter = buffer.iter_at_line(1).expect("a second line");
        iter.set_line_offset(2);
        buffer.place_cursor(&iter);
        let anchor = CursorAnchor::capture(&buffer);

        replace_all_undoable(&buffer, "SELECT\n    1\nFROM\n    t");
        anchor.restore(&buffer);

        let cursor = buffer.iter_at_mark(&buffer.get_insert());
        assert_eq!((cursor.line(), cursor.line_offset()), (1, 2));
    }
}
