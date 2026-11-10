use gtk4::gio;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;

use super::{SaveInput, StructureTab, StructureTabInput, TableInput};
use crate::application::{ShortcutOwner, local_shortcut_controller};

impl StructureTab {
    pub(super) fn install_actions(&self) {
        let imp = self.imp();
        let group = gio::SimpleActionGroup::new();
        let commands: [(_, _, _, fn() -> StructureTabInput); 4] = [
            ("save", &imp.save_button, "sensitive", || SaveInput::Save.into()),
            ("discard", &imp.discard_button, "sensitive", || {
                SaveInput::ConfirmDiscard.into()
            }),
            ("drop", &imp.drop_button, "visible", || {
                TableInput::DropTableRequested.into()
            }),
            ("stop", &imp.stop_button, "visible", || SaveInput::StopSaving.into()),
        ];
        for (name, button, property, message) in commands {
            let action = gio::SimpleAction::new(name, None);
            let sender = self.sender();
            action.connect_activate(move |_, _| sender.input(message()));
            button.bind_property(property, &action, "enabled").sync_create().build();
            group.add_action(&action);
        }
        self.insert_action_group("structure", Some(&group));
        let _ = imp.actions.set(group);
        self.add_controller(local_shortcut_controller(ShortcutOwner::StructureTab));
        crate::ui::a11y::announce_key_shortcuts(&imp.save_button.get(), "structure.save");
    }

    pub(crate) fn command_actions(&self) -> Option<&gio::SimpleActionGroup> {
        self.imp().actions.get()
    }

    pub(crate) fn save_action(&self) -> Option<gio::SimpleAction> {
        self.command_actions()?.lookup_action("save").and_downcast()
    }
}
