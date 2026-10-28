use std::collections::HashSet;

use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use gtk4::{self as gtk, glib};

use super::{DataGrid, GridCell, GridRow, PinnedRow};
use crate::services::change_tracker::RowKey;

/// What an action acts on: the cell a menu opened on, or the focused cell,
/// and the rows: the selection when that cell's row is in it, else the
/// row alone. Rows are pinned, so a page that lands meanwhile makes the
/// action act on nothing rather than on the rows that took their places.
#[derive(Debug, Clone)]
pub struct Target {
    pub cell: Option<(PinnedRow, usize)>,
    pub rows: Vec<PinnedRow>,
}

/// A target whose rows are all still in the grid.
#[derive(Debug, Clone)]
pub struct Resolved {
    pub cell: Option<(GridRow, usize)>,
    pub rows: Vec<GridRow>,
}

impl Target {
    pub fn resolve(&self) -> Option<Resolved> {
        let cell = match &self.cell {
            Some((row, column)) => Some((row.get()?.clone(), *column)),
            None => None,
        };
        let rows = self
            .rows
            .iter()
            .map(|row| row.get().cloned())
            .collect::<Option<Vec<_>>>()?;
        Some(Resolved { cell, rows })
    }
}

impl DataGrid {
    pub(crate) fn focused_cell(&self) -> Option<GridCell> {
        let window = self.root().and_downcast::<gtk::Window>()?;
        let focus = gtk::prelude::GtkWindowExt::focus(&window)?;
        let cell = GridCell::from_focus(&focus)?;
        cell.is_ancestor(&self.column_view()).then_some(cell)
    }

    /// The target of an action that is running now.
    pub(crate) fn target(&self) -> Option<Resolved> {
        if let Some(target) = self.imp().menu_target.borrow().as_ref() {
            return target.resolve();
        }
        self.focus_target().resolve()
    }

    /// The focused cell and the rows it acts on. With no focused cell, the
    /// selected rows.
    pub(crate) fn focus_target(&self) -> Target {
        match self
            .focused_cell()
            .and_then(|cell| Some((cell.row()?, cell.position()?, cell.column())))
        {
            Some((row, position, column)) => Target {
                cell: Some((row.pin(), column)),
                rows: self.rows_for(&row, position),
            },
            None => Target {
                cell: None,
                rows: self.selected_rows().iter().map(GridRow::pin).collect(),
            },
        }
    }

    /// The whole selection when `row` is in it, else `row` alone.
    pub(crate) fn rows_for(&self, row: &GridRow, position: u32) -> Vec<PinnedRow> {
        let selection = self.selection();
        let selected = selection.is_selected(position) && selection.item(position).as_ref() == Some(row.upcast_ref());
        match selected {
            true => self.selected_rows().iter().map(GridRow::pin).collect(),
            false => vec![row.pin()],
        }
    }

    /// Every row, with the keyboard on the rows so the keys that act on
    /// the selection reach them: a header's menu leaves the focus where it
    /// was.
    pub(crate) fn select_all_rows(&self) {
        self.selection().select_all();
        match self.focused_cell() {
            // An open editor gives the keyboard up as it does to a click
            // on its cell, which ends the edit.
            Some(cell) if self.edit().editor_has_focus() => {
                if let Some(focusable) = cell.parent() {
                    focusable.grab_focus();
                }
            }
            Some(_) => {}
            None => {
                self.column_view().grab_focus();
            }
        }
    }

    pub(crate) fn selected_rows(&self) -> Vec<GridRow> {
        let selection = self.selection();
        let bitset = selection.selection();
        let mut positions: Vec<u32> = (0..bitset.size()).map(|nth| bitset.nth(nth as u32)).collect();
        positions.sort_unstable();
        positions
            .into_iter()
            .filter_map(|position| selection.item(position).and_downcast::<GridRow>())
            .collect()
    }

    /// A right click moves the focus to the row it was on, so Row Details
    /// and the keys follow the row the menu acts on: to the clicked cell,
    /// else to the focused column of that row. On a selected row it keeps
    /// the selection, so a block still copies whole; any other row becomes
    /// the selection.
    pub(crate) fn select_for_menu(&self, position: u32, column: Option<usize>) {
        let focused = self.focused_cell();
        let column = column
            .or_else(|| focused.as_ref().map(GridCell::column))
            .or_else(|| self.shown_columns().first().copied());
        if let Some(column) = column
            && !focused.is_some_and(|cell| cell.position() == Some(position) && cell.column() == column)
        {
            self.focus_cell(position, column);
        }
        let selection = self.selection();
        if position < selection.n_items() && !selection.is_selected(position) {
            selection.select_item(position, true);
        }
    }

    /// Hold `target` for the actions a menu offers, until it closes.
    pub(crate) fn hold_menu_target(&self, target: Target) {
        self.imp().menu_target.replace(Some(target));
    }

    /// Let go of the menu's target once the item it activated, if any,
    /// has run: GTK closes a menu before its item's action runs.
    pub(crate) fn release_menu_target_soon(&self) {
        let grid = self.downgrade();
        glib::idle_add_local_once(move || {
            if let Some(grid) = grid.upgrade() {
                grid.imp().menu_target.take();
                grid.refresh_actions();
            }
        });
    }

    /// Move the focus to the cell at `position` in data column `column`,
    /// scrolling it into view.
    pub(crate) fn focus_cell(&self, position: u32, column: usize) -> Option<GridCell> {
        let view = self.column_view();
        let view_column = self.data_view_column(column)?;
        if position >= self.selection().n_items() {
            return None;
        }
        view.scroll_to(position, Some(&view_column), gtk::ListScrollFlags::FOCUS, None);
        let landed = |cell: &GridCell| cell.position() == Some(position) && cell.column() == column;
        // `scroll_to` moves the focus only while it is in the list already.
        // Otherwise it marks the cell the list focuses next, which the grab
        // then reaches.
        if !self.focused_cell().is_some_and(|cell| landed(&cell)) {
            view.grab_focus();
        }
        self.focused_cell().filter(landed)
    }

    /// Give the focus back to `cell` once its editor closed, since the
    /// editor took the focus with it.
    pub(crate) fn return_focus(&self, cell: &GridCell) {
        if let Some(position) = cell.position() {
            self.focus_cell(position, cell.column());
        }
    }

    pub(super) fn watch_focus(&self) {
        self.stop_watching_focus();
        let Some(window) = self.root().and_downcast::<gtk::Window>() else {
            return;
        };
        let handler = window.connect_focus_widget_notify(glib::clone!(
            #[weak(rename_to = grid)]
            self,
            move |_| grid.focus_moved()
        ));
        self.imp().focus_watch.replace(Some((window.downgrade(), handler)));
    }

    pub(super) fn stop_watching_focus(&self) {
        if let Some((window, handler)) = self.imp().focus_watch.take()
            && let Some(window) = window.upgrade()
        {
            window.disconnect(handler);
        }
    }

    fn focus_moved(&self) {
        if self.focused_cell().is_none() {
            return;
        }
        self.refresh_actions();
        self.imp().detail_pane.follow_focus();
    }
}

/// The selection and the focused cell, by key, across a reload that keeps
/// the slots but gives them other rows.
pub(super) struct Restore {
    selected: HashSet<RowKey>,
    focused: Option<(RowKey, usize)>,
}

impl Restore {
    pub(super) fn capture(grid: &DataGrid) -> Self {
        let selected = grid.selected_rows().iter().filter_map(GridRow::tracker_key).collect();
        let focused = grid
            .focused_cell()
            .and_then(|cell| Some((cell.row()?.tracker_key()?, cell.column())));
        Self { selected, focused }
    }

    /// One walk of the rows in view order: a lookup per key would scan the
    /// list again for each row a Select All kept.
    pub(super) fn apply(self, grid: &DataGrid) {
        let selection = grid.selection();
        let bitset = gtk::Bitset::new_empty();
        let mut focus = None;
        if !self.selected.is_empty() || self.focused.is_some() {
            for position in 0..selection.n_items() {
                let Some(key) = selection
                    .item(position)
                    .and_downcast::<GridRow>()
                    .and_then(|row| row.tracker_key())
                else {
                    continue;
                };
                if self.selected.contains(&key) {
                    bitset.add(position);
                }
                if let Some((focused, column)) = &self.focused
                    && *focused == key
                {
                    focus = Some((position, *column));
                }
            }
        }
        let all = gtk::Bitset::new_range(0, selection.n_items());
        selection.set_selection(&bitset, &all);
        if let Some((position, column)) = focus {
            grid.focus_cell(position, column);
        }
    }
}
