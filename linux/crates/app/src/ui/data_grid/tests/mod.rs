mod cells;
mod columns;
mod gutter;
mod keyboard;
mod layout;
mod menus;
mod selection;
mod sorting;
mod summary;
mod values;
mod view;

use gtk4 as gtk;
use gtk4::prelude::*;
use gtk4::subclass::prelude::ObjectSubclassIsExt;
use gtk4::{gdk, gio, pango};
use tablepro_core::column::ColumnType;
use tablepro_core::{ColumnInfo, Value};
use tempfile::TempDir;
use uuid::Uuid;

use super::row_detail::RowDetailPane;
use super::test_grid::{Grid, WAIT, key, named, persisted};
use super::{GridCell, GridRequest, LayoutBinding, RowData};
use crate::application::ShortcutOwner;
use crate::persistence::ColumnLayoutStore;
use crate::runtime::AppRuntime;
use crate::services::grid::ColumnLayout;
use crate::services::tracker_edit::TrackerEdit;
use crate::test_support::shortcut_keys::{owner_controller, shortcuts, trigger_keys};
use crate::test_support::{drain_main_context, wait_until};

fn none() -> gdk::ModifierType {
    gdk::ModifierType::empty()
}

/// Run what `key` does on the focused cell, as a key press reaching the
/// grid's controllers would. `true` when the grid took the key.
fn press(grid: &Grid, key: gdk::Key, modifiers: gdk::ModifierType) -> bool {
    let view: gtk::Widget = grid.grid.column_view().upcast();
    let on_grid: gtk::Widget = grid.grid.clone().upcast();
    let wanted = (key.to_lower(), modifiers);
    [(ShortcutOwner::GridCell, view), (ShortcutOwner::Grid, on_grid)]
        .into_iter()
        .filter_map(|(owner, widget)| Some((owner_controller(&widget, owner)?, widget)))
        .flat_map(|(controller, widget)| {
            shortcuts(&controller)
                .into_iter()
                .map(move |shortcut| (shortcut, widget.clone()))
        })
        .find(|(shortcut, _)| {
            shortcut
                .trigger()
                .is_some_and(|trigger| trigger_keys(&trigger).contains(&wanted))
        })
        .and_then(|(shortcut, widget)| Some((shortcut.action()?, widget)))
        .map(|(action, widget)| action.activate(gtk::ShortcutActionFlags::empty(), &widget, None))
        .expect("the grid binds the key")
}

/// Saved rows of a two-column table, keyed `ids`, in that order.
fn keyed(ids: &[i64]) -> Vec<RowData> {
    let rows: Vec<Vec<Value>> = ids
        .iter()
        .map(|id| vec![Value::Int(*id), Value::Text(format!("row {id}"))])
        .collect();
    persisted(&rows)
}

fn text(value: &str) -> Value {
    Value::Text(value.to_owned())
}

/// A column with no type, as a PostgreSQL editor result reads one.
fn untyped(name: &str) -> ColumnInfo {
    let mut column = named(name, "text", false);
    column.column_type = ColumnType::untyped_text("text");
    column
}

fn int(value: &Value) -> Option<i64> {
    match value {
        Value::Int(number) => Some(*number),
        _ => None,
    }
}

/// `column` of each row, in the order on screen.
fn column_on_screen(grid: &Grid, column: usize) -> Vec<Value> {
    grid.grid
        .shown_rows()
        .iter()
        .map(|row| {
            row.cells()
                .and_then(|cells| cells.get(column).cloned())
                .unwrap_or(Value::Null)
        })
        .collect()
}

fn ids_on_screen(grid: &Grid) -> Vec<i64> {
    column_on_screen(grid, 0).iter().filter_map(int).collect()
}

fn selected_ids(grid: &Grid) -> Vec<i64> {
    grid.grid
        .selected_rows()
        .iter()
        .filter_map(|row| row.cells().and_then(|cells| cells.first().and_then(int)))
        .collect()
}

fn row_widget(cell: &GridCell) -> gtk::Widget {
    cell.parent()
        .and_then(|cell_widget| cell_widget.parent())
        .expect("the row widget")
}

fn described(widget: &impl IsA<gtk::Accessible>) -> bool {
    gtk::test_accessible_has_property(widget, gtk::AccessibleProperty::Description)
}

/// The sorts the grid asked its host for, oldest first.
fn sorts(grid: &Grid) -> Vec<Option<(usize, bool)>> {
    grid.take_requests()
        .into_iter()
        .filter_map(|request| match request {
            GridRequest::Sort(sort) => Some(sort),
            _ => None,
        })
        .collect()
}

fn details_shown(grid: &Grid) -> bool {
    grid.grid
        .actions()
        .action_state("show-details")
        .and_then(|state| state.get::<bool>())
        .unwrap_or(false)
}

fn pane(grid: &Grid) -> RowDetailPane {
    grid.grid.imp().detail_pane.get()
}

fn close_menus(grid: &Grid) {
    if let Some(menus) = grid.grid.menus() {
        menus.cell.popdown();
        if let Some(empty) = &menus.empty {
            empty.popdown();
        }
        menus.reference_chooser.popdown();
    }
    drain_main_context();
}

fn cell_menu(grid: &Grid) -> gio::MenuModel {
    grid.grid
        .menus()
        .and_then(|menus| menus.cell.menu_model())
        .expect("the cell menu")
}

/// Every action `menu` names, with its column for a header's item,
/// sections and submenus included.
fn menu_actions(menu: &gio::MenuModel) -> Vec<(String, Option<u32>)> {
    let mut found = Vec::new();
    for position in 0..menu.n_items() {
        if let Some(action) = menu
            .item_attribute_value(position, "action", None)
            .and_then(|value| value.get::<String>())
        {
            let target = menu
                .item_attribute_value(position, "target", None)
                .and_then(|value| value.get::<u32>());
            found.push((action, target));
        }
        for link in ["section", "submenu"] {
            if let Some(inner) = menu.item_link(position, link) {
                found.extend(menu_actions(&inner));
            }
        }
    }
    found
}

fn action_names(menu: &gio::MenuModel) -> Vec<String> {
    menu_actions(menu).into_iter().map(|(action, _)| action).collect()
}

fn submenu(menu: &gio::MenuModel, label: &str) -> Option<gio::MenuModel> {
    (0..menu.n_items()).find_map(|position| {
        let named = menu
            .item_attribute_value(position, "label", None)
            .and_then(|value| value.get::<String>());
        let here = match named.as_deref() == Some(label) {
            true => menu.item_link(position, "submenu"),
            false => None,
        };
        here.or_else(|| {
            menu.item_link(position, "section")
                .and_then(|section| submenu(&section, label))
        })
    })
}

/// The key a menu item shows: `None` when `menu` has no such item.
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

fn data_column(grid: &Grid, index: usize) -> gtk::ColumnViewColumn {
    grid.grid.data_view_column(index).expect("the column")
}

/// A resize step: two digits of the font a value draws in.
fn step(grid: &Grid) -> i32 {
    let display = grid.cell_at(0, 1).display().cloned().expect("a value's text");
    let metrics = display.pango_context().metrics(None, None);
    (pango::units_to_double(metrics.approximate_digit_width()) * 2.0).ceil() as i32
}

/// How wide the first row's cell of `column` is drawn.
fn shown_width(grid: &Grid, column: usize) -> i32 {
    let cell = grid.cell_at(0, column);
    let cell_widget = cell.parent().expect("the cell's widget");
    cell_widget
        .compute_bounds(&cell_widget)
        .map_or(0, |bounds| bounds.width().round() as i32)
}

/// The width on screen, once the column's own width is drawn.
fn settled_width(grid: &Grid, column: usize) -> i32 {
    wait_until(WAIT, || {
        shown_width(grid, column) == data_column(grid, column).fixed_width()
    })
    .expect("the column drawn at its own width");
    shown_width(grid, column)
}

/// `Grid::build` waits for the cells, not for the first layout, before
/// which no width is the one on screen.
fn laid_out(grid: Grid) -> Grid {
    wait_until(WAIT, || grid.grid.column_view().width() > 0).expect("the grid to be laid out");
    grid
}

fn rename_first(grid: &Grid, to: &str) {
    grid.grid.apply_delta(&grid.tracker.apply(TrackerEdit::Cell {
        row_key: key(1),
        col: 1,
        original: text("A"),
        value: tablepro_core::edit::CellInput::Value(text(to)),
    }));
}

/// Mark the saved row `id` of the two-text-column rows for deletion.
fn delete_saved(grid: &Grid, id: i64, name: &str) {
    grid.grid.apply_delta(&grid.tracker.apply(TrackerEdit::DeleteRows {
        persisted: vec![(key(id), vec![Value::Int(id), text(name)].into())],
        drafts: Vec::new(),
    }));
}

/// The cell of the first draft once the list draws it.
fn draft_cell(grid: &Grid) -> GridCell {
    let mut draft = None;
    wait_until(WAIT, || {
        draft = grid
            .cells()
            .into_iter()
            .find(|cell| cell.row().is_some_and(|row| row.draft_id().is_some()));
        draft.is_some()
    })
    .expect("the draft is drawn");
    draft.expect("the draft's cell")
}

/// A layout store in a directory of its own, for one connection.
struct Layouts {
    store: ColumnLayoutStore,
    connection_id: Uuid,
    _root: TempDir,
    _runtime: AppRuntime,
}

impl Layouts {
    fn new() -> Self {
        let root = tempfile::tempdir().expect("tempdir");
        let runtime = crate::test_support::test_runtime();
        let store = ColumnLayoutStore::load(root.path().join("column_widths.json"), &runtime.tasks());
        Self {
            store,
            connection_id: Uuid::new_v4(),
            _root: root,
            _runtime: runtime,
        }
    }

    fn binding(&self, table: &str) -> LayoutBinding {
        LayoutBinding {
            store: self.store.clone(),
            connection_id: self.connection_id,
            schema: Some("public".to_owned()),
            table: table.to_owned(),
        }
    }

    fn saved(&self, table: &str) -> ColumnLayout {
        self.store.layout(self.connection_id, Some("public"), table)
    }
}
