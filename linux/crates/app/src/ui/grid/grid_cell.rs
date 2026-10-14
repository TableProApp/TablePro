use std::cell::{Cell, OnceCell, RefCell};
use std::rc::Rc;

use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use gtk4::{self as gtk, glib};
use tablepro_core::edit::CellInput;

use super::cell_binding::CellBinding;
use super::column_drawing::ColumnDrawing;
use super::inline_editor::InlineEditor;
use super::{CellLock, EditSnapshot, GridSink, RowObject};

mod imp {
    use super::*;

    #[derive(Default)]
    pub struct GridCell {
        pub list_item: glib::WeakRef<gtk::ColumnViewCell>,
        pub column: Cell<usize>,
        /// What the cell draws its value with: an Inscription, or a check
        /// button for a boolean column.
        pub content: OnceCell<gtk::Widget>,
        /// The one-line editor, laid over the hidden display while open.
        pub inline: RefCell<Option<InlineEditor>>,
        /// An open editor popover. Unbind pops it down, or the recycled
        /// cell is finalized with a GtkPopover child still in it.
        pub popover: RefCell<Option<gtk::Popover>>,
        pub edit: RefCell<Option<EditSnapshot>>,
        /// Set while the bind draws a check button, which would otherwise
        /// echo back as an edit of the value it just drew.
        pub suppress_toggle: Cell<bool>,
        pub lock: Cell<Option<CellLock>>,
        pub drawing: OnceCell<Rc<ColumnDrawing>>,
        /// Where the cell's editors send their edits.
        pub sink: OnceCell<GridSink>,
        pub binding: RefCell<Option<CellBinding>>,
        #[cfg(test)]
        pub renders: Cell<u32>,
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
            self.binding.take();
            self.edit.take();
            if let Some(editor) = self.inline.take() {
                editor.widget().unparent();
            }
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

    /// The text display every cell but a check box draws with.
    pub fn display(&self) -> Option<gtk::Inscription> {
        self.content()?.clone().downcast().ok()
    }

    pub fn check_button(&self) -> Option<gtk::CheckButton> {
        self.content()?.clone().downcast().ok()
    }

    /// The one-line editor's text field while it is open.
    pub fn inline_text(&self) -> Option<gtk::Text> {
        self.imp()
            .inline
            .borrow()
            .as_ref()
            .map(|editor| editor.widget().clone())
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
        let imp = self.imp();
        imp.edit.borrow().is_some() || imp.popover.borrow().is_some() || imp.inline.borrow().is_some()
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

    pub(super) fn set_drawing(&self, drawing: Rc<ColumnDrawing>) {
        let _ = self.imp().drawing.set(drawing);
    }

    pub(super) fn drawing(&self) -> Option<Rc<ColumnDrawing>> {
        self.imp().drawing.get().cloned()
    }

    pub(super) fn set_sink(&self, sink: GridSink) {
        let _ = self.imp().sink.set(sink);
    }

    pub(super) fn sink(&self) -> Option<GridSink> {
        self.imp().sink.get().cloned()
    }

    pub(super) fn bind(&self, row: &RowObject) {
        let lock = match self.imp().drawing.get() {
            Some(drawing) => drawing.lock(row.id()),
            None => Some(CellLock::ResultRow),
        };
        self.imp().lock.set(lock);
        self.imp().binding.replace(Some(CellBinding::new(self, row)));
        self.render();
    }

    /// An edit or popover still open is cancelled, since the row it was
    /// for is no longer this cell's.
    pub(super) fn unbind(&self) {
        self.imp().binding.take();
        self.cancel_edit();
    }

    /// The snapshot goes first, so an editor closing sends nothing.
    pub(crate) fn cancel_edit(&self) {
        self.take_edit();
        if let Some(editor) = self.take_inline() {
            editor.close(self);
        }
        if let Some(popover) = self.take_popover() {
            popover.popdown();
        }
    }

    pub(super) fn render(&self) {
        #[cfg(test)]
        self.imp().renders.set(self.imp().renders.get() + 1);
        let row = self
            .imp()
            .binding
            .borrow()
            .as_ref()
            .map(|binding| binding.row().clone());
        let (Some(row), Some(drawing)) = (row, self.drawing()) else {
            return;
        };
        drawing.draw(self, &row);
    }

    #[cfg(test)]
    pub(super) fn render_count(&self) -> u32 {
        self.imp().renders.get()
    }

    pub(super) fn begin_edit(&self, snapshot: EditSnapshot) {
        self.imp().edit.replace(Some(snapshot));
    }

    pub(super) fn take_edit(&self) -> Option<EditSnapshot> {
        self.imp().edit.take()
    }

    /// The value the open edit started from.
    pub(super) fn edit_original(&self) -> Option<CellInput> {
        self.imp()
            .edit
            .borrow()
            .as_ref()
            .map(|snapshot| snapshot.original.clone())
    }

    pub(super) fn set_inline(&self, editor: InlineEditor) {
        self.imp().inline.replace(Some(editor));
    }

    pub(super) fn take_inline(&self) -> Option<InlineEditor> {
        self.imp().inline.take()
    }

    /// Parent `popover` to the cell and keep it there until it closes.
    /// A popover the user closes ends its edit; one the editor took back
    /// first has already dealt with it.
    pub(super) fn present_popover(&self, popover: &gtk::Popover) {
        popover.set_parent(self);
        if let Some(previous) = self.imp().popover.replace(Some(popover.clone())) {
            previous.popdown();
        }
        // The cell holds the popover in its slot and as its child, so the
        // popover holds the cell weakly and itself not at all.
        let cell = self.downgrade();
        popover.connect_closed(move |popover| {
            popover.unparent();
            if let Some(cell) = cell.upgrade()
                && cell.release_popover(popover)
            {
                cell.take_edit();
            }
        });
        popover.popup();
    }

    pub(super) fn take_popover(&self) -> Option<gtk::Popover> {
        self.imp().popover.take()
    }

    /// Forget `popover` if it is still this cell's, leaving a newer one
    /// in place. `true` when it was.
    fn release_popover(&self, popover: &gtk::Popover) -> bool {
        let mut slot = self.imp().popover.borrow_mut();
        if slot.as_ref() == Some(popover) {
            slot.take();
            return true;
        }
        false
    }

    pub(super) fn toggle_suppressed(&self) -> bool {
        self.imp().suppress_toggle.get()
    }

    pub(super) fn suppress_toggle(&self, suppressed: bool) {
        self.imp().suppress_toggle.set(suppressed);
    }
}

#[cfg(test)]
mod tests {
    use gtk4 as gtk;
    use gtk4::prelude::*;

    use super::GridCell;

    #[gtk4::test]
    fn from_focus_finds_the_cell_below_a_focused_cell_widget_or_above_its_editor() {
        let cell_widget = gtk::Box::new(gtk::Orientation::Horizontal, 0);
        let cell = GridCell::new();
        let editor = gtk::Text::new();
        editor.set_parent(&cell);
        cell_widget.append(&cell);

        let below = GridCell::from_focus(cell_widget.upcast_ref());
        let above = GridCell::from_focus(editor.upcast_ref());

        assert_eq!(below.as_ref(), Some(&cell));
        assert_eq!(above.as_ref(), Some(&cell));
        assert!(GridCell::from_focus(gtk::Label::new(None).upcast_ref()).is_none());
        editor.unparent();
    }

    #[gtk4::test]
    fn an_unattached_cell_has_no_row() {
        let cell = GridCell::new();

        assert!(cell.row().is_none());
        assert!(cell.position().is_none());
        assert!(!cell.is_editing());
    }
}
