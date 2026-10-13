use std::cell::{Cell, OnceCell, RefCell};

use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use gtk4::{self as gtk, glib};

use super::{CellEditor, CellLock, EditSnapshot, RowObject};

mod imp {
    use super::*;

    #[derive(Default)]
    pub struct GridCell {
        pub list_item: glib::WeakRef<gtk::ColumnViewCell>,
        pub column: Cell<usize>,
        pub content: OnceCell<gtk::Widget>,
        /// An open editor popover. Unbind pops it down, or the recycled
        /// cell is finalized with a GtkPopover child still in it.
        pub popover: RefCell<Option<gtk::Popover>>,
        pub edit: RefCell<Option<EditSnapshot>>,
        /// Set while the bind draws a check button, which would otherwise
        /// echo back as an edit of the value it just drew.
        pub suppress_toggle: Cell<bool>,
        /// Set while an IME composition is in flight: focus moving to the
        /// IME popover ends the edit, and committing then would send the
        /// text from before the composition.
        pub preedit_active: Cell<bool>,
        pub lock: Cell<Option<CellLock>>,
    }

    #[glib::object_subclass]
    impl ObjectSubclass for GridCell {
        const NAME: &'static str = "TableProGridCell";
        type Type = super::GridCell;
        type ParentType = gtk::Widget;

        fn class_init(klass: &mut Self::Class) {
            klass.set_layout_manager_type::<gtk::BinLayout>();
            klass.set_css_name("tp-grid-cell");
        }
    }

    impl ObjectImpl for GridCell {
        fn dispose(&self) {
            if let Some(popover) = self.popover.take() {
                popover.unparent();
            }
            if let Some(content) = self.content.get() {
                content.unparent();
            }
        }
    }

    impl WidgetImpl for GridCell {}
}

glib::wrapper! {
    /// One cell of the grid. It resolves its row through the column view
    /// cell when an event fires, so the row is the one the cell shows
    /// then, not the one it was bound to.
    pub struct GridCell(ObjectSubclass<imp::GridCell>)
        @extends gtk::Widget,
        @implements gtk::Accessible, gtk::Buildable, gtk::ConstraintTarget;
}

impl Default for GridCell {
    fn default() -> Self {
        Self::new()
    }
}

impl GridCell {
    pub fn new() -> Self {
        glib::Object::new()
    }

    pub fn attach(&self, cell: &gtk::ColumnViewCell, column: usize) {
        self.imp().list_item.set(Some(cell));
        self.imp().column.set(column);
    }

    pub fn set_content(&self, content: &impl IsA<gtk::Widget>) {
        let content = content.as_ref();
        if self.imp().content.set(content.clone()).is_ok() {
            content.set_parent(self);
        }
    }

    pub fn content(&self) -> Option<&gtk::Widget> {
        self.imp().content.get()
    }

    pub fn editor(&self) -> Option<CellEditor> {
        self.content()?.clone().downcast().ok()
    }

    pub fn row(&self) -> Option<RowObject> {
        self.imp().list_item.upgrade()?.item().and_downcast()
    }

    pub fn position(&self) -> Option<u32> {
        let position = self.imp().list_item.upgrade()?.position();
        (position != gtk::INVALID_LIST_POSITION).then_some(position)
    }

    pub fn column(&self) -> usize {
        self.imp().column.get()
    }

    pub fn is_editing(&self) -> bool {
        self.imp().edit.borrow().is_some() || self.imp().popover.borrow().is_some()
    }

    /// The cell that holds the keyboard focus. A focused column view
    /// cell widget is this cell's parent, so its first child is tried
    /// after its ancestors.
    pub fn from_focus(focus: &gtk::Widget) -> Option<GridCell> {
        if let Some(cell) = focus.ancestor(GridCell::static_type()) {
            return cell.downcast().ok();
        }
        focus.first_child()?.downcast().ok()
    }

    pub fn lock(&self) -> Option<CellLock> {
        self.imp().lock.get()
    }

    pub(super) fn set_lock(&self, lock: Option<CellLock>) {
        self.imp().lock.set(lock);
    }

    pub(super) fn begin_edit(&self, snapshot: EditSnapshot) {
        self.imp().edit.replace(Some(snapshot));
    }

    pub(super) fn take_edit(&self) -> Option<EditSnapshot> {
        self.imp().edit.take()
    }

    pub(super) fn set_popover(&self, popover: &gtk::Popover) {
        if let Some(previous) = self.imp().popover.replace(Some(popover.clone())) {
            previous.popdown();
        }
    }

    pub(super) fn take_popover(&self) -> Option<gtk::Popover> {
        self.imp().popover.take()
    }

    /// Forget `popover` if it is still this cell's, leaving a newer one
    /// in place.
    pub(super) fn release_popover(&self, popover: &gtk::Popover) {
        let mut slot = self.imp().popover.borrow_mut();
        if slot.as_ref() == Some(popover) {
            slot.take();
        }
    }

    pub(super) fn toggle_suppressed(&self) -> bool {
        self.imp().suppress_toggle.get()
    }

    pub(super) fn suppress_toggle(&self, suppressed: bool) {
        self.imp().suppress_toggle.set(suppressed);
    }

    pub(super) fn preedit_active(&self) -> bool {
        self.imp().preedit_active.get()
    }

    pub(super) fn set_preedit_active(&self, active: bool) {
        self.imp().preedit_active.set(active);
    }
}

#[cfg(test)]
mod tests {
    use gtk4 as gtk;
    use gtk4::prelude::*;

    use super::GridCell;
    use crate::ui::grid::CellEditor;

    #[gtk4::test]
    fn from_focus_finds_the_cell_below_a_focused_cell_widget_or_above_its_editor() {
        let cell_widget = gtk::Box::new(gtk::Orientation::Horizontal, 0);
        let cell = GridCell::new();
        let editor = CellEditor::new();
        cell.set_content(&editor);
        cell_widget.append(&cell);

        let below = GridCell::from_focus(cell_widget.upcast_ref());
        let above = GridCell::from_focus(editor.entry().upcast_ref());

        assert_eq!(below.as_ref(), Some(&cell));
        assert_eq!(above.as_ref(), Some(&cell));
        assert!(GridCell::from_focus(gtk::Label::new(None).upcast_ref()).is_none());
    }

    #[gtk4::test]
    fn an_unattached_cell_has_no_row() {
        let cell = GridCell::new();

        assert!(cell.row().is_none());
        assert!(cell.position().is_none());
        assert!(!cell.is_editing());
    }
}
