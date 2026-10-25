use std::cell::{Cell, OnceCell, RefCell};
use std::rc::Rc;

use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use gtk4::{self as gtk, glib, pango};
use tablepro_core::Value;

use super::columns::ColumnPaint;
use super::tracked_values::cell_description;
use super::{DataGrid, GridRow};
use crate::services::change_tracker::CellState;
use crate::services::grid::display_text::{DisplayText, auto_filled_sentinel, display_text, editable_null_sentinel};
use crate::services::grid::{CellLock, GridColumn};

/// Enough for any number, date or short text.
const SCRATCH_KEPT_BYTES: usize = 256;

/// How a pending change marks a cell's text, so it reads without colour.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum TextMark {
    Plain,
    Modified,
    /// Wins over `Modified`: an edited cell of a row marked for deletion
    /// goes with the row.
    Deleted,
}

/// The marks a grid's cells draw their text with, built once per grid so
/// a bind sets a list rather than building one. Pango attributes, since
/// CSS `text-decoration` does not reach an Inscription's text reliably.
#[derive(Debug)]
pub struct TextAttributes {
    modified: pango::AttrList,
    modified_placeholder: pango::AttrList,
    deleted: pango::AttrList,
    deleted_placeholder: pango::AttrList,
    placeholder: pango::AttrList,
    /// The stand-in texts, translated once rather than on every bind.
    editable_null: String,
    auto_filled: String,
}

impl TextAttributes {
    pub fn new() -> Self {
        let list = |mark: TextMark, italic: bool| {
            let attrs = pango::AttrList::new();
            match mark {
                TextMark::Plain => {}
                TextMark::Modified => attrs.insert(pango::AttrInt::new_weight(pango::Weight::Bold)),
                TextMark::Deleted => attrs.insert(pango::AttrInt::new_strikethrough(true)),
            }
            if italic {
                attrs.insert(pango::AttrInt::new_style(pango::Style::Italic));
            }
            attrs
        };
        Self {
            modified: list(TextMark::Modified, false),
            modified_placeholder: list(TextMark::Modified, true),
            deleted: list(TextMark::Deleted, false),
            deleted_placeholder: list(TextMark::Deleted, true),
            placeholder: list(TextMark::Plain, true),
            editable_null: editable_null_sentinel(),
            auto_filled: auto_filled_sentinel(),
        }
    }

    fn for_text(&self, mark: TextMark, placeholder: bool) -> Option<&pango::AttrList> {
        match (mark, placeholder) {
            (TextMark::Plain, false) => None,
            (TextMark::Plain, true) => Some(&self.placeholder),
            (TextMark::Modified, false) => Some(&self.modified),
            (TextMark::Modified, true) => Some(&self.modified_placeholder),
            (TextMark::Deleted, false) => Some(&self.deleted),
            (TextMark::Deleted, true) => Some(&self.deleted_placeholder),
        }
    }
}

mod imp {
    use super::*;

    #[derive(Default)]
    pub struct GridCell {
        pub list_item: glib::WeakRef<gtk::ColumnViewCell>,
        pub paint: OnceCell<Rc<ColumnPaint>>,
        pub display: OnceCell<gtk::Inscription>,
        /// The inline editor while an edit is open in the cell.
        pub editor: RefCell<Option<gtk::Widget>>,
        /// An editor that closed while it held the focus, hidden until the
        /// cell's next edit.
        pub closed: RefCell<Option<gtk::Widget>>,
        pub binding: RefCell<Option<(GridRow, glib::SignalHandlerId)>>,
        pub lock: Cell<Option<CellLock>>,
        /// Where a value that is not text is written to draw it, kept from
        /// one bind to the next.
        pub scratch: RefCell<String>,
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
            self.obj().disconnect_row();
            for editor in [self.editor.take(), self.closed.take()].into_iter().flatten() {
                editor.unparent();
            }
            if let Some(display) = self.display.get() {
                display.unparent();
            }
        }
    }

    impl WidgetImpl for GridCell {
        fn unroot(&self) {
            let cell = self.obj();
            if let Some(grid) = cell.grid() {
                grid.edit().cell_detaching(&cell);
            }
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

impl GridCell {
    pub fn new(paint: Rc<ColumnPaint>) -> Self {
        let cell: Self = glib::Object::new();
        let display = gtk::Inscription::new(None);
        display.set_hexpand(true);
        // An ellipsized Inscription draws from its top edge, so it is kept
        // one line tall and centred rather than stretched to the row.
        display.set_valign(gtk::Align::Center);
        display.set_text_overflow(gtk::InscriptionOverflow::EllipsizeEnd);
        display.set_min_chars(1);
        display.set_parent(&cell);
        let _ = cell.imp().display.set(display);
        let _ = cell.imp().paint.set(paint);
        cell
    }

    pub fn attach(&self, list_item: &gtk::ColumnViewCell) {
        self.imp().list_item.set(Some(list_item));
    }

    pub fn display(&self) -> Option<&gtk::Inscription> {
        self.imp().display.get()
    }

    pub(crate) fn paint(&self) -> Option<&Rc<ColumnPaint>> {
        self.imp().paint.get()
    }

    pub fn grid_column(&self) -> Option<&GridColumn> {
        self.paint().map(|paint| &paint.column)
    }

    /// The column's place in the result, which is what its cells hold.
    pub fn column(&self) -> usize {
        self.paint().map_or(0, |paint| paint.column.index)
    }

    pub fn row(&self) -> Option<GridRow> {
        self.imp().list_item.upgrade()?.item().and_downcast()
    }

    pub fn position(&self) -> Option<u32> {
        let position = self.imp().list_item.upgrade()?.position();
        (position != gtk::INVALID_LIST_POSITION).then_some(position)
    }

    pub fn lock(&self) -> Option<CellLock> {
        self.imp().lock.get()
    }

    pub(crate) fn grid(&self) -> Option<DataGrid> {
        self.ancestor(DataGrid::static_type()).and_downcast()
    }

    pub fn is_editing(&self) -> bool {
        self.imp().editor.borrow().is_some()
    }

    /// The cell that holds the keyboard focus. A focused column view cell
    /// widget is this cell's parent, so its first child is tried after its
    /// ancestors.
    pub fn from_focus(focus: &gtk::Widget) -> Option<GridCell> {
        if let Some(cell) = focus.ancestor(GridCell::static_type()) {
            return cell.downcast().ok();
        }
        focus.first_child()?.downcast().ok()
    }

    pub(super) fn bind(&self, row: &GridRow) {
        self.disconnect_row();
        let handler = row.connect_revision_notify(glib::clone!(
            #[weak(rename_to = cell)]
            self,
            move |_| cell.render()
        ));
        self.imp().binding.replace(Some((row.clone(), handler)));
        self.render();
    }

    pub(super) fn unbind(&self) {
        if let Some(grid) = self.grid() {
            grid.edit().cell_unbinding(self);
        }
        self.disconnect_row();
        self.reset_property(gtk::AccessibleProperty::Description);
    }

    fn disconnect_row(&self) {
        if let Some((row, handler)) = self.imp().binding.take() {
            row.disconnect(handler);
        }
    }

    fn bound_row(&self) -> Option<GridRow> {
        self.imp().binding.borrow().as_ref().map(|(row, _)| row.clone())
    }

    pub(crate) fn render(&self) {
        #[cfg(test)]
        self.imp().renders.set(self.imp().renders.get() + 1);
        let (Some(row), Some(paint), Some(display)) = (self.bound_row(), self.paint().cloned(), self.display()) else {
            return;
        };
        let column = paint.column.index;
        let mark = paint.tracked.mark(&row, column);
        let lock = paint.tracked.lock_marked(&paint.column, &row, mark.row_deleted);
        self.imp().lock.set(lock);
        let text_mark = match (mark.row_deleted, mark.state) {
            (true, _) => TextMark::Deleted,
            (false, CellState::Modified) => TextMark::Modified,
            (false, _) => TextMark::Plain,
        };
        let null = paint.tracked.with_value(&row, column, |value, default| {
            let mut scratch = self.imp().scratch.borrow_mut();
            let shown = shown_text(&paint, value, default, lock.is_none(), &mut scratch);
            display.set_text(Some(shown.text));
            display.set_attributes(paint.attributes.for_text(text_mark, shown.placeholder));
            set_class(
                display,
                "dimmed",
                (value.is_null() && lock.is_some()) || mark.row_deleted,
            );
            !default && value.is_null()
        });
        if self.imp().scratch.borrow().capacity() > SCRATCH_KEPT_BYTES {
            self.imp().scratch.replace(String::new());
        }
        let numbers = paint.numbers.get();
        display.set_xalign(if numbers { 1.0 } else { 0.0 });
        set_class(display, "numeric", numbers);
        // Adwaita's own warning colour, beside the bold, so a changed value
        // reads apart from the rest without a tint of the app's own.
        set_class(display, "warning", text_mark == TextMark::Modified);
        // On the cell, since GtkColumnViewCell passes on no accessible
        // property of its own.
        match cell_description(mark.state, null) {
            Some(description) => self.update_property(&[gtk::accessible::Property::Description(&description)]),
            None => self.reset_property(gtk::AccessibleProperty::Description),
        }
    }

    /// Lay `editor` over the cell's text until `close_editor`.
    pub(crate) fn open_editor(&self, editor: &impl IsA<gtk::Widget>) {
        self.close_editor();
        if let Some(closed) = self.imp().closed.take() {
            closed.unparent();
        }
        if let Some(display) = self.display() {
            display.set_visible(false);
        }
        editor.as_ref().set_parent(self);
        self.imp().editor.replace(Some(editor.as_ref().clone()));
    }

    /// The editor goes and the text shows again. GTK 4.22 loops forever
    /// ending a focus change from a widget that lost its parent, so an
    /// editor that still holds the focus is only hidden until the next
    /// edit.
    pub(crate) fn close_editor(&self) {
        if let Some(editor) = self.imp().editor.take() {
            match holds_window_focus(&editor) {
                true => {
                    editor.set_visible(false);
                    if let Some(previous) = self.imp().closed.replace(Some(editor)) {
                        previous.unparent();
                    }
                }
                false => editor.unparent(),
            }
        }
        if let Some(display) = self.display() {
            display.set_visible(true);
        }
    }

    #[cfg(test)]
    pub(crate) fn render_count(&self) -> u32 {
        self.imp().renders.get()
    }
}

/// An editable cell shows NULL as `<NULL>`, so it reads apart from an
/// empty string; a locked one dims a plain NULL.
fn shown_text<'a>(
    paint: &'a ColumnPaint,
    value: &'a Value,
    default: bool,
    editable: bool,
    scratch: &'a mut String,
) -> DisplayText<'a> {
    match (default, value) {
        (true, _) if paint.column.auto_filled() => DisplayText::placeholder(&paint.attributes.auto_filled),
        (true, _) => DisplayText::placeholder("DEFAULT"),
        (false, Value::Null) if editable => DisplayText::placeholder(&paint.attributes.editable_null),
        (false, value) => display_text(value, &paint.column.column_type, scratch),
    }
}

fn set_class(widget: &impl IsA<gtk::Widget>, class: &str, on: bool) {
    match on {
        true => widget.as_ref().add_css_class(class),
        false => widget.as_ref().remove_css_class(class),
    }
}

pub(crate) fn holds_window_focus(widget: &gtk::Widget) -> bool {
    widget
        .root()
        .and_downcast::<gtk::Window>()
        .and_then(|window| gtk::prelude::GtkWindowExt::focus(&window))
        .is_some_and(|focus| focus == *widget || focus.is_ancestor(widget))
}
