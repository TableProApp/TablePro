use gtk4 as gtk;
use gtk4::prelude::*;

use tablepro_core::{ColumnInfo, Value};

use super::display_text::{auto_filled_sentinel, editable_null_sentinel, value_to_display_text};
use super::{CellEditor, CellLock, GridCell, GridRowId, RowObject, TabGridContext, cell_editability};

const PENDING_CSS_CLASSES: &[&str] = &[
    "tp-cell-modified",
    "tp-row-pending-delete",
    "tp-row-pending-insert",
    "tp-row-leftmost-error-flash",
];

/// Shorter text fits a typical 200 px column, so its ellipsized label
/// needs no tooltip.
const TOOLTIP_MIN_CHARS: usize = 40;

/// What a column's cells read to draw a row. The column makes one and
/// every cell it builds shares it.
#[derive(Debug)]
pub struct ColumnDrawing {
    /// `None` for a column the grid knows only from the result set.
    pub catalog: Option<ColumnInfo>,
    pub tab_ctx: TabGridContext,
    /// The server fills these in, so a draft row shows a placeholder
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
        let (value, pending_classes) = self.tab_ctx.bind_state(row, cell.column());
        draw_cell(cell, &value, &pending_classes, cell.lock().is_none(), self.auto_filled);
    }
}

/// `editable` is whether this row's cell takes an edit: such a cell
/// shows NULL as `<NULL>`, so it reads differently from an empty
/// string, and a locked one dims a plain NULL.
fn draw_cell(grid_cell: &GridCell, value: &Value, pending_classes: &[&'static str], editable: bool, auto_filled: bool) {
    let is_null = matches!(value, Value::Null);
    let text = if is_null && auto_filled {
        auto_filled_sentinel()
    } else if is_null && editable {
        editable_null_sentinel()
    } else {
        value_to_display_text(value)
    };
    let is_pending_delete = pending_classes.contains(&"tp-row-pending-delete");
    let Some(content) = grid_cell.content() else {
        return;
    };
    if let Some(editor) = content.downcast_ref::<CellEditor>() {
        // An edit opened on a value the row no longer has would, once it
        // ended, send that value back or leave it on screen. An edit on
        // the same value keeps what was typed.
        if grid_cell.record_drawn_text(&text) && (editor.is_editing() || grid_cell.is_editing()) {
            grid_cell.cancel_edit();
        }
        if !editor.is_editing() {
            editor.set_text(&text);
        }
        // A locked cell's text is there to be read and copied, as a
        // read-only column's is.
        editor.set_selectable(!editable);
        apply_cell_tooltip(content, &text, is_null);
        set_class(content, "dim-label", is_null && !editable);
        set_class(content, "tp-null-sentinel", is_null && (editable || auto_filled));
        apply_pending_classes(content, pending_classes);
        editor.set_strikethrough(is_pending_delete);
    } else if let Some(checkbox) = content.downcast_ref::<gtk::CheckButton>() {
        // Suppressed, so drawing the value does not echo back as an edit.
        grid_cell.suppress_toggle(true);
        // A value that is not a bool shows as inconsistent rather than as
        // a confidently wrong check box.
        let (active, inconsistent) = match value {
            Value::Bool(flag) => (*flag, false),
            _ => (false, true),
        };
        checkbox.set_inconsistent(inconsistent);
        checkbox.set_active(active);
        grid_cell.suppress_toggle(false);
        checkbox.set_sensitive(editable);
        apply_pending_classes(content, pending_classes);
        // A check box has no strikethrough, so a pending delete dims it.
        checkbox.set_opacity(if is_pending_delete { 0.5 } else { 1.0 });
    } else if let Some(label) = content.downcast_ref::<gtk::Label>() {
        label.set_text(&text);
        apply_cell_tooltip(content, &text, is_null);
        set_class(content, "dim-label", is_null);
        apply_pending_classes(content, pending_classes);
        set_label_strikethrough(label, is_pending_delete);
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

fn apply_cell_tooltip(widget: &gtk::Widget, text: &str, is_null: bool) {
    if is_null || text.chars().take(TOOLTIP_MIN_CHARS + 1).count() <= TOOLTIP_MIN_CHARS {
        widget.set_tooltip_text(None);
    } else {
        widget.set_tooltip_text(Some(text));
    }
}

/// A Pango attribute, because CSS `text-decoration` does not cascade
/// reliably into a cell's label.
fn set_label_strikethrough(label: &gtk::Label, on: bool) {
    if on {
        let attrs = gtk::pango::AttrList::new();
        attrs.insert(gtk::pango::AttrInt::new_strikethrough(true));
        label.set_attributes(Some(&attrs));
    } else {
        label.set_attributes(None);
    }
}
