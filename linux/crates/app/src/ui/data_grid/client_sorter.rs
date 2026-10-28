use std::cmp::Ordering;

use gtk4::prelude::*;
use gtk4::{self as gtk, glib};
use tablepro_core::Value;
use tablepro_core::column::ColumnKind;

use super::GridRow;
use crate::services::grid::GridColumn;
use crate::services::grid::value_order::{compare, sort_text, storage_class_order};

/// What a header click sorts a grid's rows by.
///
/// Text is collated in the user's locale by `GtkStringSorter`, which
/// builds a collation key once per row rather than once per comparison.
/// The sorter ahead of it places every value that is not text, so the
/// pair serves any column that can hold text, including a SQLite column
/// whose rows choose their own storage.
pub fn column_sorter(column: &GridColumn) -> gtk::Sorter {
    let index = column.index;
    let column_type = &column.column_type;
    if column_type.dynamic_storage || holds_text(&column_type.kind) {
        let sorter = gtk::MultiSorter::new();
        sorter.append(cells_by(index, storage_class_order));
        sorter.append(text_sorter(index));
        return sorter.upcast();
    }
    cells_by(index, compare).upcast()
}

fn holds_text(kind: &ColumnKind) -> bool {
    kind.is_textual() || matches!(kind, ColumnKind::Json { .. } | ColumnKind::Network(_))
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
