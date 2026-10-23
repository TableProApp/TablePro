use gtk4::{self as gtk, prelude::*};

use super::super::display::CELL_MENU_OPTIONS_SLOT;
use super::{GridMenus, prepare_cell_menu};

pub(super) fn install(view: &gtk::ColumnView, menus: &GridMenus, empty: gtk::PopoverMenu) {
    let weak_view = view.downgrade();
    let menus = menus.clone();
    let gesture = gtk::GestureClick::builder()
        .button(gtk::gdk::BUTTON_SECONDARY)
        .propagation_phase(gtk::PropagationPhase::Capture)
        .build();
    gesture.connect_pressed(move |gesture, _, x, y| {
        let Some(view) = weak_view.upgrade() else { return };
        if let Some(popover) = popover_at(&view, &menus, &empty, x, y) {
            gesture.set_state(gtk::EventSequenceState::Claimed);
            popover.set_pointing_to(Some(&gtk::gdk::Rectangle::new(x as i32, y as i32, 1, 1)));
            popover.popup();
        }
    });
    view.add_controller(gesture);
}

pub(super) fn popover_at(
    view: &gtk::ColumnView,
    menus: &GridMenus,
    empty: &gtk::PopoverMenu,
    x: f64,
    y: f64,
) -> Option<gtk::PopoverMenu> {
    let mut widget = view.pick(x, y, gtk::PickFlags::DEFAULT)?;
    if widget == *view {
        return Some(empty.clone());
    }
    loop {
        if CELL_MENU_OPTIONS_SLOT.with(&widget, |_| ()).is_some() {
            if widget
                .downcast_ref::<crate::ui::cell_editor::CellEditor>()
                .is_some_and(|editor| editor.is_editing())
            {
                return None;
            }
            return CELL_MENU_OPTIONS_SLOT.with(&widget, |options| prepare_cell_menu(menus, view, &widget, options));
        }
        widget = widget.parent()?;
        if widget == *view {
            return None;
        }
    }
}
