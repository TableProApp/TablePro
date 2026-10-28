use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use gtk4::{gio, glib};

use super::{DataGrid, GridSorting, column_chooser, copy, find_bar, references};

/// Add `grid.<name>`, run on the grid. The action holds the grid weakly:
/// the grid owns its action group.
pub(crate) fn add(grid: &DataGrid, name: &str, act: impl Fn(&DataGrid) + 'static) {
    let action = gio::SimpleAction::new(name, None);
    let weak = grid.downgrade();
    action.connect_activate(move |_, _| {
        if let Some(grid) = weak.upgrade() {
            act(&grid);
        }
    });
    grid.imp().actions.add_action(&action);
}

/// Add `grid.<name>` taking a data column's index, for a header's menu,
/// which GTK opens without telling the grid which column it is on.
pub(crate) fn add_for_column(grid: &DataGrid, name: &str, act: impl Fn(&DataGrid, usize) + 'static) {
    let action = gio::SimpleAction::new(name, Some(glib::VariantTy::UINT32));
    let weak = grid.downgrade();
    action.connect_activate(move |_, parameter| {
        let (Some(grid), Some(index)) = (weak.upgrade(), parameter.and_then(glib::Variant::get::<u32>)) else {
            return;
        };
        act(&grid, index as usize);
    });
    grid.imp().actions.add_action(&action);
}

pub(crate) fn enable(grid: &DataGrid, name: &str, enabled: bool) {
    if let Some(action) = grid
        .imp()
        .actions
        .lookup_action(name)
        .and_downcast::<gio::SimpleAction>()
    {
        action.set_enabled(enabled);
    }
}

pub fn install(grid: &DataGrid) {
    install_column_actions(grid);
    add(grid, "menu", |grid| {
        if let Some(cell) = grid.focused_cell() {
            grid.open_cell_menu(&cell, None);
        }
    });
    add(grid, "clear-selection", |grid| {
        grid.selection().unselect_all();
    });
    add(grid, "select-all", DataGrid::select_all_rows);
    let details = gio::SimpleAction::new_stateful("show-details", None, &false.to_variant());
    let weak = grid.downgrade();
    details.connect_change_state(move |action, state| {
        let (Some(grid), Some(shown)) = (weak.upgrade(), state.and_then(glib::Variant::get::<bool>)) else {
            return;
        };
        action.set_state(&shown.to_variant());
        grid.imp().split_view.set_show_sidebar(shown);
    });
    grid.imp().actions.add_action(&details);
    let weak = details.downgrade();
    // The pane closes itself too: its own button, or a click outside it
    // while it overlaps the rows.
    grid.imp().split_view.connect_show_sidebar_notify(move |split_view| {
        if let Some(details) = weak.upgrade() {
            details.set_state(&split_view.shows_sidebar().to_variant());
        }
    });
    add(grid, "columns", column_chooser::present);
    grid.edit().install_actions(grid);
    copy::install_actions(grid);
    references::install_actions(grid);
    find_bar::install_actions(grid);
}

fn install_column_actions(grid: &DataGrid) {
    let on_target_column = |act: fn(&DataGrid, usize)| {
        move |grid: &DataGrid| {
            if let Some(index) = grid.target_column() {
                act(grid, index);
            }
        }
    };
    add(
        grid,
        "sort-ascending",
        on_target_column(|grid, index| grid.sort_by(Some((index, true)))),
    );
    add(
        grid,
        "sort-descending",
        on_target_column(|grid, index| grid.sort_by(Some((index, false)))),
    );
    add_for_column(grid, "sort-column-ascending", |grid, index| {
        grid.sort_by(Some((index, true)))
    });
    add_for_column(grid, "sort-column-descending", |grid, index| {
        grid.sort_by(Some((index, false)))
    });
    add(grid, "clear-sort", |grid| grid.sort_by(None));
    add(
        grid,
        "hide-column",
        on_target_column(|grid, index| grid.set_column_visible(index, false)),
    );
    add_for_column(grid, "hide-column-at", |grid, index| {
        grid.set_column_visible(index, false)
    });
    add(
        grid,
        "size-to-fit",
        on_target_column(|grid, index| grid.set_column_width(index, None)),
    );
    add_for_column(grid, "size-column-to-fit", |grid, index| {
        grid.set_column_width(index, None)
    });
    add(
        grid,
        "widen-column",
        on_target_column(|grid, index| grid.step_column(index, true)),
    );
    add(
        grid,
        "narrow-column",
        on_target_column(|grid, index| grid.step_column(index, false)),
    );
}

impl DataGrid {
    /// The data column an action on "the column" means: the cell a menu
    /// opened on, else the focused cell's.
    pub(crate) fn target_column(&self) -> Option<usize> {
        self.target()?.cell.map(|(_, column)| column)
    }

    /// Open the detail pane on the focused row, with `column`'s field.
    pub(crate) fn show_details_for(&self, column: usize) {
        self.imp().detail_pane.select_field(column);
        if let Some(details) = self.imp().actions.lookup_action("show-details") {
            details.change_state(&true.to_variant());
        }
        self.imp().detail_pane.focus_value();
    }

    /// Set every action's enabled state for what the grid now shows and
    /// the target an action would act on. The keys of the actions held off
    /// while the inline editor has the focus belong to the editor.
    pub(crate) fn refresh_actions(&self) {
        let target = self.target();
        let editing = self.edit().editor_has_focus();
        let column = target
            .as_ref()
            .and_then(|target| target.cell.as_ref().map(|(_, column)| *column));
        let sorting = self.imp().columns.borrow().sorting();
        let sortable = column
            .and_then(|index| self.grid_columns().get(index).map(|column| column.sortable()))
            .unwrap_or(false);
        let sorts = sorting != GridSorting::None && sortable && !editing;
        enable(
            self,
            "menu",
            !editing && target.as_ref().is_some_and(|target| target.cell.is_some()),
        );
        enable(self, "sort-ascending", sorts);
        enable(self, "sort-descending", sorts);
        enable(self, "clear-sort", sorting != GridSorting::None && self.is_sorted());
        for name in ["hide-column", "size-to-fit", "widen-column", "narrow-column"] {
            enable(self, name, !editing && column.is_some());
        }
        enable(self, "clear-selection", !editing && self.selected_count() > 1);
        self.edit().refresh_actions(self, target.as_ref());
        copy::refresh_actions(self, target.as_ref());
        references::refresh_actions(self, target.as_ref());
        find_bar::refresh_actions(self);
    }
}
