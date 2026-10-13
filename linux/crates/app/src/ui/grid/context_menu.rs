use gtk4::prelude::*;
use gtk4::{self as gtk, glib};

use super::grid_menus::GridMenus;
use super::selection::select_row_for_menu;
use super::widget_slot::POSITION_SLOT;

#[derive(Clone)]
pub(super) struct CellContext {
    pub(super) widget: gtk::Widget,
    pub(super) col_index: usize,
    pub(super) column_name: String,
}

/// The cell holds the menu through its gesture, so the menu holds the
/// cell weakly.
pub(super) struct ClickedCell {
    widget: glib::WeakRef<gtk::Widget>,
    col_index: usize,
    column_name: String,
}

impl ClickedCell {
    pub(super) fn get(&self) -> Option<CellContext> {
        Some(CellContext {
            widget: self.widget.upgrade()?,
            col_index: self.col_index,
            column_name: self.column_name.clone(),
        })
    }
}

#[derive(Clone)]
pub(super) struct CellMenuTarget {
    pub(super) col_index: usize,
    pub(super) column_name: String,
    pub(super) editable: bool,
    pub(super) text_editable: bool,
    pub(super) accepts_empty: bool,
}

pub(super) fn attach_cell_gesture(
    widget: &gtk::Widget,
    column_view: &glib::WeakRef<gtk::ColumnView>,
    target: CellMenuTarget,
    menus: &GridMenus,
) {
    let popover = if target.editable {
        menus.editable_popover.clone()
    } else {
        menus.readonly_popover.clone()
    };

    let prepare = {
        let context = menus.context.clone();
        let actions = menus.actions.clone();
        let target = target.clone();
        move |widget: &gtk::Widget, column_view: &gtk::ColumnView| {
            *context.borrow_mut() = Some(ClickedCell {
                widget: widget.downgrade(),
                col_index: target.col_index,
                column_name: target.column_name.clone(),
            });
            actions.arm(&target);
            if let Some(position) = POSITION_SLOT.get(widget) {
                select_row_for_menu(column_view, position);
            }
        }
    };

    // The handlers below read the cell from their own arguments: the
    // cell owns its controllers, so capturing it would be a cycle.
    let view_for_gesture = column_view.clone();
    let popover_for_gesture = popover.clone();
    let prepare_for_gesture = prepare.clone();
    let gesture = gtk::GestureClick::new();
    gesture.set_button(3);
    gesture.connect_pressed(move |g, _, x, y| {
        let (Some(cv), Some(cell)) = (view_for_gesture.upgrade(), g.widget()) else {
            return;
        };
        g.set_state(gtk::EventSequenceState::Claimed);
        prepare_for_gesture(&cell, &cv);
        // The popover is parented to the column view, so it points in
        // the view's coordinates, not the cell's.
        let local = gtk::graphene::Point::new(x as f32, y as f32);
        let (cv_x, cv_y) = cell
            .compute_point(&cv, &local)
            .map(|p| (p.x() as i32, p.y() as i32))
            .unwrap_or((x as i32, y as i32));
        popover_for_gesture.set_pointing_to(Some(&gtk::gdk::Rectangle::new(cv_x, cv_y, 1, 1)));
        popover_for_gesture.popup();
    });
    widget.add_controller(gesture);

    let view_for_key = column_view.clone();
    let popover_for_key = popover;
    let menu_shortcut = gtk::Shortcut::builder()
        .trigger(&gtk::KeyvalTrigger::new(
            gtk::gdk::Key::Menu,
            gtk::gdk::ModifierType::empty(),
        ))
        .action(&gtk::CallbackAction::new(move |cell, _| {
            let Some(cv) = view_for_key.upgrade() else {
                return glib::Propagation::Proceed;
            };
            prepare(cell, &cv);
            // The Menu key has no pointer position, so the popover points
            // at the whole cell.
            if let Some(bounds) = cell.compute_bounds(&cv) {
                let rect = gtk::gdk::Rectangle::new(
                    bounds.x() as i32,
                    bounds.y() as i32,
                    bounds.width() as i32,
                    bounds.height() as i32,
                );
                popover_for_key.set_pointing_to(Some(&rect));
            } else {
                popover_for_key.set_pointing_to(None);
            }
            popover_for_key.popup();
            glib::Propagation::Stop
        }))
        .build();
    let shortcut_controller = gtk::ShortcutController::new();
    shortcut_controller.add_shortcut(menu_shortcut);
    widget.add_controller(shortcut_controller);
}
