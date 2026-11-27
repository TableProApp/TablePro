use std::cell::{Cell, OnceCell, RefCell};
use std::rc::Rc;

use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use gtk4::{self as gtk, glib, pango};
use tablepro_core::Value;

use super::columns::ColumnPaint;
use super::special_marks::{drawn, show_value};
use super::tracked_values::cell_description;
use super::{DataGrid, GridRow, ServerValue};
use crate::services::change_tracker::CellState;
use crate::services::grid::display_text::{
    DisplayText, WRAP_MAX_LINES, auto_filled_sentinel, display_text_formatted, keep_line_breaks, line_cut, null_text,
};
use crate::services::grid::{CellLock, GridColumn, HighlightColor};

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

/// What the text a wrapping cell is bound to needs to be laid out.
#[derive(Debug, Clone, Copy)]
pub struct Wrapped {
    /// It holds a line break or a tab, so its length says nothing of its width.
    unbounded: bool,
    bytes: usize,
    /// The value goes on past the text.
    truncated: bool,
}

/// The height a wrapping cell's text takes at a width.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Fit {
    width: i32,
    height: i32,
    /// Where the first line past the last one shown starts.
    cut: Option<usize>,
}

/// The text a cell is bound to, kept while the cell draws it cut at a line.
#[derive(Debug)]
pub struct Whole {
    text: String,
    attributes: Option<pango::AttrList>,
    cut: usize,
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
        /// The grid wrapped its text when the cell last drew.
        pub wraps: Cell<bool>,
        /// Set while the grid wraps and the bound text can take more than a line.
        pub wrapped: Cell<Option<Wrapped>>,
        pub whole: RefCell<Option<Whole>>,
        /// Worked out in `measure`, so the allocation that follows lays nothing out again.
        pub fit: Cell<Option<Fit>>,
        #[cfg(test)]
        pub renders: Cell<u32>,
        #[cfg(test)]
        pub resizes: Cell<u32>,
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
        // Without it GTK never tells the cell how wide it is.
        fn request_mode(&self) -> gtk::SizeRequestMode {
            match self.wraps.get() {
                true => gtk::SizeRequestMode::HeightForWidth,
                false => self.parent_request_mode(),
            }
        }

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
            // From the bound text, since an open editor hides the display. Minimum
            // and natural both, since the list takes a row's minimum.
            if orientation == gtk::Orientation::Vertical
                && let Some(fit) = self.obj().fit(for_size)
            {
                size.0 = size.0.max(fit.height);
                size.1 = size.1.max(fit.height);
            }
            size
        }

        fn size_allocate(&self, width: i32, height: i32, baseline: i32) {
            let cell = self.obj();
            cell.cut_to_fit(width);
            let wraps = self.wraps.get();
            let mut child = cell.first_child();
            while let Some(widget) = child {
                if widget.should_layout() {
                    let editing = self.editor.borrow().as_ref() == Some(&widget);
                    let (offset, available) = if editing { cell.editor_space(width) } else { (0, width) };
                    // In a tall row the editor sits on the first line, where the text it edits starts.
                    let tall = match editing && wraps {
                        true => widget.measure(gtk::Orientation::Vertical, available).1.min(height),
                        false => height,
                    };
                    let transform =
                        gtk::gsk::Transform::new().translate(&gtk::graphene::Point::new(offset as f32, 0.0));
                    widget.allocate(available, tall, baseline, Some(transform));
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
        let wraps = paint.wrap.on();
        let reflow = self.rewrap(wraps);
        let null = paint.tracked.with_value(&row, column, |value, computed| {
            let mut scratch = self.imp().scratch.borrow_mut();
            let shown = shown_text(&paint, value, computed, lock.is_none(), &mut scratch);
            let attributes = paint.attributes.for_text(text_mark, shown.placeholder);
            // A number or a placeholder is never worth a taller row.
            match wraps && !shown.placeholder && !paint.numbers.get() {
                true => self.show_wrapped(display, &shown, attributes, marks),
                false => show_value(display, shown.text, attributes, marks && !shown.placeholder),
            }
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
        if wraps {
            self.align_in_tall_row(display);
        }
        // An Inscription asks for no new size when its text changes.
        if reflow || (wraps && self.may_wrap()) {
            #[cfg(test)]
            self.imp().resizes.set(self.imp().resizes.get() + 1);
            self.queue_resize();
        }
        // GTK binds a new row before attaching it to the grid widget tree.
        let colour = paint.grid.upgrade().and_then(|grid| grid.highlight_of(&row, column));
        for each in HighlightColor::ALL {
            set_class(self, each.css_class(), colour == Some(each));
        }
        let numbers = paint.numbers.get();
        display.set_xalign(if numbers { 1.0 } else { 0.0 });
        set_class(display, "numeric", numbers);
        // Tinted backgrounds need full-opacity text; italic, bold and strikeout keep their meaning.
        if colour.is_some() {
            display.remove_css_class("dimmed");
        }
        // Warning text loses contrast over some highlights; bold still marks the edit.
        set_class(display, "warning", text_mark == TextMark::Modified && colour.is_none());
        // On the cell, since GtkColumnViewCell passes on no accessible
        // property of its own.
        let description = match (cell_description(mark.state, null), colour) {
            (Some(state), Some(colour)) => Some(crate::i18n::gettext_f(
                "{state}. {highlight}",
                &[("state", &state), ("highlight", &highlight_description(colour))],
            )),
            (None, Some(colour)) => Some(highlight_description(colour)),
            (state, None) => state,
        };
        match description {
            Some(description) => self.update_property(&[gtk::accessible::Property::Description(&description)]),
            None => self.reset_property(gtk::AccessibleProperty::Description),
        }
    }

    /// Lay the cell out for whether its grid wraps. `true` when its row may
    /// change height: the grid changed its mind, or the text drawn until
    /// now could take more than a line.
    fn rewrap(&self, wraps: bool) -> bool {
        let imp = self.imp();
        let changed = imp.wraps.replace(wraps) != wraps;
        if !changed && !wraps {
            return false;
        }
        let could_wrap = self.may_wrap();
        imp.wrapped.set(None);
        imp.whole.replace(None);
        imp.fit.set(None);
        if !wraps && let Some(display) = self.display() {
            display.set_valign(gtk::Align::Center);
            display.set_yalign(0.5);
        }
        changed || could_wrap
    }

    /// Where a wrapping grid's cell puts its text: on the first line of
    /// its row, level with the row's tallest cell.
    fn align_in_tall_row(&self, display: &gtk::Inscription) {
        // Only text that wraps takes the row's height. An Inscription wraps
        // into whatever height it gets, so a number or a placeholder stays one line tall.
        display.set_valign(match self.imp().wrapped.get() {
            Some(_) => gtk::Align::Fill,
            None => gtk::Align::Start,
        });
        display.set_yalign(0.0);
    }

    /// Draw `shown` with its line breaks kept, and its other marks as on one line.
    fn show_wrapped(
        &self,
        display: &gtk::Inscription,
        shown: &DisplayText<'_>,
        attributes: Option<&pango::AttrList>,
        marks: bool,
    ) {
        let kept = keep_line_breaks(shown.text);
        let drawn = drawn(&kept, attributes, marks, false);
        display.set_text(Some(&drawn.text));
        display.set_attributes(drawn.attributes.as_ref());
        self.imp().wrapped.set(Some(Wrapped {
            unbounded: drawn.text.contains(['\n', '\t']),
            bytes: drawn.text.len(),
            truncated: shown.truncated_bytes > 0,
        }));
    }

    /// Whether the bound text can take more than a line at the cell's width.
    fn may_wrap(&self) -> bool {
        self.imp().wrapped.get().is_some_and(|wrapped| {
            wrapped.unbounded
                || self
                    .paint()
                    .is_some_and(|paint| paint.wrap.may_overflow(wrapped.bytes, self.width()))
        })
    }

    /// The bound text as the cell draws it with nothing cut, and its marks.
    pub(super) fn whole_text(&self) -> Option<(String, Option<pango::AttrList>)> {
        if let Some(whole) = self.imp().whole.borrow().as_ref() {
            return Some((whole.text.clone(), whole.attributes.clone()));
        }
        let display = self.display()?;
        Some((display.text()?.into(), display.attributes()))
    }

    /// The height the bound text takes wrapped at `width`, and where it is
    /// cut. `None` for a cell that draws one line.
    fn fit(&self, width: i32) -> Option<Fit> {
        let wrapped = self.imp().wrapped.get()?;
        let fit = self.laid_out(wrapped, width);
        self.imp().fit.set(fit);
        fit
    }

    fn laid_out(&self, wrapped: Wrapped, width: i32) -> Option<Fit> {
        // A column has no width between Size to Fit and the width it then gets.
        if width <= 0 {
            return None;
        }
        if !wrapped.unbounded && !self.paint()?.wrap.may_overflow(wrapped.bytes, width) {
            return None;
        }
        let (text, attributes) = self.whole_text()?;
        // The text is cut to 1,000 characters already, so Pango never shapes a whole value.
        let layout = self.display()?.create_pango_layout(Some(&text));
        layout.set_attributes(attributes.as_ref());
        layout.set_width(width.saturating_mul(pango::SCALE));
        layout.set_wrap(pango::WrapMode::WordChar);
        Some(fit_of(&layout, width))
    }

    /// Draw the bound text cut at the last line `width` shows, or whole again.
    fn cut_to_fit(&self, width: i32) {
        let imp = self.imp();
        if imp.wrapped.get().is_none() {
            return;
        }
        let fit = match imp.fit.get() {
            Some(fit) if fit.width == width => Some(fit),
            _ => self.fit(width),
        };
        let cut = fit.and_then(|fit| fit.cut);
        let shown = imp.whole.borrow().as_ref().map(|whole| whole.cut);
        if cut == shown {
            return;
        }
        let (Some((text, attributes)), Some(display)) = (self.whole_text(), self.display()) else {
            return;
        };
        match cut {
            Some(at) => {
                display.set_text(Some(&line_cut(&text, at)));
                display.set_attributes(attributes.as_ref().map(|marks| clipped(marks, at)).as_ref());
                imp.whole.replace(Some(Whole {
                    text,
                    attributes,
                    cut: at,
                }));
            }
            None => {
                display.set_text(Some(&text));
                display.set_attributes(attributes.as_ref());
                imp.whole.replace(None);
            }
        }
    }

    /// The cell breaks its text into lines, as a text cell of a grid that wraps does.
    pub(super) fn wraps(&self) -> bool {
        self.imp().wrapped.get().is_some()
    }

    /// The cell draws less than the text it holds says: the value past its
    /// first 1,000 characters, or the lines past the last it shows.
    pub(super) fn leaves_text_out(&self) -> bool {
        self.imp().whole.borrow().is_some() || self.imp().wrapped.get().is_some_and(|wrapped| wrapped.truncated)
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

    /// How often a draw asked for a new size.
    #[cfg(test)]
    pub(crate) fn resize_count(&self) -> u32 {
        self.imp().resizes.get()
    }
}

/// The first `WRAP_MAX_LINES` lines of `layout`. Their height comes from
/// the lines laid out, since the font's own line height is shorter and
/// would hide the last one.
fn fit_of(layout: &pango::Layout, width: i32) -> Fit {
    if layout.line_count() <= WRAP_MAX_LINES {
        return Fit {
            width,
            height: pango::units_to_double(layout.size().1).ceil() as i32,
            cut: None,
        };
    }
    let mut lines = layout.iter();
    for _ in 1..WRAP_MAX_LINES {
        if !lines.next_line() {
            break;
        }
    }
    let (_, last) = lines.line_extents();
    let cut = match lines.next_line() {
        true => lines
            .line_readonly()
            .and_then(|line| usize::try_from(line.start_index()).ok()),
        false => None,
    };
    Fit {
        width,
        height: pango::units_to_double(last.y() + last.height()).ceil() as i32,
        cut,
    }
}

/// `marks` without those on text from `end` on. One over the whole text, as bold, stays whole.
fn clipped(marks: &pango::AttrList, end: usize) -> pango::AttrList {
    let end = u32::try_from(end).unwrap_or(u32::MAX);
    let kept = pango::AttrList::new();
    for mut mark in marks.attributes() {
        if mark.start_index() >= end {
            continue;
        }
        if mark.end_index() != u32::MAX && mark.end_index() > end {
            mark.set_end_index(end);
        }
        kept.insert(mark);
    }
    kept
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

fn highlight_description(colour: HighlightColor) -> String {
    use crate::i18n::gettext;
    match colour {
        HighlightColor::Red => gettext("Highlighted red"),
        HighlightColor::Orange => gettext("Highlighted orange"),
        HighlightColor::Yellow => gettext("Highlighted yellow"),
        HighlightColor::Green => gettext("Highlighted green"),
        HighlightColor::Blue => gettext("Highlighted blue"),
        HighlightColor::Purple => gettext("Highlighted purple"),
        HighlightColor::Gray => gettext("Highlighted gray"),
    }
}
