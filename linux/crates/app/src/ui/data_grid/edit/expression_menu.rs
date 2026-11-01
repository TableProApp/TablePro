use gtk4::gio;
use gtk4::prelude::*;
use tablepro_core::edit::{CellExpression, CellInput, cell_expressions};

use super::{EditController, edit_start};
use crate::i18n::gettext_f;
use crate::ui::data_grid::{DataGrid, GridCell, GridRow};
use crate::ui::menu_label;

pub(super) const SET_EXPRESSION: &str = "set-expression";

impl EditController {
    /// Fill the cell menu's expression items for `cell` as the menu opens;
    /// a row or the space below the rows offers none.
    pub(crate) fn arm_expressions(&self, grid: &DataGrid, cell: Option<&GridCell>) {
        let Some(menus) = grid.menus() else {
            return;
        };
        menus.expressions.remove_all();
        let Some((row, column)) = cell.and_then(|cell| Some((cell.row()?, cell.column()))) else {
            return;
        };
        for expression in self.expressions_for(grid, &row, column) {
            let label = gettext_f("Set to {expression}", &[("expression", &menu_label(expression.sql))]);
            let item = gio::MenuItem::new(Some(&label), None);
            item.set_action_and_target_value(
                Some(&format!("grid.{SET_EXPRESSION}")),
                Some(&expression.sql.to_variant()),
            );
            menus.expressions.append_item(&item);
        }
    }

    /// The menu item names its expression by its SQL, which is looked up
    /// in the engine's list again, so only that list reaches a statement.
    pub(super) fn set_expression(&self, grid: &DataGrid, sql: &str) {
        let Some((row, column)) = grid.target().and_then(|target| target.cell) else {
            return;
        };
        let Some(grid_column) = self.unlocked_column(grid, &row, column) else {
            return;
        };
        let Some(expression) = self
            .expressions_for(grid, &row, column)
            .into_iter()
            .find(|expression| expression.sql == sql)
        else {
            return;
        };
        grid.commit_editors();
        let start = edit_start(&self.tracked(), &row, column);
        self.commit_input(grid, &grid_column, &start, CellInput::Expression(expression));
    }

    fn expressions_for(&self, grid: &DataGrid, row: &GridRow, column: usize) -> Vec<CellExpression> {
        let Some(grid_column) = grid.grid_columns().get(column).cloned() else {
            return Vec::new();
        };
        let editable = self.policy().is_some_and(|policy| policy.cells.is_ok())
            && self.tracked().lock(&grid_column, row).is_none();
        match (editable, grid.sql_dialect(), grid_column.catalog.as_ref()) {
            (true, Some(dialect), Some(catalog)) => cell_expressions(dialect.as_ref(), &catalog.column_type),
            _ => Vec::new(),
        }
    }
}
