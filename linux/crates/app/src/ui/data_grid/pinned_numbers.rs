//! The row numbers stay in view while the columns scroll sideways, as
//! they do in the macOS grid. GtkColumnView has no frozen column, so once
//! the columns have scrolled, a list of the numbers alone is drawn over
//! the first column, which holds their place, and follows the rows'
//! vertical scroll.

use std::cell::{Cell, RefCell};
use std::rc::Rc;

use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use gtk4::{self as gtk, glib};

use super::row_number_column::{Watches, row_number, unwatch};
use super::{DataGrid, GridRow};

/// A pixel of sideways scroll is not yet a column out of place.
const SCROLLED_PX: f64 = 0.5;

/// What the gutter keeps between its rows being drawn and measured.
#[derive(Default)]
pub(super) struct Pinned {
    /// The rows' height in the column view, which the numbers' rows
    /// take, so the two lists stay level however far they scroll.
    row_height: Cell<i32>,
    cells: RefCell<Vec<glib::WeakRef<gtk::Widget>>>,
}

pub(super) fn install(grid: &DataGrid) {
    let imp = grid.imp();
    imp.gutter_header
        .set_label(&crate::i18n::pgettext("row number column", "#"));
    imp.row_gutter.update_state(&[gtk::accessible::State::Hidden(true)]);
    imp.gutter_list.set_model(Some(&imp.selection.0));
    imp.gutter_list.set_factory(Some(&factory(grid)));

    let follow = |adjustment: &gtk::Adjustment| {
        let weak = grid.downgrade();
        adjustment.connect_value_changed(move |_| {
            if let Some(grid) = weak.upgrade() {
                sync(&grid);
            }
        });
    };
    follow(&imp.scrolled.hadjustment());
    follow(&imp.scrolled.vadjustment());
    // The numbers' own list measures after it is shown, so the offset it
    // was given then may have been clamped.
    let weak = grid.downgrade();
    imp.gutter_scroll.vadjustment().connect_changed(move |_| {
        if let Some(grid) = weak.upgrade() {
            sync(&grid);
        }
    });
}

fn factory(grid: &DataGrid) -> gtk::SignalListItemFactory {
    let factory = gtk::SignalListItemFactory::new();
    let pinned = grid.imp().pinned_numbers.clone();
    {
        let pinned = pinned.clone();
        factory.connect_setup(move |_, item| {
            let Some(item) = item.downcast_ref::<gtk::ListItem>() else {
                return;
            };
            item.set_property("focusable", false);
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
            content.add_css_class("row-gutter-cell");
            content.set_height_request(pinned.row_height.get());
            content.append(&icon);
            content.append(&number);
            item.set_child(Some(&content));
            pinned
                .cells
                .borrow_mut()
                .push(content.upcast::<gtk::Widget>().downgrade());
        });
    }
    let watches: Watches = Rc::default();
    let weak = grid.downgrade();
    {
        let watches = watches.clone();
        factory.connect_bind(move |_, item| {
            let (Some(item), Some(grid)) = (item.downcast_ref::<gtk::ListItem>(), weak.upgrade()) else {
                return;
            };
            let Some(row) = item.item().and_downcast::<GridRow>() else {
                return;
            };
            let show = {
                let (grid, item) = (grid.downgrade(), item.downgrade());
                move || {
                    if let (Some(grid), Some(item)) = (grid.upgrade(), item.upgrade()) {
                        show_item(&grid, &item);
                    }
                }
            };
            show();
            let on_row = {
                let show = show.clone();
                row.connect_revision_notify(move |_| show())
            };
            let on_position = item.connect_notify_local(Some("position"), move |_, _| show());
            watches.borrow_mut().insert(
                item.clone().upcast(),
                vec![
                    (row.upcast_ref::<glib::Object>().downgrade(), on_row),
                    (item.upcast_ref::<glib::Object>().downgrade(), on_position),
                ],
            );
        });
    }
    factory.connect_unbind(move |_, item| unwatch(&watches, item.upcast_ref()));
    factory
}

fn show_item(grid: &DataGrid, item: &gtk::ListItem) {
    let (Some(row), Some(content)) = (item.item().and_downcast::<GridRow>(), item.child()) else {
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
    number.set_text(
        row_number(grid, &row, item.position())
            .map(|n| n.to_string())
            .as_deref(),
    );
}

/// Show the numbers once the columns have scrolled, level with the rows
/// and as wide as the column they cover.
pub(super) fn sync(grid: &DataGrid) {
    let imp = grid.imp();
    let scrolled = imp.scrolled.hadjustment().value() > SCROLLED_PX;
    imp.row_gutter.set_visible(scrolled);
    if !scrolled {
        return;
    }
    if let Some(column) = imp.columns.borrow().row_numbers() {
        imp.row_gutter.set_width_request(column.fixed_width());
    }
    let view = grid.column_view();
    if let Some(height) = header_height(&view) {
        imp.gutter_header.set_height_request(height);
    }
    // The separator under a row is drawn beside it, not in it.
    if let Some(height) = row_height(&view).map(|height| height + i32::from(view.shows_row_separators()))
        && imp.pinned_numbers.row_height.replace(height) != height
    {
        imp.pinned_numbers
            .cells
            .borrow_mut()
            .retain(|cell| match cell.upgrade() {
                Some(cell) => {
                    cell.set_height_request(height);
                    true
                }
                None => false,
            });
    }
    // A horizontal scrollbar that takes room of its own is not covered.
    let bar = imp.scrolled.hscrollbar();
    let below = if imp.scrolled.is_overlay_scrolling() || !bar.is_visible() {
        0
    } else {
        bar.height()
    };
    imp.row_gutter.set_margin_bottom(below);
    imp.gutter_scroll
        .vadjustment()
        .set_value(imp.scrolled.vadjustment().value());
}

fn header_height(view: &gtk::ColumnView) -> Option<i32> {
    let mut child = view.first_child();
    while let Some(widget) = child {
        if widget.css_name() == "header" && widget.height() > 0 {
            return Some(widget.height());
        }
        child = widget.next_sibling();
    }
    None
}

/// The height of any row the view has drawn.
fn row_height(view: &gtk::ColumnView) -> Option<i32> {
    fn find(widget: &gtk::Widget) -> Option<i32> {
        if widget.css_name() == "row" && widget.height() > 0 {
            return Some(widget.height());
        }
        let mut child = widget.first_child();
        while let Some(next) = child {
            if let Some(height) = find(&next) {
                return Some(height);
            }
            child = next.next_sibling();
        }
        None
    }
    find(view.upcast_ref())
}
