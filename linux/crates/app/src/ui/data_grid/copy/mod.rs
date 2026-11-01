use std::sync::Arc;

use gtk4::prelude::*;
use gtk4::{self as gtk, glib};
use tablepro_core::column::{ColumnInfo, ResultColumn};
use tablepro_core::dialect::SqlDialect;
use tablepro_core::edit::CellInput;
use tablepro_core::{FilterRule, Value};

use super::grid_actions::{add, add_for_column, enable};
use super::selection::Resolved;
use super::{DataGrid, GridRequest, GridRow, RowJsonRequest, present_row_json};
use crate::i18n::gettext;
use crate::services::grid::{CopyScope, GridColumn, GridRowId, RowSnapshot, cell_filter_rule, copy_scope};
use crate::ui::clipboard::{CopyKind, CopyRequest, InClauseRows, InsertCopy, InsertRow};
use crate::ui::export::ExportSource;
use crate::ui::filter_strip::FilterVocabulary;

#[cfg(test)]
mod tests;

/// Copy As, one action per format.
const ROW_COPIES: [(&str, CopyKind); 8] = [
    ("copy-rows", CopyKind::Rows),
    ("copy-rows-headers", CopyKind::RowsWithHeaders),
    ("copy-json", CopyKind::Json),
    ("copy-json-lines", CopyKind::JsonLines),
    ("copy-csv", CopyKind::Csv),
    ("copy-csv-headers", CopyKind::CsvWithHeaders),
    ("copy-markdown", CopyKind::Markdown),
    ("copy-text-table", CopyKind::TextTable),
];

pub fn install_actions(grid: &DataGrid) {
    add(grid, "copy", copy);
    for (name, kind) in ROW_COPIES {
        add(grid, name, move |grid| {
            if let Some(target) = grid.target() {
                copy_rows(grid, &target.rows, kind);
            }
        });
    }
    add(grid, "copy-in-clause", copy_in_clause);
    add(grid, "copy-one-row", copy_one_row);
    add(grid, "copy-insert", |grid| copy_insert(grid, Keys::All));
    add(grid, "copy-insert-without-generated-keys", |grid| {
        copy_insert(grid, Keys::NotGenerated)
    });
    add(grid, "copy-column-name", |grid| {
        if let Some(index) = grid.target_column() {
            copy_column_name(grid, index);
        }
    });
    add_for_column(grid, "copy-column-name-at", copy_column_name);
    add(grid, "show-row-json", show_row_json);
    add(grid, "export", |grid| {
        grid.request(GridRequest::Export(export_source(grid)))
    });
    add(grid, "filter-by-value", |grid| filter_by_value(grid, false));
    add(grid, "exclude-value", |grid| filter_by_value(grid, true));
}

pub fn refresh_actions(grid: &DataGrid, target: Option<&Resolved>) {
    let cell = target.and_then(|target| target.cell.as_ref());
    let rows = target.is_some_and(|target| !target.rows.is_empty());
    enable(grid, "copy", cell.is_some() || rows);
    for (name, _) in ROW_COPIES {
        enable(grid, name, rows);
    }
    let speaks_sql = sql_dialect(grid).is_some();
    enable(grid, "copy-in-clause", cell.is_some() && speaks_sql);
    enable(grid, "copy-one-row", rows && speaks_sql);
    let inserts = rows && copies_inserts(grid);
    enable(grid, "copy-insert", inserts);
    enable(
        grid,
        "copy-insert-without-generated-keys",
        inserts && shows_assigned_column(grid),
    );
    enable(grid, "copy-column-name", cell.is_some());
    enable(grid, "show-row-json", target.and_then(json_row).is_some());
    enable(grid, "export", grid.row_count() > 0);
    for (name, exclude) in [("filter-by-value", false), ("exclude-value", true)] {
        let rule = cell.and_then(|(row, column)| value_rule(grid, row, *column, exclude));
        enable(grid, name, rule.is_some());
    }
}

/// The rows the grid shows, pending edits included, under the columns
/// on screen in their order.
pub fn export_source(grid: &DataGrid) -> ExportSource {
    let shown = ShownColumns::of(grid);
    let tracked = grid.tracked();
    ExportSource::Rows {
        columns: shown.columns.clone(),
        rows: grid
            .shown_rows()
            .iter()
            .map(|row| shown.project(tracked.snapshot(row)))
            .collect(),
    }
}

/// The columns on screen in the order the user arranged them, which a
/// copy or an export of rows takes.
struct ShownColumns {
    indices: Vec<usize>,
    columns: Arc<[ResultColumn]>,
    /// Every column shown where the result has it.
    in_place: bool,
}

impl ShownColumns {
    fn of(grid: &DataGrid) -> Self {
        let all = grid.grid_columns();
        let indices: Vec<usize> = grid
            .shown_columns()
            .into_iter()
            .filter(|index| *index < all.len())
            .collect();
        let columns = indices
            .iter()
            .filter_map(|index| all.get(*index))
            .map(GridColumn::result_column)
            .collect();
        let in_place = indices.iter().copied().eq(0..all.len());
        Self {
            indices,
            columns,
            in_place,
        }
    }

    /// The same columns less those `left_out` picks by their index in the
    /// result.
    fn without(self, left_out: impl Fn(usize) -> bool) -> Self {
        let (indices, columns): (Vec<usize>, Vec<ResultColumn>) = self
            .indices
            .iter()
            .zip(self.columns.iter())
            .filter(|(index, _)| !left_out(**index))
            .map(|(index, column)| (*index, column.clone()))
            .unzip();
        let in_place = self.in_place && indices.len() == self.indices.len();
        Self {
            indices,
            columns: columns.into(),
            in_place,
        }
    }

    /// A row whose columns are all in place keeps sharing its cells.
    fn project(&self, row: RowSnapshot) -> RowSnapshot {
        if self.in_place && row.len() == self.indices.len() {
            return row;
        }
        let cells: Vec<Value> = self.indices.iter().map(|index| row.value(*index).clone()).collect();
        RowSnapshot::new(cells.into(), Vec::new())
    }

    fn project_inputs(&self, inputs: &[CellInput]) -> Vec<CellInput> {
        self.indices
            .iter()
            .map(|index| inputs.get(*index).cloned().unwrap_or(CellInput::Default))
            .collect()
    }
}

/// Copy: the target cell's value when one row is in play, else the rows.
fn copy(grid: &DataGrid) {
    let Some(target) = grid.target() else {
        return;
    };
    let column = target.cell.as_ref().map(|(_, column)| *column);
    match (copy_scope(target.rows.len(), column), &target.cell) {
        (CopyScope::Value(column), Some((row, _))) => copy_value(grid, row, column),
        _ => copy_rows(grid, &target.rows, CopyKind::Rows),
    }
}

/// The cell's whole value, never the text the cell draws, which stands in
/// for NULL and cuts long values.
fn copy_value(grid: &DataGrid, row: &GridRow, column: usize) {
    render(
        grid,
        CopyRequest::Rows {
            columns: result_columns(grid),
            rows: vec![grid.tracked().snapshot(row)],
            kind: CopyKind::Value(column),
        },
    );
}

fn copy_rows(grid: &DataGrid, rows: &[GridRow], kind: CopyKind) {
    if rows.is_empty() {
        return;
    }
    let (columns, rows) = shown_rows(grid, rows);
    render(grid, CopyRequest::Rows { columns, rows, kind });
}

/// The rows as the grid shows them, under the columns on screen.
fn shown_rows(grid: &DataGrid, rows: &[GridRow]) -> (Arc<[ResultColumn]>, Vec<RowSnapshot>) {
    let shown = ShownColumns::of(grid);
    let tracked = grid.tracked();
    let rows = rows.iter().map(|row| shown.project(tracked.snapshot(row))).collect();
    (shown.columns, rows)
}

fn copy_one_row(grid: &DataGrid) {
    let Some(target) = grid.target().filter(|target| !target.rows.is_empty()) else {
        return;
    };
    let Some(dialect) = sql_dialect(grid) else {
        grid.toast(gettext("Connect to a database first."));
        return;
    };
    let (columns, rows) = shown_rows(grid, &target.rows);
    render(grid, CopyRequest::Values { dialect, columns, rows });
}

fn copy_in_clause(grid: &DataGrid) {
    let Some(target) = grid.target() else {
        return;
    };
    let Some((_, column)) = target.cell else {
        return;
    };
    let Some(dialect) = sql_dialect(grid) else {
        grid.toast(gettext("Connect to a database first."));
        return;
    };
    let tracked = grid.tracked();
    render(
        grid,
        CopyRequest::InClause {
            dialect,
            values: InClauseRows {
                columns: result_columns(grid),
                rows: target.rows.iter().map(|row| tracked.snapshot(row)).collect(),
                column,
            },
        },
    );
}

/// Which key columns an INSERT copy writes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Keys {
    All,
    /// Each statement makes a new row that takes its key from the server,
    /// so the copy can run against the table the rows came from.
    NotGenerated,
}

/// Whether a column on screen takes a new row's value from the server,
/// so INSERT Without Generated Keys writes something INSERT does not.
fn shows_assigned_column(grid: &DataGrid) -> bool {
    let Some(catalog) = catalog_columns(&grid.grid_columns()) else {
        return false;
    };
    grid.shown_columns().into_iter().any(|index| {
        catalog
            .get(index)
            .is_some_and(|column| column.is_assigned_on_insert(&catalog))
    })
}

/// Each row as an INSERT for the server the rows come from, under the
/// columns on screen. A draft's leaves out what the server fills.
fn copy_insert(grid: &DataGrid, keys: Keys) {
    let (Some(target), Some(config)) = (grid.target(), grid.config()) else {
        return;
    };
    let (Some(tracker), Some(table), Some(catalog)) = (
        config.tracker.as_ref(),
        config.table.clone(),
        catalog_columns(&grid.grid_columns()),
    ) else {
        return;
    };
    if target.rows.is_empty() {
        return;
    }
    let Some(dialect) = config.dialect.as_ref().and_then(|dialect| dialect()) else {
        grid.toast(gettext("Connect to a database first."));
        return;
    };
    let shown = match keys {
        Keys::All => ShownColumns::of(grid),
        Keys::NotGenerated => ShownColumns::of(grid).without(|index| {
            catalog
                .get(index)
                .is_some_and(|column| column.is_assigned_on_insert(&catalog))
        }),
    };
    let tracked = grid.tracked();
    let rows = target
        .rows
        .iter()
        .map(|row| match row.id() {
            GridRowId::Draft(draft_id) => {
                InsertRow::Draft(shown.project_inputs(&tracker.draft_cells(draft_id, &catalog).unwrap_or_default()))
            }
            _ => InsertRow::Saved(shown.project(tracked.snapshot(row))),
        })
        .collect();
    render(
        grid,
        CopyRequest::Insert(InsertCopy {
            dialect,
            table,
            columns: shown
                .indices
                .iter()
                .filter_map(|index| catalog.get(*index).cloned())
                .collect(),
            rows,
        }),
    );
}

fn copy_column_name(grid: &DataGrid, index: usize) {
    let Some(name) = grid.grid_columns().get(index).map(|column| column.name.clone()) else {
        return;
    };
    crate::ui::clipboard::copy_text(grid, name, |message| grid.toast(message));
}

fn show_row_json(grid: &DataGrid) {
    let (Some(target), Some(config)) = (grid.target(), grid.config()) else {
        return;
    };
    let Some(row) = json_row(&target) else {
        return;
    };
    let shown = ShownColumns::of(grid);
    let request = RowJsonRequest {
        columns: shown.columns.clone(),
        row: shown.project(grid.tracked().snapshot(row)),
    };
    let parent = grid.clone().upcast::<gtk::Widget>();
    let tasks = config.tasks.clone();
    let settings = config.settings.clone();
    glib::spawn_future_local(async move {
        present_row_json(parent, tasks, Some(settings), request).await;
    });
}

/// The row Show Row as JSON shows: the target cell's, else the one row
/// a row's menu was opened on.
fn json_row(target: &Resolved) -> Option<&GridRow> {
    match (&target.cell, target.rows.as_slice()) {
        (Some((row, _)), _) | (None, [row]) => Some(row),
        _ => None,
    }
}

fn filter_by_value(grid: &DataGrid, exclude: bool) {
    let Some((row, column)) = grid.target().and_then(|target| target.cell) else {
        return;
    };
    if let Some(rule) = value_rule(grid, &row, column, exclude) {
        grid.request(GridRequest::FilterByValue(rule));
    }
}

/// The rule from the value the cell shows. A draft's cell left to the
/// server has no value to name, and an operator the engine does not
/// evaluate is one the filter strip would refuse.
fn value_rule(grid: &DataGrid, row: &GridRow, column: usize, exclude: bool) -> Option<FilterRule> {
    let config = grid.config().filter(|config| config.filter_by_value)?;
    let columns = grid.grid_columns();
    let grid_column = columns.get(column)?;
    let rule = grid.tracked().with_value(row, column, |value, default| match default {
        true => None,
        false => cell_filter_rule(grid_column, value, exclude),
    })?;
    let dialect = config.dialect.as_ref().and_then(|dialect| dialect());
    FilterVocabulary::of(dialect)
        .operators(grid_column.catalog.as_ref()?)
        .contains(&rule.op)
        .then_some(rule)
}

/// The connection's dialect, where the rows have an SQL spelling.
fn sql_dialect(grid: &DataGrid) -> Option<Arc<dyn SqlDialect>> {
    let dialect = (grid.config()?.dialect.as_ref()?)()?;
    dialect.grammar().is_sql().then_some(dialect)
}

/// An editing grid of a table, every column of it read from the
/// catalogue, which an INSERT needs.
fn copies_inserts(grid: &DataGrid) -> bool {
    grid.config()
        .is_some_and(|config| config.tracker.is_some() && config.table.is_some() && config.dialect.is_some())
        && grid.grid_columns().iter().all(|column| column.catalog.is_some())
}

fn catalog_columns(columns: &[GridColumn]) -> Option<Vec<ColumnInfo>> {
    columns.iter().map(|column| column.catalog.clone()).collect()
}

fn result_columns(grid: &DataGrid) -> Arc<[ResultColumn]> {
    grid.grid_columns().iter().map(GridColumn::result_column).collect()
}

/// Render off the GTK thread and say through the host how it went.
fn render(grid: &DataGrid, request: CopyRequest) {
    let Some(config) = grid.config() else {
        return;
    };
    let weak = grid.downgrade();
    crate::ui::clipboard::copy_rows(grid, &config.tasks, request, move |text| {
        if let Some(grid) = weak.upgrade() {
            grid.toast(text);
        }
    });
}
