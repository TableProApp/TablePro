use gtk4 as gtk;
use gtk4::gio;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;

use super::{BrowseModel, BrowseTab, BrowseTabInput};
use crate::application::{ShortcutOwner, local_shortcut_controller};
use crate::services::tab_tracker_handle::TabTrackerHandle;

/// The `browse` actions whose state follows the tab. A disabled one lets
/// its key go on, and greys out the button that names it.
#[derive(Clone)]
pub(super) struct BrowseActions {
    pub(super) save: gio::SimpleAction,
    pub(super) undo: gio::SimpleAction,
    pub(super) redo: gio::SimpleAction,
    pub(super) insert_row: gio::SimpleAction,
    pub(super) delete_rows: gio::SimpleAction,
    pub(super) copy_rows: gio::SimpleAction,
    pub(super) clear_selection: gio::SimpleAction,
}

impl BrowseActions {
    pub(super) fn follow_tracker(&self, tracker: &TabTrackerHandle, saving: bool) {
        self.save.set_enabled(!saving && tracker.pending_count() > 0);
        self.undo.set_enabled(tracker.can_undo());
        self.redo.set_enabled(tracker.can_redo());
    }

    pub(super) fn follow_selection(&self, selected: u32) {
        self.copy_rows.set_enabled(selected > 0);
        // Clearing a single focused row strands the focus indicator.
        self.clear_selection.set_enabled(selected > 1);
    }
}

/// The tab's `browse` group, the tab's own keys for it and the keys its
/// buttons announce. The grid's keys go on each column view the tab
/// builds, through `install_grid_shortcuts`.
pub(super) fn install_browse_actions(tab: &BrowseTab) -> BrowseActions {
    let group = gio::SimpleActionGroup::new();
    let add = |name: &str, input: fn() -> BrowseTabInput| {
        let action = gio::SimpleAction::new(name, None);
        let weak = tab.downgrade();
        action.connect_activate(move |_, _| {
            if let Some(tab) = weak.upgrade() {
                tab.send(input());
            }
        });
        group.add_action(&action);
        action
    };
    add("filter", || BrowseTabInput::ToggleFilterStrip);
    add("refresh", || BrowseTabInput::RequestRefresh);
    add("paste-rows", || BrowseTabInput::PasteNotSupported);
    let imp = tab.imp();
    let previous = add("previous-page", || BrowseTabInput::PrevPage);
    imp.prev_button
        .bind_property("sensitive", &previous, "enabled")
        .sync_create()
        .build();
    let next = add("next-page", || BrowseTabInput::NextPage);
    imp.next_button
        .bind_property("sensitive", &next, "enabled")
        .sync_create()
        .build();
    let delete_rows = gio::SimpleAction::new("delete-rows", None);
    let weak = tab.downgrade();
    delete_rows.connect_activate(move |_, _| {
        let Some(tab) = weak.upgrade() else {
            return;
        };
        let rows = tab.read(BrowseModel::selected_rows).unwrap_or_default();
        tab.send(BrowseTabInput::DeleteRows(rows));
    });
    group.add_action(&delete_rows);
    let actions = BrowseActions {
        save: add("save", || BrowseTabInput::CommitSave),
        undo: add("undo", || BrowseTabInput::Undo),
        redo: add("redo", || BrowseTabInput::Redo),
        insert_row: add("insert-row", || BrowseTabInput::InsertRow),
        delete_rows,
        copy_rows: add("copy-rows", || BrowseTabInput::CopySelectedRowsAsTsv),
        clear_selection: add("clear-selection", || BrowseTabInput::ClearSelection),
    };
    for action in [
        &actions.save,
        &actions.undo,
        &actions.redo,
        &actions.insert_row,
        &actions.delete_rows,
        &actions.copy_rows,
        &actions.clear_selection,
    ] {
        action.set_enabled(false);
    }
    tab.insert_action_group("browse", Some(&group));
    tab.add_controller(local_shortcut_controller(ShortcutOwner::BrowseTab));
    for (button, action) in [
        (&imp.insert_button, "browse.insert-row"),
        (&imp.delete_button, "browse.delete-rows"),
        (&imp.filter_button, "browse.filter"),
        (&imp.prev_button, "browse.previous-page"),
        (&imp.next_button, "browse.next-page"),
        (&imp.save_button, "browse.save"),
    ] {
        crate::ui::a11y::announce_key_shortcuts(&button.get(), action);
    }
    actions
}

pub(super) fn install_grid_shortcuts(view: &gtk::ColumnView) {
    view.add_controller(local_shortcut_controller(ShortcutOwner::BrowseGrid));
}
