use std::cell::{Cell, OnceCell, RefCell};
use std::rc::Rc;

use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use gtk4::{self as gtk, glib};
use tablepro_core::edit::CellInput;

use super::cell_accessibility::cell_description;
use super::cell_binding::CellBinding;
use super::cell_focus::return_focus;
use super::column_drawing::ColumnDrawing;
use super::grid_columns::GridColumns;
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
        pub(super) columns: OnceCell<Rc<GridColumns>>,
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

    impl WidgetImpl for GridCell {
        fn unroot(&self) {
            self.obj().leave_detached_row();
            self.parent_unroot();
        }
    }
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

    pub(super) fn set_columns(&self, columns: Rc<GridColumns>) {
        let _ = self.imp().columns.set(columns);
    }

    pub(super) fn columns(&self) -> Option<Rc<GridColumns>> {
        self.imp().columns.get().cloned()
    }

    pub(super) fn column_view(&self) -> Option<gtk::ColumnView> {
        self.ancestor(gtk::ColumnView::static_type()).and_downcast()
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
        self.reset_property(gtk::AccessibleProperty::Description);
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
        let state = drawing.draw(self, &row);
        // On the cell, since GtkColumnViewCell passes on no accessible
        // property of its own.
        match cell_description(state) {
            Some(description) => self.update_property(&[gtk::accessible::Property::Description(&description)]),
            None => self.reset_property(gtk::AccessibleProperty::Description),
        }
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
            let cell = cell.upgrade();
            // GTK moves a focus left in a hidden popover to the popover's
            // parent after the next frame, and by then it has none, so the
            // focus would leave the grid. An unbound cell's row is gone.
            if let Some(cell) = &cell
                && cell.is_bound()
                && holds_focus(popover)
            {
                return_focus(cell);
            }
            popover.unparent();
            if let Some(cell) = cell
                && cell.release_popover(popover)
            {
                cell.take_edit();
            }
        });
        popover.popup();
    }

    /// GTK detaches a removed row before it unbinds it, and moves a focus
    /// left inside only after the next frame; a window focus-in between
    /// the two crashes GTK 4.22 on the detached row. So the focus goes
    /// before the edit ends, and the grid takes it back after the frame.
    fn leave_detached_row(&self) {
        let window = self.root().and_downcast::<gtk::Window>();
        let held = window
            .as_ref()
            .and_then(gtk::prelude::GtkWindowExt::focus)
            .is_some_and(|focus| focus.is_ancestor(self) || focus == *self.upcast_ref::<gtk::Widget>());
        if let Some(window) = window.as_ref().filter(|_| held) {
            gtk::prelude::GtkWindowExt::set_focus(window, None::<&gtk::Widget>);
        }
        self.cancel_edit();
        let (Some(window), true) = (window, held) else {
            return;
        };
        let (Some(view), Some(clock)) = (self.column_view(), window.frame_clock()) else {
            return;
        };
        let view = view.downgrade();
        let handler: Rc<RefCell<Option<glib::SignalHandlerId>>> = Rc::default();
        let slot = handler.clone();
        let id = clock.connect_after_paint(move |clock| {
            if let Some(id) = slot.borrow_mut().take() {
                clock.disconnect(id);
            }
            if let Some(view) = view.upgrade()
                && view.root().is_some()
            {
                view.grab_focus();
            }
        });
        handler.replace(Some(id));
    }

    fn is_bound(&self) -> bool {
        self.imp().binding.borrow().is_some()
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

fn holds_focus(widget: &impl IsA<gtk::Widget>) -> bool {
    widget
        .root()
        .and_downcast::<gtk::Window>()
        .and_then(|window| gtk::prelude::GtkWindowExt::focus(&window))
        .is_some_and(|focus| focus.is_ancestor(widget))
}

#[cfg(test)]
mod tests {
    use gtk4 as gtk;
    use gtk4::prelude::*;
    use tablepro_core::Value;

    use super::GridCell;
    use crate::services::tracker_edit::TrackerEdit;
    use crate::ui::grid::test_grid::{key, two_text_rows};

    fn described(widget: &impl IsA<gtk::Accessible>) -> bool {
        gtk::test_accessible_has_property(widget, gtk::AccessibleProperty::Description)
    }

    #[gtk4::test]
    fn pending_edit_sets_description_on_grid_cell() {
        let grid = two_text_rows();
        let cell = grid.cell_of(1, 1);
        assert!(!described(&cell));

        grid.redraw(&grid.tracker.apply(TrackerEdit::Cell {
            row_key: key(1),
            col: 1,
            original: Value::Text("A".into()),
            value: Value::Text("edited".into()),
        }));
        assert!(described(&cell), "an edited cell said nothing");
        assert!(!described(&grid.cell_of(2, 1)));

        grid.redraw(&grid.tracker.undo().expect("an edit to undo"));
        assert!(!described(&cell), "an undone edit still read as modified");
    }

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
