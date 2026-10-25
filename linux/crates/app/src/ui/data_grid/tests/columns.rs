use std::rc::Rc;

use gtk4 as gtk;
use gtk4::pango;
use gtk4::prelude::*;
use gtk4::subclass::prelude::ObjectSubclassIsExt;
use tablepro_core::{ColumnInfo, Value};

use super::{Layouts, close_menus, data_column, keyed, laid_out, settled_width, shown_width, step, text, untyped};
use crate::test_support::{drain_main_context, wait_until};
use crate::ui::data_grid::columns::ColumnPaint;
use crate::ui::data_grid::test_grid::{
    Grid, GridSpec, WAIT, named, persisted, results, two_text_columns, two_text_values,
};

fn two_text_rows() -> Grid {
    Grid::open(two_text_columns(), two_text_values())
}

fn saved_to(layouts: &Layouts) -> Grid {
    Grid::build(
        GridSpec {
            layout: Some(layouts.binding("t")),
            ..GridSpec::table(two_text_columns())
        },
        keyed(&[1, 2]),
    )
}

/// Whether the grid lines column `index` up as numbers.
fn numbers(grid: &Grid, index: usize) -> bool {
    grid.grid
        .imp()
        .columns
        .borrow()
        .paint(index)
        .is_some_and(|paint| paint.numbers.get())
}

/// How wide `text` is in tabular figures, which libadwaita's `numeric`
/// class draws.
fn tabular_width(widget: &impl IsA<gtk::Widget>, text: &str) -> i32 {
    let layout = widget.create_pango_layout(Some(text));
    let tabular = pango::AttrList::new();
    tabular.insert(pango::AttrFontFeatures::new("tnum"));
    layout.set_attributes(Some(&tabular));
    layout.pixel_size().0
}

/// The text of `columns` in the rows on screen.
fn drawn(grid: &Grid, columns: &[usize]) -> Vec<gtk::Inscription> {
    grid.cells()
        .into_iter()
        .filter(|cell| columns.contains(&cell.column()) && cell.is_mapped())
        .filter_map(|cell| cell.display().cloned())
        .collect()
}

fn shows_whole(display: &gtk::Inscription) -> bool {
    let text = display.text().unwrap_or_default();
    display.width() > 0 && tabular_width(display, &text) <= display.width()
}

fn shop_columns(more_text: usize) -> Vec<ColumnInfo> {
    let mut columns = vec![
        named("id", "bigint", true),
        named("sku", "text", false),
        named("name", "text", false),
        named("price", "numeric(20,4)", false),
        named("stock", "integer", false),
        named("updated_at", "text", false),
        named("note", "text", false),
        named("comment", "text", false),
    ];
    columns.extend((0..more_text).map(|index| named(&format!("tag_{index}"), "text", false)));
    columns
}

const NUMBER_COLUMNS: [usize; 3] = [0, 3, 4];

fn shop_row(id: i64, price: &str, width: usize) -> Vec<Value> {
    let mut row = vec![
        Value::Int(id),
        text("CF-1001"),
        text("Ethiopia Yirgacheffe, 250 g"),
        Value::Decimal(price.parse().expect("a decimal")),
        Value::Int(123_456),
        text("2026-09-02 09:14:00+00"),
        text("Ground for a paper filter"),
        text("Ships in two days"),
    ];
    row.resize(width, text("seasonal"));
    row
}

/// An automatic width measures every row GTK builds and shifts as the
/// rows scroll by (research 2.3).
#[gtk4::test]
fn every_column_opens_at_a_fixed_width_and_never_expands() {
    let columns: Vec<_> = (0..9)
        .map(|index| named(&format!("c{index}"), "text", index == 0))
        .collect();
    let row = (0..9).map(|index| text(&format!("v{index}"))).collect();

    let grid = Grid::open(columns, vec![row]);

    for index in 0..9 {
        let column = data_column(&grid, index);
        assert!(column.fixed_width() > 0, "column {index} has no width of its own");
        assert!(!column.expands(), "column {index} expands");
    }
}

#[gtk4::test]
fn a_width_set_from_the_keyboard_comes_back_at_that_width() {
    let layouts = Layouts::new();
    let first = laid_out(saved_to(&layouts));
    first.focus(0, 1);
    first.activate("widen-column");
    let saved = *layouts.saved("t").widths.get("name").expect("the step's width saved");
    drop(first);

    let grid = laid_out(saved_to(&layouts));

    assert_eq!(data_column(&grid, 1).fixed_width(), saved);
    wait_until(WAIT, || shown_width(&grid, 1) == saved).expect("the column drawn at its saved width");
}

/// GtkColumnView's header drag sets the fixed width and nothing else, as
/// this does.
#[gtk4::test]
fn a_header_drag_width_is_the_width_drawn_and_saved() {
    let layouts = Layouts::new();
    let grid = laid_out(saved_to(&layouts));

    data_column(&grid, 1).set_fixed_width(200);

    assert_eq!(layouts.saved("t").widths.get("name"), Some(&200));
    wait_until(WAIT, || shown_width(&grid, 1) == 200).expect("the column drawn at the dragged width");
}

#[gtk4::test]
fn a_header_drag_in_editor_results_is_the_width_drawn() {
    let grid = laid_out(Grid::build(
        GridSpec::results(two_text_columns()),
        results(&two_text_values()),
    ));

    data_column(&grid, 1).set_fixed_width(200);

    wait_until(WAIT, || shown_width(&grid, 1) == 200).expect("the column drawn at the dragged width");
}

/// A double click on a header's edge clears the width, which the grid
/// replaces with its own guess.
#[gtk4::test]
fn a_cleared_width_takes_the_grids_guess_and_is_forgotten() {
    let layouts = Layouts::new();
    let grid = saved_to(&layouts);
    let column = data_column(&grid, 1);

    column.set_fixed_width(200);
    column.set_fixed_width(-1);

    wait_until(WAIT, || column.fixed_width() > 0).expect("the grid gives the column a width again");
    assert_ne!(column.fixed_width(), 200);
    assert_eq!(layouts.saved("t").widths.get("name"), None);
    drop((grid, column));
    let reopened = saved_to(&layouts);
    assert_ne!(data_column(&reopened, 1).fixed_width(), 200);
}

#[gtk4::test]
fn a_step_wider_starts_from_the_width_on_screen_and_is_saved() {
    let layouts = Layouts::new();
    let grid = laid_out(saved_to(&layouts));
    grid.focus(0, 1);
    let after = settled_width(&grid, 1) + step(&grid);

    grid.activate("widen-column");

    assert_eq!(data_column(&grid, 1).fixed_width(), after);
    assert_eq!(layouts.saved("t").widths.get("name"), Some(&after));
    wait_until(WAIT, || shown_width(&grid, 1) == after).expect("the column to be drawn wider");
}

#[gtk4::test]
fn a_step_narrower_shrinks_the_column_on_screen() {
    let grid = laid_out(two_text_rows());
    grid.focus(0, 1);
    let after = settled_width(&grid, 1) - step(&grid);

    grid.activate("narrow-column");

    wait_until(WAIT, || shown_width(&grid, 1) == after).expect("the column to be drawn narrower");
}

#[gtk4::test]
fn a_column_is_never_narrower_than_a_step() {
    let grid = two_text_rows();
    data_column(&grid, 1).set_fixed_width(step(&grid) + 1);
    grid.focus(0, 1);

    grid.activate("narrow-column");
    grid.activate("narrow-column");

    assert_eq!(data_column(&grid, 1).fixed_width(), step(&grid));
}

#[gtk4::test]
fn narrow_leaves_a_column_already_narrower_than_a_step() {
    let grid = two_text_rows();
    let narrow = step(&grid) - 1;
    data_column(&grid, 1).set_fixed_width(narrow);
    grid.focus(0, 1);

    grid.activate("narrow-column");

    assert_eq!(
        data_column(&grid, 1).fixed_width(),
        narrow,
        "Narrow made the column wider"
    );
}

/// The menu's Size to Fit, and the header's, give the column the grid's
/// guess and forget the width the user gave it.
#[gtk4::test]
fn size_to_fit_forgets_the_dragged_width() {
    let layouts = Layouts::new();
    let grid = saved_to(&layouts);
    let column = data_column(&grid, 1);
    column.set_fixed_width(300);
    assert_eq!(layouts.saved("t").widths.get("name"), Some(&300));

    assert!(grid.grid.open_cell_menu(&grid.cell_of(1, 1), None));
    grid.activate("size-to-fit");
    close_menus(&grid);

    wait_until(WAIT, || column.fixed_width() > 0).expect("the guess");
    assert_ne!(column.fixed_width(), 300);
    assert_eq!(layouts.saved("t").widths.get("name"), None);

    column.set_fixed_width(300);
    grid.grid
        .activate_action("grid.size-column-to-fit", Some(&1u32.to_variant()))
        .expect("the header's Size to Fit");
    wait_until(WAIT, || column.fixed_width() > 0).expect("the guess");
    assert_ne!(column.fixed_width(), 300);
    assert_eq!(layouts.saved("t").widths.get("name"), None);
}

#[gtk4::test]
fn a_typed_column_is_numbers_by_its_type_alone() {
    let grid = Grid::open(
        vec![named("id", "integer", true), named("code", "text", false)],
        vec![vec![Value::Int(12), text("12")], vec![Value::Int(7), text("7")]],
    );

    assert!(numbers(&grid, 0));
    assert!(!numbers(&grid, 1), "a text column of digits lined up as numbers");
}

#[gtk4::test]
fn an_untyped_column_is_numbers_when_every_value_is_one() {
    let cases: [(Vec<Value>, bool); 7] = [
        (
            vec![
                text("6"),
                text("-18.15"),
                Value::Null,
                text("1e-05"),
                text("NaN"),
                text("Infinity"),
            ],
            true,
        ),
        (vec![Value::Int(2), Value::Float64(0.5)], true),
        (vec![text("6"), text("Coffee")], false),
        (vec![text(" 6")], false),
        (vec![text("")], false),
        (vec![Value::Null], false),
        (Vec::new(), false),
    ];
    let columns = (0..cases.len()).map(|index| untyped(&format!("c{index}"))).collect();
    let rows: Vec<Vec<Value>> = (0..6)
        .map(|row| {
            cases
                .iter()
                .map(|(values, _)| values.get(row).cloned().unwrap_or(Value::Null))
                .collect()
        })
        .collect();

    let grid = Grid::build(GridSpec::results(columns), results(&rows));

    for (index, (values, expected)) in cases.iter().enumerate() {
        assert_eq!(numbers(&grid, index), *expected, "{values:?}");
    }
}

/// A new page only widens a column, so the columns stay put from page
/// to page.
#[gtk4::test]
fn rows_added_later_widen_the_column_and_a_draft_changes_nothing() {
    let grid = Grid::open(
        vec![named("id", "integer", true), named("n", "integer", false)],
        vec![vec![Value::Int(1), Value::Int(123_456)]],
    );
    let opened = data_column(&grid, 1).fixed_width();

    grid.grid
        .append_rows(persisted(&[vec![Value::Int(2), Value::Int(-12_345_678)]]));
    let widened = data_column(&grid, 1).fixed_width();
    grid.insert_draft();

    assert!(widened > opened, "the widest row so far did not widen the column");
    assert_eq!(data_column(&grid, 1).fixed_width(), widened);
}

#[gtk4::test]
fn an_untyped_column_stops_being_numbers_at_the_first_word_added() {
    let grid = Grid::build(GridSpec::results(vec![untyped("tag")]), results(&[vec![text("6")]]));
    assert!(numbers(&grid, 0));

    grid.grid
        .append_rows(results(&[vec![Value::Null], vec![text("Coffee")]]));
    assert!(!numbers(&grid, 0));
    grid.grid.append_rows(results(&[vec![text("7")]]));

    assert!(!numbers(&grid, 0), "one word in the column is enough");
}

#[gtk4::test]
fn a_number_column_is_as_wide_as_its_widest_number() {
    for more_text in [0, 2] {
        let columns = shop_columns(more_text);
        let width = columns.len();
        let rows: Vec<Vec<Value>> = (0..20)
            .map(|offset| shop_row(100_000_001 + offset, "123456789012.3456", width))
            .collect();
        let grid = Grid::open(columns, rows);

        let whole = wait_until(WAIT, || {
            let numbers = drawn(&grid, &NUMBER_COLUMNS);
            !numbers.is_empty() && numbers.iter().all(shows_whole)
        });

        assert!(whole.is_ok(), "a number was cut among {width} columns");
    }
}

/// A count of average characters runs short of capitals and digits.
#[gtk4::test]
fn a_short_code_in_a_text_column_shows_whole() {
    let columns = shop_columns(0);
    let width = columns.len();
    let grid = Grid::open(columns, (1..=5).map(|id| shop_row(id, "1.5", width)).collect());

    let whole = wait_until(WAIT, || {
        let codes = drawn(&grid, &[1]);
        !codes.is_empty()
            && codes.iter().all(|display| {
                let text = display.text().unwrap_or_default();
                display.width() > 0 && display.create_pango_layout(Some(&text)).pixel_size().0 <= display.width()
            })
    });

    assert!(whole.is_ok(), "CF-1001 was cut");
}

#[gtk4::test]
fn adding_a_draft_keeps_the_width_the_page_measured() {
    let columns = shop_columns(0);
    let width = columns.len();
    let mut rows: Vec<Vec<Value>> = (1..=20).map(|id| shop_row(id, "1.5", width)).collect();
    if let Some(last) = rows.last_mut() {
        last[0] = Value::Int(100_000_000_001);
    }
    let grid = Grid::open(columns, rows);
    let measured = data_column(&grid, 0).fixed_width();

    grid.insert_draft();

    assert_eq!(data_column(&grid, 0).fixed_width(), measured);
    let wide = wait_until(WAIT, || {
        let ids = drawn(&grid, &[0]);
        !ids.is_empty()
            && ids
                .iter()
                .all(|display| display.width() >= tabular_width(display, "100000000001"))
    });
    assert!(wide.is_ok(), "the draft narrowed the column its rows had widened");
}

#[gtk4::test]
fn columns_are_freed_with_the_grid() {
    let grid = two_text_rows();
    let column = data_column(&grid, 1).downgrade();
    let view = grid.grid.column_view().downgrade();

    drop(grid);
    drain_main_context();

    assert!(column.upgrade().is_none(), "the column outlived its grid");
    assert!(view.upgrade().is_none(), "the column view outlived its grid");
}

/// GTK 4.22 leaks a reference to the column after the view's focus
/// column as the view removes its columns from the first, and that
/// column's factory holds what its cells draw from.
#[gtk4::test]
fn a_column_left_behind_by_its_view_lets_go_of_the_grid() {
    let grid = two_text_rows();
    grid.focus(0, 0);
    let paints: Vec<std::rc::Weak<ColumnPaint>> = (0..2)
        .filter_map(|index| grid.grid.imp().columns.borrow().paint(index))
        .map(|paint| Rc::downgrade(&paint))
        .collect();
    assert_eq!(paints.len(), 2);
    // GTK 4.22 leaks a focused widget that is hidden and then unparented;
    // the view keeps its focus column.
    gtk::prelude::GtkWindowExt::set_focus(&grid.window, None::<&gtk::Widget>);
    drain_main_context();

    drop(grid);
    drain_main_context();

    assert!(
        paints.iter().all(|paint| paint.upgrade().is_none()),
        "a column the view left behind kept the grid's columns"
    );
}
