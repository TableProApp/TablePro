mod column;
mod column_jump;
mod column_order;
mod column_visibility;
mod context_menu;
mod display;
mod editing;
mod export;
mod presentation;
mod row_find;
mod types;
mod value_viewer;
pub(crate) use presentation::cell_allows_inline_edit;

use gtk4::prelude::*;

use tablepro_core::{ColumnInfo, QueryResult};

use crate::services::database_service::DatabaseService;
use crate::ui::row_store::RowStore;

use column::{build_column, is_cell_editable};
use context_menu::install_grid_context_menus;

pub(crate) use display::preview_to_display_text;
pub(crate) use display::value_to_full_edit_text;
pub use display::{focused_cell_identity, value_to_display_text};
pub(crate) use value_viewer::present as present_value_viewer;

pub(crate) fn enter_cell_edit_mode(label: &crate::ui::cell_editor::CellEditor) {
    editing::enter_edit_mode(label);
}

#[derive(Debug)]
pub enum GridMsg {
    SortChanged(usize, bool),
    CellEdited {
        row_position: u32,
        col_index: usize,
        new_value: String,
        /// Primary-key values read when the editor opened. The receiver
        /// rejects the edit if the row now at `row_position` is a
        /// different one.
        row_key: Vec<tablepro_core::Value>,
    },
    CopyToClipboard(String),
    FetchCellValue {
        col_index: usize,
        column_name: String,
        row_key: Vec<tablepro_core::Value>,
    },
    IncompleteRowData,
    ProjectionFailure,
    CopyRowAsInsert {
        row_position: u32,
    },
    ShowRowAsJson(String),
    ExportResults(QueryResult),
    SetCellNull {
        row_position: u32,
        col_index: usize,
        row_key: Vec<tablepro_core::Value>,
    },
    DeleteRowAt {
        row_position: u32,
        row_key: Vec<tablepro_core::Value>,
    },
    InsertRow,
    DuplicateRow {
        row_position: u32,
    },
    FilterByValue {
        column: String,
        value: tablepro_core::Value,
    },
}

#[derive(Debug, Clone, Default)]
pub struct TabGridContext {
    pub tab_id: Option<uuid::Uuid>,
    pub pk_col_indices: Vec<usize>,
    pub projected_columns: Option<Vec<usize>>,
    pub preview_long_values: bool,
    pub preview_redis_strings: bool,
    pub preview_result_values: bool,
    /// Names of columns that are part of a foreign key on this table.
    /// Marks the column header so a reference is visible before the
    /// cell value picker (a later slice) exists.
    pub foreign_key_columns: std::collections::HashSet<String>,
}

const WIDE_TABLE_THRESHOLD: usize = 8;
const MIN_COLUMN_WIDTH_PX: i32 = 120;

#[allow(clippy::too_many_arguments)]
pub fn build_column_view(
    shared: &std::sync::Arc<QueryResult>,
    schema_columns: &[ColumnInfo],
    table: &str,
    edit_sender: Option<relm4::Sender<GridMsg>>,
    menu_sender: Option<relm4::Sender<GridMsg>>,
    sort: Option<(usize, bool)>,
    sort_sender: Option<relm4::Sender<GridMsg>>,
    connection_id: Option<uuid::Uuid>,
    tab_ctx: TabGridContext,
    column_widths: Option<crate::services::column_widths::ColumnWidthStore>,
    database: std::sync::Arc<DatabaseService>,
) -> (gtk4::ColumnView, gtk4::MultiSelection) {
    let result: &QueryResult = shared;
    let store = match &tab_ctx.projected_columns {
        Some(indices) => match if tab_ctx.preview_redis_strings && !tab_ctx.pk_col_indices.is_empty() {
            RowStore::from_projected_with_redis_string_previews(
                shared.clone(),
                indices.clone(),
                schema_columns.len(),
                tab_ctx.pk_col_indices.clone(),
            )
        } else if tab_ctx.preview_long_values && !tab_ctx.pk_col_indices.is_empty() {
            RowStore::from_projected_with_previews(
                shared.clone(),
                indices.clone(),
                schema_columns.len(),
                tab_ctx.pk_col_indices.clone(),
            )
        } else {
            RowStore::from_projected(shared.clone(), indices.clone(), schema_columns.len())
        } {
            Ok(store) => store,
            Err(error) => {
                tracing::error!(%error, "projected browse rows do not match the table schema");
                if let Some(sender) = &menu_sender {
                    sender.send(GridMsg::ProjectionFailure).ok();
                }
                RowStore::from_shared(std::sync::Arc::new(QueryResult {
                    columns: schema_columns.to_vec(),
                    rows: Vec::new(),
                    truncated: false,
                }))
            }
        },
        None if tab_ctx.preview_redis_strings && !tab_ctx.pk_col_indices.is_empty() => {
            RowStore::from_shared_with_redis_string_previews(shared.clone(), tab_ctx.pk_col_indices.clone())
        }
        None if tab_ctx.preview_result_values => RowStore::from_shared_with_result_previews(shared.clone()),
        None if tab_ctx.preview_long_values && !tab_ctx.pk_col_indices.is_empty() => {
            RowStore::from_shared_with_previews(shared.clone(), tab_ctx.pk_col_indices.clone())
        }
        None => RowStore::from_shared(shared.clone()),
    };
    let columns = if tab_ctx.projected_columns.is_some() {
        schema_columns
    } else {
        &result.columns
    };
    let selection = gtk4::MultiSelection::new(Some(store));
    let column_view = gtk4::ColumnView::builder()
        .model(&selection)
        .show_row_separators(true)
        .show_column_separators(true)
        .build();

    let grid_menus = menu_sender.as_ref().map(|sender| {
        let driver_id = connection_id
            .and_then(|id| database.metadata(id))
            .map(|metadata| metadata.driver_id)
            .unwrap_or_default();
        install_grid_context_menus(
            &column_view,
            sender.clone(),
            columns,
            result.truncated,
            driver_id,
            tab_ctx.tab_id.is_some(),
        )
    });

    let default_min_width = if columns.len() > WIDE_TABLE_THRESHOLD {
        Some(MIN_COLUMN_WIDTH_PX)
    } else {
        None
    };
    let mut view_columns: Vec<gtk4::ColumnViewColumn> = Vec::with_capacity(columns.len());
    for (i, column) in columns.iter().enumerate() {
        let editable = is_cell_editable(schema_columns.get(i).unwrap_or(column));
        let col = build_column(
            column,
            i,
            editable,
            table.to_string(),
            edit_sender.clone(),
            sort_sender.clone(),
            connection_id,
            tab_ctx.clone(),
            default_min_width,
            column_view.clone(),
            grid_menus.clone(),
            column_widths.clone(),
        );
        column_view.append_column(&col);
        view_columns.push(col);
    }

    let grid_actions = gtk4::gio::SimpleActionGroup::new();
    column_visibility::install(
        &column_view,
        &grid_actions,
        &view_columns,
        columns.iter().map(|column| column.name.clone()).collect(),
        connection_id
            .zip(column_widths.clone())
            .map(|(id, store)| (id, table.to_string(), store)),
    );
    column_order::install(
        &column_view,
        &view_columns,
        columns.iter().map(|column| column.name.clone()).collect(),
        connection_id
            .zip(column_widths.clone())
            .map(|(id, store)| (id, table.to_string(), store)),
    );
    column_jump::install(
        &column_view,
        &grid_actions,
        &view_columns,
        columns.iter().map(|column| column.name.clone()).collect(),
        connection_id,
        database,
    );
    row_find::install(
        &column_view,
        &grid_actions,
        columns.iter().map(|column| column.name.clone()).collect(),
    );
    column_view.insert_action_group("grid", Some(&grid_actions));

    if let Some((col_idx, ascending)) = sort
        && let Some(col) = view_columns.get(col_idx)
    {
        let direction = if ascending {
            gtk4::SortType::Ascending
        } else {
            gtk4::SortType::Descending
        };
        column_view.sort_by_column(Some(col), direction);
    }

    if let Some(app_sender) = sort_sender
        && let Some(view_sorter) = column_view
            .sorter()
            .and_then(|s| s.downcast::<gtk4::ColumnViewSorter>().ok())
    {
        let dispatch = {
            let app_sender = app_sender.clone();
            let columns = view_columns.clone();
            move |sorter: &gtk4::ColumnViewSorter| {
                let Some(active) = sorter.primary_sort_column() else {
                    return;
                };
                let ascending = matches!(sorter.primary_sort_order(), gtk4::SortType::Ascending);
                for (idx, col) in columns.iter().enumerate() {
                    if col == &active {
                        app_sender.send(GridMsg::SortChanged(idx, ascending)).ok();
                        break;
                    }
                }
            }
        };
        view_sorter.connect_primary_sort_column_notify({
            let dispatch = dispatch.clone();
            move |sorter| dispatch(sorter)
        });
        view_sorter.connect_primary_sort_order_notify(move |sorter| dispatch(sorter));
    }

    (column_view, selection)
}

pub(crate) fn jump_to_column(widget: &gtk4::Widget) -> bool {
    column_jump::open_in(widget)
}
