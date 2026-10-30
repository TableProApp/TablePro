use gtk4::prelude::*;
use gtk4::{self as gtk};

/// The column after the last one, which takes the width the others
/// leave. A GtkColumnView row is as wide as its columns, so without it
/// the header, the rows' separators and a selection stop short of the
/// grid's edge, where an AppKit table carries them across. The columns
/// themselves keep the width they were given, as the macOS grid's do.
pub fn build() -> gtk::ColumnViewColumn {
    let factory = gtk::SignalListItemFactory::new();
    factory.connect_setup(|_, item| {
        if let Some(cell) = item.downcast_ref::<gtk::ColumnViewCell>() {
            // Nothing to focus or read: arrows and Tab stop at the last
            // column that holds values.
            cell.set_property("focusable", false);
        }
    });
    let column = gtk::ColumnViewColumn::builder()
        .factory(&factory)
        .expand(true)
        .resizable(false)
        .build();
    column.set_id(Some("filler"));
    column
}
