use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;

use gtk4::prelude::*;
use gtk4::{self as gtk, glib, pango};

use super::tracked_values::RowPendingState;
use super::{DataGrid, GridRow, grid_menu};

/// Icon, spacing and the cell's padding beside the digits.
const CHROME_PX: i32 = 16 + 4 + 13;

/// The handlers a bound gutter cell or row keeps, dropped at unbind.
type Watches = Rc<RefCell<HashMap<glib::Object, Vec<(glib::WeakRef<glib::Object>, glib::SignalHandlerId)>>>>;

/// The first column: each row's number and the icon of its pending
/// change. GtkColumnView has no row headers, so it is a column like the
/// others, scrolled and dragged with them.
pub fn build(grid: &DataGrid) -> gtk::ColumnViewColumn {
    let factory = gtk::SignalListItemFactory::new();
    factory.connect_setup(|_, item| {
        let Some(cell) = item.downcast_ref::<gtk::ColumnViewCell>() else {
            return;
        };
        cell.set_property("focusable", false);
        let icon = gtk::Image::builder().pixel_size(16).visible(false).build();
        icon.set_accessible_role(gtk::AccessibleRole::Presentation);
        let number = gtk::Inscription::builder()
            .xalign(1.0)
            .hexpand(true)
            .valign(gtk::Align::Center)
            .build();
        number.add_css_class("numeric");
        number.add_css_class("dimmed");
        let content = gtk::Box::new(gtk::Orientation::Horizontal, 4);
        content.append(&icon);
        content.append(&number);
        cell.set_child(Some(&content));
    });
    let watches: Watches = Rc::default();
    let weak = grid.downgrade();
    {
        let watches = watches.clone();
        factory.connect_bind(move |_, item| {
            let (Some(cell), Some(grid)) = (item.downcast_ref::<gtk::ColumnViewCell>(), weak.upgrade()) else {
                return;
            };
            let Some(row) = cell.item().and_downcast::<GridRow>() else {
                return;
            };
            bind_cell(&grid, cell, &row, &watches);
        });
    }
    factory.connect_unbind(move |_, item| unwatch(&watches, item.upcast_ref()));
    let column = gtk::ColumnViewColumn::builder()
        .title(crate::i18n::pgettext("row number column", "#"))
        .factory(&factory)
        .header_menu(&grid_menu::row_numbers_header_menu())
        .resizable(false)
        .build();
    column.set_id(Some("row-numbers"));
    column
}

fn bind_cell(grid: &DataGrid, cell: &gtk::ColumnViewCell, row: &GridRow, watches: &Watches) {
    let show = {
        let (grid, cell) = (grid.downgrade(), cell.downgrade());
        move || {
            if let (Some(grid), Some(cell)) = (grid.upgrade(), cell.upgrade()) {
                show_cell(&grid, &cell);
            }
        }
    };
    show();
    let on_row = {
        let show = show.clone();
        row.connect_revision_notify(move |_| show())
    };
    let on_position = cell.connect_notify_local(Some("position"), move |_, _| show());
    watches.borrow_mut().insert(
        cell.clone().upcast(),
        vec![
            (row.upcast_ref::<glib::Object>().downgrade(), on_row),
            (cell.upcast_ref::<glib::Object>().downgrade(), on_position),
        ],
    );
}

/// The tracked values are read each time, since the grid's rules follow
/// its column set.
fn show_cell(grid: &DataGrid, cell: &gtk::ColumnViewCell) {
    let Some(row) = cell.item().and_downcast::<GridRow>() else {
        return;
    };
    let Some(content) = cell.child() else {
        return;
    };
    let (Some(icon), Some(number)) = (
        content.first_child().and_downcast::<gtk::Image>(),
        content.last_child().and_downcast::<gtk::Inscription>(),
    ) else {
        return;
    };
    let state = grid.tracked().row_state(&row);
    icon.set_icon_name(state.icon());
    icon.set_visible(state.icon().is_some());
    icon.set_tooltip_text(state.text().as_deref());
    number.set_text(
        row_number(grid, &row, cell.position())
            .map(|n| n.to_string())
            .as_deref(),
    );
}

/// A saved row's number counts from the first row read; a draft has none.
fn row_number(grid: &DataGrid, row: &GridRow, position: u32) -> Option<u64> {
    if row.draft_id().is_some() || position == gtk::INVALID_LIST_POSITION {
        return None;
    }
    let drafts = grid.store().draft_count();
    Some(grid.row_base() + u64::from(position.saturating_sub(drafts)) + 1)
}

fn unwatch(watches: &Watches, item: &glib::Object) {
    if let Some(handlers) = watches.borrow_mut().remove(item) {
        for (object, handler) in handlers {
            if let Some(object) = object.upgrade() {
                object.disconnect(handler);
            }
        }
    }
}

/// As wide as the largest number the rows held reach, in tabular digits.
pub fn fit(grid: &DataGrid) {
    let Some(column) = grid.row_numbers_column() else {
        return;
    };
    let largest = grid.row_base() + u64::from(grid.store().len());
    let digits = largest.max(1).ilog10() as i32 + 1;
    // A fresh context, since the view's own follows a font change only at
    // the next frame.
    let metrics = grid.column_view().create_pango_context().metrics(None, None);
    let digit_px = pango::units_to_double(metrics.approximate_digit_width());
    column.set_fixed_width((f64::from(digits.max(2)) * digit_px).ceil() as i32 + CHROME_PX);
}

/// Each row names itself and its pending change to a screen reader, and
/// takes no focus of its own, so the focus always lands on a cell.
pub fn install_row_factory(grid: &DataGrid) {
    let factory = gtk::SignalListItemFactory::new();
    factory.connect_setup(|_, item| {
        if let Some(list_row) = item.downcast_ref::<gtk::ColumnViewRow>() {
            list_row.set_focusable(false);
        }
    });
    let watches: Watches = Rc::default();
    let weak = grid.downgrade();
    {
        let watches = watches.clone();
        factory.connect_bind(move |_, item| {
            let (Some(list_row), Some(grid)) = (item.downcast_ref::<gtk::ColumnViewRow>(), weak.upgrade()) else {
                return;
            };
            let Some(row) = list_row.item().and_downcast::<GridRow>() else {
                return;
            };
            let show = {
                let (grid, list_row) = (grid.downgrade(), list_row.downgrade());
                move || {
                    if let (Some(grid), Some(list_row)) = (grid.upgrade(), list_row.upgrade()) {
                        describe_row(&grid, &list_row);
                    }
                }
            };
            show();
            let on_row = {
                let show = show.clone();
                row.connect_revision_notify(move |_| show())
            };
            let on_position = list_row.connect_notify_local(Some("position"), move |_, _| show());
            watches.borrow_mut().insert(
                list_row.clone().upcast(),
                vec![
                    (row.upcast_ref::<glib::Object>().downgrade(), on_row),
                    (list_row.upcast_ref::<glib::Object>().downgrade(), on_position),
                ],
            );
        });
    }
    factory.connect_unbind(move |_, item| {
        unwatch(&watches, item.upcast_ref());
        if let Some(list_row) = item.downcast_ref::<gtk::ColumnViewRow>() {
            list_row.set_property("accessible-label", None::<String>);
            list_row.set_property("accessible-description", None::<String>);
        }
    });
    grid.column_view().set_row_factory(Some(&factory));
}

/// Through the properties, since their setters take no NULL to clear.
fn describe_row(grid: &DataGrid, list_row: &gtk::ColumnViewRow) {
    let Some(row) = list_row.item().and_downcast::<GridRow>() else {
        return;
    };
    let state = grid.tracked().row_state(&row);
    let label = match row_number(grid, &row, list_row.position()) {
        Some(number) => crate::i18n::gettext_f("Row {number}", &[("number", &number.to_string())]),
        None => crate::i18n::gettext("New row"),
    };
    list_row.set_property("accessible-label", Some(label));
    let description = match state {
        RowPendingState::Inserted => None,
        other => other.row_description(),
    };
    list_row.set_property("accessible-description", description);
}
