use std::rc::Rc;
use std::sync::Arc;

use gtk4::prelude::*;
use tablepro_core::dialect::SqlDialect;
use tablepro_core::edit::CellInput;
use tablepro_core::{ServerInfo, Value};

use super::{pending, type_into};
use crate::ui::data_grid::test_grid::{Grid, GridSpec, named, persisted};

fn postgres_grid() -> Grid {
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
        persisted(&[vec![Value::Int(1), Value::Null, Value::Text("a".into())]]),
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
