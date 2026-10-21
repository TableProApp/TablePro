use gtk4::gio;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use libadwaita as adw;
use libadwaita::prelude::*;

use super::find_bar::Direction;
use super::run_scope::ScopedText;
use super::{OpenTransaction, SqlEditor, toggle_line_comment};
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
            entry("cancel", SqlEditor::close_popup_or_stop),
            entry("format", SqlEditor::format),
            entry("toggle-comment", |editor| toggle_line_comment(&editor.buffer())),
            entry("find", |editor| editor.imp().find_bar.open(false)),
            entry("find-replace", |editor| editor.imp().find_bar.open(true)),
            entry("find-next", |editor| editor.imp().find_bar.find(Direction::Next)),
            entry("find-previous", |editor| {
                editor.imp().find_bar.find(Direction::Previous)
            }),
            entry("commit", SqlEditor::commit),
            entry("roll-back", SqlEditor::confirm_roll_back),
        ]);
        sync_run_actions(&actions, false, None);
        self.insert_action_group("editor", Some(&actions));
        self.connect_run_state_changed(move |editor, running| {
            sync_run_actions(&actions, running, editor.open_transaction());
        });

        let imp = self.imp();
        imp.source_view
            .add_controller(local_shortcut_controller(ShortcutOwner::SqlEditor));
        // On the tab, so the find keys work from the find bar's entries too.
        self.add_controller(local_shortcut_controller(ShortcutOwner::SqlEditorTab));
        crate::ui::a11y::announce_key_shortcuts(&imp.run_button.get(), "editor.run");
        crate::ui::a11y::announce_key_shortcuts(&imp.stop_button.get(), "editor.cancel");
        crate::ui::a11y::announce_key_shortcuts(
            imp.source_view.upcast_ref::<gtk4::Widget>(),
            "paned.cycle-child-focus",
        );
    }
}

impl SqlEditor {
    // Sent as typed SQL is, so the results, the history and the
    // transaction line follow it. The buffer keeps the user's script.
    fn commit(&self) {
        self.end_transaction("COMMIT");
    }

    fn roll_back(&self) {
        self.end_transaction("ROLLBACK");
    }

    fn end_transaction(&self, sql: &str) {
        self.execute(ScopedText {
            text: sql.to_owned(),
            base_char: 0,
        });
    }

    fn confirm_roll_back(&self) {
        let dialog = adw::AlertDialog::new(
            Some(&crate::i18n::gettext("Roll Back the Transaction?")),
            Some(&crate::i18n::gettext("Its uncommitted changes are discarded.")),
        );
        dialog.add_response("cancel", &crate::i18n::gettext("Cancel"));
        dialog.add_response("roll-back", &crate::i18n::gettext("Roll Back"));
        dialog.set_response_appearance("roll-back", adw::ResponseAppearance::Destructive);
        dialog.set_default_response(Some("cancel"));
        dialog.set_close_response("cancel");
        let weak = self.downgrade();
        dialog.connect_response(Some("roll-back"), move |_, _| {
            if let Some(editor) = weak.upgrade() {
                editor.roll_back();
            }
        });
        dialog.present(Some(self));
    }

    /// Escape while a query runs. The stop key's controller runs before
    /// the view's own, so a popup the view has open, such as the
    /// completion list, is closed here first, as the view's Escape would.
    fn close_popup_or_stop(&self) {
        if !close_view_popups(&self.imp().source_view.get()) {
            self.stop();
        }
    }
}

/// GtkSourceView parents its completion list and other assistants to
/// the view as popovers, and its Escape hides every visible one.
fn close_view_popups(view: &impl IsA<gtk4::Widget>) -> bool {
    let mut closed = false;
    let mut child = view.as_ref().first_child();
    while let Some(widget) = child {
        child = widget.next_sibling();
        if widget.is::<gtk4::Popover>() && widget.is_visible() {
            widget.set_visible(false);
            closed = true;
        }
    }
    closed
}

/// Cancel is off while nothing runs, so Escape goes on to the view and
/// its completion popup. The session takes one run at a time, so a
/// commit or rollback waits for the run in flight.
fn sync_run_actions(actions: &gio::SimpleActionGroup, running: bool, open: Option<OpenTransaction>) {
    set_enabled(actions, "cancel", running);
    set_enabled(actions, "roll-back", !running && open.is_some());
    set_enabled(actions, "commit", !running && open == Some(OpenTransaction::Open));
}

fn set_enabled(actions: &gio::SimpleActionGroup, name: &str, enabled: bool) {
    if let Some(action) = actions.lookup_action(name).and_downcast::<gio::SimpleAction>() {
        action.set_enabled(enabled);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// GtkSourceView's completion list is a popover child of the view,
    /// which GtkTextView will not take from a test; any widget holds
    /// one the same way.
    #[gtk4::test]
    fn escape_closes_a_shown_popup_and_says_so() {
        let parent = gtk4::Box::new(gtk4::Orientation::Vertical, 0);
        let _window = crate::test_support::OwnedWindow::presented(gtk4::Window::builder().child(&parent).build());
        let popup = gtk4::Popover::new();
        popup.set_parent(&parent);
        assert!(!close_view_popups(&parent), "nothing was open");

        popup.set_visible(true);

        assert!(close_view_popups(&parent));
        assert!(!popup.is_visible());
        popup.unparent();
    }
}
