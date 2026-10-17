use gtk4::gio;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;

use super::find_bar::Direction;
use super::{SqlEditor, toggle_line_comment};
use crate::application::{ShortcutOwner, local_shortcut_controller};

impl SqlEditor {
    /// The tab's `editor` group, the source view's keys for it, and the
    /// buttons' accessible keys.
    pub(super) fn install_actions(&self) {
        let actions = gio::SimpleActionGroup::new();
        let entry = |name: &'static str, act: fn(&SqlEditor)| {
            let weak = self.downgrade();
            gio::ActionEntry::<gio::SimpleActionGroup>::builder(name)
                .activate(move |_, _, _| {
                    if let Some(editor) = weak.upgrade() {
                        act(&editor);
                    }
                })
                .build()
        };
        actions.add_action_entries([
            entry("open-file", SqlEditor::open_file),
            entry("save", SqlEditor::save),
            entry("save-as", SqlEditor::save_as),
            entry("run", SqlEditor::run),
            entry("run-statement", SqlEditor::run_at_cursor),
            entry("cancel", SqlEditor::stop),
            entry("format", SqlEditor::format),
            entry("toggle-comment", |editor| toggle_line_comment(&editor.buffer())),
            entry("find", |editor| editor.imp().find_bar.open(false)),
            entry("find-replace", |editor| editor.imp().find_bar.open(true)),
            entry("find-next", |editor| editor.imp().find_bar.find(Direction::Next)),
            entry("find-previous", |editor| {
                editor.imp().find_bar.find(Direction::Previous)
            }),
        ]);
        set_cancel_enabled(&actions, false);
        self.insert_action_group("editor", Some(&actions));
        self.connect_run_state_changed(move |_, running| set_cancel_enabled(&actions, running));

        let imp = self.imp();
        imp.source_view
            .add_controller(local_shortcut_controller(ShortcutOwner::SqlEditor));
        // On the tab, so the find keys work from the find bar's entries too.
        self.add_controller(local_shortcut_controller(ShortcutOwner::SqlEditorTab));
        crate::ui::a11y::announce_key_shortcuts(&imp.run_button.get(), "editor.run");
        crate::ui::a11y::announce_key_shortcuts(&imp.stop_button.get(), "editor.cancel");
    }
}

/// Off while nothing runs, so Escape goes on to the view and its
/// completion popup.
fn set_cancel_enabled(actions: &gio::SimpleActionGroup, enabled: bool) {
    if let Some(cancel) = actions.lookup_action("cancel").and_downcast::<gio::SimpleAction>() {
        cancel.set_enabled(enabled);
    }
}
