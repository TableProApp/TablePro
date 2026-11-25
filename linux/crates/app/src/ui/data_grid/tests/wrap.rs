use gtk4 as gtk;
use gtk4::pango;
use gtk4::prelude::*;
use tablepro_core::Value;

use super::view::asks_tooltip;
use super::{action_names, cell_menu, data_column, row_widget, submenu, text};
use crate::test_support::{MemorySettings, after_next_frame, drain_main_context, wait_until};
use crate::ui::data_grid::test_grid::{Grid, GridSpec, WAIT, two_text_columns};

/// The width the wrapped column is held at, a few words wide.
const COLUMN_PX: i32 = 200;

fn words() -> String {
    "word ".repeat(40).trim_end().to_owned()
}

fn lines(count: usize) -> String {
    (0..count).map(|line| format!("l{line}")).collect::<Vec<_>>().join("\n")
}

fn rows_of(values: &[&str]) -> Grid {
    let rows = values
        .iter()
        .zip(1..)
        .map(|(value, id)| vec![Value::Int(id), text(value)])
        .collect();
    let grid = Grid::open(two_text_columns(), rows);
    data_column(&grid, 1).set_fixed_width(COLUMN_PX);
    after_next_frame(&grid.window);
    grid
}

fn row_height(grid: &Grid, id: i64) -> i32 {
    row_widget(&grid.cell_of(id, 1)).height()
}

/// The height of the first row, which every test keeps one line tall.
fn one_line(grid: &Grid) -> i32 {
    wait_until(WAIT, || row_height(grid, 1) > 0).expect("the rows are laid out");
    row_height(grid, 1)
}

fn wrap_state(grid: &Grid) -> Option<bool> {
    grid.grid
        .actions()
        .action_state("wrap-text")
        .and_then(|state| state.get::<bool>())
}

fn offers_wrap(menu: &impl IsA<gtk::gio::MenuModel>) -> bool {
    action_names(menu.as_ref())
        .iter()
        .any(|action| action == "grid.wrap-text")
}

#[gtk4::test]
fn a_long_value_grows_its_row_and_a_short_one_stays_one_line() {
    let grid = rows_of(&["B", &words(), "one\ntwo\nthree"]);
    let one = one_line(&grid);
    assert_eq!(row_height(&grid, 2), one, "a row was taller before Wrap Text");
    assert_eq!(row_height(&grid, 3), one);

    grid.activate("wrap-text");

    wait_until(WAIT, || {
        row_height(&grid, 2) > row_height(&grid, 3) && row_height(&grid, 3) > one
    })
    .expect("three heights: one line, three lines and a wrapped paragraph");
    assert_eq!(row_height(&grid, 1), one, "a short value's row grew");
    assert_eq!(Grid::display_text(&grid.cell_of(3, 1)), "one\ntwo\nthree");
}

#[gtk4::test]
fn turning_wrap_off_returns_every_row_to_one_line() {
    let grid = rows_of(&["B", &words(), &lines(30)]);
    let one = one_line(&grid);
    grid.activate("wrap-text");
    wait_until(WAIT, || row_height(&grid, 2) > one && row_height(&grid, 3) > one).expect("the rows grow");

    grid.activate("wrap-text");

    wait_until(WAIT, || row_height(&grid, 2) == one && row_height(&grid, 3) == one)
        .expect("the rows go back to one line");
    assert_eq!(wrap_state(&grid), Some(false));
    let cell = grid.cell_of(2, 1);
    assert_eq!(cell.request_mode(), gtk::SizeRequestMode::ConstantSize);
    assert_eq!(Grid::display_text(&cell), words(), "the cell kept a cut text");
}

/// Each grid holds two tall rows, so both stay inside the window: GTK
/// allocates no new height to a row that scrolled out of view.
#[gtk4::test]
fn a_row_stops_at_ten_lines_and_the_text_past_them_ends_in_an_ellipsis() {
    let capped = |value: &str| {
        let grid = rows_of(&["B", &lines(10), value]);
        let one = one_line(&grid);
        grid.activate("wrap-text");
        wait_until(WAIT, || {
            row_height(&grid, 2) > one && row_height(&grid, 3) == row_height(&grid, 2)
        })
        .expect("a value of more than ten lines takes ten lines");
        assert_eq!(Grid::display_text(&grid.cell_of(2, 1)), lines(10), "ten lines were cut");
        Grid::display_text(&grid.cell_of(3, 1))
    };

    // Pango draws no ellipsis when the cut falls on a line break, so the app writes it.
    assert_eq!(capped(&lines(11)), format!("{}…", lines(10)));
    assert_eq!(capped(&lines(50)), format!("{}…", lines(10)));
    let paragraph = capped(&"x".repeat(900));
    assert!(paragraph.ends_with('…') && !paragraph.ends_with("……"), "{paragraph}");
    assert!(paragraph.len() < 900, "the paragraph was not cut");
}

#[gtk4::test]
fn the_cut_at_a_thousand_characters_comes_before_the_cut_at_ten_lines() {
    let grid = rows_of(&["B", &"x".repeat(1_500)]);
    one_line(&grid);
    // Wide enough that the first thousand characters take fewer than ten lines.
    data_column(&grid, 1).set_fixed_width(4_000);

    grid.activate("wrap-text");
    after_next_frame(&grid.window);

    let shown = Grid::display_text(&grid.cell_of(2, 1));
    assert!(shown.ends_with("… (500 more bytes)"), "{}", &shown[990..]);
    assert!(
        asks_tooltip(&grid, &grid.cell_of(2, 1)),
        "a value cut short has no tooltip"
    );
}

#[gtk4::test]
fn a_wrapped_cell_keeps_every_line_break_and_the_other_marks() {
    let grid = rows_of(&["B", "a\u{200b}b\nc", "a\r\nb\u{2028}c\u{85}d\n"]);
    let settings = grid.grid.config().expect("a configured grid").settings.clone();
    assert_eq!(Grid::display_text(&grid.cell_of(2, 1)), "aZWSPbLFc");
    assert_eq!(Grid::display_text(&grid.cell_of(3, 1)), "aCRLFbLSEPcNELdLF");

    grid.activate("wrap-text");
    drain_main_context();

    assert_eq!(Grid::display_text(&grid.cell_of(2, 1)), "aZWSPb\nc");
    assert_eq!(Grid::display_text(&grid.cell_of(3, 1)), "a\nb\nc\nd");

    settings.set_show_invisible_characters(false).expect("store the flag");
    drain_main_context();
    assert_eq!(Grid::display_text(&grid.cell_of(2, 1)), "a\u{200b}b\nc");
    assert_eq!(Grid::display_text(&grid.cell_of(3, 1)), "a\nb\nc\nd");
}

#[gtk4::test]
fn editing_the_tallest_cell_keeps_its_row_height_and_edits_on_the_first_line() {
    let grid = rows_of(&["B", &words()]);
    let one = one_line(&grid);
    grid.activate("wrap-text");
    wait_until(WAIT, || row_height(&grid, 2) > one).expect("the row grows");
    let tall = row_height(&grid, 2);
    let cell = grid.focus(1, 1);

    assert!(grid.grid.edit().edit_cell(&cell), "the cell took no edit");
    let editor = grid.grid.edit().open_text().expect("an inline editor");
    after_next_frame(&grid.window);

    assert_eq!(row_height(&grid, 2), tall, "the row collapsed under its editor");
    let bounds = editor.compute_bounds(&cell).expect("the editor's place in its cell");
    assert!(
        bounds.y() + bounds.height() < cell.height() as f32,
        "the editor fills the tall cell: {bounds:?} in {}",
        cell.height()
    );
    assert!(
        bounds.y() < one as f32,
        "the editor is below the first line: {bounds:?}"
    );
}

#[gtk4::test]
fn only_text_that_can_take_more_than_a_line_asks_for_a_new_size() {
    let grid = rows_of(&["B", &words()]);
    let (short, long) = (grid.cell_of(1, 1), grid.cell_of(2, 1));
    let number = grid.cell_of(2, 0);
    one_line(&grid);
    assert_eq!(long.resize_count(), 0, "a cell asked for a size with Wrap Text off");
    assert_eq!(long.request_mode(), gtk::SizeRequestMode::ConstantSize);
    grid.grid.redraw();
    assert_eq!((short.resize_count(), long.resize_count()), (0, 0));

    grid.activate("wrap-text");
    wait_until(WAIT, || row_height(&grid, 2) > row_height(&grid, 1)).expect("the row grows");
    assert_eq!(long.request_mode(), gtk::SizeRequestMode::HeightForWidth);
    let before = (short.resize_count(), number.resize_count(), long.resize_count());
    let drawn = short.render_count();

    grid.grid.redraw();

    assert!(short.render_count() > drawn, "the cells were not drawn again");
    assert_eq!(short.resize_count(), before.0, "a short value asked for a new size");
    assert_eq!(number.resize_count(), before.1, "a number asked for a new size");
    assert!(long.resize_count() > before.2, "a long value kept its old size");
}

/// With Wrap Text off a value with a line break shows its first line
/// alone, so it is cut even when its longest line fits.
#[gtk4::test]
fn a_cell_has_a_tooltip_when_it_shows_fewer_lines_than_its_text_has() {
    let grid = rows_of(&["B", "ok\nsecond line", &lines(3), &lines(30)]);
    let settings = grid.grid.config().expect("a configured grid").settings.clone();
    settings.set_show_invisible_characters(false).expect("store the flag");
    data_column(&grid, 1).set_fixed_width(400);
    after_next_frame(&grid.window);
    let cell = |id: i64| grid.cell_of(id, 1);

    assert!(
        asks_tooltip(&grid, &cell(2)),
        "a value cut at its first line has no tooltip"
    );
    assert!(!asks_tooltip(&grid, &cell(1)), "a value that fits has a tooltip");

    let one = one_line(&grid);
    grid.activate("wrap-text");
    wait_until(WAIT, || {
        row_height(&grid, 4) > row_height(&grid, 3) && row_height(&grid, 3) > one
    })
    .expect("the rows grow");
    after_next_frame(&grid.window);

    assert!(!asks_tooltip(&grid, &cell(1)));
    assert!(!asks_tooltip(&grid, &cell(2)), "two lines shown in full have a tooltip");
    assert!(
        !asks_tooltip(&grid, &cell(3)),
        "three lines shown in full have a tooltip"
    );
    assert!(asks_tooltip(&grid, &cell(4)), "a value cut at ten lines has no tooltip");
}

#[gtk4::test]
fn a_new_grid_opens_with_the_setting_and_an_open_one_keeps_its_own() {
    let settings = MemorySettings::new();
    let build = || {
        Grid::build(
            GridSpec {
                settings: Some(settings.get().clone()),
                ..GridSpec::table(two_text_columns())
            },
            super::keyed(&[1]),
        )
    };
    let before = build();
    assert_eq!(wrap_state(&before), Some(false));

    settings.get().set_grid_wrap_text(true).expect("store the flag");
    drain_main_context();
    let after = build();

    assert_eq!(wrap_state(&before), Some(false), "an open grid followed the setting");
    assert_eq!(wrap_state(&after), Some(true), "a new grid ignored the setting");
    assert!(after.grid.wraps_text());

    before.activate("wrap-text");
    settings.get().set_grid_wrap_text(false).expect("store the flag");
    drain_main_context();
    assert_eq!(wrap_state(&before), Some(true));
    assert_eq!(wrap_state(&after), Some(true), "an open grid followed the setting");
}

#[gtk4::test]
fn every_grid_menu_offers_wrap_text_and_a_grid_that_does_not_wrap_offers_none() {
    let settings = MemorySettings::new();
    settings.get().set_grid_wrap_text(true).expect("store the flag");
    let build = |wrap_text: bool| {
        Grid::build(
            GridSpec {
                settings: Some(settings.get().clone()),
                wrap_text,
                ..GridSpec::table(two_text_columns())
            },
            super::keyed(&[1]),
        )
    };
    let menus = |grid: &Grid| {
        let column = submenu(&cell_menu(grid), "Colu_mn").expect("the cell menu's Column submenu");
        let header = data_column(grid, 1).header_menu().expect("the header's menu");
        let numbers = grid
            .grid
            .row_numbers_column()
            .and_then(|column| column.header_menu())
            .expect("the row number header's menu");
        [offers_wrap(&column), offers_wrap(&header), offers_wrap(&numbers)]
    };

    let offered = build(true);
    assert_eq!(menus(&offered), [true; 3]);
    assert!(offered.is_enabled("wrap-text"));

    let plain = build(false);
    assert_eq!(menus(&plain), [false; 3]);
    assert_eq!(
        wrap_state(&plain),
        None,
        "a grid that offers no Wrap Text has its action"
    );
    assert!(
        !plain.grid.wraps_text(),
        "the setting wrapped a grid that offers no Wrap Text"
    );
    plain.grid.set_wrap_text(true);
    assert!(!plain.grid.wraps_text());
}

/// What the cell's height rests on: a positive Pango height shows the
/// lines that fit in it, and text cut at a line break gets no ellipsis.
#[gtk4::test]
fn pango_caps_lines_by_height_and_draws_no_ellipsis_at_a_line_break() {
    let ten_lines_of = |text: &str| {
        let layout = gtk::Inscription::new(None).create_pango_layout(Some(text));
        layout.set_width(COLUMN_PX * pango::SCALE);
        layout.set_wrap(pango::WrapMode::WordChar);
        let mut line = layout.iter();
        for _ in 1..10 {
            assert!(line.next_line(), "the text has fewer than ten lines");
        }
        let (_, tenth) = line.line_extents();
        layout.set_ellipsize(pango::EllipsizeMode::End);
        layout.set_height(tenth.y() + tenth.height());
        layout
    };

    let paragraphs = ten_lines_of(&lines(50));
    assert_eq!(paragraphs.line_count(), 10);
    assert!(!paragraphs.is_ellipsized(), "Pango now marks a cut at a line break");

    let paragraph = ten_lines_of(&"x".repeat(1_000));
    assert_eq!(paragraph.line_count(), 10);
    assert!(paragraph.is_ellipsized());
}
