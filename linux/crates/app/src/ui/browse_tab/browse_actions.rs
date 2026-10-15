use gtk4 as gtk;
use gtk4::gio;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;

use super::{
    BrowseModel, BrowseTab, BrowseTabInput, ClipboardInput, EditInput, PagingInput, SaveInput, SelectionInput,
};
use crate::application::{ShortcutOwner, local_shortcut_controller};
use crate::i18n::gettext;
use crate::services::tab_tracker_handle::TabTrackerHandle;
use crate::ui::a11y::{announce_key_shortcuts, describe_icon_button};

const ACTION_GROUP: &str = "browse";

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
    add("filter", || PagingInput::ToggleFilterStrip.into());
    add("refresh", || PagingInput::RequestRefresh.into());
    add("paste-rows", || ClipboardInput::PasteNotSupported.into());
    let previous = add("previous-page", || PagingInput::PrevPage.into());
    let next = add("next-page", || PagingInput::NextPage.into());
    tab.imp().pager_bar.follow_page_actions(ACTION_GROUP, &previous, &next);
    let delete_rows = gio::SimpleAction::new("delete-rows", None);
    let weak = tab.downgrade();
    delete_rows.connect_activate(move |_, _| {
        let Some(tab) = weak.upgrade() else {
            return;
        };
        let rows = tab.read(BrowseModel::selected_rows).unwrap_or_default();
        tab.send(EditInput::DeleteRows(rows));
    });
    group.add_action(&delete_rows);
    let actions = BrowseActions {
        save: add("save", || SaveInput::CommitSave.into()),
        undo: add("undo", || EditInput::Undo.into()),
        redo: add("redo", || EditInput::Redo.into()),
        insert_row: add("insert-row", || EditInput::InsertRow.into()),
        delete_rows,
        copy_rows: add("copy-rows", || ClipboardInput::CopySelectedRowsAsTsv.into()),
        clear_selection: add("clear-selection", || SelectionInput::ClearSelection.into()),
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
    tab.imp().pending_bar.announce_save_keys(ACTION_GROUP, &actions.save);
    tab.insert_action_group(ACTION_GROUP, Some(&group));
    tab.add_controller(local_shortcut_controller(ShortcutOwner::BrowseTab));
    actions
}

/// Names the icon buttons and gives every button the keys of its action.
/// Run as the tab is built, so the names never wait on its actions. The
/// pager and the pending changes bar name their own.
pub(super) fn describe_buttons(tab: &BrowseTab) {
    let imp = tab.imp();
    for (button, label, action) in [
        (&imp.insert_button, gettext("Insert Row"), Some("browse.insert-row")),
        (
            &imp.delete_button,
            gettext("Delete Selected Rows"),
            Some("browse.delete-rows"),
        ),
        (&imp.export_button, gettext("Export Rows…"), None),
    ] {
        describe_icon_button(&button.get(), &label, action);
    }
    announce_key_shortcuts(&imp.filter_button.get(), "browse.filter");
}

pub(super) fn install_grid_shortcuts(view: &gtk::ColumnView) {
    view.add_controller(local_shortcut_controller(ShortcutOwner::BrowseGrid));
}
