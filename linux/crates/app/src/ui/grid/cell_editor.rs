//! The display page is a plain label with no pointer controllers while
//! the cell takes edits, so a single click reaches the column view's row
//! selection. The edit page shows only after `start_editing`.

use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use gtk4::{glib, pango};

mod imp {
    use super::*;

    pub struct CellEditor {
        pub stack: gtk4::Stack,
        pub label: gtk4::Label,
        pub entry: gtk4::Text,
    }

    impl Default for CellEditor {
        fn default() -> Self {
            Self {
                stack: gtk4::Stack::new(),
                label: gtk4::Label::new(None),
                entry: gtk4::Text::new(),
            }
        }
    }

    #[glib::object_subclass]
    impl ObjectSubclass for CellEditor {
        const NAME: &'static str = "TableProCellEditor";
        type Type = super::CellEditor;
        type ParentType = gtk4::Widget;

        fn class_init(klass: &mut Self::Class) {
            klass.set_layout_manager_type::<gtk4::BinLayout>();
        }
    }

    impl ObjectImpl for CellEditor {
        fn constructed(&self) {
            self.parent_constructed();
            // App styles select this class, not the type's node name.
            self.obj().add_css_class("tp-cell-editor");
            let stack = &self.stack;
            stack.set_transition_type(gtk4::StackTransitionType::None);
            stack.set_hhomogeneous(true);
            stack.set_vhomogeneous(true);
            let label = &self.label;
            label.set_xalign(0.0);
            label.set_hexpand(true);
            label.set_ellipsize(pango::EllipsizeMode::End);
            let entry = &self.entry;
            entry.set_hexpand(true);
            stack.add_named(label, Some("display"));
            stack.add_named(entry, Some("edit"));
            stack.set_visible_child_name("display");
            stack.set_parent(&*self.obj());

            let weak_for_activate = self.obj().downgrade();
            entry.connect_activate(move |_| {
                if let Some(this) = weak_for_activate.upgrade() {
                    this.stop_editing(true);
                }
            });

            // Capture phase, so Escape cancels before the GtkText can
            // take it to clear its own buffer.
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

            // GtkText flushes an IME preedit on focus-out before this
            // runs, so the commit copies the composed text.
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
        }

        fn dispose(&self) {
            // GTK warns about a finalized widget that still has children.
            self.stack.unparent();
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

    pub fn set_selectable(&self, selectable: bool) {
        let label = self.label_widget();
        if label.is_selectable() != selectable {
            label.set_selectable(selectable);
        }
    }

    /// The entry is left alone: a row marked for deletion is not edited.
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
        entry.set_text(&self.label_widget().text());
        stack.set_visible_child_name("edit");
        entry.grab_focus();
        // The first keystroke replaces the value, as in a Files rename.
        entry.select_region(0, -1);
    }

    pub fn stop_editing(&self, commit: bool) {
        if commit {
            let new_text = self.entry_widget().text();
            self.label_widget().set_text(&new_text);
        } else {
            self.entry_widget().set_text(&self.label_widget().text());
        }
        self.stack_widget().set_visible_child_name("display");
    }

    pub fn connect_editing_notify<F: Fn(&Self) + 'static>(&self, callback: F) -> glib::SignalHandlerId {
        let stack = self.stack_widget();
        let weak = self.downgrade();
        stack.connect_visible_child_name_notify(move |_| {
            if let Some(this) = weak.upgrade() {
                callback(&this);
            }
        })
    }

    pub fn entry(&self) -> gtk4::Text {
        self.entry_widget()
    }

    fn stack_widget(&self) -> gtk4::Stack {
        self.imp().stack.clone()
    }

    fn label_widget(&self) -> gtk4::Label {
        self.imp().label.clone()
    }

    fn entry_widget(&self) -> gtk4::Text {
        self.imp().entry.clone()
    }
}
