use std::rc::Rc;
use std::sync::Arc;

use gtk4::prelude::*;
use tablepro_core::dialect::SqlDialect;
use tablepro_core::edit::CellInput;
use tablepro_core::{ServerInfo, Value};

use super::{pending, type_into};
use crate::ui::data_grid::test_grid::{Grid, GridSpec, named, persisted};

fn postgres_grid() -> Grid {
    postgres_rows(vec![vec![Value::Int(1), Value::Null, Value::Text("a".into())]])
}

fn postgres_rows(rows: Vec<Vec<Value>>) -> Grid {
    let dialect: Arc<dyn SqlDialect> = Arc::new(tablepro_driver_postgres::PgDialect::new(&ServerInfo::new(
        "PostgreSQL",
        "18.0",
        18,
        0,
        0,
    )));
    Grid::build(
        GridSpec {
            dialect: Some(Rc::new(move || Some(dialect.clone()))),
            ..GridSpec::table(vec![
                named("id", "integer", true),
                named("seen", "timestamp", false),
                named("note", "text", false),
            ])
        },
        persisted(&rows),
    )
}

fn staged(grid: &Grid, column: usize) -> Option<&'static str> {
    match pending(grid, 1, column) {
        Some(CellInput::Expression(expression)) => Some(expression.sql),
        _ => None,
    }
}

fn offered(grid: &Grid, column: usize) -> Vec<String> {
    assert!(grid.grid.open_cell_menu(&grid.cell_of(1, column), None));
    let menus = grid.grid.menus().expect("the grid's menus");
    let expressions = &menus.expressions;
    (0..expressions.n_items())
        .filter_map(|index| {
            expressions
                .item_attribute_value(index, "target", None)?
                .str()
                .map(str::to_owned)
        })
        .collect()
}

fn close_menu(grid: &Grid) {
    if let Some(menus) = grid.grid.menus() {
        menus.cell.popdown();
    }
}

#[gtk4::test]
fn a_typed_expression_is_staged_and_shown_as_its_sql() {
    let grid = postgres_grid();
    let cell = grid.focus(0, 1);

    type_into(&grid, &cell, "NOW()");
    grid.grid.commit_editors();

    assert_eq!(staged(&grid, 1), Some("now()"));
    assert_eq!(Grid::display_text(&grid.cell_of(1, 1)), "now()");
}

#[gtk4::test]
fn the_cell_menu_offers_the_expressions_the_column_takes() {
    let grid = postgres_grid();

    assert_eq!(offered(&grid, 1), ["now()", "CURRENT_TIMESTAMP", "LOCALTIMESTAMP"]);
    grid.grid
        .activate_action("grid.set-expression", Some(&"LOCALTIMESTAMP".to_variant()))
        .expect("the menu's Set to LOCALTIMESTAMP");
    assert_eq!(staged(&grid, 1), Some("LOCALTIMESTAMP"));
    close_menu(&grid);

    assert!(offered(&grid, 2).is_empty(), "a text column offered an expression");
    close_menu(&grid);
}

#[gtk4::test]
fn only_an_expression_from_the_engines_list_is_staged() {
    let grid = postgres_grid();

    let _ = offered(&grid, 1);
    grid.grid
        .activate_action("grid.set-expression", Some(&"now(); DROP TABLE users".to_variant()))
        .expect("the action");
    close_menu(&grid);

    assert_eq!(pending(&grid, 1, 1), None);
}

#[gtk4::test]
fn an_expression_is_staged_in_every_selected_row() {
    let grid = postgres_rows(
        (1..=60)
            .map(|id| vec![Value::Int(id), Value::Null, Value::Text("note".into())])
            .collect(),
    );
    grid.focus(0, 1);
    grid.grid.selection().select_all();
    crate::test_support::drain_main_context();

    grid.grid
        .activate_action("grid.set-expression", Some(&"now()".to_variant()))
        .expect("Set to now()");

    for id in 1..=60 {
        assert!(
            matches!(pending(&grid, id, 1), Some(CellInput::Expression(expression)) if expression.sql == "now()"),
            "row {id}"
        );
    }
    grid.grid.undo();
    assert_eq!(grid.tracker.pending_count(), 0);
    assert!(!grid.tracker.can_undo());
    grid.grid.redo();
    assert_eq!(grid.tracker.pending_count(), 60);
}

#[gtk4::test]
fn expressions_remain_available_with_a_locked_focused_row() {
    use crate::services::tracker_edit::TrackerEdit;
    use crate::ui::data_grid::test_grid::key;
    let grid = postgres_rows(vec![
        vec![Value::Int(1), Value::Null, Value::Text("a".into())],
        vec![Value::Int(2), Value::Null, Value::Text("b".into())],
    ]);
    let delta = grid.tracker.apply(TrackerEdit::DeleteRows {
        persisted: vec![(key(1), Arc::from([Value::Int(1), Value::Null, Value::Text("a".into())]))],
        drafts: vec![],
    });
    grid.grid.apply_delta(&delta);
    grid.focus(0, 1);
    grid.grid.selection().select_all();
    crate::test_support::drain_main_context();
    assert!(offered(&grid, 1).iter().any(|sql| sql == "now()"));
    grid.grid
        .activate_action("grid.set-expression", Some(&"now()".to_variant()))
        .expect("Set to now()");
    close_menu(&grid);
    assert_eq!(pending(&grid, 1, 1), None);
    assert!(matches!(pending(&grid, 2, 1), Some(CellInput::Expression(expression)) if expression.sql == "now()"));
    assert_eq!(
        super::toasts(&grid),
        ["1 row can't take this value and was left as it was"]
    );
}

#[gtk4::test]
fn an_unlisted_expression_changes_none_of_the_selected_rows() {
    let grid = postgres_rows(vec![
        vec![Value::Int(1), Value::Null, Value::Text("a".into())],
        vec![Value::Int(2), Value::Null, Value::Text("b".into())],
    ]);
    grid.focus(0, 1);
    grid.grid.selection().select_all();
    crate::test_support::drain_main_context();
    grid.grid
        .activate_action("grid.set-expression", Some(&"now(); DROP TABLE users".to_variant()))
        .expect("the action");
    assert_eq!(grid.tracker.pending_count(), 0);
    assert!(!grid.tracker.can_undo());
}
