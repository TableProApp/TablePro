use std::cell::RefCell;
use std::rc::Rc;
use std::sync::Arc;
use std::time::Duration;

use gtk4 as gtk;
use gtk4::prelude::*;
use tablepro_core::edit::CellInput;
use tablepro_core::meta::{RowIdentity, TableRef};
use tablepro_core::{ColumnInfo, Value};

use super::{
    DataGrid, DialectSource, EditRules, GridCell, GridConfig, GridRequest, GridSorting, LayoutBinding, RowData,
};
use crate::runtime::AppRuntime;
use crate::services::change_tracker::RowKey;
use crate::services::grid::{EditPolicy, GridColumn, edit_policy, grid_columns};
use crate::services::tab_tracker_handle::TabTrackerHandle;
use crate::services::tracker_edit::TrackerEdit;
use crate::test_support::{MemorySettings, descendants, drain_main_context, wait_until};

pub(crate) const WAIT: Duration = Duration::from_secs(5);

#[expect(
    clippy::disallowed_methods,
    reason = "a test fixture stands in for the catalogue, which is where this text comes from in production"
)]
pub(crate) fn col(data_type: &str, primary_key: bool) -> ColumnInfo {
    let kind = tablepro_core::column::classify_type_name(data_type);
    ColumnInfo {
        name: "x".into(),
        column_type: tablepro_core::column::ColumnType {
            name: data_type.to_owned(),
            dynamic_storage: tablepro_core::column::has_dynamic_storage(&kind),
            kind,
            catalog: Some(tablepro_core::column::CatalogType {
                declaration: tablepro_core::column::SqlTypeExpr::from_catalog_text(data_type),
                cast_target: tablepro_core::column::SqlTypeExpr::from_catalog_text(data_type),
            }),
            read_form: tablepro_core::column::ReadForm::Native,
        },
        nullable: true,
        primary_key,
        is_auto_increment: false,
        is_generated: false,
        partition_scoped: false,
        default: tablepro_core::column::ColumnDefault::None,
        comment: None,
    }
}

pub(crate) fn named(name: &str, data_type: &str, primary_key: bool) -> ColumnInfo {
    let mut column = col(data_type, primary_key);
    column.name = name.to_owned();
    column
}

pub(crate) fn key(id: i64) -> RowKey {
    RowKey::from_pk_values(&[Value::Int(id)]).expect("a key")
}

pub(crate) fn keyed_by_id() -> RowIdentity {
    RowIdentity::UniqueKey {
        columns: vec!["id".to_owned()],
    }
}

/// Saved rows keyed by their first cell, as a page read from a table is.
pub(crate) fn persisted(rows: &[Vec<Value>]) -> Vec<RowData> {
    rows.iter()
        .map(|cells| {
            let id = cells.first().cloned().unwrap_or(Value::Null);
            RowData::persisted(RowKey::from_pk_values(&[id]), cells.clone().into())
        })
        .collect()
}

pub(crate) fn results(rows: &[Vec<Value>]) -> Vec<RowData> {
    rows.iter().map(|cells| RowData::result(cells.clone().into())).collect()
}

/// Saved rows keyed `ids`, as a page of a two-column table.
pub(crate) fn page(ids: std::ops::Range<i64>) -> Vec<RowData> {
    let rows: Vec<Vec<Value>> = ids
        .map(|id| vec![Value::Int(id), Value::Text(format!("row {id}"))])
        .collect();
    persisted(&rows)
}

pub(crate) fn two_text_columns() -> Vec<ColumnInfo> {
    vec![named("id", "integer", true), named("name", "text", false)]
}

pub(crate) fn two_text_values() -> Vec<Vec<Value>> {
    vec![
        vec![Value::Int(1), Value::Text("A".into())],
        vec![Value::Int(2), Value::Text("B".into())],
    ]
}

pub(crate) fn text(value: &str) -> CellInput {
    CellInput::Value(Value::Text(value.to_owned()))
}

/// How a test grid is built: an editing table grid by default.
pub(crate) struct GridSpec {
    pub columns: Vec<ColumnInfo>,
    pub editable: bool,
    pub sorting: GridSorting,
    pub layout: Option<LayoutBinding>,
    pub find: bool,
    pub filter_by_value: bool,
    pub policy: Option<EditPolicy>,
    pub references: Option<super::KeysHandle>,
    pub dialect: Option<DialectSource>,
    pub table: Option<TableRef>,
    /// Columns no filter, sort or update can name, as a document's
    /// nested fields (ADR 0026).
    pub unaddressable: Vec<String>,
}

impl GridSpec {
    pub(crate) fn table(columns: Vec<ColumnInfo>) -> Self {
        Self {
            columns,
            editable: true,
            sorting: GridSorting::Server { initial: None },
            layout: None,
            find: false,
            filter_by_value: true,
            policy: None,
            references: None,
            dialect: None,
            table: None,
            unaddressable: Vec::new(),
        }
    }

    pub(crate) fn results(columns: Vec<ColumnInfo>) -> Self {
        Self {
            editable: false,
            sorting: GridSorting::Client,
            find: true,
            filter_by_value: false,
            ..Self::table(columns)
        }
    }
}

/// A grid in a shown window, with the requests it made.
pub(crate) struct Grid {
    pub window: gtk::Window,
    pub grid: DataGrid,
    pub tracker: TabTrackerHandle,
    pub columns: Arc<[GridColumn]>,
    requests: Rc<RefCell<Vec<GridRequest>>>,
    _settings: MemorySettings,
    _runtime: AppRuntime,
}

impl Grid {
    /// `rows` keyed by their first cell, in a grid that edits them.
    pub(crate) fn open(columns: Vec<ColumnInfo>, rows: Vec<Vec<Value>>) -> Self {
        Self::build(GridSpec::table(columns), persisted(&rows))
    }

    pub(crate) fn build(spec: GridSpec, rows: Vec<RowData>) -> Self {
        crate::register_test_resources();
        // The stylesheet the app draws the grid with, cell padding and the
        // monospace font included.
        libadwaita::init().expect("libadwaita initialises under the test backend");
        let runtime = crate::test_support::test_runtime();
        let settings = MemorySettings::new();
        let tracker = TabTrackerHandle::default();
        let columns = grid_columns(
            &spec.columns.iter().map(ColumnInfo::result_column).collect::<Vec<_>>(),
            &spec.columns,
            |name| !spec.unaddressable.iter().any(|unaddressable| unaddressable == name),
        );
        let has_key = spec.columns.iter().any(|column| column.primary_key);
        let config = GridConfig {
            columns: columns.clone(),
            sorting: spec.sorting,
            rules: spec.editable.then(|| EditRules {
                identity: keyed_by_id(),
                policy: spec.policy.unwrap_or_else(|| edit_policy(false, has_key, true)),
            }),
            tracker: spec.editable.then(|| tracker.clone()),
            settings: settings.get().clone(),
            layout: spec.layout,
            references: spec.references,
            dialect: spec.dialect,
            table: spec.table,
            find: spec.find,
            filter_by_value: spec.filter_by_value,
            tasks: runtime.tasks(),
            label: "test grid".to_owned(),
        };
        let grid = DataGrid::new(config);
        let requests: Rc<RefCell<Vec<GridRequest>>> = Rc::default();
        let log = requests.clone();
        grid.connect_request(move |_, request| log.borrow_mut().push(request));
        let window = gtk::Window::new();
        window.set_default_size(800, 500);
        window.set_child(Some(&grid));
        window.present();
        let count = rows.len();
        grid.replace_rows(rows, 0);
        let opened = Self {
            window,
            grid,
            tracker,
            columns,
            requests,
            _settings: settings,
            _runtime: runtime,
        };
        // A saved layout can hide columns, which draw no cells.
        let width = opened.grid.shown_columns().len();
        wait_until(WAIT, || opened.cells().len() >= width * count.min(20)).expect("the cells are drawn");
        // Rows are measured before the window's first layout; a user meets
        // the grid laid out, with a width Row Details can open from.
        wait_until(WAIT, || opened.grid.width() > 0).expect("the grid is laid out");
        opened
    }

    pub(crate) fn cells(&self) -> Vec<GridCell> {
        descendants(&self.grid.column_view())
            .into_iter()
            .filter_map(|widget| widget.downcast::<GridCell>().ok())
            .filter(|cell| cell.row().is_some())
            .collect()
    }

    /// The cell that shows `column` of the row named `id`.
    pub(crate) fn cell_of(&self, id: i64, column: usize) -> GridCell {
        self.cells()
            .into_iter()
            .find(|cell| cell.column() == column && cell.row().is_some_and(|row| row.key() == Some(key(id))))
            .expect("the row's cell is drawn")
    }

    pub(crate) fn cell_at(&self, position: u32, column: usize) -> GridCell {
        self.find_cell(position, column).expect("the cell is drawn")
    }

    pub(crate) fn find_cell(&self, position: u32, column: usize) -> Option<GridCell> {
        self.cells()
            .into_iter()
            .find(|cell| cell.column() == column && cell.position() == Some(position))
    }

    pub(crate) fn focused_cell(&self) -> Option<GridCell> {
        let focus = gtk::prelude::GtkWindowExt::focus(&self.window)?;
        GridCell::from_focus(&focus)
    }

    /// Focus the cell of data column `column` at `position`, as the arrow
    /// keys do.
    pub(crate) fn focus(&self, position: u32, column: usize) -> GridCell {
        let mut focused = None;
        wait_until(WAIT, || {
            focused = self.grid.focus_cell(position, column);
            focused.is_some()
        })
        .expect("the cell takes the focus");
        focused.expect("a focused cell")
    }

    pub(crate) fn activate(&self, action: &str) {
        self.grid
            .activate_action(&format!("grid.{action}"), None)
            .unwrap_or_else(|_| panic!("the grid has no {action}"));
        drain_main_context();
    }

    pub(crate) fn is_enabled(&self, action: &str) -> bool {
        self.grid
            .actions()
            .lookup_action(action)
            .is_some_and(|action| action.is_enabled())
    }

    pub(crate) fn take_requests(&self) -> Vec<GridRequest> {
        self.requests.take()
    }

    pub(crate) fn insert_draft(&self) -> u64 {
        let delta = self.tracker.apply(TrackerEdit::InsertDrafts {
            rows: vec![vec![CellInput::Value(Value::Null); self.columns.len()]],
        });
        let draft_id = delta
            .inserted_drafts
            .first()
            .copied()
            .expect("an insert adds a draft row");
        self.grid.apply_delta(&delta);
        drain_main_context();
        draft_id
    }

    pub(crate) fn display_text(cell: &GridCell) -> String {
        cell.display()
            .and_then(|display| display.text())
            .map(|text| text.to_string())
            .unwrap_or_default()
    }
}

impl Drop for Grid {
    fn drop(&mut self) {
        self.window.destroy();
        drain_main_context();
    }
}

/// Whether the window's focus is the grid or inside it.
pub(crate) fn focus_in_grid(grid: &Grid) -> bool {
    let view = grid.grid.column_view();
    gtk::prelude::GtkWindowExt::focus(&grid.window)
        .is_some_and(|focus| focus == *view.upcast_ref::<gtk::Widget>() || focus.is_ancestor(&view))
}
