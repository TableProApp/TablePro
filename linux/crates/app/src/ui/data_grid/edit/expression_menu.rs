use gtk4::gio;
use gtk4::prelude::*;
use tablepro_core::edit::{CellExpression, CellInput, cell_expressions};

use super::EditController;
use crate::i18n::gettext_f;
use crate::ui::data_grid::{DataGrid, GridCell, GridRow};
use crate::ui::menu_label;

pub(super) const SET_EXPRESSION: &str = "set-expression";

impl EditController {
    pub(crate) fn arm_expressions(&self, grid: &DataGrid, cell: Option<&GridCell>) {
        let Some(menus) = grid.menus() else {
            return;
        };
        menus.expressions.remove_all();
        let (Some(column), Some(target)) = (cell.map(GridCell::column), grid.target()) else {
            return;
        };
        let expressions = target
            .rows
            .iter()
            .find_map(|row| {
                let expressions = self.expressions_for(grid, row, column);
                (!expressions.is_empty()).then_some(expressions)
            })
            .unwrap_or_default();
        for expression in expressions {
            let label = gettext_f("Set to {expression}", &[("expression", &menu_label(expression.sql))]);
            let item = gio::MenuItem::new(Some(&label), None);
            item.set_action_and_target_value(
                Some(&format!("grid.{SET_EXPRESSION}")),
                Some(&expression.sql.to_variant()),
            );
            menus.expressions.append_item(&item);
        }
    }

    pub(super) fn set_expression(&self, grid: &DataGrid, sql: &str) {
        self.set_values(grid, |row, column| {
            let Some(grid_column) = self.unlocked_column(grid, row, column) else {
                return Ok(None);
            };
            // Recheck the engine's list so an action parameter cannot introduce SQL.
            let expression = self
                .expressions_for(grid, row, column)
                .into_iter()
                .find(|expression| expression.sql == sql);
            Ok(expression.map(|expression| (grid_column, CellInput::Expression(expression))))
        });
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
