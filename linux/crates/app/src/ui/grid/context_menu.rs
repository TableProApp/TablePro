use gtk4::prelude::*;
use gtk4::{self as gtk, glib};

use super::GridCell;
use super::grid_menus::GridMenus;
use super::menu_rows::menu_rows_of;
use super::selection::select_row_for_menu;

/// The cell a menu was opened on. The cell holds the menu through its
/// gesture, so the menu holds the cell weakly, and asks it for its row
/// only when an item is chosen.
#[derive(Default)]
pub(super) struct CellContext {
    cell: glib::WeakRef<GridCell>,
}

impl CellContext {
    fn set(&self, cell: &GridCell) {
        self.cell.set(Some(cell));
    }

    pub(super) fn cell(&self) -> Option<GridCell> {
        self.cell.upgrade()
    }
}

pub(super) fn attach_cell_gesture(cell: &GridCell, column_view: &glib::WeakRef<gtk::ColumnView>, menus: &GridMenus) {
    // The cell's lock follows the row bound to it, so the menu is picked
    // when it opens.
    let prepare = {
        let menus = menus.clone();
        move |cell: &GridCell, column_view: &gtk::ColumnView| -> gtk::PopoverMenu {
            menus.context.set(cell);
            if let Some(position) = cell.position() {
                select_row_for_menu(column_view, position);
            }
            menus.actions.arm(cell, &menu_rows_of(column_view, cell));
            match cell.lock() {
                None => menus.editable_popover.clone(),
                Some(_) => menus.readonly_popover.clone(),
            }
        }
    };

    // The handlers below read the cell from their own arguments: the
    // cell owns its controllers, so capturing it would be a cycle.
    let view_for_gesture = column_view.clone();
    let prepare_for_gesture = prepare.clone();
    let gesture = gtk::GestureClick::new();
    gesture.set_button(3);
    gesture.connect_pressed(move |g, _, x, y| {
        let (Some(cv), Some(cell)) = (view_for_gesture.upgrade(), g.widget().and_downcast::<GridCell>()) else {
            return;
        };
        g.set_state(gtk::EventSequenceState::Claimed);
        let popover = prepare_for_gesture(&cell, &cv);
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

    let view_for_key = column_view.clone();
    let menu_shortcut = gtk::Shortcut::builder()
        .trigger(&gtk::KeyvalTrigger::new(
            gtk::gdk::Key::Menu,
            gtk::gdk::ModifierType::empty(),
        ))
        .action(&gtk::CallbackAction::new(move |widget, _| {
            let (Some(cv), Some(cell)) = (view_for_key.upgrade(), widget.downcast_ref::<GridCell>()) else {
                return glib::Propagation::Proceed;
            };
            let popover = prepare(cell, &cv);
            // The Menu key has no pointer position, so the popover points
            // at the whole cell.
            if let Some(bounds) = cell.compute_bounds(&cv) {
                let rect = gtk::gdk::Rectangle::new(
                    bounds.x() as i32,
                    bounds.y() as i32,
                    bounds.width() as i32,
                    bounds.height() as i32,
                );
                popover.set_pointing_to(Some(&rect));
            } else {
                popover.set_pointing_to(None);
            }
            popover.popup();
            glib::Propagation::Stop
        }))
        .build();
    let shortcut_controller = gtk::ShortcutController::new();
    shortcut_controller.add_shortcut(menu_shortcut);
    cell.add_controller(shortcut_controller);
}
