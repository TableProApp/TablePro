use std::time::{Duration, Instant};

use gtk4 as gtk;
use gtk4::glib;
use gtk4::prelude::*;
use tablepro_core::{ColumnInfo, Value};

use super::{
    action_names, close_menus, column_on_screen, data_column, ids_on_screen, keyed, selected_ids, sorts, text,
};
use crate::test_support::drain_main_context;
use crate::ui::data_grid::GridSorting;
use crate::ui::data_grid::test_grid::{Grid, GridSpec, named, persisted, results, two_text_columns, two_text_values};

/// What a click on `column`'s header does.
fn header_click(grid: &Grid, column: usize, order: gtk::SortType) {
    grid.grid
        .column_view()
        .sort_by_column(Some(&data_column(grid, column)), order);
    drain_main_context();
}

fn header_clear(grid: &Grid) {
    grid.grid
        .column_view()
        .sort_by_column(None::<&gtk::ColumnViewColumn>, gtk::SortType::Ascending);
    drain_main_context();
}

/// The column and order the headers show.
fn sorted_by(grid: &Grid) -> Option<(usize, gtk::SortType)> {
    let sorter = grid
        .grid
        .column_view()
        .sorter()
        .and_downcast::<gtk::ColumnViewSorter>()?;
    let column = sorter.primary_sort_column()?;
    Some((grid.grid.column_index(&column)?, sorter.primary_sort_order()))
}

fn said(grid: &Grid) -> Vec<String> {
    crate::ui::a11y::announced_in(&grid.grid)
        .into_iter()
        .map(|(text, _)| text)
        .collect()
}

fn results_of(columns: Vec<ColumnInfo>, rows: &[Vec<Value>]) -> Grid {
    Grid::build(GridSpec::results(columns), results(rows))
}

#[gtk4::test]
fn sort_by_column_descending_orders_result_rows() {
    let grid = results_of(
        vec![named("id", "integer", false), named("name", "text", false)],
        &[
            vec![Value::Int(2), text("b")],
            vec![Value::Int(10), text("j")],
            vec![Value::Null, text("none")],
            vec![Value::Int(-1), text("a")],
        ],
    );

    header_click(&grid, 0, gtk::SortType::Descending);

    assert_eq!(
        column_on_screen(&grid, 0),
        [Value::Int(10), Value::Int(2), Value::Int(-1), Value::Null]
    );
    assert_eq!(
        column_on_screen(&grid, 1),
        [text("j"), text("b"), text("a"), text("none")]
    );
    header_click(&grid, 0, gtk::SortType::Ascending);
    assert_eq!(
        column_on_screen(&grid, 0),
        [Value::Null, Value::Int(-1), Value::Int(2), Value::Int(10)]
    );
}

#[gtk4::test]
fn a_sort_keeps_the_selected_rows_selected() {
    let grid = results_of(
        vec![named("id", "integer", false)],
        &[vec![Value::Int(3)], vec![Value::Int(1)], vec![Value::Int(2)]],
    );
    let selection = grid.grid.selection();
    selection.select_item(0, true);
    selection.select_item(1, false);

    header_click(&grid, 0, gtk::SortType::Ascending);

    assert_eq!(ids_on_screen(&grid), [1, 2, 3]);
    assert_eq!(selected_ids(&grid), [1, 3]);
}

#[gtk4::test]
fn text_column_sorts_with_unicode_collation() {
    let names = ["f", "é", "e", "E"];
    let mut rows: Vec<Vec<Value>> = names.iter().map(|name| vec![text(name)]).collect();
    rows.insert(2, vec![Value::Null]);
    let grid = results_of(vec![named("name", "text", false)], &rows);

    header_click(&grid, 0, gtk::SortType::Ascending);

    // The order is the locale's: whatever it is, it is the order of the
    // collation keys GLib builds for it, with NULL first. The sorter
    // ignores case, as GtkStringSorter does by default, so `e` and `E`
    // tie and keep their row order.
    let key = |name: &str| glib::CollationKey::from(glib::casefold(name).as_str());
    let mut collated = names.to_vec();
    collated.sort_by_key(|name| key(name));
    let mut expected = vec![Value::Null];
    expected.extend(collated.iter().map(|name| text(name)));
    assert_eq!(column_on_screen(&grid, 0), expected);
    if key("e") < key("é") && key("é") < key("f") {
        let order: Vec<Value> = column_on_screen(&grid, 0)
            .into_iter()
            .filter(|value| *value != text("E"))
            .collect();
        assert_eq!(order, [Value::Null, text("e"), text("é"), text("f")]);
    }
    header_click(&grid, 0, gtk::SortType::Descending);
    assert_eq!(
        column_on_screen(&grid, 0).last(),
        Some(&Value::Null),
        "NULL is not last descending"
    );
}

#[gtk4::test]
fn a_text_column_orders_its_numbers_before_its_text() {
    let mut column = named("tag", "nvarchar(20)", false);
    column.column_type.dynamic_storage = false;
    let grid = results_of(
        vec![column],
        &[
            vec![Value::Int(10)],
            vec![text("b")],
            vec![Value::Int(9)],
            vec![Value::Null],
            vec![text("a")],
        ],
    );

    header_click(&grid, 0, gtk::SortType::Ascending);

    assert_eq!(
        column_on_screen(&grid, 0),
        [Value::Null, Value::Int(9), Value::Int(10), text("a"), text("b")]
    );
}

#[gtk4::test]
fn text_column_sorter_is_string_sorter_with_unicode_collation() {
    let grid = results_of(vec![named("name", "varchar(20)", false)], &[]);

    let sorter = data_column(&grid, 0)
        .sorter()
        .and_downcast::<gtk::MultiSorter>()
        .expect("a text column sorts in steps");

    let collating = sorter
        .item(sorter.n_items() - 1)
        .and_downcast::<gtk::StringSorter>()
        .expect("the last step collates the text");
    assert_eq!(collating.collation(), gtk::Collation::Unicode);
    assert!(
        sorter.item(0).and_downcast::<gtk::CustomSorter>().is_some(),
        "NULL is not placed first"
    );
}

#[gtk4::test]
fn sorting_10k_text_rows_finishes_within_one_second() {
    let rows: Vec<Vec<Value>> = (0..10_000_u64)
        .map(|row| vec![text(&format!("name {:05}", row * 7_919 % 10_000))])
        .collect();
    let grid = results_of(vec![named("name", "text", false)], &rows);

    let started = Instant::now();
    grid.grid
        .column_view()
        .sort_by_column(Some(&data_column(&grid, 0)), gtk::SortType::Ascending);
    let count = grid.grid.selection().n_items();
    let elapsed = started.elapsed();

    assert_eq!(count, 10_000);
    assert!(elapsed < Duration::from_secs(1), "sorting took {elapsed:?}");
    let names = column_on_screen(&grid, 0);
    assert_eq!(names.first(), Some(&text("name 00000")));
    assert_eq!(names.last(), Some(&text("name 09999")));
}

#[gtk4::test]
fn the_cell_menu_sorts_the_results_and_restores_their_order() {
    let grid = results_of(
        vec![named("id", "integer", false), named("name", "text", false)],
        &[
            vec![Value::Int(2), text("b")],
            vec![Value::Int(3), text("c")],
            vec![Value::Int(1), text("a")],
        ],
    );

    assert!(grid.grid.open_cell_menu(&grid.cell_at(0, 0), None));
    grid.activate("sort-descending");
    close_menus(&grid);
    assert_eq!(
        column_on_screen(&grid, 0),
        [Value::Int(3), Value::Int(2), Value::Int(1)]
    );
    assert!(grid.grid.open_cell_menu(&grid.cell_at(0, 0), None));
    grid.activate("clear-sort");
    close_menus(&grid);

    assert_eq!(
        column_on_screen(&grid, 0),
        [Value::Int(2), Value::Int(3), Value::Int(1)]
    );
}

/// The header's arrow says nothing to a screen reader on Linux.
#[gtk4::test]
fn a_header_click_in_a_grid_that_sorts_its_rows_is_announced() {
    let grid = results_of(two_text_columns(), &two_text_values());

    header_click(&grid, 1, gtk::SortType::Ascending);
    header_click(&grid, 1, gtk::SortType::Descending);
    header_clear(&grid);

    assert_eq!(
        said(&grid),
        [
            "Sorted by name, ascending",
            "Sorted by name, descending",
            "Sort cleared"
        ]
    );
}

#[gtk4::test]
fn a_header_click_asks_the_host_and_leaves_the_rows_in_place() {
    let grid = Grid::build(GridSpec::table(two_text_columns()), keyed(&[3, 1, 2]));

    header_click(&grid, 0, gtk::SortType::Descending);

    assert_eq!(sorts(&grid), [Some((0, false))]);
    assert_eq!(ids_on_screen(&grid), [3, 1, 2], "the grid sorted rows the server sorts");
    assert_eq!(sorted_by(&grid), Some((0, gtk::SortType::Descending)));
    header_clear(&grid);
    assert_eq!(sorts(&grid), [None]);
    assert_eq!(sorted_by(&grid), None);
}

#[gtk4::test]
fn a_header_click_in_a_grid_the_server_sorts_is_announced() {
    let grid = Grid::open(two_text_columns(), two_text_values());

    header_click(&grid, 1, gtk::SortType::Ascending);

    assert_eq!(said(&grid), ["Sorted by name, ascending"]);
}

/// A restored tab's sort is the one its rows were read in.
#[gtk4::test]
fn set_sort_marks_the_header_without_asking() {
    let grid = Grid::build(
        GridSpec {
            sorting: GridSorting::Server {
                initial: Some((1, false)),
            },
            ..GridSpec::table(two_text_columns())
        },
        keyed(&[1, 2]),
    );
    assert_eq!(sorted_by(&grid), Some((1, gtk::SortType::Descending)));

    grid.grid.set_sort(Some((0, true)));
    assert_eq!(sorted_by(&grid), Some((0, gtk::SortType::Ascending)));
    grid.grid.set_sort(None);
    drain_main_context();

    assert_eq!(sorted_by(&grid), None);
    assert!(
        sorts(&grid).is_empty(),
        "putting the sort on the headers asked for rows"
    );
    assert!(said(&grid).is_empty(), "{:?}", said(&grid));
}

/// A header's click and drag take a pointer, so the menu, which the
/// Menu key opens, sorts too.
#[gtk4::test]
fn the_menu_sorts_by_its_column_and_clears_the_sort() {
    let grid = Grid::open(two_text_columns(), two_text_values());
    assert!(grid.grid.open_cell_menu(&grid.cell_of(1, 1), None));
    assert!(!grid.is_enabled("clear-sort"), "Clear Sort was on with no sort");

    grid.activate("sort-descending");
    close_menus(&grid);
    assert!(grid.grid.open_cell_menu(&grid.cell_of(1, 1), None));
    grid.activate("clear-sort");
    close_menus(&grid);

    assert_eq!(sorts(&grid), [Some((1, false)), None]);
    assert_eq!(sorted_by(&grid), None);
}

#[gtk4::test]
fn no_header_sorts_a_table_in_the_engines_order() {
    let grid = Grid::build(
        GridSpec {
            sorting: GridSorting::None,
            ..GridSpec::table(two_text_columns())
        },
        keyed(&[1]),
    );
    let view = grid.grid.column_view();

    let sorters: Vec<bool> = (0..view.columns().n_items())
        .filter_map(|position| view.columns().item(position).and_downcast::<gtk::ColumnViewColumn>())
        .map(|column| column.sorter().is_some())
        .collect();

    assert_eq!(sorters, [false, false, false]);
}

/// D4: a field no sort can name, as a document's nested field, sorts by
/// no header and no menu.
#[gtk4::test]
fn an_unaddressable_column_offers_no_sort() {
    let grid = Grid::build(
        GridSpec {
            unaddressable: vec!["address.city".to_owned()],
            ..GridSpec::table(vec![
                named("id", "integer", true),
                named("name", "text", false),
                named("address.city", "text", false),
            ])
        },
        persisted(&[vec![Value::Int(1), text("Ada"), text("London")]]),
    );
    let nested = data_column(&grid, 2);
    let header = action_names(&nested.header_menu().expect("the header's menu"));

    assert!(nested.sorter().is_none());
    assert!(data_column(&grid, 1).sorter().is_some());
    assert!(
        !header.iter().any(|action| action.starts_with("grid.sort")),
        "{header:?}"
    );
    grid.focus(0, 2);
    assert!(!grid.is_enabled("sort-ascending"));
    grid.focus(0, 1);
    assert!(grid.is_enabled("sort-ascending"));
}

#[gtk4::test]
fn reset_columns_keeps_the_sort_the_headers_show() {
    let grid = Grid::open(two_text_columns(), two_text_values());
    header_click(&grid, 1, gtk::SortType::Descending);
    sorts(&grid);

    grid.grid.reset_layout();
    drain_main_context();

    let sorter = grid
        .grid
        .column_view()
        .sorter()
        .and_downcast::<gtk::ColumnViewSorter>()
        .expect("the column view's sorter");
    assert_eq!(sorter.primary_sort_column(), Some(data_column(&grid, 1)));
    assert_eq!(sorter.primary_sort_order(), gtk::SortType::Descending);
    assert!(sorts(&grid).is_empty(), "the reset asked the host for rows again");
}

/// Clear Sort follows the headers with no row selected, and for a sort
/// the host put there.
#[gtk4::test]
fn clear_sort_follows_every_sort_change() {
    let grid = results_of(two_text_columns(), &two_text_values());
    grid.grid.selection().unselect_all();
    header_click(&grid, 1, gtk::SortType::Ascending);
    let after_click = grid.is_enabled("clear-sort");
    header_clear(&grid);
    let after_clear = grid.is_enabled("clear-sort");
    let table = Grid::build(
        GridSpec {
            sorting: GridSorting::Server { initial: None },
            ..GridSpec::table(two_text_columns())
        },
        keyed(&[1, 2]),
    );
    table.grid.selection().unselect_all();
    table.grid.set_sort(Some((0, true)));
    drain_main_context();

    assert_eq!((after_click, after_clear), (true, false));
    assert!(
        table.is_enabled("clear-sort"),
        "a sort the host set left Clear Sort off"
    );
}
