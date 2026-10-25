use gtk4::glib::translate::IntoGlib;
use gtk4::prelude::*;
use gtk4::{self as gtk, gdk, glib};

use super::{DataGrid, PinnedRow};
use crate::application::{ShortcutOwner, local_shortcut_controller};

/// The grid's keys, each through the `grid` action it names, so a
/// disabled action lets its key go on: Space selects the row when the
/// cell is no boolean, Return activates it when it cannot be edited, and
/// an open editor keeps every key.
///
/// GtkListFactoryWidget binds Return, Space and Menu in its class and
/// stops them, so the cell's keys are taken on the view in the capture
/// phase. The grid-wide keys bubble up to the grid itself, after a focused
/// editor had its turn, so they work from the detail pane and the find bar
/// too.
pub fn install(grid: &DataGrid) {
    let view = grid.column_view();
    view.add_controller(local_shortcut_controller(ShortcutOwner::GridCell));
    grid.add_controller(local_shortcut_controller(ShortcutOwner::Grid));
    view.add_controller(type_to_edit(grid));
    // A double click activates inside the row's own click handler, which
    // then grabs the focus and would take it from the editor or the pane
    // opened here, so they open once the click is handled, on the row it
    // was.
    view.connect_activate(glib::clone!(
        #[weak]
        grid,
        move |_, _| {
            let Some((row, column)) = grid
                .focused_cell()
                .and_then(|cell| Some((cell.row()?.pin(), cell.column())))
            else {
                return;
            };
            glib::idle_add_local_once(glib::clone!(
                #[weak]
                grid,
                move || grid.activate_cell(&row, column)
            ));
        }
    ));
}

/// Text typed on a cell that takes edits opens its editor and hands it
/// the key, so the editor's input method sees it: a dead key, a composed
/// character or a preedit starts in the editor. Space and keys with a
/// modifier never start one.
fn type_to_edit(grid: &DataGrid) -> gtk::EventControllerKey {
    let keys = gtk::EventControllerKey::new();
    let weak = grid.downgrade();
    keys.connect_key_pressed(move |controller, keyval, _, state| {
        let Some(grid) = weak.upgrade() else {
            return glib::Propagation::Proceed;
        };
        let modified = state
            .intersects(gdk::ModifierType::CONTROL_MASK | gdk::ModifierType::ALT_MASK | gdk::ModifierType::SUPER_MASK);
        let types = keyval.to_unicode().is_some_and(|c| !c.is_control() && c != ' ') || starts_composition(keyval);
        if modified || !types {
            return glib::Propagation::Proceed;
        }
        let Some(editor) = grid.edit().open_for_typing() else {
            return glib::Propagation::Proceed;
        };
        match controller.forward(&editor) {
            true => glib::Propagation::Stop,
            false => glib::Propagation::Proceed,
        }
    });
    keys
}

/// A dead key or Compose has no character of its own; the editor's input
/// method composes the next key with it. 0xfe50 to 0xfe93 is GDK's block
/// of dead keys.
fn starts_composition(keyval: gdk::Key) -> bool {
    (0xfe50..=0xfe93).contains(&keyval.into_glib()) || keyval == gdk::Key::Multi_key
}

impl DataGrid {
    /// Return on a cell no shortcut took, or a double click: edit the cell
    /// where it can be edited in place, else show its whole value in the
    /// detail pane, while the focus is still on it and its slot holds the
    /// row it held.
    fn activate_cell(&self, row: &PinnedRow, column: usize) {
        let Some(cell) = self
            .focused_cell()
            .filter(|cell| cell.column() == column && row.get().is_some_and(|row| cell.row().as_ref() == Some(row)))
        else {
            return;
        };
        if !self.edit().edit_cell(&cell) {
            self.show_details_for(column);
        }
    }
}

#[cfg(test)]
mod tests {
    use gtk4::gdk;

    use super::starts_composition;

    #[test]
    fn dead_keys_and_compose_start_a_composition() {
        assert!(starts_composition(gdk::Key::dead_grave));
        assert!(starts_composition(gdk::Key::dead_acute));
        assert!(starts_composition(gdk::Key::Multi_key));
        assert!(!starts_composition(gdk::Key::a));
        assert!(!starts_composition(gdk::Key::Return));
    }
}
