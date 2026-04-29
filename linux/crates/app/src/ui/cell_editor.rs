//! `CellEditor` — the cell widget for editable ColumnView cells.
//!
//! A thin `Stack[Label | Text]` `gtk::Widget` subclass. The display
//! page is a plain `GtkLabel` that does not install any pointer-event
//! controllers, so a single click on the cell bubbles up to the
//! ColumnView's row-selection gesture without a forwarder. The edit
//! page is a `GtkText` shown only after `start_editing()`, where
//! click-to-position-cursor is the desired behaviour. Edit-mode
//! transitions are observable via `connect_editing_notify`, which
//! mirrors the stack's `visible-child-name` notify so callers can
//! snapshot the original text on entry and emit a commit on exit.

use std::cell::OnceCell;

use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use gtk4::{glib, pango};

mod imp {
    use super::*;

    #[derive(Default)]
    pub struct CellEditor {
        pub stack: OnceCell<gtk4::Stack>,
        pub label: OnceCell<gtk4::Label>,
        pub entry: OnceCell<gtk4::Text>,
    }

    #[glib::object_subclass]
    impl ObjectSubclass for CellEditor {
        const NAME: &'static str = "TableProCellEditor";
        type Type = super::CellEditor;
        type ParentType = gtk4::Widget;

        fn class_init(klass: &mut Self::Class) {
            // BinLayout sizes the single child (the stack) to fill
            // the cell — same effect as having a single-child
            // container.
            klass.set_layout_manager_type::<gtk4::BinLayout>();
        }
    }

    impl ObjectImpl for CellEditor {
        fn constructed(&self) {
            self.parent_constructed();
            // Stable CSS class so app-level selectors can target this
            // widget without depending on the type-name node default.
            self.obj().add_css_class("tp-cell-editor");
            let stack = gtk4::Stack::builder()
                .transition_type(gtk4::StackTransitionType::None)
                .hhomogeneous(true)
                .vhomogeneous(true)
                .build();
            let label = gtk4::Label::builder()
                .xalign(0.0)
                .hexpand(true)
                .ellipsize(pango::EllipsizeMode::End)
                .build();
            let entry = gtk4::Text::builder().hexpand(true).build();
            stack.add_named(&label, Some("display"));
            stack.add_named(&entry, Some("edit"));
            stack.set_visible_child_name("display");
            stack.set_parent(&*self.obj());

            // Enter commits the edit. `gtk::Text::activate` fires on
            // Enter / Return / KP_Enter — the canonical "user is done
            // typing" signal.
            let weak_for_activate = self.obj().downgrade();
            entry.connect_activate(move |_| {
                if let Some(this) = weak_for_activate.upgrade() {
                    this.stop_editing(true);
                }
            });

            // Esc cancels — switch back to the display child without
            // committing the entry's text. Capture phase so we run
            // before the inner GtkText handles the key (otherwise
            // GtkText might consume Escape to clear its own buffer
            // without us knowing to revert).
            let key_ctrl = gtk4::EventControllerKey::new();
            key_ctrl.set_propagation_phase(gtk4::PropagationPhase::Capture);
            let weak_for_key = self.obj().downgrade();
            key_ctrl.connect_key_pressed(move |_, keyval, _, _| {
                if keyval == gtk4::gdk::Key::Escape
                    && let Some(this) = weak_for_key.upgrade()
                    && this.is_editing()
                {
                    this.stop_editing(false);
                    return glib::Propagation::Stop;
                }
                glib::Propagation::Proceed
            });
            entry.add_controller(key_ctrl);

            // Focus-out commits — matches the spreadsheet convention
            // where moving focus away accepts the value. Without this
            // an edit would only commit on Enter / Tab. GtkText
            // flushes any active IME preedit on focus-out before this
            // fires, so the entry's text holds the final composed
            // value when stop_editing copies it.
            let focus_ctrl = gtk4::EventControllerFocus::new();
            let weak_for_focus = self.obj().downgrade();
            focus_ctrl.connect_leave(move |_| {
                if let Some(this) = weak_for_focus.upgrade()
                    && this.is_editing()
                {
                    this.stop_editing(true);
                }
            });
            entry.add_controller(focus_ctrl);

            self.stack.set(stack).expect("constructed once");
            self.label.set(label).expect("constructed once");
            self.entry.set(entry).expect("constructed once");
        }

        fn dispose(&self) {
            // BinLayout-managed child must be unparented before our
            // destructor runs or GTK warns about a finalised widget
            // with leftover children.
            if let Some(stack) = self.stack.get() {
                stack.unparent();
            }
        }
    }

    impl WidgetImpl for CellEditor {}
}

glib::wrapper! {
    pub struct CellEditor(ObjectSubclass<imp::CellEditor>)
        @extends gtk4::Widget,
        @implements gtk4::Accessible, gtk4::Buildable, gtk4::ConstraintTarget;
}

impl Default for CellEditor {
    fn default() -> Self {
        Self::new()
    }
}

impl CellEditor {
    pub fn new() -> Self {
        glib::Object::new()
    }

    /// Current displayed text. In edit mode reads from the entry
    /// (so a still-editing cell returns the user's in-progress
    /// value); otherwise reads from the label.
    pub fn text(&self) -> glib::GString {
        if self.is_editing() {
            self.entry_widget().text()
        } else {
            self.label_widget().text()
        }
    }

    pub fn set_text(&self, s: &str) {
        self.label_widget().set_text(s);
        self.entry_widget().set_text(s);
    }

    /// Apply or clear a Pango strikethrough attribute on the display
    /// Label. Edit-mode `GtkText` is intentionally unaffected — a row
    /// marked for deletion is read-only by definition.
    pub fn set_strikethrough(&self, on: bool) {
        let label = self.label_widget();
        if on {
            let attrs = pango::AttrList::new();
            attrs.insert(pango::AttrInt::new_strikethrough(true));
            label.set_attributes(Some(&attrs));
        } else {
            label.set_attributes(None);
        }
    }

    pub fn is_editing(&self) -> bool {
        self.stack_widget()
            .visible_child_name()
            .map(|n| n == "edit")
            .unwrap_or(false)
    }

    pub fn start_editing(&self) {
        let stack = self.stack_widget();
        let entry = self.entry_widget();
        // Mirror the label's text into the entry before showing it
        // so the user starts editing the value they see.
        entry.set_text(&self.label_widget().text());
        stack.set_visible_child_name("edit");
        entry.grab_focus();
        // Select all so the first keystroke replaces — matches the
        // GTK Files rename flow and is what spreadsheet users expect.
        entry.select_region(0, -1);
    }

    pub fn stop_editing(&self, commit: bool) {
        if commit {
            let new_text = self.entry_widget().text();
            self.label_widget().set_text(&new_text);
        } else {
            // Revert the entry buffer so a subsequent start_editing
            // doesn't surface stale aborted text.
            self.entry_widget().set_text(&self.label_widget().text());
        }
        self.stack_widget().set_visible_child_name("display");
    }

    /// Subscribe to edit-mode toggles. The callback fires whenever
    /// the stack's visible child changes (display ↔ edit).
    pub fn connect_editing_notify<F: Fn(&Self) + 'static>(&self, callback: F) -> glib::SignalHandlerId {
        let stack = self.stack_widget();
        let weak = self.downgrade();
        stack.connect_visible_child_name_notify(move |_| {
            if let Some(this) = weak.upgrade() {
                callback(&this);
            }
        })
    }

    /// The inner `GtkText` widget. Exposed so callers that need the
    /// IME-aware delegate (preedit-changed, etc.) can hook directly
    /// onto it.
    pub fn entry(&self) -> gtk4::Text {
        self.entry_widget()
    }

    fn stack_widget(&self) -> gtk4::Stack {
        self.imp().stack.get().expect("constructed").clone()
    }

    fn label_widget(&self) -> gtk4::Label {
        self.imp().label.get().expect("constructed").clone()
    }

    fn entry_widget(&self) -> gtk4::Text {
        self.imp().entry.get().expect("constructed").clone()
    }
}
