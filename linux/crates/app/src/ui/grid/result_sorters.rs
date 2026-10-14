use std::cmp::Ordering;

use gtk4::prelude::*;
use gtk4::{self as gtk, glib};
use tablepro_core::Value;
use tablepro_core::column::{ColumnKind, ResultColumn};

use super::RowObject;
use super::value_order::{compare, sort_text, storage_class_order};

/// What a header click on column `index` sorts the rows by.
///
/// Text is collated in the user's locale by `GtkStringSorter`, which
/// builds a `g_utf8_collate_key` once per row and compares the keys
/// with `strcmp`, so a sort of thousands of rows does not normalise a
/// string for every comparison. A sorter ahead of it places what it
/// cannot: NULL, and in a column whose rows each choose their storage,
/// the numbers and blobs.
pub(crate) fn column_sorter(index: usize, column: &ResultColumn) -> gtk::Sorter {
    let column_type = &column.column_type;
    if column_type.dynamic_storage {
        return collating(cells_by(index, storage_class_order), index);
    }
    if holds_text(&column_type.kind) {
        return collating(cells_by(index, nulls_first), index);
    }
    cells_by(index, compare).upcast()
}

fn holds_text(kind: &ColumnKind) -> bool {
    kind.is_textual() || matches!(kind, ColumnKind::Json { .. } | ColumnKind::Network(_))
}

/// `first`, then the locale's collation of the column's text.
fn collating(first: gtk::CustomSorter, index: usize) -> gtk::Sorter {
    let sorter = gtk::MultiSorter::new();
    sorter.append(first);
    sorter.append(text_sorter(index));
    sorter.upcast()
}

fn text_sorter(index: usize) -> gtk::StringSorter {
    let text = gtk::ClosureExpression::with_callback(&[] as &[gtk::Expression], move |values: &[glib::Value]| {
        let row = values.first()?.get::<RowObject>().ok()?;
        row.cell(index).and_then(sort_text).map(str::to_owned)
    });
    let sorter = gtk::StringSorter::new(Some(text));
    sorter.set_collation(gtk::Collation::Unicode);
    sorter
}

/// A sorter that orders two rows by their cells in column `index`.
fn cells_by(index: usize, order: fn(&Value, &Value) -> Ordering) -> gtk::CustomSorter {
    gtk::CustomSorter::new(move |a, b| {
        let (Some(a), Some(b)) = (a.downcast_ref::<RowObject>(), b.downcast_ref::<RowObject>()) else {
            return gtk::Ordering::Equal;
        };
        order(
            a.cell(index).unwrap_or(&Value::Null),
            b.cell(index).unwrap_or(&Value::Null),
        )
        .into()
    })
}

fn nulls_first(a: &Value, b: &Value) -> Ordering {
    b.is_null().cmp(&a.is_null())
}
