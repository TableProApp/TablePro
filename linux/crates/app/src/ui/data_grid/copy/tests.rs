use std::rc::Rc;
use std::sync::Arc;

use gtk4 as gtk;
use gtk4::prelude::*;
use gtk4::{gdk, gio};
use libadwaita as adw;
use libadwaita::prelude::*;
use tablepro_core::dialect::SqlDialect;
use tablepro_core::edit::CellInput;
use tablepro_core::meta::TableRef;
use tablepro_core::{ColumnInfo, FilterOp, FilterRule, FilterValue, Value};
use tablepro_test_support::FakeDialect;

use crate::application::ShortcutOwner;
use crate::services::tab_tracker_handle::TabTrackerHandle;
use crate::services::tracker_edit::TrackerEdit;
use crate::test_support::shortcut_keys::{keystroke, owner_controller, shortcuts, trigger_keys};
use crate::test_support::{descendants, drain_main_context, wait_until};
use crate::ui::data_grid::test_grid::{
    Grid, GridSpec, WAIT, key, named, page, persisted, results, two_text_columns, two_text_values,
};
use crate::ui::data_grid::{DataGrid, GridCell, GridRequest};
use crate::ui::export::ExportSource;

const BEFORE: &str = "nothing copied yet";

/// What a copy test drives: a grid and the requests it made.
trait Copies {
    fn data_grid(&self) -> &DataGrid;
    fn requests(&self) -> Vec<GridRequest>;
}

impl Copies for Grid {
    fn data_grid(&self) -> &DataGrid {
        &self.grid
    }

    fn requests(&self) -> Vec<GridRequest> {
        self.take_requests()
    }
}

fn local_text(clipboard: &gdk::Clipboard) -> Option<String> {
    clipboard.content()?.value(String::static_type()).ok()?.get().ok()
}

fn toasts(requests: Vec<GridRequest>) -> Vec<String> {
    requests
        .into_iter()
        .filter_map(|request| match request {
            GridRequest::Toast(text) => Some(text),
            _ => None,
        })
        .collect()
}

/// What the clipboard holds once the copy `act` starts has landed, which
/// its toast says.
fn copied(grid: &impl Copies, act: impl FnOnce()) -> String {
    let clipboard = grid.data_grid().clipboard();
    clipboard.set_text(BEFORE);
    act();
    let mut said = Vec::new();
    wait_until(WAIT, || {
        said.extend(toasts(grid.requests()));
        !said.is_empty()
    })
    .expect("the copy to land");
    local_text(&clipboard).unwrap_or_else(|| panic!("nothing on the clipboard; toasts: {said:?}"))
}

fn activate(grid: &DataGrid, action: &str) {
    grid.activate_action(&format!("grid.{action}"), None)
        .unwrap_or_else(|_| panic!("the grid has no {action}"));
    drain_main_context();
}

/// Copy from the cell menu opened on `cell`, then close it.
fn from_menu(grid: &DataGrid, cell: &GridCell, action: &str) {
    assert!(grid.open_cell_menu(cell, None), "the menu opens");
    activate(grid, action);
    if let Some(menus) = grid.menus() {
        menus.cell.popdown();
    }
    drain_main_context();
}

/// Run what `accel` does on the focused cell, as a key press reaching the
/// grid's controller would. `true` when the grid took the key.
fn press(grid: &DataGrid, owner: ShortcutOwner, accel: &str) -> bool {
    let widget: gtk::Widget = match owner {
        ShortcutOwner::GridCell => grid.column_view().upcast(),
        _ => grid.clone().upcast(),
    };
    let controller = owner_controller(&widget, owner).expect("the grid's keys");
    let action = shortcuts(&controller)
        .into_iter()
        .find(|shortcut| {
            shortcut
                .trigger()
                .is_some_and(|trigger| trigger_keys(&trigger).contains(&keystroke(accel)))
        })
        .and_then(|shortcut| shortcut.action())
        .expect("the grid binds the key");
    action.activate(gtk::ShortcutActionFlags::empty(), &widget, None)
}

fn no_focus(grid: &Grid) {
    gtk::prelude::GtkWindowExt::set_focus(&grid.window, None::<&gtk::Widget>);
    drain_main_context();
}

fn people() -> Vec<ColumnInfo> {
    vec![
        named("id", "integer", true),
        named("name", "text", false),
        named("age", "integer", false),
    ]
}

fn people_rows() -> Vec<Vec<Value>> {
    vec![
        vec![Value::Int(1), Value::Text("Ada".into()), Value::Int(36)],
        vec![Value::Int(2), Value::Text("Grace".into()), Value::Int(85)],
    ]
}

fn rename(tracker: &TabTrackerHandle, id: i64, from: &str, to: &str) -> crate::services::tracker_delta::TrackerDelta {
    tracker.apply(TrackerEdit::Cell {
        row_key: key(id),
        col: 1,
        original: Value::Text(from.into()),
        value: Value::Text(to.into()),
    })
}

fn accel_of(menu: &gio::MenuModel, action: &str) -> Option<Option<String>> {
    for position in 0..menu.n_items() {
        let named = menu
            .item_attribute_value(position, "action", None)
            .and_then(|value| value.get::<String>());
        if named.as_deref() == Some(action) {
            return Some(
                menu.item_attribute_value(position, "accel", None)
                    .and_then(|value| value.get::<String>()),
            );
        }
        for link in ["section", "submenu"] {
            if let Some(found) = menu
                .item_link(position, link)
                .and_then(|inner| accel_of(&inner, action))
            {
                return Some(found);
            }
        }
    }
    None
}

/// D2: every grid binds Ctrl+C, not only the table tab's.
#[gtk4::test]
fn ctrl_c_in_a_read_only_results_grid_copies() {
    let grid = Grid::build(GridSpec::results(two_text_columns()), results(&two_text_values()));
    grid.focus(1, 1);

    let text = copied(&grid, || {
        assert!(press(&grid.grid, ShortcutOwner::Grid, "<Primary>c"), "Ctrl+C went by");
    });

    assert_eq!(text, "B");
}

/// D3: the key and the menu item are one action, so they copy the same
/// thing: the cell for one row, the rows for several.
#[gtk4::test]
fn ctrl_c_and_the_menus_copy_copy_the_same() {
    let grid = Grid::open(two_text_columns(), two_text_values());
    let cell = grid.focus(0, 1);
    let by_key = copied(&grid, || {
        press(&grid.grid, ShortcutOwner::Grid, "<Primary>c");
    });
    let by_menu = copied(&grid, || from_menu(&grid.grid, &cell, "copy"));
    grid.grid.selection().select_all();
    let cell = grid.focus(0, 1);
    let rows_by_key = copied(&grid, || {
        press(&grid.grid, ShortcutOwner::Grid, "<Primary>c");
    });
    let rows_by_menu = copied(&grid, || from_menu(&grid.grid, &cell, "copy"));

    assert_eq!((by_key.as_str(), by_menu.as_str()), ("A", "A"));
    assert_eq!(rows_by_key, "1\tA\n2\tB\n");
    assert_eq!(rows_by_menu, rows_by_key);
    let menu = grid
        .grid
        .menus()
        .and_then(|menus| menus.cell.menu_model())
        .expect("the cell menu");
    assert_eq!(accel_of(&menu, "grid.copy"), Some(Some("<Primary>c".to_owned())));
}

#[gtk4::test]
fn copy_is_off_once_a_page_takes_the_selection_away() {
    let grid = Grid::build(GridSpec::table(two_text_columns()), page(0..100));
    no_focus(&grid);

    grid.grid.selection().select_range(0, 2, true);
    let with_rows = (grid.is_enabled("copy"), grid.is_enabled("copy-rows"));
    grid.grid.replace_rows(page(100..102), 100);
    drain_main_context();

    assert_eq!(with_rows, (true, true));
    assert!(grid.grid.selection().selection().is_empty());
    assert!(!grid.is_enabled("copy"), "Ctrl+C stayed on with nothing selected");
    assert!(!grid.is_enabled("copy-rows"));
}

/// The rows leave as the user arranged them: a dragged column where it
/// was dropped, a hidden one left out, pending edits in.
#[gtk4::test]
fn copies_and_exports_follow_a_moved_and_a_hidden_column() {
    let grid = Grid::open(people(), people_rows());
    let name = grid.grid.data_view_column(1).expect("the name column");
    let row_numbers = grid.grid.row_numbers_column().expect("the row numbers");
    let view = grid.grid.column_view();
    let after_numbers = (0..view.columns().n_items())
        .find(|position| view.columns().item(*position).as_ref() == Some(row_numbers.upcast_ref()))
        .map_or(0, |position| position + 1);
    view.insert_column(after_numbers, &name);
    grid.grid.set_column_visible(2, false);
    grid.grid
        .apply_delta(&rename(&grid.tracker, 2, "Grace", "Grace Hopper"));
    drain_main_context();
    grid.grid.selection().select_all();
    no_focus(&grid);

    let rows = copied(&grid, || activate(&grid.grid, "copy-rows-headers"));
    activate(&grid.grid, "export");
    let exported = grid.take_requests().into_iter().find_map(|request| match request {
        GridRequest::Export(ExportSource::Rows { columns, rows }) => Some((columns, rows)),
        _ => None,
    });

    assert_eq!(grid.grid.shown_columns(), [1, 0]);
    assert_eq!(rows, "name\tid\nAda\t1\nGrace Hopper\t2\n");
    let (columns, rows) = exported.expect("an export of the rows");
    let names: Vec<&str> = columns.iter().map(|column| column.name.as_str()).collect();
    assert_eq!(names, ["name", "id"]);
    let values: Vec<Vec<Value>> = rows.iter().map(|row| row.to_values()).collect();
    assert_eq!(
        values,
        [
            vec![Value::Text("Ada".into()), Value::Int(1)],
            vec![Value::Text("Grace Hopper".into()), Value::Int(2)],
        ]
    );
}

#[gtk4::test]
fn an_export_of_every_column_in_place_shares_the_rows_cells() {
    let grid = Grid::open(people(), people_rows());

    activate(&grid.grid, "export");
    let exported = grid
        .take_requests()
        .into_iter()
        .find_map(|request| match request {
            GridRequest::Export(ExportSource::Rows { rows, .. }) => Some(rows),
            _ => None,
        })
        .expect("an export of the rows");

    let held: Vec<_> = grid.grid.store().rows().filter_map(|row| row.data().cells).collect();
    assert_eq!(exported.len(), held.len());
    for (snapshot, cells) in exported.iter().zip(&held) {
        assert!(snapshot.shares_cells_with(cells), "a saved row's cells were copied");
    }
}

#[gtk4::test]
fn copy_after_a_sort_takes_the_row_on_screen() {
    let rows = vec![
        vec![Value::Int(3), Value::Text("c".into())],
        vec![Value::Int(1), Value::Text("a".into())],
        vec![Value::Int(2), Value::Text("b".into())],
    ];
    let grid = Grid::build(GridSpec::results(two_text_columns()), results(&rows));
    grid.grid.sort_by(Some((0, true)));
    let first = || {
        grid.cells()
            .into_iter()
            .find(|cell| cell.position() == Some(0) && cell.column() == 1)
    };
    wait_until(WAIT, || first().is_some_and(|cell| Grid::display_text(&cell) == "a"))
        .expect("the sorted rows are drawn");

    let text = copied(&grid, || {
        from_menu(&grid.grid, &first().expect("the first row's cell"), "copy")
    });

    assert_eq!(text, "a");
}

/// The rule names the value the cell holds, never the text it draws: a
/// NULL is a NULL test and a long value goes whole.
#[gtk4::test]
fn filter_by_value_builds_eq_and_is_null_rules_from_the_value() {
    let long = "x".repeat(1_500);
    let grid = Grid::open(
        two_text_columns(),
        vec![
            vec![Value::Int(1), Value::Text("Ada".into())],
            vec![Value::Int(2), Value::Null],
            vec![Value::Int(3), Value::Text(long.clone())],
        ],
    );
    let rule = |op: FilterOp, value: Option<&str>| FilterRule {
        column: "name".to_owned(),
        op,
        value: value.map(|text| FilterValue::Single(text.to_owned())),
    };

    for (id, action) in [
        (1, "filter-by-value"),
        (1, "exclude-value"),
        (2, "filter-by-value"),
        (2, "exclude-value"),
        (3, "filter-by-value"),
    ] {
        from_menu(&grid.grid, &grid.cell_of(id, 1), action);
    }
    let rules: Vec<FilterRule> = grid
        .take_requests()
        .into_iter()
        .filter_map(|request| match request {
            GridRequest::FilterByValue(rule) => Some(rule),
            _ => None,
        })
        .collect();

    assert_eq!(
        rules,
        [
            rule(FilterOp::Eq, Some("Ada")),
            rule(FilterOp::NotEq, Some("Ada")),
            rule(FilterOp::IsNull, None),
            rule(FilterOp::IsNotNull, None),
            rule(FilterOp::Eq, Some(&long)),
        ]
    );
}

#[gtk4::test]
fn a_results_grid_offers_no_filter_by_value() {
    let grid = Grid::build(GridSpec::results(two_text_columns()), results(&two_text_values()));

    grid.grid.open_cell_menu(&grid.cell_at(0, 1), None);
    let offered = (grid.is_enabled("filter-by-value"), grid.is_enabled("exclude-value"));
    if let Some(menus) = grid.grid.menus() {
        menus.cell.popdown();
    }

    assert_eq!(offered, (false, false));
}

/// CQL matches a text column by equality but has no `!=` and no NULL test.
#[gtk4::test]
fn filter_by_value_offers_only_what_the_engine_filters() {
    let cassandra =
        tablepro_driver_cassandra::CqlDialect::new(&tablepro_core::ServerInfo::new("Cassandra", "5.0.9", 5, 0, 9));
    let grid = sql_grid(
        two_text_columns(),
        vec![
            vec![Value::Int(1), Value::Text("Ada".into())],
            vec![Value::Int(2), Value::Null],
        ],
        Arc::new(cassandra),
    );
    let offered = |id: i64| {
        grid.grid.open_cell_menu(&grid.cell_of(id, 1), None);
        let offered = (grid.is_enabled("filter-by-value"), grid.is_enabled("exclude-value"));
        if let Some(menus) = grid.grid.menus() {
            menus.cell.popdown();
        }
        offered
    };

    assert_eq!(offered(1), (true, false));
    assert_eq!(offered(2), (false, false));
}

#[gtk4::test]
fn a_page_that_lands_under_an_open_menu_leaves_its_items_acting_on_nothing() {
    let grid = Grid::open(two_text_columns(), two_text_values());
    let clipboard = grid.grid.clipboard();
    clipboard.set_text(BEFORE);
    let actions = [
        "copy",
        "copy-rows",
        "copy-column-name",
        "show-row-json",
        "filter-by-value",
    ];
    grid.grid.open_cell_menu(&grid.cell_of(2, 1), None);
    let before: Vec<bool> = actions.iter().map(|action| grid.is_enabled(action)).collect();

    grid.grid.replace_rows(page(3..5), 0);
    drain_main_context();
    let after: Vec<bool> = actions.iter().map(|action| grid.is_enabled(action)).collect();
    for action in actions {
        activate(&grid.grid, action);
    }
    if let Some(menus) = grid.grid.menus() {
        menus.cell.popdown();
    }
    drain_main_context();

    assert_eq!(before, [true; 5]);
    assert_eq!(after, [false; 5]);
    let acted = grid
        .take_requests()
        .into_iter()
        .any(|request| matches!(request, GridRequest::Toast(_) | GridRequest::FilterByValue(_)));
    assert!(!acted, "the menu acted on a row of the new page");
    assert_eq!(local_text(&clipboard).as_deref(), Some(BEFORE));
}

/// The list hands its cell widgets on to other rows as it scrolls, all but
/// the focused one, which the right click moved to the clicked cell.
#[gtk4::test]
fn a_scroll_under_an_open_menu_leaves_it_on_its_row() {
    let grid = Grid::build(GridSpec::table(two_text_columns()), page(0..300));
    let clicked = grid.cell_of(6, 1);
    let below = grid.cell_of(7, 1);
    grid.grid.open_cell_menu(&clicked, None);

    grid.grid
        .column_view()
        .scroll_to(299, None, gtk::ListScrollFlags::NONE, None);
    wait_until(WAIT, || below.row().is_some_and(|row| row.key() != Some(key(7))))
        .expect("the scroll did not rebind the cells it left");
    let text = copied(&grid, || activate(&grid.grid, "copy"));
    if let Some(menus) = grid.grid.menus() {
        menus.cell.popdown();
    }

    assert_eq!(clicked.row().and_then(|row| row.key()), Some(key(6)));
    assert_eq!(text, "row 6");
}

#[gtk4::test]
fn copy_column_name_takes_the_menus_column_or_the_headers() {
    let grid = Grid::open(two_text_columns(), two_text_values());

    let from_cell = copied(&grid, || from_menu(&grid.grid, &grid.cell_of(1, 1), "copy-column-name"));
    let from_header = copied(&grid, || {
        grid.grid
            .activate_action("grid.copy-column-name-at", Some(&0u32.to_variant()))
            .expect("the header's Copy Column Name");
    });

    assert_eq!((from_cell.as_str(), from_header.as_str()), ("name", "id"));
}

#[gtk4::test]
fn show_row_json_shows_the_row_under_the_columns_on_screen() {
    adw::init().expect("libadwaita initialises under the test backend");
    let grid = Grid::open(people(), people_rows());
    grid.grid.set_column_visible(2, false);
    grid.grid.apply_delta(&rename(&grid.tracker, 1, "Ada", "Ada Lovelace"));

    from_menu(&grid.grid, &grid.cell_of(1, 0), "show-row-json");
    let text = |view: &sourceview5::View| {
        let buffer = view.buffer();
        buffer.text(&buffer.start_iter(), &buffer.end_iter(), false).to_string()
    };
    let mut shown = None;
    wait_until(WAIT, || {
        shown = gtk::Window::list_toplevels()
            .into_iter()
            .flat_map(|window| descendants(&window))
            .filter_map(|widget| widget.downcast::<sourceview5::View>().ok())
            .find(|view| text(view).contains("Ada Lovelace"));
        shown.is_some()
    })
    .expect("the row's JSON is shown");
    let view = shown.expect("the JSON view");
    let json = text(&view);
    if let Some(dialog) = view.ancestor(adw::Dialog::static_type()).and_downcast::<adw::Dialog>() {
        dialog.force_close();
    }

    assert!(json.contains("\"Ada Lovelace\""), "{json}");
    assert!(json.contains("\"id\": 1"), "{json}");
    assert!(!json.contains("age"), "a hidden column was shown: {json}");
}

/// A table grid that writes SQL: Copy As INSERT and IN Clause need the
/// connection's dialect and the table.
fn sql_grid(columns: Vec<ColumnInfo>, rows: Vec<Vec<Value>>, dialect: Arc<dyn SqlDialect>) -> Grid {
    Grid::build(
        GridSpec {
            dialect: Some(Rc::new(move || Some(dialect.clone()))),
            table: Some(TableRef::new(None, "users")),
            ..GridSpec::table(columns)
        },
        persisted(&rows),
    )
}

fn select_all(grid: &Grid) {
    gtk::prelude::GtkWindowExt::set_focus(&grid.window, None::<&gtk::Widget>);
    grid.grid.selection().select_all();
    drain_main_context();
}

fn mysql() -> Arc<dyn SqlDialect> {
    Arc::new(tablepro_driver_mysql::MySqlDialect::new(
        tablepro_driver_mysql::MySqlFlavour::MySql,
        &tablepro_core::ServerInfo::new("MySQL", "8.4.3", 8, 4, 3),
    ))
}

#[gtk4::test]
fn copy_as_insert_writes_the_columns_on_screen_with_pending_edits() {
    let grid = sql_grid(people(), people_rows(), Arc::new(FakeDialect));
    grid.grid.set_column_visible(2, false);
    grid.grid
        .apply_delta(&rename(&grid.tracker, 2, "Grace", "Grace Hopper"));
    select_all(&grid);

    let text = copied(&grid, || activate(&grid.grid, "copy-insert"));

    assert_eq!(
        text,
        "INSERT INTO \"users\" (\"id\", \"name\") VALUES (1, 'Ada');\n\
         INSERT INTO \"users\" (\"id\", \"name\") VALUES (2, 'Grace Hopper');"
    );
}

#[gtk4::test]
fn copy_as_insert_on_a_draft_leaves_what_the_server_fills_out() {
    let mut id = named("id", "integer", true);
    id.is_auto_increment = true;
    let columns = vec![
        id,
        named("name", "text", false),
        named("created_at", "timestamptz", false),
    ];
    let grid = sql_grid(
        columns,
        vec![vec![Value::Int(1), Value::Text("Ada".into()), Value::Null]],
        Arc::new(FakeDialect),
    );
    let delta = grid.tracker.apply(TrackerEdit::InsertDrafts {
        rows: vec![vec![
            CellInput::Default,
            CellInput::Value(Value::Text("x".into())),
            CellInput::Default,
        ]],
    });
    grid.grid.apply_delta(&delta);
    let mut draft = None;
    wait_until(WAIT, || {
        draft = grid
            .find_cell(0, 1)
            .filter(|cell| cell.row().is_some_and(|row| row.draft_id().is_some()));
        draft.is_some()
    })
    .expect("the draft goes on top");
    let draft = draft.expect("the draft's cell");

    let text = copied(&grid, || from_menu(&grid.grid, &draft, "copy-insert"));

    assert_eq!(text, "INSERT INTO \"users\" (\"name\") VALUES ('x');");
}

#[gtk4::test]
fn copy_as_insert_is_off_in_a_grid_with_no_table_to_write_into() {
    let table = Grid::open(two_text_columns(), two_text_values());
    let read_only = Grid::build(GridSpec::results(two_text_columns()), results(&two_text_values()));

    for grid in [&table, &read_only] {
        grid.grid.selection().select_all();
    }

    assert!(!table.is_enabled("copy-insert"), "a grid with no dialect or table");
    assert!(!read_only.is_enabled("copy-insert"));
}

/// MySQL reads a backslash in a string as an escape, so the list is
/// written in the server's own literals.
#[gtk4::test]
fn copy_as_in_clause_writes_the_servers_literals() {
    let injected = "\\') OR 1=1 -- ";
    let grid = sql_grid(
        two_text_columns(),
        vec![
            vec![Value::Int(1), Value::Text(injected.into())],
            vec![Value::Int(2), Value::Null],
        ],
        mysql(),
    );
    select_all(&grid);
    let cell = grid.cell_at(0, 1);

    let text = copied(&grid, || from_menu(&grid.grid, &cell, "copy-in-clause"));

    assert_eq!(
        text,
        format!(
            "(_utf8mb4 X'{}')",
            tablepro_core::hex::encode_lower(injected.as_bytes())
        )
    );
}

#[gtk4::test]
fn in_clause_is_offered_only_for_a_dialect_that_speaks_sql() {
    let mongo = sql_grid(
        two_text_columns(),
        two_text_values(),
        Arc::new(tablepro_driver_mongodb::MongoDialect),
    );
    let none = Grid::build(GridSpec::results(two_text_columns()), results(&two_text_values()));
    let sql = sql_grid(two_text_columns(), two_text_values(), Arc::new(FakeDialect));
    let offered = |grid: &DataGrid, cell: &GridCell| {
        grid.open_cell_menu(cell, None);
        let enabled = grid
            .actions()
            .lookup_action("copy-in-clause")
            .is_some_and(|action| action.is_enabled());
        if let Some(menus) = grid.menus() {
            menus.cell.popdown();
        }
        drain_main_context();
        enabled
    };

    let in_mongo = offered(&mongo.grid, &mongo.cell_at(0, 1));
    let in_results = offered(&none.grid, &none.cell_at(0, 1));
    let in_sql = offered(&sql.grid, &sql.cell_at(0, 1));

    assert_eq!((in_mongo, in_results, in_sql), (false, false, true));
}
