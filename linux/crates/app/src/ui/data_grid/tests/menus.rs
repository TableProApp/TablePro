use gtk4 as gtk;
use gtk4::prelude::*;
use gtk4::{gdk, glib, graphene};
use tablepro_core::Value;
use tablepro_core::edit::CellInput;

use super::{
    accel_of, action_names, cell_menu, close_menus, data_column, keyed, menu_actions, none, press, selected_ids,
    submenu, text,
};
use crate::test_support::{FocusThief, after_next_frame, assert_access_keys, drain_main_context, wait_until};
use crate::ui::data_grid::test_grid::{
    Grid, GridSpec, WAIT, focus_in_grid, key, named, results, two_text_columns, two_text_values,
};
use crate::ui::data_grid::{GridRow, GridSorting};

fn two_text_rows() -> Grid {
    Grid::open(two_text_columns(), two_text_values())
}

fn people() -> Grid {
    Grid::open(
        vec![
            named("id", "integer", true),
            named("name", "text", false),
            named("email", "text", false),
        ],
        vec![
            vec![Value::Int(1), text("Ada"), text("ada@example.com")],
            vec![Value::Int(2), text("Grace"), text("grace@example.com")],
        ],
    )
}

fn shown_menu(grid: &Grid) -> gtk::PopoverMenu {
    let menu = grid
        .grid
        .menus()
        .map(|menus| menus.cell.clone())
        .expect("the cell menu");
    wait_until(WAIT, || menu.is_visible()).expect("the cell menu opens");
    menu
}

/// The cell menu's item for a header item, which names its column.
fn cell_menu_counterpart(header_action: &str) -> &str {
    match header_action {
        "grid.sort-column-ascending" => "grid.sort-ascending",
        "grid.sort-column-descending" => "grid.sort-descending",
        "grid.hide-column-at" => "grid.hide-column",
        "grid.size-column-to-fit" => "grid.size-to-fit",
        "grid.copy-column-name-at" => "grid.copy-column-name",
        other => other,
    }
}

/// The header takes no keyboard focus, so the cell menu offers what its
/// menu does, for the cell's column.
#[gtk4::test]
fn every_header_action_is_in_the_cell_menus_column_submenu() {
    let grid = people();
    let header = data_column(&grid, 1).header_menu().expect("the header's menu");
    let menu = cell_menu(&grid);
    let in_column = action_names(&submenu(&menu, "Colu_mn").expect("the cell menu's Column submenu"));
    let in_cell = action_names(&menu);
    let header_actions = menu_actions(&header);

    assert_eq!(header_actions.len(), 7, "{header_actions:?}");
    for (action, column) in &header_actions {
        assert!(column.is_none_or(|column| column == 1), "{action} names another column");
        let counterpart = cell_menu_counterpart(action.as_str());
        // Copy Column Name sits with the other copies.
        let offered = match counterpart {
            "grid.copy-column-name" => &in_cell,
            _ => &in_column,
        };
        assert!(
            offered.iter().any(|item| item == counterpart),
            "{action} has no {counterpart} in the cell menu"
        );
    }
}

#[gtk4::test]
fn every_grid_menu_gives_each_item_its_own_access_key() {
    let grid = people();
    let empty = grid
        .grid
        .menus()
        .and_then(|menus| menus.empty.as_ref()?.menu_model())
        .expect("the menu below the rows");

    assert_access_keys(&cell_menu(&grid));
    assert_access_keys(&empty);
    assert_access_keys(&data_column(&grid, 1).header_menu().expect("the header's menu"));
    assert_access_keys(&crate::ui::data_grid::grid_menu::row_numbers_header_menu());
}

#[gtk4::test]
fn the_cell_menus_column_items_act_on_its_cell_not_the_focused_one() {
    let grid = people();
    grid.focus(0, 1);
    data_column(&grid, 2).set_fixed_width(300);

    assert!(grid.grid.open_cell_menu(&grid.cell_of(2, 2), None));
    grid.activate("size-to-fit");
    grid.activate("hide-column");
    close_menus(&grid);

    assert_eq!(grid.grid.shown_columns(), [0, 1], "Hide Column hid another column");
    wait_until(WAIT, || data_column(&grid, 2).fixed_width() > 0).expect("Size to Fit gives a width");
    assert_ne!(
        data_column(&grid, 2).fixed_width(),
        300,
        "Size to Fit sized another column"
    );
}

#[gtk4::test]
fn a_grid_in_the_engines_order_offers_no_sort() {
    let sorted = two_text_rows();
    let unsorted = Grid::build(
        GridSpec {
            sorting: GridSorting::None,
            ..GridSpec::table(two_text_columns())
        },
        keyed(&[1, 2]),
    );
    let offered = |grid: &Grid| {
        let mut actions = action_names(&cell_menu(grid));
        actions.extend(action_names(
            &data_column(grid, 1).header_menu().expect("the header's menu"),
        ));
        actions
    };

    for action in [
        "grid.sort-ascending",
        "grid.sort-descending",
        "grid.clear-sort",
        "grid.sort-column-ascending",
        "grid.sort-column-descending",
    ] {
        assert!(offered(&sorted).iter().any(|item| item == action), "{action}");
        assert!(!offered(&unsorted).iter().any(|item| item == action), "{action}");
    }
    assert!(offered(&unsorted).iter().any(|item| item == "grid.edit"));
}

#[gtk4::test]
fn the_cell_menu_shows_the_cell_keys() {
    let grid = two_text_rows();
    let menu = cell_menu(&grid);

    assert_eq!(
        accel_of(&menu, "grid.set-null"),
        Some(Some("<Primary>BackSpace".to_owned()))
    );
    assert_eq!(accel_of(&menu, "grid.edit"), Some(Some("F2".to_owned())));
    assert_eq!(accel_of(&menu, "grid.set-empty"), Some(None));
}

#[gtk4::test]
fn shift_f10_opens_menu_anchored_to_focused_cell() {
    let grid = two_text_rows();
    let cell = grid.focus(1, 1);
    let view = grid.grid.column_view();
    wait_until(WAIT, || {
        cell.compute_bounds(&view)
            .is_some_and(|bounds| bounds.width() > 0.0 && bounds.y() > 0.0)
    })
    .expect("the cell is laid out");

    assert!(press(&grid, gdk::Key::F10, gdk::ModifierType::SHIFT_MASK));

    let menu = shown_menu(&grid);
    let bounds = cell.compute_bounds(&view).expect("the cell's bounds");
    let corner = graphene::Point::new(bounds.x() as i32 as f32, bounds.y() as i32 as f32);
    let corner = view
        .compute_point(&grid.grid, &corner)
        .expect("the cell's corner in the grid");
    let (pointed, rect) = menu.pointing_to();
    assert!(pointed);
    assert_eq!(
        (rect.x(), rect.y(), rect.width(), rect.height()),
        (
            corner.x() as i32,
            corner.y() as i32,
            bounds.width() as i32,
            bounds.height() as i32
        )
    );
    grid.activate("set-null");
    close_menus(&grid);
    assert_eq!(
        grid.tracker.cell_overlay(&key(2), 1).pending,
        Some(CellInput::Value(Value::Null)),
        "the menu acts on another cell"
    );
}

#[gtk4::test]
fn a_result_grid_opens_its_read_only_menu_from_the_keyboard() {
    let grid = Grid::build(
        GridSpec::results(vec![named("id", "integer", true)]),
        results(&[vec![Value::Int(7)]]),
    );
    grid.focus(0, 0);

    assert!(!press(&grid, gdk::Key::Return, none()), "Return edited a result cell");
    assert!(press(&grid, gdk::Key::Menu, none()));

    shown_menu(&grid);
    assert!(!grid.is_enabled("set-null"), "a result grid offers Set to NULL");
    assert!(
        !action_names(&cell_menu(&grid))
            .iter()
            .any(|item| item == "grid.set-null")
    );
    close_menus(&grid);
}

/// A menu holds its rows pinned, so a page that lands meanwhile leaves
/// its edit items acting on nothing.
#[gtk4::test]
fn a_page_that_lands_under_an_open_menu_leaves_its_items_acting_on_nothing() {
    let grid = two_text_rows();
    assert!(grid.grid.open_cell_menu(&grid.cell_of(2, 1), None));

    grid.grid.replace_rows(keyed(&[3, 4]), 0);
    drain_main_context();
    for action in ["set-null", "delete-rows", "duplicate-rows"] {
        grid.activate(action);
    }
    close_menus(&grid);

    assert_eq!(
        grid.tracker.pending_count(),
        0,
        "the menu acted on a row of the new page"
    );
    assert_eq!(grid.grid.store().draft_count(), 0);
}

/// A menu closed, or kept from opening by another client holding the
/// pointer, leaves the focus on a cell. A page that then takes that
/// cell's row out, and the window taking the focus back before the next
/// frame, crashed GTK 4.22 on the detached row.
#[gtk4::test]
fn a_page_under_a_closed_menu_then_a_focus_in_keeps_the_focus_in_the_grid() {
    let grid = two_text_rows();
    grid.focus(0, 1);
    assert!(grid.grid.open_cell_menu(&grid.cell_of(2, 1), None));
    close_menus(&grid);
    wait_until(WAIT, || grid.focused_cell().is_some()).expect("the closed menu left the focus off the grid");
    let thief = FocusThief::take_from(&grid.window).expect("another window takes the focus");

    let store = grid.grid.store();
    let rows: Vec<GridRow> = keyed(&[3, 4]).into_iter().map(GridRow::new).collect();
    store.list().splice(0, store.len(), &rows);
    thief.give_back(&grid.window);
    drain_main_context();
    after_next_frame(&grid.window);

    assert!(focus_in_grid(&grid), "the focus left the grid");
}

/// GTK gives the focus a closed menu held to the first control an ancestor
/// of the grid takes, so Escape or an item left the keyboard off the rows.
#[gtk4::test]
fn a_closed_cell_menu_gives_the_keyboard_back_to_its_cell() {
    let grid = two_text_rows();
    let cell = grid.cell_of(2, 1);
    assert!(grid.grid.open_cell_menu(&cell, None));
    gtk::prelude::GtkWindowExt::set_focus(&grid.window, None::<&gtk::Widget>);

    close_menus(&grid);

    assert_eq!(
        grid.focused_cell(),
        Some(cell),
        "the keyboard did not come back to the cell"
    );
}

/// The header gives the rows the keys that act on a selection, wherever
/// the focus was.
#[gtk4::test]
fn the_row_number_headers_menu_selects_every_row() {
    let grid = people();
    let header = grid
        .grid
        .row_numbers_column()
        .and_then(|column| column.header_menu())
        .expect("the row number header's menu");
    gtk::prelude::GtkWindowExt::set_focus(&grid.window, None::<&gtk::Widget>);

    grid.activate("select-all");

    assert_eq!(action_names(&header), ["grid.select-all", "grid.columns"]);
    assert_eq!(
        accel_of(&header, "grid.select-all"),
        Some(Some("<Primary>a".to_owned()))
    );
    assert_eq!(selected_ids(&grid), [1, 2]);
    wait_until(WAIT, || focus_in_grid(&grid)).expect("the focus stayed off the rows");
}

/// The editor ends its edit, keeping what was typed, and the keys go to
/// the rows rather than to its text.
#[gtk4::test]
fn select_all_rows_takes_the_keyboard_from_an_open_editor() {
    let grid = people();
    let cell = grid.focus(0, 1);
    assert!(grid.grid.edit().edit_cell(&cell), "the cell took no edit");
    grid.grid.edit().open_text().expect("the editor").set_text("Ada L.");
    wait_until(WAIT, || grid.grid.edit().editor_has_focus()).expect("the editor takes the keyboard");

    grid.activate("select-all");

    assert_eq!(selected_ids(&grid), [1, 2]);
    wait_until(WAIT, || {
        grid.grid.edit().editing_cell().is_none() && grid.focused_cell().is_some()
    })
    .expect("the editor kept the keyboard");
    assert_eq!(
        grid.tracker.cell_overlay(&key(1), 1).pending,
        Some(CellInput::Value(Value::Text("Ada L.".to_owned())))
    );
}

#[gtk4::test]
fn the_space_below_the_rows_offers_insert_and_paste_where_rows_can_be_added() {
    let table = two_text_rows();
    let shown = Grid::build(GridSpec::results(two_text_columns()), results(&two_text_values()));

    let empty = table
        .grid
        .menus()
        .and_then(|menus| menus.empty.clone())
        .and_then(|menu| menu.menu_model())
        .expect("the menu below the rows");

    assert_eq!(action_names(&empty), ["grid.insert-row", "grid.paste"]);
    assert!(
        shown.grid.menus().is_some_and(|menus| menus.empty.is_none()),
        "a grid that adds no rows offers to add one"
    );
}

#[gtk4::test]
fn the_grid_takes_its_menus_with_it() {
    let grid = two_text_rows();
    let menus: Vec<glib::WeakRef<gtk::PopoverMenu>> = grid
        .grid
        .menus()
        .map(|menus| {
            [Some(&menus.cell), menus.empty.as_ref(), Some(&menus.reference_chooser)]
                .into_iter()
                .flatten()
                .map(ObjectExt::downgrade)
                .collect()
        })
        .unwrap_or_default();
    assert_eq!(menus.len(), 3);
    assert!(grid.grid.open_cell_menu(&grid.cell_of(1, 1), None));
    close_menus(&grid);

    drop(grid);
    drain_main_context();

    assert!(
        menus.iter().all(|menu| menu.upgrade().is_none()),
        "a menu outlived its grid"
    );
}
