use gtk4::gio;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;

use super::{StructureTab, StructureTabInput};
use crate::application::{ShortcutOwner, local_shortcut_controller};

impl StructureTab {
    /// Ctrl+S saves as the Save button does, and only while it could.
    pub(super) fn install_actions(&self) {
        let imp = self.imp();
        let save = gio::SimpleAction::new("save", None);
        let sender = self.sender();
        save.connect_activate(move |_, _| sender.input(StructureTabInput::Save));
        imp.save_button
            .bind_property("sensitive", &save, "enabled")
            .sync_create()
            .build();
        let group = gio::SimpleActionGroup::new();
        group.add_action(&save);
        self.insert_action_group("structure", Some(&group));
        self.add_controller(local_shortcut_controller(ShortcutOwner::StructureTab));
        crate::ui::a11y::announce_key_shortcuts(&imp.save_button.get(), "structure.save");
    }
}
