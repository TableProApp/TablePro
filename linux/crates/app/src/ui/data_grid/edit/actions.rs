use super::{EditController, cell_widget};
use crate::services::grid::{
    CellEditorKind, CellPreset, CellPresets, DeleteAvailability, GridRowId, cell_presets, delete_availability,
};
use crate::ui::data_grid::grid_actions::{add, enable};
use crate::ui::data_grid::selection::Resolved;
use crate::ui::data_grid::{DataGrid, GridRow};

/// Installed on every grid, so a key that names one finds it; a grid
/// that edits nothing keeps them off.
pub(super) fn install(grid: &DataGrid) {
    add(grid, "edit", |grid| {
        if let Some((row, column)) = grid.target().and_then(|target| target.cell)
            && let Some(cell) = cell_widget(grid, &row, column)
        {
            grid.edit().edit_cell(&cell);
        }
    });
    add(grid, "toggle", |grid| grid.edit().toggle_target(grid));
    add(grid, "set-empty", |grid| {
        grid.edit().set_preset(grid, CellPreset::Empty)
    });
    add(grid, "set-null", |grid| grid.edit().set_preset(grid, CellPreset::Null));
    add(grid, "set-default", |grid| {
        grid.edit().set_preset(grid, CellPreset::Default)
    });
    add(grid, "insert-row", |grid| grid.edit().insert_row(grid));
    add(grid, "duplicate-rows", |grid| grid.edit().duplicate_rows(grid));
    add(grid, "delete-rows", |grid| grid.edit().delete_rows(grid));
    add(grid, "paste", |grid| grid.edit().paste(grid));
}

const ACTIONS: [&str; 9] = [
    "edit",
    "toggle",
    "set-empty",
    "set-null",
    "set-default",
    "insert-row",
    "duplicate-rows",
    "delete-rows",
    "paste",
];

pub(super) fn refresh(controller: &EditController, grid: &DataGrid, target: Option<&Resolved>) {
    let Some(policy) = controller.policy() else {
        for name in ACTIONS {
            enable(grid, name, false);
        }
        return;
    };
    let cell = match policy.cells {
        Ok(()) => target.and_then(|target| target.cell.as_ref()),
        Err(_) => None,
    };
    let (kind, presets) = cell.map_or((None, CellPresets::default()), |(row, column)| {
        cell_state(controller, grid, row, *column)
    });
    // The capture-phase keys a focused editor would lose to the grid.
    let typing = controller.editor_has_focus();
    let edits = !typing
        && matches!(
            kind,
            Some(CellEditorKind::Inline { .. } | CellEditorKind::Toggle | CellEditorKind::Details(_))
        );
    enable(grid, "edit", edits);
    enable(grid, "toggle", !typing && kind == Some(CellEditorKind::Toggle));
    enable(grid, "set-empty", !typing && presets.empty);
    enable(grid, "set-null", !typing && presets.null);
    enable(grid, "set-default", !typing && presets.default);
    let rows: &[GridRow] = target.map_or(&[], |target| target.rows.as_slice());
    enable(grid, "insert-row", policy.insert.is_ok());
    enable(grid, "duplicate-rows", policy.duplicate.is_ok() && !rows.is_empty());
    let ids: Vec<GridRowId> = rows.iter().map(GridRow::id).collect();
    let deletes = policy.delete.is_ok() && delete_availability(&ids, false) == DeleteAvailability::Available;
    enable(grid, "delete-rows", deletes);
    enable(grid, "paste", policy.paste.is_ok());
}

/// The cell's editor and the presets it takes, from its lock now.
fn cell_state(
    controller: &EditController,
    grid: &DataGrid,
    row: &GridRow,
    column: usize,
) -> (Option<CellEditorKind>, CellPresets) {
    let Some(grid_column) = grid.grid_columns().get(column).cloned() else {
        return (None, CellPresets::default());
    };
    let lock = controller.tracked().lock(&grid_column, row);
    let kind = CellEditorKind::for_cell(&grid_column, lock.map_or(Ok(()), Err));
    let presets = match lock {
        None => cell_presets(&grid_column, &row.id()),
        Some(_) => CellPresets::default(),
    };
    (Some(kind), presets)
}
