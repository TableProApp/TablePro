use std::cell::RefCell;
use std::collections::HashSet;

use gtk4::prelude::*;
use gtk4::{self as gtk, glib};

use super::grid_menus::GridMenus;
use super::menu_rows::menu_rows_of;
use super::selection::select_row_for_menu;
use super::{GridCell, RowObject};

/// What a menu was opened on, fixed as it opens. A page that lands while
/// the menu is open rebinds the cell to another row, so an item chosen
/// then acts on the rows the menu was opened for, or on nothing once
/// they have left the grid. Everything is held weakly: the cell holds
/// the menu through its gesture, and a row the grid let go of is gone.
#[derive(Default)]
pub(super) struct CellContext {
    opened_on: RefCell<Option<OpenedOn>>,
}

struct OpenedOn {
    cell: glib::WeakRef<GridCell>,
    row: glib::WeakRef<RowObject>,
    rows: Vec<glib::WeakRef<RowObject>>,
}

/// The cell, the row it showed and the rows a chosen item acts on.
pub(super) struct MenuTarget {
    pub(super) cell: GridCell,
    pub(super) row: RowObject,
    pub(super) rows: Vec<RowObject>,
}

impl CellContext {
    fn set(&self, cell: &GridCell, rows: &[RowObject]) {
        let opened_on = cell.row().map(|row| OpenedOn {
            cell: cell.downgrade(),
            row: row.downgrade(),
            rows: rows.iter().map(|row| row.downgrade()).collect(),
        });
        self.opened_on.replace(opened_on);
    }

    /// The target while the grid still shows every row of it.
    pub(super) fn target(&self, column_view: &gtk::ColumnView) -> Option<MenuTarget> {
        let opened_on = self.opened_on.borrow();
        let opened_on = opened_on.as_ref()?;
        let target = MenuTarget {
            cell: opened_on.cell.upgrade()?,
            row: opened_on.row.upgrade()?,
            rows: opened_on
                .rows
                .iter()
                .map(|row| row.upgrade())
                .collect::<Option<Vec<_>>>()?,
        };
        let model = column_view.model()?;
        let shown: HashSet<RowObject> = (0..model.n_items())
            .filter_map(|position| model.item(position).and_downcast::<RowObject>())
            .collect();
        let all_shown = shown.contains(&target.row) && target.rows.iter().all(|row| shown.contains(row));
        all_shown.then_some(target)
    }
}

/// Arm the cell menu for `cell` and pick the one its lock calls for.
/// The cell's lock follows the row bound to it, so the menu is picked
/// when it opens.
pub(super) fn prepare_menu(menus: &GridMenus, cell: &GridCell, column_view: &gtk::ColumnView) -> gtk::PopoverMenu {
    if let Some(position) = cell.position() {
        select_row_for_menu(column_view, position);
    }
    let rows = menu_rows_of(column_view, cell);
    menus.context.set(cell, &rows);
    menus.actions.arm(cell, &rows);
    match cell.lock() {
        None => menus.editable_popover.clone(),
        Some(_) => menus.readonly_popover.clone(),
    }
}

pub(super) fn attach_cell_gesture(cell: &GridCell, column_view: &glib::WeakRef<gtk::ColumnView>, menus: &GridMenus) {
    // The handler reads the cell from its gesture: the cell owns its
    // controllers, so capturing it would be a cycle.
    let view_for_gesture = column_view.clone();
    let menus = menus.clone();
    let gesture = gtk::GestureClick::new();
    gesture.set_button(3);
    gesture.connect_pressed(move |g, _, x, y| {
        let (Some(cv), Some(cell)) = (view_for_gesture.upgrade(), g.widget().and_downcast::<GridCell>()) else {
            return;
        };
        g.set_state(gtk::EventSequenceState::Claimed);
        let popover = prepare_menu(&menus, &cell, &cv);
        // The popover is parented to the column view, so it points in
        // the view's coordinates, not the cell's.
        let local = gtk::graphene::Point::new(x as f32, y as f32);
        let (cv_x, cv_y) = cell
            .compute_point(&cv, &local)
            .map(|p| (p.x() as i32, p.y() as i32))
            .unwrap_or((x as i32, y as i32));
        popover.set_pointing_to(Some(&gtk::gdk::Rectangle::new(cv_x, cv_y, 1, 1)));
        popover.popup();
    });
    cell.add_controller(gesture);
}

#[cfg(test)]
mod tests {
    use gtk4 as gtk;
    use gtk4::prelude::*;

    use crate::services::change_tracker::RowKey;
    use crate::test_support::{FocusThief, after_next_frame, descendants, drain_main_context, wait_until};
    use crate::ui::grid::test_grid::{Grid, WAIT, focus_in_grid, key, page, two_text_rows};
    use crate::ui::grid::{GridCell, GridMsg, RowObject};

    fn open_menu(cell: &GridCell) {
        let controllers = cell.observe_controllers();
        let gesture = (0..controllers.n_items())
            .filter_map(|index| controllers.item(index).and_downcast::<gtk::GestureClick>())
            .find(|gesture| gesture.button() == 3)
            .expect("a cell answers a right-click");
        gesture.emit_by_name::<()>("pressed", &[&1i32, &1.0f64, &1.0f64]);
    }

    fn choose(grid: &Grid, actions: &[&str]) {
        for action in actions {
            grid.view
                .activate_action(action, None)
                .unwrap_or_else(|_| panic!("the menu has no {action}"));
        }
    }

    /// Each row-changing message the menu sent, by the rows it names.
    fn acted_on(grid: &Grid) -> Vec<(&'static str, Vec<Option<RowKey>>)> {
        let keys = |rows: &[RowObject]| rows.iter().map(|row| row.key().cloned()).collect();
        grid.take_messages()
            .into_iter()
            .filter_map(|msg| match msg {
                GridMsg::SetCellValue { row, .. } => Some(("set", vec![row.key().cloned()])),
                GridMsg::DeleteRows { rows } => Some(("delete", keys(&rows))),
                GridMsg::DuplicateRows { rows } => Some(("duplicate", keys(&rows))),
                GridMsg::CopyRowsAsInsert { rows } => Some(("insert", keys(&rows))),
                _ => None,
            })
            .collect()
    }

    #[gtk4::test]
    fn a_page_that_lands_under_an_open_menu_leaves_its_items_acting_on_nothing() {
        let grid = two_text_rows();
        let cell = grid.cell_of(2, 1);
        open_menu(&cell);

        grid.store.splice(0, grid.store.n_items(), &page(3..5));
        drain_main_context();
        choose(
            &grid,
            &[
                "cell.set-null",
                "cell.delete-row",
                "cell.duplicate-row",
                "cell.copy-row-insert",
            ],
        );

        assert_eq!(acted_on(&grid), Vec::new(), "the menu acted on a row of the new page");
    }

    fn shown_menu(grid: &Grid) -> Option<gtk::PopoverMenu> {
        descendants(&grid.view)
            .into_iter()
            .filter_map(|widget| widget.downcast::<gtk::PopoverMenu>().ok())
            .find(|menu| menu.is_visible())
    }

    /// A menu closed, or kept from opening by another client holding the
    /// pointer, leaves the focus on a cell. A page that then takes that
    /// cell's row out, and the window taking the focus back before the
    /// next frame, crashed GTK 4.22 on the detached row.
    #[gtk4::test]
    fn a_page_under_a_closed_menu_then_a_focus_in_keeps_the_focus_in_the_grid() {
        let grid = two_text_rows();
        grid.focus(0, 1);
        open_menu(&grid.cell_of(2, 1));
        if let Some(menu) = shown_menu(&grid) {
            menu.popdown();
        }
        assert!(
            grid.focused_cell().is_some(),
            "the closed menu left the focus off the grid"
        );
        let thief = FocusThief::take_from(&grid.window).expect("another window takes the focus");

        grid.store.splice(0, grid.store.n_items(), &page(3..5));
        thief.give_back(&grid.window);
        drain_main_context();
        after_next_frame(&grid.window);

        assert!(focus_in_grid(&grid), "the focus left the grid");
    }

    /// The list keeps the widgets of the first row for its focus, so the
    /// menu opens on a row further down, which scrolling hands on.
    #[gtk4::test]
    fn a_cell_scrolled_onto_another_row_leaves_the_menu_on_its_own() {
        let grid = two_text_rows();
        grid.store.splice(grid.store.n_items(), 0, &page(3..300));
        let cell = drawn_cell(&grid, 6, 1);
        open_menu(&cell);

        grid.view
            .scroll_to(grid.store.n_items() - 1, None, gtk::ListScrollFlags::NONE, None);
        wait_until(WAIT, || cell.row().is_some_and(|row| row.key() != Some(&key(6))))
            .expect("the scroll did not rebind the clicked cell");
        choose(&grid, &["cell.set-null", "cell.delete-row"]);

        assert_eq!(
            acted_on(&grid),
            [("set", vec![Some(key(6))]), ("delete", vec![Some(key(6))])]
        );
    }

    fn drawn_cell(grid: &Grid, id: i64, column: usize) -> GridCell {
        let mut drawn = None;
        wait_until(WAIT, || {
            drawn = grid
                .cells()
                .into_iter()
                .find(|cell| cell.column() == column && cell.row().is_some_and(|row| row.key() == Some(&key(id))));
            drawn.is_some()
        })
        .expect("the row's cell is drawn");
        drawn.expect("a drawn cell")
    }
}
