use std::collections::{BTreeMap, BTreeSet};

use gtk4 as gtk;
use gtk4::prelude::*;
use tablepro_core::{ColumnInfo, Value};

use super::{Layouts, data_column, text};
use crate::services::grid::{ColumnLayout, LayoutSlot};
use crate::test_support::{drain_main_context, wait_until};
use crate::ui::data_grid::test_grid::{Grid, GridSpec, WAIT, named, persisted, two_text_columns, two_text_values};

fn users() -> Vec<ColumnInfo> {
    vec![
        named("id", "integer", true),
        named("name", "text", false),
        named("email", "varchar(80)", false),
    ]
}

fn open_users(layouts: &Layouts, table: &str) -> Grid {
    Grid::build(
        GridSpec {
            layout: Some(layouts.binding(table)),
            ..GridSpec::table(users())
        },
        persisted(&[
            vec![Value::Int(1), text("Ada"), text("ada@example.com")],
            vec![Value::Int(2), text("Grace"), text("grace@example.com")],
        ]),
    )
}

fn position_in_view(view: &gtk::ColumnView, column: &gtk::ColumnViewColumn) -> u32 {
    (0..view.columns().n_items())
        .find(|position| view.columns().item(*position).as_ref() == Some(column.upcast_ref()))
        .expect("the column is in the view")
}

fn slot(name: &str) -> LayoutSlot {
    LayoutSlot::Column(name.to_owned())
}

#[gtk4::test]
fn a_moved_hidden_and_resized_column_comes_back_in_a_new_grid() {
    let layouts = Layouts::new();
    let first = open_users(&layouts, "users");
    let view = first.grid.column_view();
    let name = data_column(&first, 1);

    view.insert_column(position_in_view(&view, &name), &data_column(&first, 2));
    first.grid.set_column_visible(0, false);
    name.set_fixed_width(321);
    drain_main_context();
    assert_eq!(first.grid.shown_columns(), [2, 1]);
    drop((first, view, name));

    let again = open_users(&layouts, "users");
    let other = open_users(&layouts, "orders");

    assert_eq!(
        again.grid.shown_columns(),
        [2, 1],
        "the order or the hidden column was lost"
    );
    assert!(!data_column(&again, 0).is_visible());
    assert_eq!(data_column(&again, 1).fixed_width(), 321);
    assert_eq!(other.grid.shown_columns(), [0, 1, 2], "another table took the layout");
    assert_ne!(data_column(&other, 1).fixed_width(), 321);
}

/// Two tabs on one table: each saves only what it changed.
#[gtk4::test]
fn two_grids_on_one_table_keep_each_others_changes() {
    let layouts = Layouts::new();
    let first = open_users(&layouts, "users");
    let second = open_users(&layouts, "users");

    data_column(&first, 1).set_fixed_width(321);
    drain_main_context();
    data_column(&second, 2).set_fixed_width(222);
    second.grid.set_column_visible(0, false);
    drain_main_context();

    let saved = layouts.saved("users");
    assert_eq!(saved.widths.get("name"), Some(&321), "the first tab's width was lost");
    assert_eq!(saved.widths.get("email"), Some(&222));
    assert!(saved.hidden.contains("id"));
}

/// A read without a column keeps what the user gave it for when it is
/// back.
#[gtk4::test]
fn a_column_missing_from_one_read_keeps_its_entry() {
    let layouts = Layouts::new();
    let stored = ColumnLayout {
        order: vec![LayoutSlot::RowNumbers, slot("id"), slot("email"), slot("name")],
        hidden: BTreeSet::from(["email".to_owned()]),
        widths: BTreeMap::from([("email".to_owned(), 222), ("name".to_owned(), 150)]),
    };
    layouts
        .store
        .save(layouts.connection_id, Some("public"), "users", &stored);
    let without_email = Grid::build(
        GridSpec {
            layout: Some(layouts.binding("users")),
            ..GridSpec::table(two_text_columns())
        },
        persisted(&two_text_values()),
    );
    assert_eq!(data_column(&without_email, 1).fixed_width(), 150);

    data_column(&without_email, 1).set_fixed_width(180);
    drain_main_context();

    assert_eq!(
        layouts.saved("users"),
        ColumnLayout {
            widths: BTreeMap::from([("email".to_owned(), 222), ("name".to_owned(), 180)]),
            ..stored
        }
    );
    drop(without_email);
    let all = open_users(&layouts, "users");
    assert_eq!(all.grid.shown_columns(), [0, 1]);
    assert!(!data_column(&all, 2).is_visible());
    assert_eq!(data_column(&all, 2).fixed_width(), 222);
}

/// GTK drops a header let go over the space after the last column after
/// the filler that holds that space, and lets the filler be dragged too.
#[gtk4::test]
fn the_space_after_the_last_column_stays_last() {
    let layouts = Layouts::new();
    let grid = open_users(&layouts, "users");
    let view = grid.grid.column_view();
    let last = || {
        view.columns()
            .item(view.columns().n_items() - 1)
            .and_downcast::<gtk::ColumnViewColumn>()
            .expect("a column")
    };
    let filler = last();

    view.insert_column(position_in_view(&view, &filler), &data_column(&grid, 0));
    wait_until(WAIT, || last() == filler).expect("the filler back at the end");
    assert_eq!(grid.grid.shown_columns(), [1, 2, 0]);
    assert_eq!(layouts.saved("users").order.last(), Some(&slot("id")));

    view.insert_column(1, &filler);
    wait_until(WAIT, || last() == filler).expect("the filler back at the end");
    assert_eq!(grid.grid.shown_columns(), [1, 2, 0]);
}

/// A grid of no columns has nothing to focus and no header to bring one
/// back from.
#[gtk4::test]
fn the_last_shown_column_cannot_be_hidden() {
    let grid = Grid::open(two_text_columns(), two_text_values());

    grid.grid.set_column_visible(0, false);
    grid.grid.set_column_visible(1, false);
    assert_eq!(grid.grid.shown_columns(), [1]);
    grid.grid
        .activate_action("grid.hide-column-at", Some(&1u32.to_variant()))
        .expect("the header's Hide Column");
    assert_eq!(grid.grid.shown_columns(), [1], "the header hid the last column");
    grid.focus(0, 1);
    grid.activate("hide-column");

    assert_eq!(grid.grid.shown_columns(), [1], "the cell menu hid the last column");
    assert!(data_column(&grid, 1).is_visible());
}
