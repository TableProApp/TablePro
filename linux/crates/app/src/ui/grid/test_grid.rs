use std::cell::RefCell;
use std::rc::Rc;
use std::time::Duration;

use gtk4::prelude::*;
use gtk4::{self as gtk, gio};

use tablepro_core::edit::CellInput;
use tablepro_core::meta::RowIdentity;
use tablepro_core::{ColumnInfo, Value};

use super::{
    ColumnWidthBinding, GridCell, GridContent, GridMsg, GridSink, GridSorting, KeysHandle, RowObject, TabGridContext,
    TableKeys, begin_edit, build_column_view, data_columns,
};
use crate::services::change_tracker::RowKey;
use crate::services::tab_tracker_handle::TabTrackerHandle;
use crate::services::tracker_delta::TrackerDelta;
use crate::services::tracker_edit::TrackerEdit;
use crate::test_support::{descendants, drain_main_context, wait_until};

pub(super) const WAIT: Duration = Duration::from_secs(5);

#[expect(
    clippy::disallowed_methods,
    reason = "a test fixture stands in for the catalogue, which is where this text comes from in production"
)]
pub(super) fn col(data_type: &str, primary_key: bool) -> ColumnInfo {
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

pub(super) fn named(name: &str, data_type: &str, primary_key: bool) -> ColumnInfo {
    let mut column = col(data_type, primary_key);
    column.name = name.to_owned();
    column
}

pub(super) fn key(id: i64) -> RowKey {
    RowKey::from_pk_values(&[Value::Int(id)]).expect("a key")
}

pub(super) fn keyed_by_id() -> RowIdentity {
    RowIdentity::UniqueKey {
        columns: vec!["id".to_owned()],
    }
}

pub(super) fn tracked(tracker: &TabTrackerHandle) -> TabGridContext {
    TabGridContext {
        tracker: Some(tracker.clone()),
        editable: true,
        identity: keyed_by_id(),
        column_widths: None,
        in_clause: true,
        keys: None,
    }
}

/// Persisted rows keyed by their first cell, as a browse page is.
pub(super) fn persisted(rows: &[Vec<Value>]) -> Vec<RowObject> {
    rows.iter()
        .map(|cells| {
            let id = cells.first().cloned().unwrap_or(Value::Null);
            RowObject::persisted(RowKey::from_pk_values(&[id]), cells.clone().into())
        })
        .collect()
}

/// `rows` under the result columns of `columns`.
pub(super) fn content(columns: &[ColumnInfo], rows: Vec<RowObject>) -> GridContent {
    GridContent {
        columns: columns.iter().map(ColumnInfo::result_column).collect(),
        rows,
    }
}

pub(super) fn recorder() -> (GridSink, Rc<RefCell<Vec<GridMsg>>>) {
    let messages = Rc::new(RefCell::new(Vec::new()));
    let log = messages.clone();
    (Rc::new(move |msg| log.borrow_mut().push(msg)), messages)
}

pub(super) struct Grid {
    pub(super) window: gtk::Window,
    pub(super) view: gtk::ColumnView,
    pub(super) store: gio::ListStore,
    pub(super) tracker: TabTrackerHandle,
    messages: Rc<RefCell<Vec<GridMsg>>>,
    width: usize,
}

impl Grid {
    /// `rows` keyed by their first cell, in a grid that edits them.
    pub(super) fn open(columns: Vec<ColumnInfo>, rows: Vec<Vec<Value>>) -> Self {
        Self::open_in(columns, rows, None, None)
    }

    /// As `open`, with the column widths saved through `widths`.
    pub(super) fn open_with_widths(
        columns: Vec<ColumnInfo>,
        rows: Vec<Vec<Value>>,
        widths: ColumnWidthBinding,
    ) -> Self {
        Self::open_in(columns, rows, Some(widths), None)
    }

    /// As `open`, for a table with `keys`.
    pub(super) fn open_with_keys(columns: Vec<ColumnInfo>, rows: Vec<Vec<Value>>, keys: TableKeys) -> Self {
        let handle = KeysHandle::new(keys.table.clone());
        handle.set(keys);
        Self::open_in(columns, rows, None, Some(handle))
    }

    fn open_in(
        columns: Vec<ColumnInfo>,
        rows: Vec<Vec<Value>>,
        widths: Option<ColumnWidthBinding>,
        keys: Option<KeysHandle>,
    ) -> Self {
        let tracker = TabTrackerHandle::default();
        let (sink, messages) = recorder();
        let (view, selection) = build_column_view(
            content(&columns, persisted(&rows)),
            &columns,
            sink,
            GridSorting::Server { initial: None },
            TabGridContext {
                column_widths: widths,
                keys,
                ..tracked(&tracker)
            },
        );
        let store = selection
            .model()
            .and_downcast::<gio::ListStore>()
            .expect("a list store");
        let window = gtk::Window::new();
        window.set_default_size(600, 400);
        window.set_child(Some(&view));
        window.present();
        let grid = Self {
            window,
            view,
            store,
            tracker,
            messages,
            width: columns.len(),
        };
        wait_until(WAIT, || grid.cells().len() == columns.len() * rows.len()).expect("the cells are drawn");
        grid
    }

    pub(super) fn cells(&self) -> Vec<GridCell> {
        descendants(&self.view)
            .into_iter()
            .filter_map(|widget| widget.downcast::<GridCell>().ok())
            .filter(|cell| cell.row().is_some())
            .collect()
    }

    /// The cell that shows `column` of the row named `id`.
    pub(super) fn cell_of(&self, id: i64, column: usize) -> GridCell {
        self.cells()
            .into_iter()
            .find(|cell| cell.column() == column && cell.row().is_some_and(|row| row.key() == Some(&key(id))))
            .expect("the row's cell is drawn")
    }

    pub(super) fn insert_draft(&self) {
        let delta = self.tracker.apply(TrackerEdit::InsertDrafts {
            rows: vec![vec![CellInput::Value(Value::Null); self.width]],
        });
        let Some(draft_id) = delta.inserted_drafts.into_iter().next() else {
            panic!("an insert adds a draft row");
        };
        self.store.insert(0, &RowObject::draft(draft_id));
        drain_main_context();
    }

    /// The view's `index`th column of the result, past the state column.
    pub(super) fn column(&self, index: u32) -> gtk::ColumnViewColumn {
        let index = usize::try_from(index).expect("a column index");
        data_columns(&self.view).into_iter().nth(index).expect("a column")
    }

    pub(super) fn focused_cell(&self) -> Option<GridCell> {
        let focus = gtk::prelude::GtkWindowExt::focus(&self.window)?;
        GridCell::from_focus(&focus)
    }

    /// Focus the cell of the `column`th shown column at `position`, as
    /// the arrow keys do. `scroll_to` moves the focus only within a
    /// focused list, so the view's grab carries it there. The view shows
    /// the columns in result order.
    pub(super) fn focus(&self, position: u32, column: u32) -> GridCell {
        self.view
            .scroll_to(position, Some(&self.column(column)), gtk::ListScrollFlags::FOCUS, None);
        self.view.grab_focus();
        let mut focused = None;
        wait_until(WAIT, || {
            focused = self
                .focused_cell()
                .filter(|cell| cell.position() == Some(position) && u32::try_from(cell.column()) == Ok(column));
            focused.is_some()
        })
        .expect("the cell takes the focus");
        focused.expect("a focused cell")
    }

    pub(super) fn take_messages(&self) -> Vec<GridMsg> {
        self.messages.take()
    }

    /// What the tab does with a tracker change.
    pub(super) fn redraw(&self, delta: &TrackerDelta) {
        for position in 0..self.store.n_items() {
            if let Some(row) = self.store.item(position).and_downcast::<RowObject>()
                && row.id().tracker_key().is_some_and(|key| delta.changed.contains(&key))
            {
                row.bump_revision();
            }
        }
    }
}

impl Drop for Grid {
    fn drop(&mut self) {
        self.window.destroy();
        drain_main_context();
    }
}

/// Saved rows keyed `ids`, as a page read from the table is.
pub(super) fn page(ids: std::ops::Range<i64>) -> Vec<RowObject> {
    let rows: Vec<Vec<Value>> = ids
        .map(|id| vec![Value::Int(id), Value::Text(format!("row {id}"))])
        .collect();
    persisted(&rows)
}

/// Open the cell's menu as a right click does.
pub(super) fn open_menu(cell: &GridCell) {
    let controllers = cell.observe_controllers();
    let gesture = (0..controllers.n_items())
        .filter_map(|index| controllers.item(index).and_downcast::<gtk::GestureClick>())
        .find(|gesture| gesture.button() == 3)
        .expect("a cell answers a right-click");
    gesture.emit_by_name::<()>("pressed", &[&1i32, &1.0f64, &1.0f64]);
}

/// Whether the window's focus is the grid or inside it.
pub(super) fn focus_in_grid(grid: &Grid) -> bool {
    gtk::prelude::GtkWindowExt::focus(&grid.window)
        .is_some_and(|focus| focus == *grid.view.upcast_ref::<gtk::Widget>() || focus.is_ancestor(&grid.view))
}

pub(super) fn two_text_rows() -> Grid {
    Grid::open(two_text_columns(), two_text_values())
}

pub(super) fn two_text_columns() -> Vec<ColumnInfo> {
    vec![named("id", "integer", true), named("name", "text", false)]
}

pub(super) fn two_text_values() -> Vec<Vec<Value>> {
    vec![
        vec![Value::Int(1), Value::Text("A".into())],
        vec![Value::Int(2), Value::Text("B".into())],
    ]
}

/// Open the cell's one-line editor and type `text` over its value.
pub(super) fn type_into(cell: &GridCell, text: &str) -> gtk::Text {
    begin_edit(cell);
    let editor = cell.inline_text().expect("the cell did not open for editing");
    editor.set_text(text);
    editor
}

pub(super) fn display_text(cell: &GridCell) -> String {
    cell.display()
        .and_then(|display| display.text())
        .map(|text| text.to_string())
        .unwrap_or_default()
}

/// Each edit the grid sent, as the row, the column and the value.
pub(super) fn edited_rows(messages: &[GridMsg]) -> Vec<(Option<RowKey>, usize, CellInput)> {
    messages
        .iter()
        .filter_map(|msg| match msg {
            GridMsg::Edit { row, column, edit } => {
                let input = match edit {
                    TrackerEdit::Cell { value, .. } => CellInput::Value(value.clone()),
                    TrackerEdit::DraftCell { input, .. } => input.clone(),
                    other => panic!("a cell commit made {other:?}"),
                };
                Some((row.key().cloned(), *column, input))
            }
            _ => None,
        })
        .collect()
}

pub(super) fn text(value: &str) -> CellInput {
    CellInput::Value(Value::Text(value.to_owned()))
}

pub(super) fn flag_rows() -> Grid {
    Grid::open(
        vec![named("id", "integer", true), named("flag", "boolean", false)],
        vec![
            vec![Value::Int(1), Value::Bool(false)],
            vec![Value::Int(2), Value::Bool(false)],
        ],
    )
}
