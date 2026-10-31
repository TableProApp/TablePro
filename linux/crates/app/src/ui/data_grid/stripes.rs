use gtk4 as gtk;
use gtk4::prelude::*;

/// The class `alternate_rows_provider` shades.
pub(super) const STRIPE: &str = "tp-stripe";

/// GTK recycles row widgets as the view scrolls, so the stripe follows
/// the row's position in the result, never the widget's place among the
/// rows on screen. The class goes on the cell widget, which spans the
/// cell's padding that its child leaves bare.
pub(super) fn follow(cell: &gtk::ColumnViewCell) {
    cell.connect_notify_local(Some("position"), |cell, _| mark(cell));
}

pub(super) fn mark(cell: &gtk::ColumnViewCell) {
    let Some(widget) = cell.child().and_then(|child| child.parent()) else {
        return;
    };
    let position = cell.position();
    match position != gtk::INVALID_LIST_POSITION && position % 2 == 1 {
        true => widget.add_css_class(STRIPE),
        false => widget.remove_css_class(STRIPE),
    }
}
