use gtk4 as gtk;
use gtk4::prelude::*;

use super::grid_cell::set_class;

const STRIPE: &str = "tp-stripe";

// Rows are recycled, so `:nth-child` cannot stripe them and GTK has no API
// to class a row: each cell's child follows its row's position instead.
pub(super) fn follow(cell: &gtk::ColumnViewCell) {
    cell.connect_notify_local(Some("position"), |cell, _| {
        if let Some(child) = cell.child() {
            let position = cell.position();
            let odd = position != gtk::INVALID_LIST_POSITION && !position.is_multiple_of(2);
            set_class(&child, STRIPE, odd);
        }
    });
}
