use std::sync::Arc;

use gtk4 as gtk;
use gtk4::prelude::*;

use tablepro_core::QueryResult;
use tablepro_core::column::ResultColumn;

use super::{RowObject, RowSnapshot, TabGridContext};

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

pub(super) fn selection_of(column_view: &gtk::ColumnView) -> Option<gtk::MultiSelection> {
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

/// The paginator's Export button and the menu's Export Results both
/// read the rows here, so one label cannot mean two files.
pub(crate) fn export_snapshot(column_view: &gtk::ColumnView, ctx: &TabGridContext) -> Vec<RowSnapshot> {
    let Some(model) = column_view.model() else {
        return Vec::new();
    };
    (0..model.n_items())
        .filter_map(|position| row_at(column_view, position))
        .map(|row| ctx.snapshot(&row))
        .collect()
}

/// Rows for an encoder that takes owned cells, under the columns the
/// grid shows.
pub(crate) fn snapshot_result(columns: Arc<[ResultColumn]>, rows: &[RowSnapshot], truncated: bool) -> QueryResult {
    QueryResult::new(columns, rows.iter().map(RowSnapshot::to_values).collect()).truncated(truncated)
}
