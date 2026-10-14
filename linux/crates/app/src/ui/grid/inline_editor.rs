use std::cell::Cell;
use std::rc::Rc;

use gtk4::prelude::*;
use gtk4::{self as gtk, glib};

use super::edit_commit::{commit_edit, send_commit};
use super::{EditSnapshot, GridCell};

/// How the one-line editor treats what is typed into it.
#[derive(Debug, Clone, PartialEq)]
pub struct InlineOptions {
    /// Off for a column a line break means nothing in: a pasted break
    /// keeps the first line, as a one-line field does elsewhere.
    pub accepts_line_breaks: bool,
    pub purpose: gtk::InputPurpose,
    /// What an empty commit means, shown while the field is empty.
    pub placeholder: Option<String>,
}

/// A `gtk::Text` laid over the cell's display while an edit is open, and
/// removed when it commits or is cancelled.
#[derive(Debug)]
pub struct InlineEditor {
    text: gtk::Text,
}

impl InlineEditor {
    pub(super) fn begin(cell: &GridCell, snapshot: EditSnapshot, initial: &str, options: InlineOptions) {
        cell.cancel_edit();
        let text = gtk::Text::new();
        text.set_hexpand(true);
        text.set_margin_start(8);
        text.set_margin_end(8);
        text.add_css_class("tp-cell-text");
        text.set_truncate_multiline(!options.accepts_line_breaks);
        text.set_input_purpose(options.purpose);
        text.set_placeholder_text(options.placeholder.as_deref());
        text.set_text(initial);
        connect_commit(cell, &text);
        if let Some(display) = cell.content() {
            display.set_visible(false);
        }
        text.set_parent(cell);
        cell.begin_edit(snapshot);
        cell.set_inline(Self { text: text.clone() });
        text.grab_focus();
        // The first keystroke replaces the value, as in a Files rename.
        text.select_region(0, -1);
    }

    pub(super) fn widget(&self) -> &gtk::Text {
        &self.text
    }

    /// Take the field out of the cell and show the display again, with
    /// the text the field held.
    pub(super) fn close(self, cell: &GridCell) -> String {
        let typed = self.text.text().to_string();
        self.text.unparent();
        if let Some(display) = cell.content() {
            display.set_visible(true);
        }
        typed
    }
}

/// End the cell's one-line edit. The field leaves before the commit is
/// sent, so the redraw the commit causes meets no open editor.
pub(super) fn finish_inline(cell: &GridCell, commit: bool) {
    let Some(editor) = cell.take_inline() else {
        return;
    };
    let snapshot = cell.take_edit();
    let typed = editor.close(cell);
    if !commit {
        return;
    }
    let (Some(snapshot), Some(drawing)) = (snapshot, cell.drawing()) else {
        return;
    };
    let Some(column) = drawing.catalog.as_ref() else {
        return;
    };
    let result = commit_edit(column, &snapshot, &typed);
    send_commit(cell, snapshot, result);
}

/// The field is the cell's child, so its handlers hold the cell weakly.
fn connect_commit(cell: &GridCell, text: &gtk::Text) {
    let weak = cell.downgrade();
    text.connect_activate(move |_| {
        if let Some(cell) = weak.upgrade() {
            finish_inline(&cell, true);
        }
    });

    // Capture phase, so Escape cancels before the GtkText can take it to
    // clear its own buffer.
    let keys = gtk::EventControllerKey::new();
    keys.set_propagation_phase(gtk::PropagationPhase::Capture);
    let weak = cell.downgrade();
    keys.connect_key_pressed(move |_, keyval, _, _| {
        if keyval != gtk::gdk::Key::Escape {
            return glib::Propagation::Proceed;
        }
        let Some(cell) = weak.upgrade() else {
            return glib::Propagation::Proceed;
        };
        finish_inline(&cell, false);
        glib::Propagation::Stop
    });
    text.add_controller(keys);

    // Focus moving to an IME popover ends the edit mid-composition, and
    // committing then would send the text from before it, so the commit
    // waits for the preedit to clear.
    let composing = Rc::new(Cell::new(false));
    let commit_when_composed = Rc::new(Cell::new(false));
    let weak = cell.downgrade();
    let preedit_composing = composing.clone();
    let preedit_commit = commit_when_composed.clone();
    text.connect_preedit_changed(move |_, preedit| {
        preedit_composing.set(!preedit.is_empty());
        if preedit.is_empty()
            && preedit_commit.replace(false)
            && let Some(cell) = weak.upgrade()
        {
            finish_inline(&cell, true);
        }
    });

    let focus = gtk::EventControllerFocus::new();
    let weak = cell.downgrade();
    focus.connect_leave(move |_| {
        let Some(cell) = weak.upgrade() else {
            return;
        };
        if composing.get() {
            commit_when_composed.set(true);
            return;
        }
        finish_inline(&cell, true);
    });
    text.add_controller(focus);
}
