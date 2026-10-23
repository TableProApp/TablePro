use std::cell::{Cell, RefCell};
use std::sync::OnceLock;

use glib::subclass::Signal;
use gtk4 as gtk;
use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use sourceview5::subclass::prelude::*;

use super::Order;
use super::caret::Caret;
use super::paint;
use super::pending::Pending;

/// The buffer outlives a buffer swap, and keeps its handlers.
pub(super) struct BufferHandlers {
    pub(super) buffer: glib::WeakRef<gtk::TextBuffer>,
    pub(super) ids: Vec<glib::SignalHandlerId>,
}

impl Drop for BufferHandlers {
    fn drop(&mut self) {
        if let Some(buffer) = self.buffer.upgrade() {
            for id in self.ids.drain(..) {
                buffer.disconnect(id);
            }
        }
    }
}

#[derive(Default)]
pub struct EditorView {
    /// GTK's own cursor is the primary.
    pub(super) carets: RefCell<Vec<Caret>>,
    /// GTK's cursor moves or the buffer changes for the carets themselves.
    pub(super) busy: Cell<bool>,
    /// An undo or a redo puts GTK's cursor back where the edit was.
    pub(super) restoring: Cell<bool>,
    pub(super) in_user_action: Cell<bool>,
    pub(super) pending: RefCell<Vec<Pending>>,
    /// Vim mode edits the buffer itself, so no caret could follow it.
    pub(super) disabled: Cell<bool>,
    /// The next-match text came from the word at the cursor.
    pub(super) word_search: Cell<bool>,
    /// Where a column of carets started, so a short line on the way does
    /// not pull the next one in.
    pub(super) column_x: Cell<Option<i32>>,
    pub(super) handlers: RefCell<Option<BufferHandlers>>,
    pub(super) replay: RefCell<Option<super::Replay>>,
    pub(super) disposed: Cell<bool>,
    /// The column each caret, in document order, keeps over Up and Down,
    /// as GTK keeps one for its own cursor.
    pub(super) columns: RefCell<Option<Vec<i32>>>,
    /// Carets inside text the user action under way deleted, such as a
    /// word a completion replaced around them.
    pub(super) swallowed: RefCell<std::collections::HashSet<usize>>,
    pub(super) completion_blocked: Cell<bool>,
    pub(super) snippets_enabled: Cell<bool>,
}

#[glib::object_subclass]
impl ObjectSubclass for EditorView {
    const NAME: &'static str = "TableProEditorView";
    type Type = super::EditorView;
    type ParentType = sourceview5::View;
}

impl ObjectImpl for EditorView {
    fn signals() -> &'static [Signal] {
        static SIGNALS: OnceLock<Vec<Signal>> = OnceLock::new();
        SIGNALS.get_or_init(|| vec![Signal::builder("carets-changed").build()])
    }

    fn constructed(&self) {
        self.parent_constructed();
        self.obj().setup();
    }

    fn dispose(&self) {
        // GtkTextView drops its buffer as it goes, and asking a view with
        // none for its buffer makes it a new one.
        self.disposed.set(true);
        self.handlers.take();
        self.carets.take();
    }
}

impl WidgetImpl for EditorView {}

impl TextViewImpl for EditorView {
    fn move_cursor(&self, step: gtk::MovementStep, count: i32, extend_selection: bool) {
        let view = self.obj();
        if !view.runs_per_caret() {
            return self.parent_move_cursor(step, count, extend_selection);
        }
        // A page moves the view too, once per caret it would scroll as many.
        if matches!(step, gtk::MovementStep::Pages | gtk::MovementStep::HorizontalPages) {
            view.single_caret();
            return self.parent_move_cursor(step, count, extend_selection);
        }
        if step == gtk::MovementStep::DisplayLines {
            return view.move_vertically(extend_selection, || {
                self.parent_move_cursor(step, count, extend_selection);
            });
        }
        view.at_every_caret(|_| self.parent_move_cursor(step, count, extend_selection));
    }

    fn backspace(&self) {
        let view = self.obj();
        if view.runs_per_caret() {
            view.at_every_caret_in(Order::Backward, |_| self.parent_backspace());
        } else {
            self.parent_backspace();
        }
    }

    fn delete_from_cursor(&self, type_: gtk::DeleteType, count: i32) {
        let view = self.obj();
        if !view.runs_per_caret() {
            return self.parent_delete_from_cursor(type_, count);
        }
        if matches!(type_, gtk::DeleteType::Paragraphs | gtk::DeleteType::DisplayLines) {
            view.one_caret_per_line();
        }
        let order = if count < 0 { Order::Backward } else { Order::Forward };
        view.at_every_caret_in(order, |_| self.parent_delete_from_cursor(type_, count));
    }

    fn insert_at_cursor(&self, text: &str) {
        let view = self.obj();
        if view.runs_per_caret() {
            view.at_every_caret(|_| self.parent_insert_at_cursor(text));
        } else {
            self.parent_insert_at_cursor(text);
        }
    }

    fn copy_clipboard(&self) {
        let view = self.obj();
        if !(view.runs_per_caret() && view.copy_carets()) {
            self.parent_copy_clipboard();
        }
    }

    fn cut_clipboard(&self) {
        let view = self.obj();
        if view.runs_per_caret() {
            view.cut_carets();
        } else {
            self.parent_cut_clipboard();
        }
    }

    fn paste_clipboard(&self) {
        let view = self.obj();
        if view.runs_per_caret() {
            view.paste_at_carets();
        } else {
            self.parent_paste_clipboard();
        }
    }

    fn snapshot_layer(&self, layer: gtk::TextViewLayer, snapshot: gtk::Snapshot) {
        self.parent_snapshot_layer(layer, snapshot.clone());
        paint::carets(&self.obj(), layer, &snapshot);
    }
}

impl ViewImpl for EditorView {
    // A completion replaces the word at GTK's cursor alone.
    fn show_completion(&self) {
        let view = self.obj();
        if view.has_extra_carets() {
            view.error_bell();
        } else {
            self.parent_show_completion();
        }
    }

    // Both move the text around the cursor, which two carets on one line
    // would move twice.
    fn move_lines(&self, down: bool) {
        self.obj().single_caret();
        self.parent_move_lines(down);
    }

    fn move_words(&self, step: i32) {
        self.obj().single_caret();
        self.parent_move_words(step);
    }
}
