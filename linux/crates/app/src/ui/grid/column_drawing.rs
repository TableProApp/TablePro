use std::rc::Rc;

use gtk4 as gtk;
use gtk4::prelude::*;

use tablepro_core::column::{BoolStorage, ColumnKind, ColumnType};
use tablepro_core::{ColumnInfo, Value};

use super::cell_tooltip::cell_tooltip;
use super::column_figures::ColumnFigures;
use super::display_text::{DisplayText, display_text};
use super::grid_attributes::{GridAttributes, TextMark};
use super::toggle_cell::{ToggleCell, toggle_state};
use super::{CellLock, GridCell, GridRowId, RowObject, TabGridContext, cell_editability};
use crate::services::change_tracker::CellState;

const PENDING_CSS_CLASSES: &[&str] = &[
    "tp-cell-modified",
    "tp-row-pending-delete",
    "tp-row-pending-insert",
    "tp-row-leftmost-error-flash",
];

/// What a column's cells read to draw a row. The column makes one and
/// every cell it builds shares it.
#[derive(Debug)]
pub struct ColumnDrawing {
    /// `None` for a column the grid knows only from the result set.
    pub catalog: Option<ColumnInfo>,
    /// The type the result set gives the column, which a value is
    /// written out in.
    pub column_type: ColumnType,
    pub tab_ctx: TabGridContext,
    /// The server fills these in, so a new row shows a placeholder
    /// rather than an empty cell the user should type in.
    pub auto_filled: bool,
    pub attributes: Rc<GridAttributes>,
    pub figures: ColumnFigures,
}

impl ColumnDrawing {
    pub fn lock(&self, row: &GridRowId) -> Option<CellLock> {
        match self.catalog.as_ref() {
            Some(column) => cell_editability(column, row, &self.tab_ctx.identity, !self.tab_ctx.editable).err(),
            None => Some(CellLock::ResultRow),
        }
    }

    pub fn draw(&self, cell: &GridCell, row: &RowObject) -> DrawnCell {
        let column = cell.column();
        let (pending_classes, state) = self.tab_ctx.pending_marks(row, column);
        self.tab_ctx.with_effective_value(row, column, |value, default| {
            let drawn = DrawnCell {
                state,
                null: !default && value.is_null(),
            };
            // An edit opened on a value the row no longer has would, once
            // it ended, send that value back. An edit on the same value
            // keeps what was typed.
            if cell.edit_left_behind(value, default) {
                cell.cancel_edit();
            }
            let Some(content) = cell.content() else {
                return drawn;
            };
            apply_pending_classes(content, &pending_classes);
            let pending_delete = pending_classes.contains(&"tp-row-pending-delete");
            if let Some(check) = content.downcast_ref::<gtk::CheckButton>() {
                let storage = match self.catalog.as_ref().map(|column| &column.column_type.kind) {
                    Some(ColumnKind::Bool(storage)) => *storage,
                    _ => BoolStorage::Native,
                };
                ToggleCell::draw(cell, check, &toggle_state(value, default, &self.column_type, storage));
                check.set_sensitive(cell.lock().is_none());
                // A check box has no strikethrough, so a pending delete dims it.
                check.set_opacity(if pending_delete { 0.5 } else { 1.0 });
            } else if let Some(display) = content.downcast_ref::<gtk::Inscription>() {
                let mark = match (pending_delete, state) {
                    (true, _) => TextMark::PendingDelete,
                    (false, CellState::Modified) => TextMark::Modified,
                    (false, _) => TextMark::Plain,
                };
                let shown = CellText {
                    value,
                    default,
                    editable: cell.lock().is_none(),
                    mark,
                };
                cell.with_scratch(|scratch| self.draw_text(display, &shown, scratch));
            }
            drawn
        })
    }

    /// An editable cell shows NULL as `<NULL>`, so it reads differently
    /// from an empty string, and a locked one dims a plain NULL.
    fn draw_text(&self, display: &gtk::Inscription, cell: &CellText<'_>, scratch: &mut String) {
        let attributes = &self.attributes;
        let shown = match (cell.default, cell.value) {
            (true, _) if self.auto_filled => DisplayText::placeholder(&attributes.auto_filled),
            (true, _) => DisplayText::placeholder("DEFAULT"),
            (false, Value::Null) if cell.editable => DisplayText::placeholder(&attributes.editable_null),
            (false, value) => display_text(value, &self.column_type, scratch),
        };
        self.figures.apply(display);
        display.set_text(Some(shown.text));
        let widget = display.upcast_ref::<gtk::Widget>();
        widget.set_tooltip_text(cell_tooltip(shown.text, shown.truncated_bytes, shown.placeholder).as_deref());
        set_class(
            widget,
            "dimmed",
            !cell.default && cell.value.is_null() && !cell.editable,
        );
        display.set_attributes(attributes.for_text(cell.mark, shown.placeholder));
    }
}

/// What a draw tells a screen reader about the cell.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DrawnCell {
    pub state: CellState,
    /// The cell holds NULL, not a draft's cell left to the server.
    pub null: bool,
}

/// One cell's value and the state it is drawn in.
struct CellText<'a> {
    value: &'a Value,
    /// A draft's cell left to the server.
    default: bool,
    editable: bool,
    mark: TextMark,
}

fn set_class(widget: &gtk::Widget, class: &str, on: bool) {
    if on {
        widget.add_css_class(class);
    } else {
        widget.remove_css_class(class);
    }
}

fn apply_pending_classes(widget: &gtk::Widget, pending_classes: &[&'static str]) {
    for class in PENDING_CSS_CLASSES {
        set_class(widget, class, pending_classes.contains(class));
    }
}
