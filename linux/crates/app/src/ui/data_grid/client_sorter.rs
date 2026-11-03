use std::cmp::Ordering;

use gtk4::prelude::*;
use gtk4::{self as gtk, glib};
use tablepro_core::Value;
use tablepro_core::value::order::{compare, sort_text, sorts_as_text, storage_class_order, storage_class_rank};

use super::GridRow;
use crate::services::grid::GridColumn;

// GtkStringSorter collates text in the user's locale with one key per row. A custom sorter runs on every comparison
// that reaches it, so it comes last, where two texts never do.
pub fn column_sorter(column: &GridColumn) -> gtk::Sorter {
    let index = column.index;
    if sorts_as_text(&column.column_type) {
        let sorter = gtk::MultiSorter::new();
        sorter.append(class_sorter(index));
        sorter.append(text_sorter(index));
        sorter.append(cells_by(index, storage_class_order));
        return sorter.upcast();
    }
    cells_by(index, compare).upcast()
}

fn class_sorter(index: usize) -> gtk::NumericSorter {
    let class = gtk::ClosureExpression::with_callback(&[] as &[gtk::Expression], move |values: &[glib::Value]| {
        let cells = values
            .first()
            .and_then(|value| value.get::<GridRow>().ok())
            .and_then(|row| row.cells());
        let null = Value::Null;
        storage_class_rank(cells.as_deref().and_then(|cells| cells.get(index)).unwrap_or(&null))
    });
    gtk::NumericSorter::new(Some(class))
}

fn text_sorter(index: usize) -> gtk::StringSorter {
    let text = gtk::ClosureExpression::with_callback(&[] as &[gtk::Expression], move |values: &[glib::Value]| {
        let row = values.first()?.get::<GridRow>().ok()?;
        let cells = row.cells()?;
        cells.get(index).and_then(sort_text).map(str::to_owned)
    });
    let sorter = gtk::StringSorter::new(Some(text));
    sorter.set_collation(gtk::Collation::Unicode);
    sorter
}

fn cells_by(index: usize, order: fn(&Value, &Value) -> Ordering) -> gtk::CustomSorter {
    gtk::CustomSorter::new(move |left, right| {
        let (Some(left), Some(right)) = (left.downcast_ref::<GridRow>(), right.downcast_ref::<GridRow>()) else {
            return gtk::Ordering::Equal;
        };
        let (left, right) = (left.cells(), right.cells());
        let null = Value::Null;
        let left = left.as_deref().and_then(|cells| cells.get(index)).unwrap_or(&null);
        let right = right.as_deref().and_then(|cells| cells.get(index)).unwrap_or(&null);
        order(left, right).into()
    })
}
