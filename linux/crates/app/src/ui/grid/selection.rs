use gtk4 as gtk;
use gtk4::prelude::*;

use tablepro_core::column::ResultColumn;
use tablepro_core::{QueryResult, Value};

use super::widget_slot::{COLUMN_SLOT, POSITION_SLOT};
use super::{RowObject, TabGridContext};

pub(crate) fn selected_positions(selection: &gtk::MultiSelection) -> Vec<u32> {
    let bitset = selection.selection();
    let mut out = Vec::with_capacity(bitset.size() as usize);
    for i in 0..bitset.size() {
        out.push(bitset.nth(i as u32));
    }
    out.sort_unstable();
    out
}

pub(super) fn row_at(column_view: &gtk::ColumnView, position: u32) -> Option<RowObject> {
    column_view.model()?.item(position)?.downcast::<RowObject>().ok()
}

fn selection_of(column_view: &gtk::ColumnView) -> Option<gtk::MultiSelection> {
    column_view.model()?.downcast::<gtk::MultiSelection>().ok()
}

/// A right-click on a selected row keeps the selection, so a block
/// still copies whole; any other row becomes the selection. That keeps
/// Copy and Delete in one menu pointing at the same rows.
pub(super) fn select_row_for_menu(column_view: &gtk::ColumnView, position: u32) {
    let Some(selection) = selection_of(column_view) else {
        return;
    };
    if position >= selection.n_items() || selection.is_selected(position) {
        return;
    }
    selection.select_item(position, true);
}

/// `clicked` is the fallback for the keyboard path on a grid whose
/// selection is empty.
pub(super) fn rows_for_menu(column_view: &gtk::ColumnView, ctx: &TabGridContext, clicked: u32) -> Vec<Vec<Value>> {
    let mut positions = selection_of(column_view)
        .map(|s| selected_positions(&s))
        .unwrap_or_default();
    if positions.is_empty() {
        positions.push(clicked);
    }
    positions
        .iter()
        .filter_map(|p| row_at(column_view, *p))
        .map(|r| ctx.effective_cells(&r))
        .collect()
}

/// The paginator's Export button and the menu's Export Results both
/// build their payload here, so one label cannot mean two files.
pub(crate) fn export_snapshot(
    column_view: &gtk::ColumnView,
    columns: &[ResultColumn],
    truncated: bool,
    ctx: &TabGridContext,
) -> QueryResult {
    let rows = match column_view.model() {
        Some(model) => (0..model.n_items())
            .filter_map(|p| row_at(column_view, p))
            .map(|r| ctx.effective_cells(&r))
            .collect(),
        None => Vec::new(),
    };
    QueryResult::new(columns.to_vec(), rows).truncated(truncated)
}

pub(crate) fn focused_cell_coords(widget: &impl IsA<gtk::Widget>) -> Option<(u32, usize)> {
    let root = widget.root()?;
    let window = root.dynamic_cast::<gtk::Window>().ok()?;
    // `RootExt::focus` would return the window itself.
    let focused = gtk4::prelude::GtkWindowExt::focus(&window)?;
    let position = POSITION_SLOT.get(&focused)?;
    let column = COLUMN_SLOT.get(&focused)?;
    Some((position, column))
}
