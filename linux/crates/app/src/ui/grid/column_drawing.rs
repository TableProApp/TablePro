use gtk4 as gtk;
use gtk4::prelude::*;

use tablepro_core::column::{BoolStorage, ColumnKind};
use tablepro_core::edit::CellInput;
use tablepro_core::{ColumnInfo, Value};

use super::display_text::{auto_filled_sentinel, editable_null_sentinel, value_to_display_text};
use super::toggle_cell::{ToggleCell, toggle_state};
use super::{CellLock, GridCell, GridRowId, RowObject, TabGridContext, cell_editability};

const PENDING_CSS_CLASSES: &[&str] = &[
    "tp-cell-modified",
    "tp-row-pending-delete",
    "tp-row-pending-insert",
    "tp-row-leftmost-error-flash",
];

/// Shorter text fits a typical 200 px column, so its ellipsized display
/// needs no tooltip.
const TOOLTIP_MIN_CHARS: usize = 40;

/// What a column's cells read to draw a row. The column makes one and
/// every cell it builds shares it.
#[derive(Debug)]
pub struct ColumnDrawing {
    /// `None` for a column the grid knows only from the result set.
    pub catalog: Option<ColumnInfo>,
    pub tab_ctx: TabGridContext,
    /// The server fills these in, so a new row shows a placeholder
    /// rather than an empty cell the user should type in.
    pub auto_filled: bool,
}

impl ColumnDrawing {
    pub fn lock(&self, row: &GridRowId) -> Option<CellLock> {
        match self.catalog.as_ref() {
            Some(column) => cell_editability(column, row, &self.tab_ctx.identity, !self.tab_ctx.editable).err(),
            None => Some(CellLock::ResultRow),
        }
    }

    pub fn draw(&self, cell: &GridCell, row: &RowObject) {
        let (input, pending_classes) = self.tab_ctx.bind_state(row, cell.column());
        // An edit opened on a value the row no longer has would, once it
        // ended, send that value back. An edit on the same value keeps
        // what was typed.
        if cell.edit_original().is_some_and(|original| original != input) {
            cell.cancel_edit();
        }
        let Some(content) = cell.content() else {
            return;
        };
        apply_pending_classes(content, &pending_classes);
        let pending_delete = pending_classes.contains(&"tp-row-pending-delete");
        if let Some(check) = content.downcast_ref::<gtk::CheckButton>() {
            let storage = match self.catalog.as_ref().map(|column| &column.column_type.kind) {
                Some(ColumnKind::Bool(storage)) => *storage,
                _ => BoolStorage::Native,
            };
            ToggleCell::draw(cell, check, &toggle_state(&input, storage));
            check.set_sensitive(cell.lock().is_none());
            // A check box has no strikethrough, so a pending delete dims it.
            check.set_opacity(if pending_delete { 0.5 } else { 1.0 });
        } else if let Some(display) = content.downcast_ref::<gtk::Inscription>() {
            self.draw_text(display, &input, cell.lock().is_none(), pending_delete);
        }
    }

    /// An editable cell shows NULL as `<NULL>`, so it reads differently
    /// from an empty string, and a locked one dims a plain NULL.
    fn draw_text(&self, display: &gtk::Inscription, input: &CellInput, editable: bool, pending_delete: bool) {
        let (text, placeholder) = match input {
            CellInput::Default if self.auto_filled => (auto_filled_sentinel(), true),
            CellInput::Default => ("DEFAULT".to_owned(), true),
            CellInput::Value(Value::Null) if editable => (editable_null_sentinel(), true),
            CellInput::Value(value) => (value_to_display_text(value), false),
        };
        let is_null = matches!(input, CellInput::Value(Value::Null));
        display.set_text(Some(&text));
        let widget = display.upcast_ref::<gtk::Widget>();
        apply_cell_tooltip(widget, &text, placeholder || is_null);
        set_class(widget, "dim-label", is_null && !editable);
        set_class(widget, "tp-null-sentinel", placeholder);
        display.set_attributes(pending_delete.then(strikethrough).as_ref());
    }
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

fn apply_cell_tooltip(widget: &gtk::Widget, text: &str, stands_in: bool) {
    if stands_in || text.chars().take(TOOLTIP_MIN_CHARS + 1).count() <= TOOLTIP_MIN_CHARS {
        widget.set_tooltip_text(None);
    } else {
        widget.set_tooltip_text(Some(text));
    }
}

/// A Pango attribute, because CSS `text-decoration` does not cascade
/// reliably into a cell's text.
fn strikethrough() -> gtk::pango::AttrList {
    let attrs = gtk::pango::AttrList::new();
    attrs.insert(gtk::pango::AttrInt::new_strikethrough(true));
    attrs
}
