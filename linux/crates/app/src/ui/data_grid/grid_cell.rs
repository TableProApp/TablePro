use std::cell::{Cell, OnceCell, RefCell};
use std::rc::Rc;

use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use gtk4::{self as gtk, glib, pango};
use tablepro_core::Value;

use super::columns::ColumnPaint;
use super::special_marks::show_value;
use super::tracked_values::cell_description;
use super::{DataGrid, GridRow, ServerValue};
use crate::services::change_tracker::CellState;
use crate::services::grid::display_text::{DisplayText, auto_filled_sentinel, display_text_formatted, null_text};
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
        fn measure(&self, orientation: gtk::Orientation, for_size: i32) -> (i32, i32, i32, i32) {
            let mut size = (0, 0, -1, -1);
            let mut child = self.obj().first_child();
            while let Some(widget) = child {
                if widget.should_layout() {
                    let measured = widget.measure(orientation, for_size);
                    size = (
                        size.0.max(measured.0),
                        size.1.max(measured.1),
                        size.2.max(measured.2),
                        size.3.max(measured.3),
                    );
                }
                child = widget.next_sibling();
            }
            size
        }

        fn size_allocate(&self, width: i32, height: i32, baseline: i32) {
            let cell = self.obj();
            let mut child = cell.first_child();
            while let Some(widget) = child {
                if widget.should_layout() {
                    let (offset, available) = if self.editor.borrow().as_ref() == Some(&widget) {
                        cell.editor_space(width)
                    } else {
                        (0, width)
                    };
                    let transform =
                        gtk::gsk::Transform::new().translate(&gtk::graphene::Point::new(offset as f32, 0.0));
                    widget.allocate(available, height, baseline, Some(transform));
                }
                child = widget.next_sibling();
            }
        }

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
        cell.set_overflow(gtk::Overflow::Hidden);
        let display = gtk::Inscription::new(None);
        display.set_hexpand(true);
        // An ellipsized Inscription draws from its top edge, so it is kept
        // one line tall and centred rather than stretched to the row.
        display.set_valign(gtk::Align::Center);
        display.set_text_overflow(gtk::InscriptionOverflow::EllipsizeEnd);
        display.set_min_chars(1);
        // A column of codes or times lines up character for character.
        display.add_css_class("monospace");
        display.set_parent(&cell);
        let _ = cell.imp().display.set(display);
        let _ = cell.imp().paint.set(paint);
        cell
    }

    fn editor_space(&self, width: i32) -> (i32, i32) {
        let Some(grid) = self.grid() else {
            return (0, width);
        };
        let Some(edge) = super::pinned_numbers::covered_edge(&grid) else {
            return (0, width);
        };
        let Some(origin) = self.compute_point(&grid.column_view(), &gtk::graphene::Point::new(0.0, 0.0)) else {
            return (0, width);
        };
        // GTK picks descendants before their parent's contains method. Allocate
        // the editor in the uncovered part so its native gestures cannot reach the gutter.
        match grid.column_view().direction() {
            gtk::TextDirection::Rtl => (0, ((edge - origin.x()).floor() as i32).clamp(0, width)),
            _ => {
                let offset = ((edge - origin.x()).ceil() as i32).clamp(0, width);
                (offset, width - offset)
            }
        }
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
        let marks = paint.preferences.snapshot().show_invisible_characters;
        let null = paint.tracked.with_value(&row, column, |value, computed| {
            let mut scratch = self.imp().scratch.borrow_mut();
            let shown = shown_text(&paint, value, computed, lock.is_none(), &mut scratch);
            show_value(
                display,
                shown.text,
                paint.attributes.for_text(text_mark, shown.placeholder),
                marks && !shown.placeholder,
            );
            set_class(
                display,
                "dimmed",
                (value.is_null() && lock.is_some()) || mark.row_deleted,
            );
            computed.is_none() && value.is_null()
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

    pub(crate) fn open_editor(&self, editor: &impl IsA<gtk::Widget>) {
        self.close_editor();
        if let Some(closed) = self.imp().closed.take() {
            closed.unparent();
        }
        if let Some(display) = self.display() {
            display.set_visible(false);
        }
        // A viewport clips a fully covered editor without allocating GtkText
        // below its minimum size or changing its text and cursor state.
        let viewport = gtk::Viewport::new(None::<&gtk::Adjustment>, None::<&gtk::Adjustment>);
        viewport.set_child(Some(editor));
        viewport.set_scroll_to_focus(true);
        viewport.set_parent(self);
        self.imp().editor.replace(Some(viewport.upcast()));
    }

    // GTK 4.22 loops when focus leaves a widget that lost its parent.
    // Keep an editor that holds focus parented until the next edit.
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
/// empty string; a locked one dims a plain NULL. A value the server
/// computes shows as the SQL that computes it, in placeholder style, so
/// `NOW()` reads apart from the text `NOW()`.
fn shown_text<'a>(
    paint: &'a ColumnPaint,
    value: &'a Value,
    computed: Option<ServerValue>,
    editable: bool,
    scratch: &'a mut String,
) -> DisplayText<'a> {
    match (computed, value) {
        (Some(ServerValue::Default), _) if paint.column.auto_filled() => {
            DisplayText::placeholder(&paint.attributes.auto_filled)
        }
        (Some(ServerValue::Default), _) => DisplayText::placeholder("DEFAULT"),
        (Some(ServerValue::Expression(expression)), _) => DisplayText::placeholder(expression.sql),
        (None, Value::Null) => {
            *scratch = null_text(&paint.preferences.snapshot().null_display, editable);
            DisplayText::placeholder(scratch)
        }
        (None, value) => display_text_formatted(
            value,
            &paint.column.column_type,
            paint.preferences.snapshot().date_format,
            scratch,
        ),
    }
}

pub(super) fn set_class(widget: &impl IsA<gtk::Widget>, class: &str, on: bool) {
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
